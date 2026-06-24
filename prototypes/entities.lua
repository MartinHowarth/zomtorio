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
-- v1 ships a single scaled/tinted tier per biter-tier. A richer multi-biter
-- cluster sprite (several biters animating in a tight pattern) and a second
-- visual size-tier (small vs. large cluster) are future polish (R-HORDE-3).

local util = require("util")
local tiers = require("lib.tiers")

-- How much bigger a cluster reads than a single biter.
local CLUSTER_SCALE = 1.7

-- Tint the cluster a sickly green so it reads as distinct from a lone biter even
-- before the scale is obvious.
local CLUSTER_TINT = { r = 0.55, g = 0.85, b = 0.45, a = 1.0 }

--- Recursively scale every `scale` field found under an animation node, in place.
--- Unit graphics are nested (layers, direction arrays, animation containers), so
--- we walk the whole subtree rather than assume one shape.
local function scale_graphics(node, factor)
  if type(node) ~= "table" then return end
  if node.scale then node.scale = node.scale * factor end
  if node.layers then
    for _, layer in pairs(node.layers) do scale_graphics(layer, factor) end
  end
  for _, v in ipairs(node) do scale_graphics(v, factor) end
  for _, key in ipairs({ "animation", "animations" }) do
    if node[key] then scale_graphics(node[key], factor) end
  end
end

local new_protos = {}

for _, tier in ipairs(tiers.ORDER) do
  local source = data.raw.unit[tiers.INDIVIDUAL[tier]]
  if source then
    local horde = util.table.deepcopy(source)
    horde.name = tiers.HORDE[tier]
    -- keep it discoverable in the same family but ordered after the biters
    horde.order = (horde.order or "b") .. "-zomtorio-horde"

    -- Make it visually read as a larger, tinted cluster (R-HORDE-3).
    if horde.run_animation then scale_graphics(horde.run_animation, CLUSTER_SCALE) end
    if horde.attack_parameters and horde.attack_parameters.animation then
      scale_graphics(horde.attack_parameters.animation, CLUSTER_SCALE)
    end
    horde.tint = CLUSTER_TINT

    -- Prototype health is pure headroom: the script sets `health` to track
    -- population and is the only thing that destroys the unit (at pop 0). A big
    -- ceiling stops a single large hit from killing it before the script runs.
    horde.max_health = math.max(1e6, (source.max_health or 1) * 1000)
    -- Don't let it heal back toward that (huge) max between hits.
    horde.healing_per_tick = 0

    new_protos[#new_protos + 1] = horde
  end
end

if #new_protos > 0 then
  data:extend(new_protos)
end
