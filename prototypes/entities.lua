-- S2 — horde-unit entities: single entities that visually read as a CLUSTER of
-- zombies and stand in for a population of N (R-HORDE-2/3).
--
-- One horde unit per zombie tier, built by deep-copying the matching vanilla
-- biter and scaling its graphics up so it clearly reads as larger than a single
-- biter. Health here is just prototype headroom: actual life/death is managed by
-- the script (lib/horde.lua) which sets `health` to track population and destroys
-- the entity at population 0. We give it a large bounded max_health so a single
-- big hit can't pre-empt the script's pop bookkeeping.
--
-- A horde unit reads as a CLUMP of several biters (R-HORDE-3): we overlay multiple
-- copies of the source biter's animation at small offsets so one entity looks like a
-- packed swarm rather than a single (scaled) biter. Each copy is tinted a sickly green
-- so a cluster is distinguishable from a lone biter.

local util = require("util")
local tiers = require("lib.tiers")

-- Where the overlaid biters sit relative to the entity centre (tiles). More entries
-- = a denser-looking clump (and more sprites to draw, so keep it modest — clusters
-- are few because overflow folds into a handful of them).
local CLUSTER_OFFSETS = {
  { 0, 0 }, { -0.8, -0.45 }, { 0.8, -0.4 },
  { -0.6, 0.5 }, { 0.65, 0.55 }, { 0, 0.85 }, { 0, -0.8 },
}

-- Tint each zombie in the clump so a swarm reads as distinct from a lone enemy, and
-- so biter swarms (sickly green) and spitter swarms (sickly violet) read differently.
local CLUSTER_TINT = {
  biter   = { r = 0.55, g = 0.85, b = 0.45, a = 1.0 },  -- sickly green
  spitter = { r = 0.70, g = 0.45, b = 0.90, a = 1.0 },  -- sickly violet
}

-- A shambler reads as a washed-out, grey zombie (a reanimated corpse).
local SHAMBLER_TINT = { r = 0.6, g = 0.6, b = 0.6, a = 1.0 }

--- Tint an animation's (non-shadow) layers a flat colour, without offsetting them.
--- Used for the single-biter shambler (unlike clump(), which also replicates).
local function tint_anim(anim, tint)
  if type(anim) ~= "table" then return anim end
  local src = anim.layers or { anim }
  local layers = {}
  for _, layer in ipairs(src) do
    local c = util.table.deepcopy(layer)
    if not c.draw_as_shadow then c.tint = tint end
    layers[#layers + 1] = c
  end
  return { layers = layers }
end

-- A cluster's health is pure ONE-SHOT HEADROOM, not a representation of population
-- (the script owns deaths; pop lives in storage). It just has to exceed the largest
-- single damage INSTANCE a cluster might take, so the engine can't wipe a whole swarm
-- in one hit before our 1-per-hit rule runs. 1000 (further buffered by the biter's
-- inherited resistances) covers normal weapons; explosive/fire multi-kill by rule
-- anyway. A sane number — 1e6 read as ridiculous on the health bar.
local CLUSTER_MAX_HEALTH = 1000

--- Turn one zombie animation into a clump: replicate its layers once per offset,
--- shifting (and `tint`-ing) each copy. Handles the layered or single-animation
--- shapes a unit's run/attack animation can take.
local function clump(anim, tint)
  if type(anim) ~= "table" then return anim end
  local src = anim.layers or { anim }
  local layers = {}
  for _, off in ipairs(CLUSTER_OFFSETS) do
    for _, layer in ipairs(src) do
      local c = util.table.deepcopy(layer)
      local sx = (c.shift and (c.shift[1] or c.shift.x)) or 0
      local sy = (c.shift and (c.shift[2] or c.shift.y)) or 0
      c.shift = { sx + off[1], sy + off[2] }
      if not c.draw_as_shadow then c.tint = tint end
      layers[#layers + 1] = c
    end
  end
  return { layers = layers }
end

local new_protos = {}

-- One swarm-cluster prototype per (kind, tier): a clump of that kind's individual,
-- tinted per kind so biter and spitter swarms read differently (R-HORDE-3). Built
-- for BOTH kinds so the engine's evolution-gated spitter spawns can form spitter
-- swarms (lib/swarm + lib/nest route folded spitters here by kind).
for _, kind in ipairs(tiers.KINDS) do
  local tint = CLUSTER_TINT[kind]
  for _, tier in ipairs(tiers.ORDER) do
    local source = data.raw.unit[tiers.individual_name(kind, tier)]
    if source then
      local cluster = util.table.deepcopy(source)
      cluster.name = tiers.swarm_name(kind, tier)
      -- keep it discoverable in the same family but ordered after the base enemies
      cluster.order = (cluster.order or "b") .. "-zomtorio-swarm"

      -- Make it read as a clump of several zombies (R-HORDE-3).
      if cluster.run_animation then cluster.run_animation = clump(cluster.run_animation, tint) end
      if cluster.attack_parameters and cluster.attack_parameters.animation then
        cluster.attack_parameters.animation = clump(cluster.attack_parameters.animation, tint)
      end

      -- Health is one-shot headroom only (see CLUSTER_MAX_HEALTH); the script tracks
      -- population in storage and is the only thing that destroys the unit (at pop 0).
      cluster.max_health = CLUSTER_MAX_HEALTH
      -- Don't let it heal back up between hits (we keep it pinned at max ourselves).
      cluster.healing_per_tick = 0

      new_protos[#new_protos + 1] = cluster
    end
  end
end

-- The shambler: a grey, reanimated small-biter (corpse -> spoil -> shambler). It
-- drops no corpse on death (lib/corpses), terminating the reanimation chain. Its
-- stats (slower, weak) are set in prototypes/tuning.lua at data-final-fixes.
local shambler_src = data.raw.unit[tiers.INDIVIDUAL.small]
if shambler_src then
  local shambler = util.table.deepcopy(shambler_src)
  shambler.name = tiers.SHAMBLER
  shambler.order = (shambler.order or "b") .. "-zomtorio-shambler"
  if shambler.run_animation then
    shambler.run_animation = tint_anim(shambler.run_animation, SHAMBLER_TINT)
  end
  if shambler.attack_parameters and shambler.attack_parameters.animation then
    shambler.attack_parameters.animation = tint_anim(shambler.attack_parameters.animation, SHAMBLER_TINT)
  end
  new_protos[#new_protos + 1] = shambler
end

if #new_protos > 0 then
  data:extend(new_protos)
end
