-- S8 — melee upgrade technologies (R-MELEE-2/5).
--
-- Tier 1 (red / automation science) is the GATE for any swarm multi-kill: until
-- it is researched a player punch kills exactly one zombie (R-MELEE-1). The
-- actual multi-kill is applied script-side (lib/melee.lua checks
-- force.technologies["zomtorio-swarm-melee-1"].researched), so the tech effect is
-- intentionally a no-op marker — the gating lives in the script.
--
-- Tier 2 (red + green / logistic science) requires Tier 1, increases the AoE
-- damage magnitude (again checked script-side) AND unlocks the double-tap
-- shortcut (the shortcut's `technology_to_unlock` points here; lib/melee also
-- flips its availability on research). Effects are markers for the same reason.
--
-- Icons reuse base technology art so the techs are valid without shipping new
-- assets; they sit on sensible vanilla prerequisites so they're reachable.

data:extend({
  {
    type = "technology",
    name = "zomtorio-swarm-melee-1",
    icon = "__base__/graphics/technology/military.png",
    icon_size = 256,
    -- No engine effect: lib/melee.lua reads `researched` directly to gate the
    -- enemy-only AoE multi-kill. A nil-effects tech is valid and still appears.
    effects = {},
    prerequisites = { "automation-science-pack" },
    unit = {
      count = 50,
      ingredients = { { "automation-science-pack", 1 } },
      time = 15,
    },
  },
  {
    type = "technology",
    name = "zomtorio-swarm-melee-2",
    icon = "__base__/graphics/technology/military-2.png",
    icon_size = 256,
    effects = {},
    prerequisites = { "zomtorio-swarm-melee-1", "logistic-science-pack" },
    unit = {
      count = 100,
      ingredients = {
        { "automation-science-pack", 1 },
        { "logistic-science-pack", 1 },
      },
      time = 30,
    },
  },
})
