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
-- S10b adds the runtime swarm-event state machine (R-GEN-5: telegraphed,
-- night-bound assaults whose duration/frequency/intensity scale with evolution)
-- plus the smaller night-escalation baseline (R-GEN-4), driven from swarm.on_tick.
-- The map-settings code (S10a) above is left untouched.

local config  = require("lib.config")
local planets = require("lib.planets")
local util    = require("lib.util")
local night   = require("lib.night")
local horde   = require("lib.horde")

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

----------------------------------------------------------- swarm-event tuning
--
-- One Nauvis day is ~25000 ticks; the dark (night) portion the events live in is
-- ~7500 ticks (the part where night.is_night reads true). surface.ticks_per_day
-- is read when exposed so a modified day-length is respected; otherwise these
-- constants stand in.
local DAY_TICKS   = 25000   -- full day/night cycle
local NIGHT_TICKS = 7500    -- the dark portion an event can occupy

-- Frequency (R-GEN-5): the interval between events shrinks with evolution AND
-- with the frequency setting. At evolution 0 / frequency 1 events are ~8 days
-- apart; at evolution 1 they collapse toward ~1 day apart. A higher frequency
-- setting scales the whole interval down (2x frequency => half the wait).
local INTERVAL_MAX_DAYS = 8.0   -- near evo 0
local INTERVAL_MIN_DAYS = 1.0   -- near evo 1

-- Telegraph lead (R-GEN-5): warn the players this far ahead of the scheduled
-- start so "a swarm approaches in N days" lands with time to prepare.
local TELEGRAPH_LEAD_TICKS = DAY_TICKS  -- ~one day's notice

-- Spawning cadence/intensity. The state machine itself runs every TICK_PERIOD
-- ticks; a burst happens every BURST_PERIOD ticks of an active event. Each burst
-- spawns BURST_BASE zombies scaled by intensity and evolution, capped so a single
-- tick's work stays bounded (the cap-aware spawner folds overflow into clusters).
local TICK_PERIOD  = 60     -- the on_tick self-throttle
local BURST_PERIOD = 60     -- one swarm burst per second of an active event
local SWARM_BURST_BASE = 40 -- zombies per burst at intensity 1 / evolution 0
local SWARM_BURST_CAP  = 600

-- Night-escalation baseline (R-GEN-4): a much smaller trickle on ordinary nights
-- (when no event is active), so nights are tenser than days but clearly below a
-- swarm event. One small burst per NIGHT_BURST_PERIOD ticks.
local NIGHT_BURST_PERIOD = 300  -- one trickle every ~5s of night
local NIGHT_BURST_BASE   = 4    -- attackers per trickle at multiplier 1 / evo 0
local NIGHT_BURST_CAP    = 60

-- Ring distance from an anchor (player/character) to spawn at, so zombies have to
-- close the distance and the swarm reads as "approaching" (R-GEN-5).
local SPAWN_RING_MIN = 40
local SPAWN_RING_MAX = 60

--------------------------------------------------------------------- overrides
-- Runtime-global settings can only be written by their owning mod, so the test
-- harness (a separate mod) can't drive these. These internal hooks let a test pin
-- behaviour deterministically; nil in normal play => the live setting / evolution.
local overrides = {}          -- { enabled, intensity, frequency, night_assault }
local evolution_override = nil

local function opt_enabled()
  if overrides.enabled ~= nil then return overrides.enabled end
  local v = config.swarm_events_enabled()
  if v == nil then return true end
  return v
end

local function opt_intensity()
  return overrides.intensity or config.swarm_intensity() or 1.0
end

local function opt_frequency()
  return overrides.frequency or config.swarm_frequency() or 1.0
end

local function opt_night_assault()
  return overrides.night_assault or config.night_assault_multiplier() or 1.5
end

--------------------------------------------------------------------- helpers

