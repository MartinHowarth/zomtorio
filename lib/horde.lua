-- S2 — the horde population model and the unified cap-aware spawner.
--
-- A "horde unit" is one entity that stands in for N individual zombies
-- (population kept in storage; health = pop x single-zombie health). This keeps
-- enormous effective numbers cheap (R-HORDE-2/3).
--
-- On hit (R-HORDE-4/5): a normal hit kills one zombie's worth; an explosive (or,
-- later, upgraded-melee) hit kills floor(damage / single-zombie-health). If the
-- dynamic cap has room and a player is near, the cluster bursts into individuals;
-- otherwise it just loses population. The script alone destroys the unit, at
-- population 0 — the prototype carries huge health headroom so the engine's own
-- damage never pre-empts this (see prototypes/entities.lua).
--
-- spawn() is the single entry point every zombie source routes through
-- (R-HORDE-6 / R-GEN-6): it creates individuals up to the dynamic cap, folding
-- any overflow into higher-population horde units rather than discarding it.

local config  = require("lib.config")
local tiers   = require("lib.tiers")
local corpses = require("lib.corpses")
local melee   = require("lib.melee")
local util    = require("lib.util")

local horde = {}

-- Damage types that multi-kill in a swarm (R-HORDE-5). "explosion" is the
-- explosive rule; "zomtorio-swarm-melee" is the S8 tech-gated swarm-melee AoE
-- (lib/melee). The BASE punch "zomtorio-zombie-melee" is deliberately ABSENT:
-- unupgraded melee kills exactly one (R-MELEE-1).
local MULTI_KILL_TYPES = { explosion = true, ["zomtorio-swarm-melee"] = true }

-- A burst (R-HORDE-4) only triggers when a character is within this radius, so
-- abstract clusters only "become real" near a player who'd actually see them.
local BURST_RADIUS = 32

