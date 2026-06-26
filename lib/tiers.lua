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

-- The two zombie KINDS. "biter" is the default everywhere a kind is unspecified —
-- ALL our scripted spawns (building-death cascade, horde waves, reanimation) are
-- biters. "spitter" zombies arise ONLY from the engine's own nest spawn decision
-- (evolution-gated, vanilla logic); we just group folded spitters into spitter
-- swarms instead of absorbing them into biter swarms.
tiers.KINDS = { "biter", "spitter" }

-- kind -> tier -> the vanilla unit prototype used for an INDIVIDUAL zombie.
tiers.INDIVIDUAL_BY_KIND = {
  biter   = { small = "small-biter",   medium = "medium-biter",   big = "big-biter" },
  spitter = { small = "small-spitter", medium = "medium-spitter", big = "big-spitter" },
}

-- kind -> tier -> the swarm-cluster (horde-unit) entity prototype name (created in
-- the data stage, prototypes/entities.lua).
tiers.SWARM_BY_KIND = {
  biter   = { small = "zomtorio-swarm-small",         medium = "zomtorio-swarm-medium",         big = "zomtorio-swarm-big" },
  spitter = { small = "zomtorio-swarm-spitter-small", medium = "zomtorio-swarm-spitter-medium", big = "zomtorio-swarm-spitter-big" },
}

-- Back-compat defaults (== the biter kind): every existing call site that means
-- "biter" keeps working unchanged by reading these.
tiers.INDIVIDUAL = tiers.INDIVIDUAL_BY_KIND.biter
tiers.SWARM      = tiers.SWARM_BY_KIND.biter

--- Individual unit prototype name for a kind/tier (kind defaults to "biter").
function tiers.individual_name(kind, tier)
  local k = tiers.INDIVIDUAL_BY_KIND[kind] or tiers.INDIVIDUAL_BY_KIND.biter
  return k[tier]
end

--- Swarm-cluster prototype name for a kind/tier (kind defaults to "biter").
function tiers.swarm_name(kind, tier)
  local k = tiers.SWARM_BY_KIND[kind] or tiers.SWARM_BY_KIND.biter
  return k[tier]
end

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

--- { day cluster name, night cluster name } for a kind/tier — the name list for
--- find_entities_filtered that must catch a cluster in either form (fold merge).
function tiers.swarm_both(kind, tier)
  local day = tiers.swarm_name(kind, tier)
  return { day, day .. tiers.NIGHT_SUFFIX }
end

-- kind -> tier -> night-variant cluster prototype name (created in prototypes/night.lua).
-- So swarms (clusters), like loose biters, get a faster night form to swap to.
tiers.SWARM_NIGHT_BY_KIND = {}
for _, kind in ipairs(tiers.KINDS) do
  tiers.SWARM_NIGHT_BY_KIND[kind] = {}
  for tier, name in pairs(tiers.SWARM_BY_KIND[kind]) do
    tiers.SWARM_NIGHT_BY_KIND[kind][tier] = name .. tiers.NIGHT_SUFFIX
  end
end

-- Back-compat (biter): tier -> night cluster name; tier -> {day,night}.
tiers.SWARM_NIGHT = tiers.SWARM_NIGHT_BY_KIND.biter
tiers.SWARM_BOTH = {}
for tier in pairs(tiers.SWARM) do
  tiers.SWARM_BOTH[tier] = tiers.swarm_both("biter", tier)
end

-- Flat list of EVERY cluster prototype name (all KINDS, day + night), for sweeps
-- that don't care about kind/tier (nest swarm sum, the data-stage tuning pass).
tiers.SWARM_ALL = {}
for _, kind in ipairs(tiers.KINDS) do
  for tier, name in pairs(tiers.SWARM_BY_KIND[kind]) do
    tiers.SWARM_ALL[#tiers.SWARM_ALL + 1] = name
    tiers.SWARM_ALL[#tiers.SWARM_ALL + 1] = tiers.SWARM_NIGHT_BY_KIND[kind][tier]
  end
end

-- Reverse lookups: cluster prototype name -> tier and -> kind, for every cluster
-- form (all kinds, day + night), so the runtime damage handler recognises a spitter
-- (or night-variant) swarm as one of ours and recovers its tier/kind. A cheap "is
-- this one of our clusters?" check.
tiers.SWARM_TO_TIER = {}
tiers.SWARM_TO_KIND = {}
for _, kind in ipairs(tiers.KINDS) do
  for tier, name in pairs(tiers.SWARM_BY_KIND[kind]) do
    local night = tiers.SWARM_NIGHT_BY_KIND[kind][tier]
    tiers.SWARM_TO_TIER[name]  = tier
    tiers.SWARM_TO_TIER[night] = tier
    tiers.SWARM_TO_KIND[name]  = kind
    tiers.SWARM_TO_KIND[night] = kind
  end
end

function tiers.is_valid(tier)
  return tiers.INDIVIDUAL[tier] ~= nil
end

return tiers