--- Per-surface enemy-force evolution (2.1: per-surface). Test override wins.
local function evolution(surface)
  if evolution_override ~= nil then return evolution_override end
  local enemy = game and game.forces and game.forces[util.ENEMY_FORCE]
  if not (enemy and surface and surface.valid) then return 0 end
  local ok, e = pcall(function() return enemy.get_evolution_factor(surface) end)
  return (ok and e) or 0
end

--- Length of one dark period (the window an event occupies), respecting a
--- modified day-length when the engine exposes it.
local function night_len(surface)
  if surface and surface.valid then
    local ok, tpd = pcall(function() return surface.ticks_per_day end)
    if ok and tpd and tpd > 0 then
      -- Keep NIGHT_TICKS's share (~30%) of whatever the day actually is.
      return math.floor(tpd * (NIGHT_TICKS / DAY_TICKS))
    end
  end
  return NIGHT_TICKS
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

--- The swarm-event state, created lazily. Stored in storage so it survives across
--- ticks and config changes.
local function state()
  storage.zomtorio = storage.zomtorio or {}
  local s = storage.zomtorio.swarm
  if not s then
    s = { next_event_tick = nil, warned = false, active = false,
          period_end_tick = nil, forced_until = nil }
    storage.zomtorio.swarm = s
  end
  return s
end

--------------------------------------------------------------- pure scheduling

--- Interval (ticks) until the next swarm event (R-GEN-5). PURE + testable: higher
--- evolution => shorter interval (linear from INTERVAL_MAX_DAYS at evo 0 to
--- INTERVAL_MIN_DAYS at evo 1); higher frequency => proportionally shorter.
function swarm.event_interval_ticks(evolution_factor, frequency)
  local e = clamp(evolution_factor or 0, 0, 1)
  local f = frequency or 1.0
  if f <= 0 then f = 1.0 end
  local days = INTERVAL_MAX_DAYS + (INTERVAL_MIN_DAYS - INTERVAL_MAX_DAYS) * e
  local ticks = (days * DAY_TICKS) / f
  -- Never let it collapse below a single dark period.
  return math.max(NIGHT_TICKS, math.floor(ticks))
end

--- Length (ticks) of the active spawning period (R-GEN-5). PURE + testable:
--- ~10% of a night at evolution 0 up to a FULL night at evolution 1.0
--- (linear: night * (0.1 + 0.9*evolution)), scaled by intensity, clamped to at
--- most one full night.
function swarm.spawning_period_ticks(evolution_factor, intensity)
  local e = clamp(evolution_factor or 0, 0, 1)
  local i = intensity or 1.0
  if i <= 0 then i = 1.0 end
  local frac = (0.1 + 0.9 * e) * i
  frac = clamp(frac, 0.05, 1.0)            -- never under a sliver, never over a night
  return math.floor(NIGHT_TICKS * frac)
end

--------------------------------------------------------------- spawn placement

--- A point on a ring SPAWN_RING_MIN..SPAWN_RING_MAX from `pos`, seeded by `tick`
--- so successive bursts come from different directions.
local function ring_point(pos, tick, salt)
  local angle = ((tick * 0.137) + (salt or 0) * 1.7) % (2 * math.pi)
  local r = SPAWN_RING_MIN + ((tick + (salt or 0) * 53) % (SPAWN_RING_MAX - SPAWN_RING_MIN))
  return { x = pos.x + math.cos(angle) * r, y = pos.y + math.sin(angle) * r }
end

--- Route `count` zombies through the unified cap-aware spawner near each anchor
--- (R-GEN-6). With no characters present (headless) it's a no-op — the event
--- still tracks state, it simply has nowhere to spawn.
local function spawn_near_anchors(surface, count, tier, tick)
  if count <= 0 then return end
  local chars = surface.find_entities_filtered { type = "character" }
  local n = 0
  for _, c in pairs(chars) do
    if c.valid then
      n = n + 1
      local pos = ring_point(c.position, tick, n)
      horde.spawn(surface, pos, count, tier, util.ENEMY_FORCE)
    end
  end
