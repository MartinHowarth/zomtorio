-- S7 — the corpse-kiln building, its drying recipe, and the kiln's own build
-- recipe (R-CORPSE-6/7).
--
-- Approach: a DEDICATED corpse-kiln building rather than a normal furnace burning
-- corpses as fuel. The dedicated building sidesteps the furnace fuel-vs-ingredient
-- ambiguity entirely (a single inserter can't reliably load a corpse as both fuel
-- AND ingredient): the lossy 5->2 recipe bakes the fuel sacrifice into the ratio.
--
-- 5 zomtorio-corpse -> 2 zomtorio-kiln-dried-corpse. With corpse=2MJ and
-- kiln-dried=4MJ (items.lua), drying turns 10MJ of raw fuel into 8MJ of dried
-- fuel: denser per item, but a net energy loss for the loop (R-CORPSE-7).

local util = require("util")

-- A custom crafting category so ONLY the corpse-kiln can run the drying recipe
-- (and the kiln can run nothing else).
data:extend({
  {
    type = "recipe-category",
    name = "zomtorio-corpse-drying",
  },
})

------------------------------------------------------------------- the kiln
-- Clone an assembling machine (no fuel slot to confuse the recipe) and retarget
-- it at the drying category. Strip every self-reference the clone carries
-- (its item, remnants, upgrade target, fast-replace group) so it stands alone.
local kiln = util.table.deepcopy(data.raw["assembling-machine"]["assembling-machine-2"])
kiln.name = "zomtorio-corpse-kiln"
kiln.minable = { mining_time = 0.2, result = "zomtorio-corpse-kiln" }
kiln.crafting_categories = { "zomtorio-corpse-drying" }
kiln.crafting_speed = 1.0
kiln.next_upgrade = nil
kiln.fast_replaceable_group = nil
kiln.placeable_by = { item = "zomtorio-corpse-kiln", count = 1 }
-- It takes no fluids; drop the inherited fluid boxes so no pipe connections show.
kiln.fluid_boxes = nil
kiln.fluid_boxes_off_when_no_fluid_recipe = nil

data:extend({
  kiln,
  -- The kiln's item (modest steel-tier cost; reuse the assembler-2 icon).
  {
    type = "item",
    name = "zomtorio-corpse-kiln",
    icon = "__base__/graphics/icons/assembling-machine-2.png",
    icon_size = 64,
    subgroup = "production-machine",
    order = "z-zomtorio-corpse-kiln",
    place_result = "zomtorio-corpse-kiln",
    stack_size = 20,
  },
  -- Build recipe for the kiln.
  {
    type = "recipe",
    name = "zomtorio-corpse-kiln",
    enabled = true,             -- available from the start (no tech gate in v1)
    energy_required = 2,
    ingredients = {
      { type = "item", name = "steel-plate", amount = 5 },
      { type = "item", name = "iron-gear-wheel", amount = 10 },
      { type = "item", name = "stone-brick", amount = 10 },
    },
    results = { { type = "item", name = "zomtorio-corpse-kiln", amount = 1 } },
  },
  -- The lossy drying recipe (R-CORPSE-6): 5 corpses -> 2 kiln-dried corpses.
  {
    type = "recipe",
    name = "zomtorio-kiln-dried-corpse",
    categories = { "zomtorio-corpse-drying" },
    enabled = true,
    energy_required = 4,
    ingredients = {
      { type = "item", name = "zomtorio-corpse", amount = 5 },
    },
    results = {
      { type = "item", name = "zomtorio-kiln-dried-corpse", amount = 2 },
    },
    allow_decomposition = false,   -- don't let it feed the S1 total-raw walk
  },
})