-- Cap the population of a single cluster so absurd counts (e.g. a megabase
-- building's total-raw) become a handful of dense clusters rather than one
-- entity claiming an implausible health value. Kept simple: split into clusters
-- of at most this each.
local MAX_CLUSTER_POP = 1000

--------------------------------------------------------------------- storage
-- storage.zomtorio.horde            : unit_number -> { pop, tier }
-- storage.zomtorio.individuals      : unit_number -> true  (zombies WE spawned)
-- storage.zomtorio.individual_count : running size of the above (cap accounting)

local function state()
  storage.zomtorio = storage.zomtorio or {}
  local z = storage.zomtorio
  z.horde = z.horde or {}
  z.individuals = z.individuals or {}
  z.individual_count = z.individual_count or 0
  return z
end

-- Idempotent: only creates missing tables, never wipes live state. control.lua
-- runs this on BOTH new game and on_configuration_changed, so a mod update must
-- not orphan the clusters / cap-count already present in an existing save.
function horde.on_init()
  state()
end

--------------------------------------------------------------------- helpers

--- Single-zombie health for a tier, read live from the individual's prototype so
--- it auto-tracks the S10 health tuning. Falls back to 1 defensively.
--- (2.1: LuaEntityPrototype.max_health was replaced by get_max_health(quality?).)
local function single_health(tier)
  local proto = prototypes.entity[tiers.INDIVIDUAL[tier]]
  return (proto and proto.get_max_health()) or 1
end

--- Health a cluster of `pop` should display: tracks population without ever
--- exceeding the entity's ceiling (so setting it never errors), and stays
--- positive so the engine doesn't kill the unit between our hits.
local function pop_health(entity, pop, tier)
  local h = pop * single_health(tier)
  local max = entity.max_health  -- 2.1: readable directly off the LuaEntity
  if h < 1 then h = 1 end
  if h > max then h = max end
  return h
end

-- Optional cap override. Runtime-global settings can only be written by their
-- owning mod, so the test harness (a separate mod) can't set the cap setting;
-- this single internal hook lets a test pin the cap deterministically. nil in
-- normal play -> the live setting is used.
local cap_override

--- The dynamic individual-zombie cap (R-HORDE-6). Defensive default if unset.
local function zombie_cap()
  if cap_override ~= nil then return cap_override end
  return config.zombie_cap() or 1000
end

--- Spare capacity for individual zombies before the cap.
local function cap_room()
  return math.max(0, zombie_cap() - state().individual_count)
end

--- True if a character (a stand-in for "a player") is within BURST_RADIUS.
local function character_near(surface, pos)
  if not (surface and surface.valid) then return false end
  local found = surface.find_entities_filtered {
    type = "character", position = pos, radius = BURST_RADIUS, limit = 1,
  }
  return #found > 0
end

--- Register an individual zombie we created so the cap counts it exactly.
local function track_individual(entity)
  local z = state()
  if entity and entity.valid and not z.individuals[entity.unit_number] then
    z.individuals[entity.unit_number] = true
    z.individual_count = z.individual_count + 1
  end
end

--- Create one horde-unit entity holding `pop`, record it, size its health.
local function create_cluster(surface, pos, pop, tier, force)
  local name = tiers.HORDE[tier]
  local place = surface.find_non_colliding_position(name, pos, 16, 0.5) or pos
  local unit = surface.create_entity { name = name, position = place, force = force }
  if not (unit and unit.valid) then return nil end
  state().horde[unit.unit_number] = { pop = pop, tier = tier }
  unit.health = pop_health(unit, pop, tier)
  return unit
end

--------------------------------------------------------------------- public

--- Unified spawner (R-HORDE-6 / R-GEN-6). Create `count` zombies of `tier` for
--- `force` near `pos` on `surface`: individuals up to the dynamic cap, with all
--- overflow folded into horde unit(s). Never discards zombies.
function horde.spawn(surface, pos, count, tier, force)
  count = math.floor(count or 0)
  if count <= 0 then return end
  if not (surface and surface.valid) then return end
  if not tiers.is_valid(tier) then tier = "small" end
  force = force or util.ENEMY_FORCE

  -- 1/2. Real individuals up to the cap.
  local make_individuals = math.min(count, cap_room())
  local individual_name = tiers.INDIVIDUAL[tier]
  local made = 0
  for _ = 1, make_individuals do
    local place = surface.find_non_colliding_position(individual_name, pos, 16, 0.5) or pos
    local biter = surface.create_entity {
      name = individual_name, position = place, force = force,
    }
    if biter and biter.valid then
      track_individual(biter)
      made = made + 1
    end
  end

  -- 3. Fold the remainder into horde unit(s), splitting so no one cluster holds
  -- an absurd population. Never discard zombies.
  local remainder = count - made
  while remainder > 0 do
    local pop = math.min(remainder, MAX_CLUSTER_POP)
    create_cluster(surface, pos, pop, tier, force)
    remainder = remainder - pop
  end
end

--- Handle a hit on one of our horde units (R-HORDE-4/5). Dispatched for ALL
--- damage right now, so the not-ours early-out is kept cheap.
function horde.on_entity_damaged(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  if tiers.HORDE_TO_TIER[entity.name] == nil then return end  -- not a horde unit

  local z = state()
  local rec = z.horde[entity.unit_number]
  if rec == nil then return end  -- untracked horde unit: let it die normally
  local tier = rec.tier

  local single = single_health(tier)
  local dtype = event.damage_type and event.damage_type.name
  local kills
  if dtype and MULTI_KILL_TYPES[dtype] then
    -- Use damage actually DEALT (post-resistance): horde units inherit the
    -- biter's resistances, so original_damage_amount would over-count kills.
    local dealt = event.final_damage_amount or event.original_damage_amount or 0
    kills = math.max(1, math.floor(dealt / single))
  else
    kills = 1
  end

  local surface, pos, force = entity.surface, entity.position, entity.force

  -- Double-tap (R-MELEE-5): a melee kill while double-tap is on is dead-dead, so
  -- the killed population leaves no corpse — same rule as for individual zombies.
  local no_corpse = melee.is_dead_dead(event)

  -- Burst: cap has room AND a player is near -> the cluster becomes real. The
  -- killed zombies are gone; the survivors spawn as individuals (R-HORDE-4).
  if cap_room() > 0 and character_near(surface, pos) then
    local survivors = rec.pop - kills
    z.horde[entity.unit_number] = nil
    entity.destroy()
    if survivors > 0 then
      horde.spawn(surface, pos, survivors, tier, force)
    end
    -- The zombies the hit killed drop corpses (skipped for flame/explosion/
    -- double-tap); a hit can't kill more than the cluster held.
    corpses.drop(surface, pos, math.min(kills, rec.pop), dtype, no_corpse)
    return
  end

  -- Otherwise lose population. The script is the only thing that kills the unit.
  -- Corpses dropped = zombies ACTUALLY removed (a hit can't kill more than the
  -- cluster holds), skipped for flame/explosion (R-CORPSE-4) / double-tap.
  local removed = math.min(kills, rec.pop)
  rec.pop = rec.pop - kills
  if rec.pop <= 0 then
    z.horde[entity.unit_number] = nil
    entity.destroy()
  else
    entity.health = pop_health(entity, rec.pop, tier)
  end
  corpses.drop(surface, pos, removed, dtype, no_corpse)
end

--- Idempotent removal from our bookkeeping. Safe to call from several remove
--- paths (death, mined, scripted destroy) without double-counting: a
--- unit_number already forgotten is a no-op. A tracked individual leaves the cap
--- count; a horde unit has its record cleared.
local function forget(un)
  if un == nil then return end
  local z = state()
  if z.individuals[un] then
    z.individuals[un] = nil
    z.individual_count = math.max(0, z.individual_count - 1)
  elseif z.horde[un] then
    z.horde[un] = nil
  end
end

--- Death bookkeeping.
function horde.on_entity_died(event)
  local e = event.entity
  if e and e.valid then forget(e.unit_number) end
end

--- Bookkeeping for NON-death removals (mined, scripted destroy, platform mined),
--- so a tracked individual that vanishes without dying can't leak its cap slot.
function horde.on_removed(event)
  local e = event.entity
  if e and e.valid then forget(e.unit_number) end
end

--------------------------------------------------------------------- test API

--- Number of live individual zombies we've spawned (cap accounting).
function horde.active_count()
  return state().individual_count
end

--- Population a given horde-unit entity stands in for, or nil if not tracked.
function horde.pop_of(entity)
  if not (entity and entity.valid and entity.unit_number) then return nil end
  local rec = state().horde[entity.unit_number]
  return rec and rec.pop or nil
end

--- Exposed for tests/other stages that need the live single-zombie health.
function horde.single_health(tier)
  return single_health(tier)
end

--- Test-only: pin (or, with nil, release) the cap. See `cap_override` above.
function horde.set_cap_override(n)
  cap_override = n
end

--- Test-only: hard-reset all bookkeeping. Production on_init is intentionally
--- idempotent (preserves live state across a config change), so tests that need
--- a clean slate between cases call this instead.
function horde.reset_state()
  storage.zomtorio = storage.zomtorio or {}
  storage.zomtorio.horde = {}
  storage.zomtorio.individuals = {}
  storage.zomtorio.individual_count = 0
end

return horde