end

--- Tier for swarm spawns: shift toward tougher zombies as evolution climbs
--- (R-GEN-5 intensity grows with evolution; R-BAL-2 tier mix).
local function swarm_tier(e)
  if e >= 0.9 then return "big" end
  if e >= 0.5 then return "medium" end
  return "small"
end

--------------------------------------------------------------------- public

function swarm.on_init()
  apply_map_settings()
  -- Seed the event schedule without wiping live state (preserve across a config
  -- change). Only fill a missing next_event_tick.
  local s = state()
  if s.next_event_tick == nil then
    local surface = game and game.surfaces and game.surfaces[util.HOME_SURFACE]
    local e = evolution(surface)
    s.next_event_tick = (game and game.tick or 0)
      + swarm.event_interval_ticks(e, opt_frequency())
    s.warned = false
    s.active = false
    s.period_end_tick = nil
  end
end

function swarm.on_configuration_changed()
  apply_map_settings()
  swarm.on_init()  -- ensure the event state exists; does not wipe live state
end

--- Re-apply when the expansion-rate setting changes so the slider takes effect in
--- an existing save (R-GEN-7). Other settings here are derived from the same call,
--- so re-applying on any of ours is harmless; we gate on the expansion-rate key.
function swarm.on_runtime_setting_changed(event)
  if event and event.setting == "zomtorio-expansion-rate" then
    apply_map_settings()
  end
end

--- Per-tick entry (control.lua fans this out). Self-throttled to TICK_PERIOD.
--- Drives the swarm-event state machine (R-GEN-5) and, on ordinary nights, the
--- smaller night-escalation baseline (R-GEN-4). Nauvis-only (R-SCOPE-1).
function swarm.on_tick(event)
  if event.tick % TICK_PERIOD ~= 0 then return end

  -- R-GEN-4 (night escalation) is baseline pressure independent of the
  -- swarm-event on/off flag (R-GEN-5); only the event branch below is gated on it.
  local surface = game.surfaces[util.HOME_SURFACE]
  if not (surface and surface.valid and planets.is_active(surface)) then return end

  local s = state()
  local tick = event.tick
  local e = evolution(surface)
  local night_now = night.is_night(surface)

  ------------------------------------------------------- swarm event (R-GEN-5)
  -- Process the active branch whenever an event is running, even if the on/off
  -- setting is disabled: a manually forced event (swarm.force_event) must still
  -- run and clean up. Only the SCHEDULING of new events is gated on the setting.
  if opt_enabled() or s.active then
    if s.next_event_tick == nil then
      s.next_event_tick = tick + swarm.event_interval_ticks(e, opt_frequency())
    end

    if s.active then
      -- Spawn at a greatly amplified rate while active (R-GEN-5 / R-GEN-6).
      if tick % BURST_PERIOD == 0 then
        local count = math.floor(SWARM_BURST_BASE * opt_intensity() * (1 + 2 * e))
        count = clamp(count, 1, SWARM_BURST_CAP)
        spawn_near_anchors(surface, count, swarm_tier(e), tick)
      end
      -- End at period_end OR at dawn — "at most one full night" (R-GEN-5). A
      -- FORCED event ignores the dawn end until its forced window elapses, so a
      -- debug trigger works in daylight too.
      local forced = s.forced_until ~= nil and tick < s.forced_until
      if tick >= (s.period_end_tick or tick) or (not night_now and not forced) then
        s.active = false
        s.period_end_tick = nil
        s.forced_until = nil
        s.warned = false
        s.next_event_tick = tick + swarm.event_interval_ticks(e, opt_frequency())
      end
    else
      -- Telegraph once, a lead-time before the scheduled start (R-GEN-5).
      if not s.warned and s.next_event_tick - tick <= TELEGRAPH_LEAD_TICKS then
        local remaining = math.max(0, s.next_event_tick - tick)
        local days = math.max(1, math.ceil(remaining / DAY_TICKS))
        game.print("A swarm approaches in " .. days .. (days == 1 and " day" or " days"))
        s.warned = true
      end
      -- Begin only once due AND it is night (R-GEN-5 night-bound start).
      if tick >= s.next_event_tick and night_now then
        s.active = true
        s.period_end_tick = tick + swarm.spawning_period_ticks(e, opt_intensity())
      end
    end
  end

  ---------------------------------------------- night escalation (R-GEN-4)
  -- Baseline night pressure: a small trickle on ordinary nights, never while a
  -- swarm event is active (so the spike stays clearly bigger). Scales with the
  -- night-assault multiplier and evolution, kept well below a swarm burst.
  if night_now and not s.active and tick % NIGHT_BURST_PERIOD == 0 then
    local count = math.floor(NIGHT_BURST_BASE * opt_night_assault() * (1 + e))
    count = clamp(count, 1, NIGHT_BURST_CAP)
    spawn_near_anchors(surface, count, swarm_tier(e), tick)
  end
