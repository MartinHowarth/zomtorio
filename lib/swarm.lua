-- S10 — enemy generation: map/force tuning (R-GEN-3). Applies the denser, more
-- aggressive map settings (expansion + dense, frequent, tightly-packed unit
-- groups) on top of the prototype tuning done in data-final-fixes.
--
-- `game.map_settings` is the global, mutable settings table at runtime (a
-- LuaMapSettings). Its sub-tables (enemy_expansion, unit_group) are writable in
-- place and take effect
-- immediately, so applying at on_init / on_configuration_changed (and re-applying
-- when the expansion-rate setting changes) is enough — there is no per-surface
-- map_settings in 2.1; the table is map-global.
--
-- Scaling: the runtime-global "zomtorio-expansion-rate" setting (default 2.0,
-- read via config.expansion_rate()) cranks the aggression — higher rate => shorter
-- expansion cooldowns and a denser map. expansion_rate 1.0 leaves cooldowns at the
-- carry-over baseline; >1 shortens them proportionally.
--
-- The runtime swarm-event state machine (R-GEN-5: telegraphed, night-bound
-- assaults whose duration/frequency/intensity scale with evolution) is a SEPARATE
-- later step. swarm.on_tick is intentionally still a no-op stub here.

local config = require("lib.config")

local swarm = {}

-- Carry-over (1.1 control.lua init_settings) expansion baseline, in ticks, at
-- expansion_rate 1.0. The denser-than-vanilla values: small influence radii, far
-- shorter expansion cooldowns than vanilla (vanilla min/max = 14400/216000).
-- NOTE: 1.1's `min_base_spacing` is GONE in the 2.1 API (verified against
-- EnemyExpansionMapSettings) — base density is governed by the influence radii.
local EXPANSION_BASE = {
  max_expansion_distance         = 20,
  enemy_building_influence_radius = 1,
  friendly_base_influence_radius  = 1,
  min_expansion_cooldown         = 2 * 3600,  -- 2 minutes at rate 1.0
  max_expansion_cooldown         = 4 * 3600,  -- 4 minutes at rate 1.0
}

--- Apply the dense/aggressive map settings, scaled by expansion_rate. Idempotent:
--- it overwrites the same fields with the same derived values each call, so it can
--- be (re-)run at init, on configuration change, and on a setting change.
local function apply_map_settings()
  if not game then return end

  local rate = config.expansion_rate() or 2.0
  if rate <= 0 then rate = 1.0 end

  local ms = game.map_settings

  ---------------------------------------------------------------- expansion
  -- Denser bases that expand far more often than vanilla (R-GEN-3). Higher rate
  -- => shorter cooldowns (floored so they can't reach zero).
  local exp = ms.enemy_expansion
  if exp then
    exp.enabled                        = true
    exp.max_expansion_distance         = EXPANSION_BASE.max_expansion_distance
    exp.enemy_building_influence_radius = EXPANSION_BASE.enemy_building_influence_radius
    exp.friendly_base_influence_radius  = EXPANSION_BASE.friendly_base_influence_radius
    exp.min_expansion_cooldown =
      math.max(60, math.floor(EXPANSION_BASE.min_expansion_cooldown / rate))
    exp.max_expansion_cooldown =
      math.max(120, math.floor(EXPANSION_BASE.max_expansion_cooldown / rate))
  end

  ---------------------------------------------------------------- unit groups
  -- Frequent, large, TIGHTLY-PACKED groups: short gathering time, big size cap,
  -- small group radius (a dense swarm rather than a loose ring), members keep up.
  local ug = ms.unit_group
  if ug then
    ug.max_group_gathering_time     = 2 * 3600   -- frequent swarms
    ug.max_unit_group_size          = 500         -- large groups
    ug.max_gathering_unit_groups    = 10          -- fewer but bigger
    ug.max_group_radius             = 10          -- packed tight
    ug.min_group_radius             = 0
    ug.max_member_speedup_when_behind = 3.0       -- stragglers catch up
    ug.member_disown_distance       = 50
  end

  -- NOTE: `steering` is data-stage-only in 2.1 — LuaMapSettings does NOT expose it
  -- at runtime (verified: writing game.map_settings.steering errors "unknown
  -- path"). The dense-mass feel is instead delivered by the small unit_group radius
  -- above plus the x0.2 collision-box shrink in prototypes/tuning.lua.
end

--------------------------------------------------------------------- public

function swarm.on_init()
  apply_map_settings()
end

function swarm.on_configuration_changed()
  apply_map_settings()
end

--- Re-apply when the expansion-rate setting changes so the slider takes effect in
--- an existing save (R-GEN-7). Other settings here are derived from the same call,
--- so re-applying on any of ours is harmless; we gate on the expansion-rate key.
function swarm.on_runtime_setting_changed(event)
  if event and event.setting == "zomtorio-expansion-rate" then
    apply_map_settings()
  end
end

--- Test/helper: force a (re-)apply regardless of event plumbing.
function swarm.reset_state()
  apply_map_settings()
end

-- INTENTIONAL STUB: the telegraphed, evolution-scaled swarm-event state machine
-- (R-GEN-5) is the next build step. Until then there is no per-tick work to do.
function swarm.on_tick(event) end

return swarm
