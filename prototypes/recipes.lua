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
-- The kiln needs no electricity: a void energy source runs it for free (thematically
-- the burned corpses are the fuel — baked into the lossy 5->2 recipe, R-CORPSE-7).
kiln.energy_source = { type = "void" }

-- Make it LOOK like a stone furnace (a "corpse kiln") with a small biter lurking in
-- the bottom-right corner, while remaining an assembling-machine mechanically. Use
-- the base stone-furnace sprites (scaled up to fill the 3x3 footprint) plus a small
-- biter-icon overlay. Replaces the inherited assembler graphics/working-arms.
kiln.graphics_set = {
  animation = {
    layers = {
      {
        filename = "__base__/graphics/entity/stone-furnace/stone-furnace.png",
        width = 151, height = 146, scale = 0.6, shift = { 0, -0.05 },
        -- A cool grey tint so the kiln reads as a distinct ashen building, not a
        -- plain (warm) stone furnace.
        tint = { r = 0.55, g = 0.6, b = 0.7, a = 1 },
      },
      {
        filename = "__base__/graphics/entity/stone-furnace/stone-furnace-shadow.png",
        width = 164, height = 74, scale = 0.6, shift = { 0.25, 0.05 },
        draw_as_shadow = true,
      },
      {
        -- small biter in the bottom-right (positive shift = right/down)
        filename = "__base__/graphics/icons/small-biter.png",
        width = 64, height = 64, scale = 0.42, shift = { 0.7, 0.7 },
      },
    },
  },
}

data:extend({
  kiln,
  -- The kiln's item: a stone-furnace icon with a small biter in the bottom-right,
  -- matching the entity (shift is in pixels: positive = right/down).
  {
    type = "item",
    name = "zomtorio-corpse-kiln",
    icons = {
      { icon = "__base__/graphics/icons/stone-furnace.png", icon_size = 64,
        tint = { r = 0.55, g = 0.6, b = 0.7, a = 1 } },
      { icon = "__base__/graphics/icons/small-biter.png", icon_size = 64, scale = 0.32, shift = { 10, 10 } },
    },
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

------------------------------------------------------------ the zombie pyre
-- An ever-burning firepit: corpses inserted into it burn away continuously, no
-- electricity. Unlike the corpse-kiln (an assembling-machine that needs its recipe
-- set), the pyre is a FURNACE, which auto-selects its recipe from whatever ingredient
-- is inserted — so a single inserter dropping corpses in just burns them. The burn
-- recipe produces NOTHING (the corpse is destroyed); the 5s craft time = 1 corpse / 5s.
-- energy_source = void (like the kiln) means it runs with no power, "ever-burning".

data:extend({
  { type = "recipe-category", name = "zomtorio-pyre-burning" },
})

local pyre = util.table.deepcopy(data.raw["furnace"]["stone-furnace"])
pyre.name = "zomtorio-zombie-pyre"
pyre.minable = { mining_time = 0.5, result = "zomtorio-zombie-pyre" }
pyre.crafting_categories = { "zomtorio-pyre-burning" }
pyre.crafting_speed = 1.0
pyre.next_upgrade = nil
pyre.fast_replaceable_group = nil
pyre.placeable_by = { item = "zomtorio-zombie-pyre", count = 1 }
-- No electricity: void energy makes it run for free (the corpses are the "fuel").
pyre.energy_source = { type = "void" }
pyre.energy_usage = "1kW"
-- 4x4 footprint.
pyre.collision_box = { { -1.9, -1.9 }, { 1.9, 1.9 } }
pyre.selection_box = { { -2, -2 }, { 2, 2 } }
pyre.tile_width = 4
pyre.tile_height = 4
-- One corpse slot in, nothing out (the burn recipe yields nothing).
pyre.source_inventory_size = 1
pyre.result_inventory_size = 0
-- Looks like a wooden chest with an ALWAYS-animated fire on top (an ever-burning
-- firepit). The fire lives in `animation` (always drawn), not working_visualisations,
-- so it burns visibly even between corpses. (Sprite paths are GUI-only; the headless
-- engine ships no graphics and does not load/validate them.)
pyre.graphics_set = {
  animation = {
    layers = {
      {
        filename = "__base__/graphics/entity/wooden-chest/wooden-chest.png",
        width = 62, height = 72, scale = 3.0, shift = { 0, 0.1 },
        -- A static layer must match the fire layer's frame count (all layers of one
        -- animation share frame count): repeat the single chest frame to fill 90.
        frame_count = 1, repeat_count = 90,
      },
      {
        -- constant flames rising from the pit. Spec copied from the base fire-flame
        -- (data/base/prototypes/fire-util.lua): fire-flame-01.png is line_length 10,
        -- 84x130, 90 frames. (The old fire-flame-13.png does not exist - base only
        -- ships fire-flame-01..04 - which caused the load failure.)
        filename = "__base__/graphics/entity/fire-flame/fire-flame-01.png",
        line_length = 10, width = 84, height = 130, frame_count = 90,
        axially_symmetrical = false, direction_count = 1,
        blend_mode = "additive", draw_as_glow = true,
        animation_speed = 0.5, scale = 1.8, shift = { 0, -0.8 },
      },
    },
  },
}
-- A furnace clone carries working_visualisations (the smelting glow); drop them so the
-- only fire is our always-on one.
pyre.working_visualisations = nil

data:extend({
  pyre,
  {
    type = "item",
    name = "zomtorio-zombie-pyre",
    icons = {
      { icon = "__base__/graphics/icons/wooden-chest.png", icon_size = 64 },
    },
    subgroup = "production-machine",
    order = "z-zomtorio-zombie-pyre",
    place_result = "zomtorio-zombie-pyre",
    stack_size = 20,
  },
  -- Cheap, no tech gate: 50 wood.
  {
    type = "recipe",
    name = "zomtorio-zombie-pyre",
    enabled = true,
    energy_required = 1,
    ingredients = { { type = "item", name = "wood", amount = 50 } },
    results = { { type = "item", name = "zomtorio-zombie-pyre", amount = 1 } },
  },
  -- The burn recipe the furnace auto-selects from an inserted corpse: 1 corpse in,
  -- NOTHING out, 5s -> exactly 1 corpse incinerated every 5 seconds.
  {
    type = "recipe",
    name = "zomtorio-burn-corpse",
    categories = { "zomtorio-pyre-burning" },
    enabled = true,
    energy_required = 5,
    ingredients = { { type = "item", name = "zomtorio-corpse", amount = 1 } },
    results = {},
    -- Empty results => no product to derive an icon from, so the recipe needs an
    -- explicit one. Hide it from menus: it's furnace-only, never hand-crafted.
    icon = "__base__/graphics/icons/small-biter.png",
    icon_size = 64,
    hidden = true,
    allow_decomposition = false,
  },
})
