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
tiers.HORDE = {
  small  = "zomtorio-horde-small",
  medium = "zomtorio-horde-medium",
  big    = "zomtorio-horde-big",
}

-- Reverse lookup: horde-unit prototype name -> tier. Used by the runtime damage
-- handler for a cheap "is this one of ours?" check.
tiers.HORDE_TO_TIER = {}
for tier, name in pairs(tiers.HORDE) do
  tiers.HORDE_TO_TIER[name] = tier
end

function tiers.is_valid(tier)
  return tiers.INDIVIDUAL[tier] ~= nil
end

return tiers
