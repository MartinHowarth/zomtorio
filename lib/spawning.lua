-- S3 — buildings become zombie sources on death (R-DEATH).
--
-- When a non-wall building is destroyed by something on the infected (enemy)
-- force, it spawns zombies equal to its total-raw solid cost, all of the BASIC
-- tier. The zombies spawn on the enemy force and route through the unified
-- cap-aware spawner (R-HORDE-6).
--
-- NOTE (playtest decision, overrides R-DEATH-4): building deaths no longer pick a
-- stronger zombie tier from oil/ingredients. Spawning high-tier biters from
-- buildings proved too strong; the threat comes from the SHEER NUMBERS (a building
-- yields its whole raw cost in basic zombies), not from individual strength. So
-- every building-death zombie is the basic tier, and only the COUNT scales.
--
-- Player-caused destruction must NOT spawn zombies (R-DEATH-1). Deconstruction,
-- self-mining and blueprint removal fire on_player/robot_mined_entity (NOT
-- on_entity_died), so they are naturally excluded here. The remaining player
-- case is the player's OWN weapons killing their OWN building, which DOES fire
-- on_entity_died — so we explicitly gate on the death being enemy-caused.

local raw_cost = require("lib.raw_cost")
local swarm    = require("lib.swarm")
local planets  = require("lib.planets")
local util     = require("lib.util")

local spawning = {}

-- All building-death zombies are the basic tier (see playtest note above).
local DEATH_TIER = "small"

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

  -- Count = total-raw solid cost (R-DEATH-2). Fluids don't add to the count.
  local solid = raw_cost.for_entity(entity.name)
  if solid <= 0 then return end  -- non-buildings (trees/rocks) decompose to 0

  -- Count = total-raw solid cost (R-DEATH-2). The overall swarm-size multiplier
  -- (R-HORDE-7) is applied centrally in swarm.spawn, which also guarantees a
  -- qualifying building always yields at least one zombie. Always the basic tier
  -- (playtest decision): the threat is numbers, not per-zombie strength.
  swarm.spawn(entity.surface, entity.position, solid, DEATH_TIER, util.ENEMY_FORCE)
end

return spawning
