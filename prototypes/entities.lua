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

-- Tint each biter in the clump a sickly green so it reads as distinct from a lone biter.
local CLUSTER_TINT = { r = 0.55, g = 0.85, b = 0.45, a = 1.0 }

-- A cluster's health is pure ONE-SHOT HEADROOM, not a representation of population
-- (the script owns deaths; pop lives in storage). It just has to exceed the largest
-- single damage INSTANCE a cluster might take, so the engine can't wipe a whole swarm
-- in one hit before our 1-per-hit rule runs. 1000 (further buffered by the biter's
-- inherited resistances) covers normal weapons; explosive/fire multi-kill by rule
-- anyway. A sane number — 1e6 read as ridiculous on the health bar.
local CLUSTER_MAX_HEALTH = 1000

--- Turn one biter animation into a clump: replicate its layers once per offset,
--- shifting (and green-tinting) each copy. Handles the layered or single-animation
--- shapes a unit's run/attack animation can take.
local function clump(anim)
  if type(anim) ~= "table" then return anim end
  local src = anim.layers or { anim }
  local layers = {}
  for _, off in ipairs(CLUSTER_OFFSETS) do
    for _, layer in ipairs(src) do
      local c = util.table.deepcopy(layer)
      local sx = (c.shift and (c.shift[1] or c.shift.x)) or 0
      local sy = (c.shift and (c.shift[2] or c.shift.y)) or 0
      c.shift = { sx + off[1], sy + off[2] }
      if not c.draw_as_shadow then c.tint = CLUSTER_TINT end
      layers[#layers + 1] = c
    end
  end
  return { layers = layers }
end

local new_protos = {}

for _, tier in ipairs(tiers.ORDER) do
  local source = data.raw.unit[tiers.INDIVIDUAL[tier]]
  if source then
    local horde = util.table.deepcopy(source)
    horde.name = tiers.HORDE[tier]
    -- keep it discoverable in the same family but ordered after the biters
    horde.order = (horde.order or "b") .. "-zomtorio-horde"

    -- Make it read as a clump of several biters (R-HORDE-3).
    if horde.run_animation then horde.run_animation = clump(horde.run_animation) end
    if horde.attack_parameters and horde.attack_parameters.animation then
      horde.attack_parameters.animation = clump(horde.attack_parameters.animation)
    end

    -- Health is one-shot headroom only (see CLUSTER_MAX_HEALTH); the script tracks
    -- population in storage and is the only thing that destroys the unit (at pop 0).
    horde.max_health = CLUSTER_MAX_HEALTH
    -- Don't let it heal back up between hits (we keep it pinned at max ourselves).
    horde.healing_per_tick = 0

    new_protos[#new_protos + 1] = horde
  end
end

if #new_protos > 0 then
  data:extend(new_protos)
end
