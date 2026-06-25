-- S8 — swarm melee and the double-tap toggle (R-MELEE).
--
-- Base melee is the vanilla no-ammo attack and kills one zombie per hit
-- (R-MELEE-1). prototypes/melee-retype.lua retypes that punch to the custom
-- "zomtorio-zombie-melee" damage type so we can detect it unambiguously and react
-- enemy-only. The base type is NOT a horde multi-kill type, so a base punch on a
-- cluster removes exactly one population.
--
-- Two technologies grow it (R-MELEE-2). When a "zomtorio-zombie-melee" hit lands
-- on an enemy and the attacking force has Tier 1, we apply a scripted AoE: deal
-- the "zomtorio-swarm-melee" damage type (a horde multi-kill type) to the target
-- and nearby ENEMY-force entities. Tier 2 makes that magnitude larger. The AoE is
-- enemy-only by construction — we only ever damage enemy-force entities, so there
-- is no friendly fire (R-MELEE-4) — and uses its own type so it never re-triggers
-- itself (no recursion).
--
-- Double-tap (R-MELEE-5) is a per-player toggle (shortcut, unlocked by Tier 2):
-- while on, melee kills are dead-dead and drop no corpse. is_dead_dead() answers
-- that question for the corpse-drop paths.
--
-- Deliberately requires NEITHER horde NOR corpses: it only deals damage through
-- the engine (which routes through horde for clusters) and reads technologies.
-- horde and corpses require THIS module (one-way) to consult is_dead_dead — so
-- there is no require cycle.

local util = require("lib.util")

local melee = {}

-- The retyped player punch (the trigger we react to).
local BASE_MELEE_TYPE  = "zomtorio-zombie-melee"
-- The bonus AoE type we emit (a horde multi-kill type). Never reacted to.
local SWARM_MELEE_TYPE = "zomtorio-swarm-melee"

local TIER_1 = "zomtorio-swarm-melee-1"
local TIER_2 = "zomtorio-swarm-melee-2"
local SHORTCUT = "zomtorio-double-tap"

-- Radius the swarm-melee AoE reaches around the struck zombie. Small: melee is a
-- close-quarters mow-down, not a grenade.
local AOE_RADIUS = 2.5

-- AoE damage magnitudes, as multiples of a single small-biter's health so they
-- scale sensibly with the (S10) health curve. Tier 2 hits harder than Tier 1
-- (R-MELEE-2). Tuned by playtest later; the ordering is the contract.
local TIER_1_DAMAGE = 30
local TIER_2_DAMAGE = 80

--------------------------------------------------------------------- storage
-- storage.zomtorio.melee.double_tap : player_index -> true/false

local function state()
  storage.zomtorio = storage.zomtorio or {}
  local z = storage.zomtorio
  z.melee = z.melee or { double_tap = {} }
  z.melee.double_tap = z.melee.double_tap or {}
  return z.melee
end

-- Idempotent: only creates missing tables, never wipes live toggle state, so a
-- mod update doesn't reset every player's double-tap.
function melee.on_init()
  state()
end

--------------------------------------------------------------------- helpers

--- Has `force` researched a given tech? Defensive about missing prototypes.
local function researched(force, tech)
  if not (force and force.valid) then return false end
  local t = force.technologies[tech]
  return t ~= nil and t.researched
end

--------------------------------------------------------------------- swarm AoE

--- React to a base melee punch (R-MELEE-2). Only the retyped player punch on an
--- enemy-force target, and only when the attacker's force has Tier 1, triggers
--- the scripted swarm AoE. We NEVER react to SWARM_MELEE_TYPE itself (the AoE we
--- emit), so there is no recursion.
function melee.on_entity_damaged(event)
  if not event then return end
  local dtype = event.damage_type and event.damage_type.name
  if dtype ~= BASE_MELEE_TYPE then return end

  local entity = event.entity
  if not (entity and entity.valid) then return end
  if not util.is_enemy_force(entity.force) then return end  -- enemy-only

  -- The attacking character (so kills attribute to the player) and its force.
  local dealer = event.cause
  local force = event.force
    or (dealer and dealer.valid and dealer.force)
    or (entity.valid and game.forces.player)
  if not researched(force, TIER_1) then return end  -- Tier 1 gates any multi-kill

  local amount = researched(force, TIER_2) and TIER_2_DAMAGE or TIER_1_DAMAGE
  local surface = entity.surface
  local pos = entity.position
  if not (dealer and dealer.valid) then dealer = nil end

  -- Damage the struck zombie plus nearby enemies, ENEMY-FORCE ONLY (no friendly
  -- fire). On a cluster the swarm-melee type routes through horde (multi-kill);
  -- on individuals it damages/kills them directly.
  local targets = surface.find_entities_filtered {
    force = util.ENEMY_FORCE, position = pos, radius = AOE_RADIUS,
  }
  for _, e in ipairs(targets) do
    if e.valid and e.health and e.health > 0 then
      e.damage(amount, force, SWARM_MELEE_TYPE, dealer)
    end
  end
