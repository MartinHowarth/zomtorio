-- Cap-aware interception of ENGINE nest output (R-GEN-1/6, R-HORDE-6).
--
-- Biter nests/spawners spawn units directly via the engine; those spawns never
-- pass through lib/swarm's cap-aware spawner, so before this module a saturated
-- world just kept emitting unlimited LOOSE individuals near nests and no local
-- swarm ever formed. The engine raises `on_entity_spawned` whenever a spawner
-- emits a unit, handing us BOTH the spawner and the new unit -- so we can route
-- nest output through the same global cap and form local clusters at the nest.
--
-- Per spawn (Nauvis-only, R-SCOPE-1):
--   * global cap has room  -> keep the unit as a real individual and count it
--     against the cap. The engine's own max_count_of_owned_units (bumped in
--     prototypes/tuning.lua) bounds how many loose individuals a nest holds.
--   * cap full, local swarm < nest budget -> destroy the unit and FOLD +1 into the
--     nearest local cluster (release_from_spawner first so the freed slot lets the
--     nest keep producing to fill the swarm).
--   * cap full, local swarm >= nest budget -> the nest is saturated: destroy the
--     unit (throttle). This is what stops a nest whose attack never triggers from
--     growing a literally infinite swarm.
--
-- The nest budget is MEASURED on demand (sum of nearby cluster populations), not a
-- stored per-nest counter: a cluster that marches off to attack or dies leaves the
-- nest's radius, so the budget frees itself with zero attribution bookkeeping
-- (clusters move; a fixed nest->cluster mapping would be wrong the moment a swarm
-- advances). The budget scales with local chunk pollution between two settings
-- (base at no pollution up to max at heavy pollution), so busy nests sustain bigger
-- swarms while wilderness nests stay small.

local config  = require("lib.config")
local swarm   = require("lib.swarm")
local planets = require("lib.planets")
local tiers   = require("lib.tiers")
local util    = require("lib.util")

local nest = {}

-- Radius (tiles) around a spawner within which we measure the local swarm and
-- fold new output. Slightly larger than swarm.fold's own merge radius (8) so a
-- nest's spawns reliably accumulate into one growing cluster.
local NEST_RADIUS = 16

-- Chunk pollution at which the nest swarm budget reaches its configured MAX. Below
-- this it interpolates linearly from the base; at or above it, the max applies.
-- A module constant (only the base/max endpoints are player settings).
local POLLUTION_FOR_MAX = 1000

-- individual-zombie prototype name -> tier, for mapping a spawned unit to the tier
-- of cluster it folds into. Unknown enemies (spitters, modded) fall back by size
-- keyword to the nearest tier (the cluster abstraction is just "a blob of zombies").
local INDIVIDUAL_TO_TIER = {}
for tier, name in pairs(tiers.INDIVIDUAL) do
  INDIVIDUAL_TO_TIER[name] = tier
end

local function tier_of(name)
  local t = INDIVIDUAL_TO_TIER[name]
  if t then return t end
  if string.find(name, "behemoth") or string.find(name, "big") then return "big" end
  if string.find(name, "medium") then return "medium" end
  return "small"
end

--- biter vs spitter from the spawned unit's prototype name. The engine (vanilla,
--- evolution-gated logic) decides WHICH spawns; we only group a spitter into a
--- SPITTER swarm so it doesn't get absorbed into a biter swarm and vanish.
local function kind_of(name)
  return string.find(name, "spitter") and "spitter" or "biter"
end

-- Optional test override of the budget (runtime-global settings can't be written by
-- the separate test harness mod). nil in normal play -> the pollution-scaled budget.
local budget_override

--- The nest swarm budget at `pos`: interpolates between the base and max settings on
--- local chunk pollution (R-GEN: busier nests sustain bigger swarms).
local function nest_budget(surface, pos)
  if budget_override ~= nil then return budget_override end
  local base = config.nest_swarm_base() or 50
  local maxb = config.nest_swarm_max() or 1000
  if maxb < base then maxb = base end
  local pollution = 0
  local ok, p = pcall(function() return surface.get_pollution(pos) end)
  if ok and p then pollution = p end
  local frac = pollution / POLLUTION_FOR_MAX
  if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
  return base + (maxb - base) * frac
end

--- Total population of tracked clusters within NEST_RADIUS of `pos`, counting both
--- the day and night cluster forms (HORDE_ALL) so the measurement isn't fooled at
--- night when nearby swarms have been swapped to their night variant.
local function local_swarm_pop(surface, pos)
  local found = surface.find_entities_filtered {
    name = tiers.SWARM_ALL, position = pos, radius = NEST_RADIUS,
  }
  local total = 0
  for _, u in ipairs(found) do
    total = total + (swarm.pop_of(u) or 0)
  end
  return total
end

--- Route one engine-spawned nest unit through the global cap (see header).
--- control.lua dispatches on_entity_spawned here.
function nest.on_entity_spawned(event)
  local entity = event and event.entity
  if not (entity and entity.valid) then return end
  if entity.type ~= "unit" then return end
  local surface = entity.surface
  if not planets.is_active(surface) then return end
  if not util.is_enemy_force(entity.force) then return end

  -- Cap has room: leave it a real individual; it now counts against the cap.
  if swarm.cap_room() > 0 then
    swarm.track(entity)
    return
  end

  -- Cap full: this nest's output must fold into a local cluster -- unless the local
  -- swarm is already at its (pollution-scaled) budget, in which case throttle.
  local pos = entity.position
  if local_swarm_pop(surface, pos) >= nest_budget(surface, pos) then
    -- Saturated: drop the spawn. Deliberately NO release_from_spawner -- if the
    -- engine keeps counting this as owned and so holds the spawner off, that is
    -- exactly the throttle we want.
    entity.destroy()
    return
  end

  -- Fold +1 into the nearest local cluster of the same KIND (so a spitter forms a
  -- spitter swarm, not a biter one). Release first (pcall-guarded: the method is
  -- 2.1.7+ and only valid for spawner-owned units) so destroying the unit frees the
  -- spawner's slot and it keeps producing to fill the swarm.
  local tier = tier_of(entity.name)
  local kind = kind_of(entity.name)
  pcall(function() entity.release_from_spawner() end)
  entity.destroy()
  swarm.fold(surface, pos, 1, tier, util.ENEMY_FORCE, 0, kind)
end

--------------------------------------------------------------------- test API

--- Test-only: pin (or, with nil, release) the per-nest swarm budget. See
--- `budget_override`.
function nest.set_budget_override(n)
  budget_override = n
end

return nest
