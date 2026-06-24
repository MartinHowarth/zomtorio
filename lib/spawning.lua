-- S3 — buildings become zombie sources on death (R-DEATH).
--
-- When a non-wall building is destroyed by something on the infected (enemy)
-- force, it spawns zombies equal to its total-raw solid cost, at a tier chosen
-- by how much oil its cost involved. The zombies spawn on the enemy force and
-- route through the unified cap-aware spawner (R-HORDE-6).
--
-- Player-caused destruction must NOT spawn zombies (R-DEATH-1). Deconstruction,
-- self-mining and blueprint removal fire on_player/robot_mined_entity (NOT
-- on_entity_died), so they are naturally excluded here. The remaining player
-- case is the player's OWN weapons killing their OWN building, which DOES fire
-- on_entity_died — so we explicitly gate on the death being enemy-caused.

local raw_cost = require("lib.raw_cost")
local horde    = require("lib.horde")
local planets  = require("lib.planets")
local config   = require("lib.config")
local util     = require("lib.util")

local spawning = {}

-- Oil thresholds for zombie tier (R-DEATH-4), carried over from the old mod:
-- a costly oil presence yields the strongest zombies, any oil yields medium,
-- and a purely-solid cost yields the basic tier.
local OIL_BIG_THRESHOLD    = 50
local OIL_MEDIUM_THRESHOLD = 0

--- Pick a zombie tier from the oil amount in the building's decomposed cost.
local function tier_for_oil(oil)
  if oil > OIL_BIG_THRESHOLD then return "big" end
  if oil > OIL_MEDIUM_THRESHOLD then return "medium" end
  return "small"
end

--- True if the death was caused by the enemy force — either the killing
--- force is the enemy force, or the (valid) cause entity is on it.
local function enemy_caused(event)
  if util.is_enemy_force(event.force) then return true end
  local cause = event.cause
  if cause and cause.valid and util.is_enemy_force(cause.force) then return true end
  return false
end

function spawning.on_entity_died(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end

  -- Nauvis-only in v1 (R-SCOPE-1).
  if not planets.is_active(entity.surface) then return end

  -- Don't cascade zombies from enemy structures dying.
  if util.is_enemy_force(entity.force) then return end

  -- Walls and gates are purely-defensive barriers: no spawn (R-DEATH-3).
  if entity.type == "wall" or entity.type == "gate" then return end

  -- Only enemy-caused deaths spawn zombies (R-DEATH-1).
  if not enemy_caused(event) then return end

  -- Count = total-raw solid cost, scaled by the horde-size multiplier
  -- (R-DEATH-2 / R-HORDE-7). Fluids don't add to the count (only the tier).
  local solid, oil = raw_cost.for_entity(entity.name)
  local count = math.floor(solid * (config.horde_size_multiplier() or 1) + 0.5)
  if count <= 0 then return end  -- non-buildings (trees/rocks) decompose to 0

  local tier = tier_for_oil(oil)
  horde.spawn(entity.surface, entity.position, count, tier, game.forces[util.ENEMY_FORCE])
end

return spawning
