-- Shared tier name constants for zombies and their cluster (horde-unit) forms.
--
-- Individual zombies ARE the vanilla biters, mapped by tier. A horde unit is one
-- entity standing in for N individuals of a given tier. Both the data stage
-- (prototypes/entities.lua, which deep-copies the biter into the horde-unit
-- prototype) and the runtime (lib/horde.lua) need these names, so they live here
-- to keep the two stages in agreement.

local tiers = {}

-- Ordered list of tiers, weakest first. S3's oil tiering picks among these.
tiers.ORDER = { "small", "medium", "big" }

-- tier -> the vanilla biter prototype used for an individual zombie of that tier.
tiers.INDIVIDUAL = {
  small  = "small-biter",
  medium = "medium-biter",
  big    = "big-biter",
}

-- tier -> the horde-unit (cluster) entity prototype name (created in the data stage).
tiers.SWARM = {
  small  = "zomtorio-swarm-small",
  medium = "zomtorio-swarm-medium",
  big    = "zomtorio-swarm-big",
}

-- The shambler: a REANIMATED zombie (corpse spoiled -> shambler). A distinct,
-- grey-tinted, slower prototype. Killing a shambler drops NO corpse, so the
-- reanimation chain terminates after exactly one generation (zombie -> corpse ->
-- shambler -> dead). It's an individual, NOT a cluster, so it is deliberately kept
-- out of SWARM_TO_TIER; when folded into a swarm the swarm tracks its count.
tiers.SHAMBLER = "zomtorio-shambler"

function tiers.is_shambler(name)
  return name == tiers.SHAMBLER
end

-- Suffix that turns any day prototype into its faster night variant (R-NIGHT).
-- Defined here so the data stage (prototypes/night.lua), the tuning pass
-- (prototypes/tuning.lua) and the runtime swap (lib/night.lua) all agree on it.
tiers.NIGHT_SUFFIX = "-zomtorio-night"

-- tier -> the night-variant cluster prototype name (created in prototypes/night.lua,
-- which clones each cluster). So swarms (clusters), like loose biters, get a faster
-- night form to swap to.
tiers.SWARM_NIGHT = {}
for tier, name in pairs(tiers.SWARM) do
  tiers.SWARM_NIGHT[tier] = name .. tiers.NIGHT_SUFFIX
end

-- tier -> { day cluster name, night cluster name } for find_entities_filtered name
-- lists that must catch a cluster in either form (fold merge, nest swarm measure).
tiers.SWARM_BOTH = {}
for tier, name in pairs(tiers.SWARM) do
  tiers.SWARM_BOTH[tier] = { name, tiers.SWARM_NIGHT[tier] }
end

-- Flat list of every cluster prototype name (day + night), for sweeps that don't
-- care about tier (nest swarm sum, the data-stage tuning pass).
tiers.SWARM_ALL = {}
for tier, name in pairs(tiers.SWARM) do
  tiers.SWARM_ALL[#tiers.SWARM_ALL + 1] = name
  tiers.SWARM_ALL[#tiers.SWARM_ALL + 1] = tiers.SWARM_NIGHT[tier]
end

-- Reverse lookup: cluster prototype name -> tier, for both the day and night forms,
-- so the runtime damage/corpse handlers recognise a night-variant cluster as one of
-- ours just like the day form. A cheap "is this one of our clusters?" check.
tiers.SWARM_TO_TIER = {}
for tier, name in pairs(tiers.SWARM) do
  tiers.SWARM_TO_TIER[name] = tier
  tiers.SWARM_TO_TIER[tiers.SWARM_NIGHT[tier]] = tier
end

function tiers.is_valid(tier)
  return tiers.INDIVIDUAL[tier] ~= nil
end

return tiers
