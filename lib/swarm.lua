-- S2 — the swarm population model and the unified cap-aware spawner.
--
-- A "swarm unit" is one entity that stands in for N individual zombies
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
-- any overflow into higher-population swarm units rather than discarding it.

local config  = require("lib.config")
local planets = require("lib.planets")
local tiers   = require("lib.tiers")
local corpses = require("lib.corpses")
local melee   = require("lib.melee")
local util    = require("lib.util")

local swarm = {}

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
-- storage.zomtorio.swarm            : unit_number -> { pop, tier, kind, ... }
-- storage.zomtorio.individuals      : unit_number -> true  (zombies WE spawned)
-- storage.zomtorio.individual_count : running size of the above (cap accounting)
-- storage.zomtorio.horde_units      : unit_number -> LuaEntity  (members of the
--   CURRENT horde event — clusters AND individuals — so the horde warning can count
--   the live horde by POPULATION, dispersion-proof; see swarm.horde_population)

local function state()
  storage.zomtorio = storage.zomtorio or {}
  local z = storage.zomtorio
  z.swarm = z.swarm or {}
  z.individuals = z.individuals or {}
  z.individual_count = z.individual_count or 0
  z.horde_units = z.horde_units or {}
  return z
end

-- Idempotent: only creates missing tables, never wipes live state. control.lua
-- runs this on BOTH new game and on_configuration_changed, so a mod update must
-- not orphan the clusters / cap-count already present in an existing save.
function swarm.on_init()
  state()
end

--------------------------------------------------------------------- helpers

--- Single-zombie health for a kind/tier, read live from the individual's prototype
--- so it auto-tracks the S10 health tuning. A spitter swarm's pop math must use the
--- spitter's health, not the biter's. kind defaults to "biter". Falls back to 1.
--- (2.1: LuaEntityPrototype.max_health was replaced by get_max_health(quality?).)
local function single_health(tier, kind)
  local proto = prototypes.entity[tiers.individual_name(kind, tier)]
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

-- Optional overall swarm-size multiplier override (test-only, same rationale as
-- cap_override). nil -> the live setting.
local size_mult_override

--- The overall swarm-size multiplier (R-HORDE-7). Applied here in the unified
--- spawner so EVERY source (death cascade, swarm events, night escalation)
--- scales by it. Defensive default of 1.
local function size_multiplier()
  if size_mult_override ~= nil then return size_mult_override end
  return config.zombie_count_multiplier() or 1
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

--- Mark an entity (cluster or individual) as a member of the CURRENT horde event,
--- keeping its reference so horde.update_warning can count the live horde by
--- POPULATION (Σ cluster pops + loose individuals). This is dispersion-proof: the
--- "remaining" count only falls when zombies actually die/merge-away (pruned on
--- read), never because the horde spread out beyond a scan radius.
local function register_horde_unit(entity)
  if entity and entity.valid and entity.unit_number then
    state().horde_units[entity.unit_number] = entity
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

--- Give a freshly-spawned unit/cluster an AI command (e.g. a swarm event's
--- attack-march toward the factory). pcall-guarded and a no-op for nil.
local function apply_command(entity, command)
  if not command then return end
  pcall(function() entity.commandable.set_command(command) end)
end

--- Create one swarm-unit entity holding `pop`, record it, size its health.
--- `shamblers` (default 0) is how many of `pop` are reanimated shamblers that drop
--- no corpse on death — tracked so proportional corpse drops survive folding.
--- `kind` ("biter" default | "spitter") picks the cluster prototype and is stored on
--- the record so the hit handler uses the right single-zombie health and burst kind.
--- `horde_member` (bool) flags it as part of the current horde event (warning count).
local function create_cluster(surface, pos, pop, tier, force, command, shamblers, kind, horde_member)
  kind = kind or "biter"
  local name = tiers.swarm_name(kind, tier)
  local place = surface.find_non_colliding_position(name, pos, 16, 0.5) or pos
  local unit = surface.create_entity { name = name, position = place, force = force }
  if not (unit and unit.valid) then return nil end
  local rec = { pop = pop, tier = tier, kind = kind, horde_member = horde_member or nil,
                shamblers = math.min(shamblers or 0, pop), shambler_acc = 0 }
  rec.label = pop_label(unit, pop)
  state().swarm[unit.unit_number] = rec
  unit.health = pop_health(unit, pop, tier)
  apply_command(unit, command)
  if horde_member then register_horde_unit(unit) end
  return unit