end

--------------------------------------------------------------------- double-tap

-- Test-only forced answer for is_dead_dead, set via set_double_tap_override. The
-- headless benchmark has no connected players, so a test can't toggle the
-- shortcut for a real player; this pins the double-tap answer deterministically.
-- nil in normal play -> the real per-player toggle is consulted.
local double_tap_override

--- Resolve the player_index behind a kill's `cause` (a character), or nil.
local function player_index_of(cause)
  if not (cause and cause.valid) then return nil end
  local player = cause.player  -- a character driven by a player exposes .player
  if player and player.valid then return player.index end
  return nil
end

--- Is double-tap currently on for this player? (Read by is_dead_dead.)
function melee.double_tap_on(player_index)
  if player_index == nil then return false end
  return state().double_tap[player_index] == true
end

--- Should this kill leave NO corpse (R-MELEE-5)? True only when the damage type
--- is a melee type AND the causing player has double-tap ON. Consulted by both
--- the individual (corpses.on_entity_died) and cluster (horde.on_entity_damaged)
--- corpse-drop paths so both kinds of melee kill are dead-dead under double-tap.
function melee.is_dead_dead(event)
  if not event then return false end
  local dtype = event.damage_type and event.damage_type.name
  if dtype ~= BASE_MELEE_TYPE and dtype ~= SWARM_MELEE_TYPE then return false end
  if double_tap_override ~= nil then return double_tap_override end
  return melee.double_tap_on(player_index_of(event.cause))
end

--- Toggle double-tap for the acting player when our shortcut is pressed, gated on
--- the unlocking tech being researched. Mirrors the new state to the shortcut's
--- toggled visual.
function melee.on_toggle_shortcut(event)
  if not event or event.prototype_name ~= SHORTCUT then return end
  local player = game.get_player(event.player_index)
  if not (player and player.valid) then return end
  if not researched(player.force, TIER_2) then return end  -- not yet unlocked

  local s = state()
  local now = not (s.double_tap[event.player_index] == true)
  s.double_tap[event.player_index] = now
  player.set_shortcut_toggled(SHORTCUT, now)
end

--- Make the double-tap shortcut available to a force's players once Tier 2 is
--- researched (R-MELEE-5: unlocked by a melee technology). Cheap and idempotent.
function melee.on_research_finished(event)
  local research = event and event.research
  if not (research and research.valid) then return end
  if research.name ~= TIER_2 then return end
  local force = research.force
  if not (force and force.valid) then return end
  for _, player in pairs(force.players) do
    if player.valid then player.set_shortcut_available(SHORTCUT, true) end
  end
end

--- Drop a removed player's toggle state so the table can't accumulate stale keys.
function melee.on_player_removed(event)
  if not event then return end
  state().double_tap[event.player_index] = nil
end

--------------------------------------------------------------------- test API

--- Test-only: force the double-tap answer (true/false) regardless of player, or
--- release it with nil. Lets the headless harness exercise is_dead_dead without a
--- connected player. See `double_tap_override` above.
function melee.set_double_tap_override(v)
  double_tap_override = v
end

--- Test-only: hard-reset toggle state. on_init is intentionally idempotent
--- (preserves live state across a config change), so tests call this for a clean
--- slate between cases.
function melee.reset_state()
  storage.zomtorio = storage.zomtorio or {}
  storage.zomtorio.melee = { double_tap = {} }
  double_tap_override = nil
end

return melee
