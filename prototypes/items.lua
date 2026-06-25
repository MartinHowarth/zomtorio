-- S7 — corpse and kiln-dried-corpse items (R-CORPSE-2/3/6/7).
--
-- The raw corpse is burnable fuel (R-CORPSE-3) and is the thing a killed zombie
-- drops. Its spoilage (the reanimation timer + spawn) is configured separately
-- in prototypes/corpse-spoilage.lua at data-final-fixes, so it only runs once
-- the zombie entities exist and the startup gate can be honoured (R-CORPSE-1/5).
--
-- The kiln-dried corpse NEVER spoils (so it can be stockpiled safely) and is
-- worth MORE fuel per item than a raw corpse (R-CORPSE-6). The drying recipe
-- (prototypes/recipes.lua) is deliberately lossy so the whole dry-then-burn loop
-- yields less total energy than burning raw corpses directly (R-CORPSE-7).

-- Fuel values are the contract for the R-CORPSE-7 invariant; the kiln's 5->2
-- ratio (recipes.lua) is chosen so 2 * KILN_DRIED_FUEL_MJ < 5 * CORPSE_FUEL_MJ
-- (energy is lost overall) while KILN_DRIED_FUEL_MJ > CORPSE_FUEL_MJ (denser per
-- item). 2*4 = 8 < 5*2 = 10. ✓
local CORPSE_FUEL_MJ      = 2
local KILN_DRIED_FUEL_MJ  = 4

-- Reuse Space Age's spoilage icon: a decayed organic look that reads as a corpse
-- without shipping new art (a valid icon is required for the mod to load).
local CORPSE_ICON       = "__space-age__/graphics/icons/spoilage.png"
local KILN_DRIED_ICON   = "__space-age__/graphics/icons/bioflux.png"

data:extend({
  {
    type = "item",
    name = "zomtorio-corpse",
    icon = CORPSE_ICON,
    icon_size = 64,
    subgroup = "raw-resource",
    order = "z-zomtorio-a-corpse",
    stack_size = 100,
    fuel_category = "chemical",
    fuel_value = CORPSE_FUEL_MJ .. "MJ",
    -- spoil_ticks + spoil_to_trigger_result are set in corpse-spoilage.lua.
  },
  {
    type = "item",
    name = "zomtorio-kiln-dried-corpse",
    icon = KILN_DRIED_ICON,
    icon_size = 64,
    subgroup = "raw-resource",
    order = "z-zomtorio-b-kiln-dried-corpse",
    stack_size = 100,
    fuel_category = "chemical",
    fuel_value = KILN_DRIED_FUEL_MJ .. "MJ",
    -- No spoilage: a stable, stockpilable fuel that never reanimates.
  },
})