end

--------------------------------------------------------------------- spawning

--- Cap-aware spawn of EXACTLY `count` zombies (NO swarm-size multiplier): create
--- individuals up to the dynamic cap, fold all overflow into swarm unit(s), never
--- discard. The burst path uses this directly to re-spawn an already-existing
--- (already-scaled) surviving population — applying the multiplier there too would
--- scale it twice.
local function do_spawn(surface, pos, count, tier, force, command, kind, horde_member)
  count = math.floor(count or 0)
  if count <= 0 then return end
  if not (surface and surface.valid) then return end
  if not tiers.is_valid(tier) then tier = "small" end
  force = force or util.ENEMY_FORCE
  kind = kind or "biter"

  -- 1/2. Real individuals up to the cap.
  local make_individuals = math.min(count, cap_room())
  local individual_name = tiers.individual_name(kind, tier)
  local made = 0
  for _ = 1, make_individuals do
    local place = surface.find_non_colliding_position(individual_name, pos, 16, 0.5) or pos
    local zombie = surface.create_entity {
      name = individual_name, position = place, force = force,
    }
    if zombie and zombie.valid then
      track_individual(zombie)
      if horde_member then register_horde_unit(zombie) end
      apply_command(zombie, command)
      made = made + 1
    end
  end

  -- 3. Fold the remainder into swarm unit(s), splitting so no one cluster holds
  -- an absurd population. Never discard zombies.
  local remainder = count - made
  while remainder > 0 do
    local pop = math.min(remainder, MAX_CLUSTER_POP)
    create_cluster(surface, pos, pop, tier, force, command, nil, kind, horde_member)
    remainder = remainder - pop
  end
end

--- Spawn `n` reanimated-shambler individuals near `pos`, cap-aware: real shambler
--- entities up to the cap, folding any overflow into a swarm AS SHAMBLERS. Used by
--- the burst path so a bursting swarm's shambler share stays shamblers (no corpse).
local function spawn_shamblers(surface, pos, n, force, horde_member)
  n = math.floor(n or 0)
  if n <= 0 then return end
  force = force or util.ENEMY_FORCE
  local make = math.min(n, cap_room())
  local made = 0
  for _ = 1, make do
    local place = surface.find_non_colliding_position(tiers.SHAMBLER, pos, 16, 0.5) or pos
    local s = surface.create_entity { name = tiers.SHAMBLER, position = place, force = force }
    if s and s.valid then
      track_individual(s)
      if horde_member then register_horde_unit(s) end
      made = made + 1
    end
  end
  local overflow = n - made
  if overflow > 0 then
    swarm.fold(surface, pos, overflow, "small", force, overflow, "biter", horde_member)
  end
end

--------------------------------------------------------------------- public

--- Unified spawner (R-HORDE-6 / R-GEN-6) and the single point where the overall
--- swarm-size multiplier (R-HORDE-7) is applied — so every generation SOURCE
--- (death cascade, swarm events, night escalation) scales uniformly. Create
--- `count` zombies of `tier` for `force` near `pos`, capped/clustered by do_spawn.
--- `command` (optional) is an AI command applied to every spawned unit/cluster —
--- used by swarm events to march the swarm at the factory from its spawn point.
--- `kind` ("biter" default | "spitter") — our scripted sources all pass biter; only
--- the engine's evolution-gated spitter spawns (routed via lib/nest) use "spitter".
--- `horde_member` (bool) flags every unit/cluster created as part of the current
--- horde event so the warning can track the live horde's population (lib/horde).
function swarm.spawn(surface, pos, count, tier, force, command, kind, horde_member)
  count = math.floor(count or 0)
  if count <= 0 then return end
  -- max(1,...) so a positive request never rounds away at a low multiplier
  -- (a building destroyed by zombies always yields at least one zombie).
  count = math.max(1, math.floor(count * size_multiplier()))
  do_spawn(surface, pos, count, tier, force, command, kind, horde_member)
