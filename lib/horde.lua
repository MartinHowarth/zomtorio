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
local planets = require("lib.planets")
local tiers   = require("lib.tiers")
local corpses = require("lib.corpses")
local melee   = require("lib.melee")
local util    = require("lib.util")

local horde = {}

-- Damage types that multi-kill in a swarm (R-HORDE-5): explosive OR fire kill
-- floor(damage / single-zombie-health); everything else kills exactly one per hit.
-- "explosion"/"fire" are the area rules; "zomtorio-swarm-melee" is the S8 tech-gated
-- swarm-melee AoE (lib/melee). The BASE punch "zomtorio-zombie-melee" is deliberately
-- ABSENT: unupgraded melee kills exactly one (R-MELEE-1).
local MULTI_KILL_TYPES = { explosion = true, fire = true, ["zomtorio-swarm-melee"] = true }

-- A burst (R-HORDE-4) only triggers when a character is within this radius, so
-- abstract clusters only "become real" near a player who'd actually see them.
local BURST_RADIUS = 32

-- Cap the population of a single cluster so absurd counts (e.g. a megabase
-- building's total-raw) become a handful of dense clusters rather than one
-- entity claiming an implausible health value. Kept simple: split into clusters
-- of at most this each.
local MAX_CLUSTER_POP = 1000

-- Reverse of tiers.INDIVIDUAL: individual-zombie prototype name -> tier. Used by
-- the reanimation handler to recognise OUR hatched zombies and recover their tier.
local INDIVIDUAL_TO_TIER = {}
for tier, name in pairs(tiers.INDIVIDUAL) do
  INDIVIDUAL_TO_TIER[name] = tier
end

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

--- Health to keep a cluster at: its FULL (huge) prototype max_health. Clusters do
--- NOT reflect population in their health bar — if they did, the bar would be
--- pop*single, and a single damage instance larger than that total (a high-tier
--- turret/weapon vs a small cluster) would let the ENGINE kill the whole cluster in
--- one shot, wiping the entire population instead of the one zombie our rule allows
--- (R-HORDE-4/5). Keeping health maxed makes the cluster immune to a one-shot; the
--- script owns every death (1 per hit, or floor(dmg/single) for explosive/fire), and
--- population lives in storage. (pop/tier kept in the signature for call sites.)
local function pop_health(entity, pop, tier)
  return entity.max_health  -- 2.1: readable directly off the LuaEntity
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

-- Optional overall horde-size multiplier override (test-only, same rationale as
-- cap_override). nil -> the live setting.
local size_mult_override

--- The overall horde-size multiplier (R-HORDE-7). Applied here in the unified
--- spawner so EVERY source (death cascade, swarm events, night escalation)
--- scales by it. Defensive default of 1.
local function size_multiplier()
  if size_mult_override ~= nil then return size_mult_override end
  return config.horde_size_multiplier() or 1
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

--- An alt-mode text label over a cluster showing how many zombies it stands in for.
--- The cluster's health bar can't carry this (it's pinned to full so a single hit
--- can't one-shot the swarm), and a `unit`'s hover tooltip can't be customised, so we
--- draw the count and reveal it when the player holds ALT (like belt item counts). The
--- render is bound to the entity, so it's auto-destroyed when the cluster dies/bursts.
--- (Drop `only_in_alt_mode` to make the count always visible.)
local function pop_label(unit, pop)
  return rendering.draw_text {
    text = tostring(pop),
    surface = unit.surface,
    target = { entity = unit, offset = { 0, -1.4 } },
    color = { r = 1, g = 0.5, b = 0.4 },
    scale = 1.4,
    alignment = "center",
    vertical_alignment = "middle",
    only_in_alt_mode = true,
  }
end

--- Keep a cluster's pop label in sync after its population changes.
local function update_label(rec)
  if rec.label and rec.label.valid then rec.label.text = tostring(rec.pop) end
end

--- Create one horde-unit entity holding `pop`, record it, size its health.
local function create_cluster(surface, pos, pop, tier, force)
  local name = tiers.HORDE[tier]
  local place = surface.find_non_colliding_position(name, pos, 16, 0.5) or pos
  local unit = surface.create_entity { name = name, position = place, force = force }
  if not (unit and unit.valid) then return nil end
  local rec = { pop = pop, tier = tier }
  rec.label = pop_label(unit, pop)
  state().horde[unit.unit_number] = rec
  unit.health = pop_health(unit, pop, tier)
  return unit
end

--------------------------------------------------------------------- spawning

--- Cap-aware spawn of EXACTLY `count` zombies (NO horde-size multiplier): create
--- individuals up to the dynamic cap, fold all overflow into horde unit(s), never
--- discard. The burst path uses this directly to re-spawn an already-existing
--- (already-scaled) surviving population — applying the multiplier there too would
--- scale it twice.
local function do_spawn(surface, pos, count, tier, force)
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

--------------------------------------------------------------------- public

--- Unified spawner (R-HORDE-6 / R-GEN-6) and the single point where the overall
--- horde-size multiplier (R-HORDE-7) is applied — so every generation SOURCE
--- (death cascade, swarm events, night escalation) scales uniformly. Create
--- `count` zombies of `tier` for `force` near `pos`, capped/clustered by do_spawn.
function horde.spawn(surface, pos, count, tier, force)
  count = math.floor(count or 0)
  if count <= 0 then return end
  -- max(1,...) so a positive request never rounds away at a low multiplier
  -- (a building destroyed by zombies always yields at least one zombie).
  count = math.max(1, math.floor(count * size_multiplier()))
  do_spawn(surface, pos, count, tier, force)
end

--- Spare individual-zombie capacity before the cap (R-HORDE-6). Exposed so other
--- modules (e.g. corpse reanimation) can decide whether a new zombie stays a real
--- individual or must be folded into a cluster.
function horde.cap_room()
  return cap_room()
end

--- Fold `count` ALREADY-DECIDED-OVERFLOW zombies into cluster(s) near `pos`
--- (R-HORDE-6). Unlike horde.spawn this applies NO cap check and NO horde-size
--- multiplier: the caller has already decided these zombies are overflow that
--- cannot be individuals, so they're not a fresh generation source.
---
--- To realise "fold overflow into HIGHER-POPULATION horde units", we first try to
--- merge into an existing tracked cluster of the same `tier` within a small radius
--- of `pos` (growing it) rather than littering the area with tiny clusters; only
--- if none exists do we create new cluster(s), split by MAX_CLUSTER_POP.
function horde.fold(surface, pos, count, tier, force)
  count = math.floor(count or 0)
  if count <= 0 then return end
  if not (surface and surface.valid) then return end
  if not tiers.is_valid(tier) then tier = "small" end
  force = force or util.ENEMY_FORCE

  local z = state()

  -- Merge into a nearby existing cluster of the same tier if one is tracked.
  local nearby = surface.find_entities_filtered {
    name = tiers.HORDE[tier], position = pos, radius = 8,
  }
  for _, unit in ipairs(nearby) do
    if unit.valid then
      local rec = z.horde[unit.unit_number]
      if rec then
        rec.pop = rec.pop + count
        unit.health = pop_health(unit, rec.pop, tier)
        update_label(rec)
        return
      end
    end
  end

  -- No mergeable cluster: create new one(s), split so none holds an absurd pop.
  local remainder = count
  while remainder > 0 do
    local pop = math.min(remainder, MAX_CLUSTER_POP)
    create_cluster(surface, pos, pop, tier, force)
    remainder = remainder - pop
  end
end

--- A corpse spoiled and the spoilage trigger hatched a zombie (R-CORPSE-5). Route
--- that reanimation through the dynamic cap (R-HORDE-6 / R-GEN-6) so a big pile
--- spoiling at once can't dump hundreds of individuals: under-cap zombies stay
--- real individuals (and now count against the cap), overflow folds into a cluster
--- (merging into a nearby one, so a spoiling pile becomes one growing cluster).
---
--- Lives here, not in lib/corpses, because Factorio forbids runtime require() and
--- a top-level corpses->horde require would cycle (horde requires corpses already);
--- horde already owns the cap (cap_room/track/fold), so this is its natural home.
--- control.lua dispatches on_trigger_created_entity to it.
function horde.on_trigger_created_entity(event)
  local entity = event and event.entity
  if not (entity and entity.valid) then return end
  if not planets.is_active(entity.surface) then return end
  -- Only OUR reanimated zombies: an enemy-force `unit` whose name is one of our
  -- individual tiers. Leaves other mods' trigger-created entities (e.g. pentapods)
  -- entirely untouched.
  if entity.type ~= "unit" then return end
  if not util.is_enemy_force(entity.force) then return end
  local tier = INDIVIDUAL_TO_TIER[entity.name]
  if tier == nil then return end

  if cap_room() > 0 then
    -- Under the cap: it stays a real individual and now counts against the cap.
    track_individual(entity)
  else
    -- Cap full: remove the hatched individual and fold it into a cluster (merged
    -- into a nearby one by horde.fold, so a spoiling pile accumulates into one).
    local surface, pos = entity.surface, entity.position
    entity.destroy()
    horde.fold(surface, pos, 1, tier, util.ENEMY_FORCE)
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
      -- Survivors are an EXISTING (already-scaled) population — re-spawn them
      -- without re-applying the horde-size multiplier (use do_spawn, not spawn).
      do_spawn(surface, pos, survivors, tier, force)
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
    update_label(rec)
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

--- Is this individual (by unit_number) currently counted against the cap?
function horde.is_tracked(unit_number)
  if unit_number == nil then return false end
  return state().individuals[unit_number] == true
end

--- Register an externally-created individual zombie so it counts against the cap.
--- Used by night.lua: swapping a tracked unit for its faster night variant
--- destroys the old one (which frees its cap slot via on_removed), so the new
--- variant must be re-tracked or the cap would silently drift down.
function horde.track(entity)
  track_individual(entity)
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

--- Test/debug: the current text of a cluster's pop label (the count shown in
--- alt-mode), or nil if it has none. Lets a headless test verify the count display
--- tracks population.
function horde.pop_label_text(entity)
  if not (entity and entity.valid and entity.unit_number) then return nil end
  local rec = state().horde[entity.unit_number]
  if rec and rec.label and rec.label.valid then return rec.label.text end
  return nil
end

--- Exposed for tests/other stages that need the live single-zombie health.
function horde.single_health(tier)
  return single_health(tier)
end

--- Test-only: pin (or, with nil, release) the cap. See `cap_override` above.
function horde.set_cap_override(n)
  cap_override = n
end

--- Test-only: pin (or, with nil, release) the overall horde-size multiplier.
function horde.set_size_multiplier_override(n)
  size_mult_override = n
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