end

--- Force a horde (telegraphed attack-wave; "swarm event" in the code) to start
--- RIGHT NOW, regardless of the schedule, the on/off setting, or time of day —
--- the debug/console trigger (control.lua registers `/zomtorio-horde` for it).
--- `minutes` overrides the spawning-period length; nil uses the evolution-scaled
--- default. Returns the duration in ticks.
function swarm.force_event(minutes)
  local s = state()
  local surface = game and game.surfaces and game.surfaces[util.HOME_SURFACE]
  local tick = (game and game.tick) or 0
  local e = evolution(surface)
  local dur
  if minutes and minutes > 0 then
    dur = math.floor(minutes * 3600)
  else
    dur = swarm.spawning_period_ticks(e, opt_intensity())
  end
  s.active = true
  s.warned = true                 -- already "telegraphed" (it's manual)
  s.period_end_tick = tick + dur
  s.forced_until = tick + dur     -- run day or night until this tick
  s.next_event_tick = nil
  return dur
end

--------------------------------------------------------------------- test API

--- Test/helper: re-apply map settings AND reset the event state machine to a
--- known baseline (S10a only reset map settings; S10b repurposes this to cover
--- both, so a test gets a clean slate). Clears overrides too.
function swarm.reset_state()
  apply_map_settings()
  overrides = {}
  evolution_override = nil
  storage.zomtorio = storage.zomtorio or {}
  storage.zomtorio.swarm = {
    next_event_tick = (game and game.tick or 0)
      + swarm.event_interval_ticks(0, 1.0),
    warned = false,
    active = false,
    period_end_tick = nil,
    forced_until = nil,
  }
end

--- Test-only: pin individual settings (each nil => live setting).
function swarm.set_overrides(o)
  o = o or {}
  overrides.enabled       = o.enabled
  overrides.intensity     = o.intensity
  overrides.frequency     = o.frequency
  overrides.night_assault = o.night_assault
end

--- Test-only: pin (or, with nil, release) the per-surface evolution factor.
function swarm.set_evolution_override(n)
  evolution_override = n
end

--- Test-only: schedule the next event at an absolute tick (and clear the
--- telegraph flag so the warning can re-fire for that scheduled time).
function swarm.set_next_event_tick(t)
  local s = state()
  s.next_event_tick = t
  s.warned = false
end

--- Test-only: read the live event state for assertions.
function swarm.get_state()
  local s = state()
  return {
    next_event_tick = s.next_event_tick,
    warned          = s.warned,
    active          = s.active,
    period_end_tick = s.period_end_tick,
    forced_until    = s.forced_until,
  }
end

--- Test/helper: exposed tuning constants so tests can assert ratios precisely.
swarm.NIGHT_TICKS = NIGHT_TICKS
swarm.DAY_TICKS   = DAY_TICKS

return swarm