end

--- Spare individual-zombie capacity before the cap (R-HORDE-6). Exposed so other
--- modules (e.g. corpse reanimation) can decide whether a new zombie stays a real
--- individual or must be folded into a cluster.
function swarm.cap_room()
  return cap_room()
end

--- Fold `count` ALREADY-DECIDED-OVERFLOW zombies into cluster(s) near `pos`
--- (R-HORDE-6). Unlike swarm.spawn this applies NO cap check and NO swarm-size
--- multiplier: the caller has already decided these zombies are overflow that
--- cannot be individuals, so they're not a fresh generation source.
---
--- To realise "fold overflow into HIGHER-POPULATION swarm units", we first try to
--- merge into an existing tracked cluster of the same `tier` within a small radius
--- of `pos` (growing it) rather than littering the area with tiny clusters; only
--- if none exists do we create new cluster(s), split by MAX_CLUSTER_POP.
--- `shambler_count` (optional, default 0): how many of `count` are reanimated
--- shamblers (no-corpse-on-death). Carried into the merged/created cluster so the
--- swarm drops corpses only for its non-shambler share.
--- `kind` ("biter" default | "spitter"): a folded spitter forms a SPITTER swarm and
--- only ever merges into a same-KIND cluster — so spitters don't vanish into biter
--- swarms. (Shamblers are always biters, so shambler_count only ever rides biter folds.)
--- `horde_member` (bool) flags the merged/created cluster as part of the horde event.
function swarm.fold(surface, pos, count, tier, force, shambler_count, kind, horde_member)
  count = math.floor(count or 0)
  if count <= 0 then return end
  if not (surface and surface.valid) then return end
  if not tiers.is_valid(tier) then tier = "small" end
  force = force or util.ENEMY_FORCE
  kind = kind or "biter"
  shambler_count = math.min(math.floor(shambler_count or 0), count)

  local z = state()

  -- Merge into a nearby existing cluster of the SAME kind+tier if one is tracked.
  -- Match BOTH the day and night forms of that kind so a night-time swarm still merges.
  local nearby = surface.find_entities_filtered {
    name = tiers.swarm_both(kind, tier), position = pos, radius = 8,
  }
  for _, unit in ipairs(nearby) do
    if unit.valid then
      local rec = z.swarm[unit.unit_number]
      if rec then
        rec.pop = rec.pop + count
        rec.shamblers = math.min((rec.shamblers or 0) + shambler_count, rec.pop)
        if horde_member then rec.horde_member = true; register_horde_unit(unit) end
        unit.health = pop_health(unit, rec.pop, tier)
        update_label(rec)
        return
      end
    end
  end

  -- No mergeable cluster: create new one(s), split so none holds an absurd pop.
  -- Distribute the shambler share across the split chunks.
  local remainder = count
  while remainder > 0 do
    local pop = math.min(remainder, MAX_CLUSTER_POP)
    local sh = math.min(shambler_count, pop)
    shambler_count = shambler_count - sh
    create_cluster(surface, pos, pop, tier, force, nil, sh, kind, horde_member)
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
--- a top-level corpses->swarm require would cycle (swarm requires corpses already);
--- swarm already owns the cap (cap_room/track/fold), so this is its natural home.
--- control.lua dispatches on_trigger_created_entity to it.
function swarm.on_trigger_created_entity(event)
  local entity = event and event.entity
  if not (entity and entity.valid) then return end
  if not planets.is_active(entity.surface) then return end
  -- Only OUR reanimated zombies: an enemy-force `unit` whose name is one of our
  -- individual tiers. Leaves other mods' trigger-created entities (e.g. pentapods)
  -- entirely untouched.
  if entity.type ~= "unit" then return end
  if not util.is_enemy_force(entity.force) then return end
  -- Our reanimated units are SHAMBLERS (corpse spoilage), but accept a plain
  -- individual tier too (defensive / other spawn paths). Shamblers map to "small".
  local is_shambler = tiers.is_shambler(entity.name)
  local tier = INDIVIDUAL_TO_TIER[entity.name] or (is_shambler and "small") or nil
  if tier == nil then return end

  if cap_room() > 0 then
    -- Under the cap: it stays a real individual (already the shambler prototype, so
    -- it drops no corpse on death) and now counts against the cap.
    track_individual(entity)
  else
    -- Cap full: remove the hatched individual and fold it into a cluster (merged
    -- into a nearby one by swarm.fold, so a spoiling pile accumulates into one). A
    -- shambler folds in as a shambler (the swarm tracks how many won't drop corpses).
    local surface, pos = entity.surface, entity.position
    entity.destroy()
    swarm.fold(surface, pos, 1, tier, util.ENEMY_FORCE, is_shambler and 1 or 0)
  end
end

--- Handle a hit on one of our swarm units (R-HORDE-4/5). Dispatched for ALL
--- damage right now, so the not-ours early-out is kept cheap.
function swarm.on_entity_damaged(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  if tiers.SWARM_TO_TIER[entity.name] == nil then return end  -- not a swarm unit

  local z = state()
  local rec = z.swarm[entity.unit_number]
  if rec == nil then return end  -- untracked swarm unit: let it die normally
  local tier = rec.tier
  local kind = rec.kind or "biter"

  local single = single_health(tier, kind)
  local dtype = event.damage_type and event.damage_type.name
  local kills
  if dtype and MULTI_KILL_TYPES[dtype] then
    -- Use damage actually DEALT (post-resistance): swarm units inherit the
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

  -- Decide how many of the killed zombies are SHAMBLERS (drop no corpse) vs normal
  -- (drop a corpse), proportional to the swarm's current shambler share, via an
  -- error-diffusion accumulator: deterministic and exact over many hits, no RNG.
  -- This loop also performs the population decrement (rec.pop -= removed).
  rec.shamblers = rec.shamblers or 0
  rec.shambler_acc = rec.shambler_acc or 0
  local removed = math.min(kills, rec.pop)
  local corpse_kills = 0
  for _ = 1, removed do
    if rec.pop <= 0 then break end
    local frac = rec.shamblers / rec.pop
    rec.shambler_acc = rec.shambler_acc + frac
    if rec.shambler_acc >= 1 and rec.shamblers > 0 then
      rec.shambler_acc = rec.shambler_acc - 1
      rec.shamblers = rec.shamblers - 1          -- a shambler died: no corpse
    else
      corpse_kills = corpse_kills + 1            -- a normal zombie died: corpse
    end
    rec.pop = rec.pop - 1
  end

  -- Burst: cap has room AND a player is near -> the cluster becomes real. The
  -- killed zombies are gone; the survivors spawn as individuals (R-HORDE-4),
  -- preserving the surviving shambler fraction as shambler individuals.
  if cap_room() > 0 and character_near(surface, pos) then
    local survivors = rec.pop                    -- already decremented above
    local surviving_shamblers = rec.shamblers
    local hm = rec.horde_member                  -- survivors stay horde members
    z.swarm[entity.unit_number] = nil
    entity.destroy()
    if survivors > 0 then
      -- Survivors are an EXISTING (already-scaled) population — re-spawn without
      -- re-applying the swarm-size multiplier (do_spawn, not spawn). Shamblers
      -- (always biters) first (cap-aware), then the normal remainder as THIS swarm's
      -- kind (so a spitter swarm bursts into spitters). horde_member carries over so
      -- the warning count survives a burst.
      local sh = math.min(surviving_shamblers, survivors)
      spawn_shamblers(surface, pos, sh, force, hm)
      local normal = survivors - sh
      if normal > 0 then do_spawn(surface, pos, normal, tier, force, nil, kind, hm) end
    end
    corpses.drop(surface, pos, corpse_kills, dtype, no_corpse)
    return
  end

  -- Otherwise just lose population. The script is the only thing that kills the
  -- unit. Corpses drop only for the non-shambler kills (and never for flame/
  -- explosion/double-tap, which corpses.drop suppresses).
  if rec.pop <= 0 then
    z.swarm[entity.unit_number] = nil
    entity.destroy()
  else
    entity.health = pop_health(entity, rec.pop, tier)
    update_label(rec)
  end
  corpses.drop(surface, pos, corpse_kills, dtype, no_corpse)
end

--- Idempotent removal from our bookkeeping. Safe to call from several remove
--- paths (death, mined, scripted destroy) without double-counting: a
--- unit_number already forgotten is a no-op. A tracked individual leaves the cap
--- count; a swarm unit has its record cleared.
local function forget(un)
  if un == nil then return end
  local z = state()
  z.horde_units[un] = nil   -- drop from horde tracking too (idempotent, hygiene)
  if z.individuals[un] then
    z.individuals[un] = nil
    z.individual_count = math.max(0, z.individual_count - 1)
  elseif z.swarm[un] then
    z.swarm[un] = nil
  end
end

--- Death bookkeeping.
function swarm.on_entity_died(event)
  local e = event.entity
  if e and e.valid then forget(e.unit_number) end
end

--- Bookkeeping for NON-death removals (mined, scripted destroy, platform mined),
--- so a tracked individual that vanishes without dying can't leak its cap slot.
function swarm.on_removed(event)
  local e = event.entity
  if e and e.valid then forget(e.unit_number) end
end

--- Is this individual (by unit_number) currently counted against the cap?
function swarm.is_tracked(unit_number)
  if unit_number == nil then return false end
  return state().individuals[unit_number] == true
end

--- Register an externally-created individual zombie so it counts against the cap.
--- Used by night.lua: swapping a tracked unit for its faster night variant
--- destroys the old one (which frees its cap slot via on_removed), so the new
--- variant must be re-tracked or the cap would silently drift down.
function swarm.track(entity)
  track_individual(entity)
end

--- Swap a CLUSTER entity to another cluster prototype (its day<->night variant),
--- carrying the population record across so the swarm keeps its pop, health and
--- label (R-NIGHT for swarms). Used by night.lua: a plain destroy+create would
--- orphan the storage record keyed by unit_number, so the swap must be done here
--- where that record lives. Returns the new entity (or nil). No cap impact —
--- clusters aren't tracked individuals.
function swarm.swap_cluster(old_entity, new_name)
  if not (old_entity and old_entity.valid) then return nil end
  local z = state()
  local old_un = old_entity.unit_number
  local rec = z.swarm[old_un]
  local surface, pos, force = old_entity.surface, old_entity.position, old_entity.force
  -- Preserve the active command so a swapped, charging swarm keeps its target.
  local cmd
  local ok, cmdable = pcall(function() return old_entity.commandable end)
  if ok and cmdable and cmdable.valid then cmd = cmdable.command end

  z.swarm[old_un] = nil           -- detach the record before destroying the old unit
  old_entity.destroy()            -- its bound pop label auto-destroys with it
  local unit = surface.create_entity { name = new_name, position = pos, force = force }
  if not (unit and unit.valid) then return nil end

  if rec then
    local newrec = { pop = rec.pop, tier = rec.tier, kind = rec.kind,
                     shamblers = rec.shamblers, shambler_acc = rec.shambler_acc,
                     horde_member = rec.horde_member }
    newrec.label = pop_label(unit, rec.pop)
    z.swarm[unit.unit_number] = newrec
    unit.health = pop_health(unit, rec.pop, rec.tier)
    -- Carry horde membership across the night day<->night swap, else the warning
    -- count would drop every time clusters near a player are swapped at dusk/dawn.
    if rec.horde_member then register_horde_unit(unit) end
  end
  if cmd then pcall(function() unit.commandable.set_command(cmd) end) end
  return unit
end

--------------------------------------------------------------------- test API

--- Number of live individual zombies we've spawned (cap accounting).
function swarm.active_count()
  return state().individual_count
end

--- Population a given swarm-unit entity stands in for, or nil if not tracked.
function swarm.pop_of(entity)
  if not (entity and entity.valid and entity.unit_number) then return nil end
  local rec = state().swarm[entity.unit_number]
  return rec and rec.pop or nil
end

--- The CURRENT horde's live population and pop-weighted centroid, by summing flagged
--- members (a cluster by its pop, a loose individual as 1) and pruning dead/merged-away
--- ones on read. Used by the horde warning so its "remaining" count tracks real DEATHS,
--- not how far the horde has dispersed (the old fixed-radius position scan decayed as
--- the marching wall spread out). Returns (count, centroid-or-nil).
function swarm.horde_population()
  local z = state()
  local total, sx, sy = 0, 0, 0
  for un, e in pairs(z.horde_units) do
    if e and e.valid then
      local rec = z.swarm[un]
      local pop = (rec and rec.pop) or 1   -- cluster pop, or 1 for a loose individual
      total = total + pop
      local p = e.position
      sx = sx + p.x * pop; sy = sy + p.y * pop
    else
      z.horde_units[un] = nil              -- dead or merged away: prune
    end
  end
  local centroid = total > 0 and { x = sx / total, y = sy / total } or nil
  return total, centroid
end

--- Drop ALL horde-membership tracking. Called when a NEW horde begins (lib/horde
--- begin_active) so a previous horde's survivors can't inflate the new count.
function swarm.clear_horde_members()
  local z = state()
  for un in pairs(z.horde_units) do z.horde_units[un] = nil end
  for k, rec in pairs(z.swarm) do
    if type(rec) == "table" then
      rec.horde_member = nil
    else
      -- Defensive: a save predating the swarm<->horde rename left the OLD wave-event
      -- state (booleans/numbers) in this storage slot. It isn't a cluster record;
      -- prune it so it can't crash this sweep (and so it stops lingering).
      z.swarm[k] = nil
    end
  end
end

--- The kind ("biter"/"spitter") of a tracked swarm-unit entity, or nil if untracked.
function swarm.kind_of(entity)
  if not (entity and entity.valid and entity.unit_number) then return nil end
  local rec = state().swarm[entity.unit_number]
  return rec and (rec.kind or "biter") or nil
end

--- Test/debug: the current text of a cluster's pop label (the count shown in
--- alt-mode), or nil if it has none. Lets a headless test verify the count display
--- tracks population.
function swarm.pop_label_text(entity)
  if not (entity and entity.valid and entity.unit_number) then return nil end
  local rec = state().swarm[entity.unit_number]
  if rec and rec.label and rec.label.valid then return rec.label.text end
  return nil
end

--- Exposed for tests/other stages that need the live single-zombie health
--- (kind defaults to "biter"; a spitter swarm's pop math uses the spitter's health).
function swarm.single_health(tier, kind)
  return single_health(tier, kind)
end

--- Test-only: pin (or, with nil, release) the cap. See `cap_override` above.
function swarm.set_cap_override(n)
  cap_override = n
end

--- Test-only: pin (or, with nil, release) the overall swarm-size multiplier.
function swarm.set_size_multiplier_override(n)
  size_mult_override = n
end

--- Test-only: hard-reset all bookkeeping. Production on_init is intentionally
--- idempotent (preserves live state across a config change), so tests that need
--- a clean slate between cases call this instead.
function swarm.reset_state()
  storage.zomtorio = storage.zomtorio or {}
  storage.zomtorio.swarm = {}
  storage.zomtorio.individuals = {}
  storage.zomtorio.individual_count = 0
  storage.zomtorio.horde_units = {}
end

return swarm
