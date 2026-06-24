-- S1 — total-raw cost decomposition.
--
-- The runtime API exposes a recipe's direct ingredients but NOT its fully
-- decomposed "total raw" cost (the recipe-tooltip figure). We compute it once
-- per entity by recursively expanding producing recipes down to raw resources,
-- and cache the result in storage (computed lazily, reset at on_init /
-- on_configuration_changed since prototypes can change across a mod update).
--
-- Returns, per entity prototype: a count of solid mined raws (iron/copper/stone/
-- coal/uranium ore — 1 zombie each, R-DEATH-2) and the crude-oil-equivalent
-- fluid amount in the cost (feeds zombie tier, R-DEATH-4). Fluids never add to
-- the solid count.

local raw_cost = {}

local MAX_DEPTH = 64  -- backstop against pathological recipe graphs

-- Fluids whose presence in the decomposed cost should count as "oil" for tiering
-- (R-DEATH-4). These are the oil-chain fluids that bottom out as raw (i.e. have
-- no producing recipe, or are reached as raw): crude-oil is the canonical raw;
-- the derivatives are included so a build that bottoms out on a refined fluid
-- still reads as oil-derived.
local OIL_FLUIDS = {
  ["crude-oil"] = true,
  ["petroleum-gas"] = true,
  ["light-oil"] = true,
  ["heavy-oil"] = true,
  ["sulfuric-acid"] = true,
  ["lubricant"] = true,
}

-- Recipe lookup: item-name -> chosen producing recipe prototype (or nil if
-- none). Built once per session and reused across entities. Excludes recycling.
local recipe_for_item

-- Set of item/fluid names that are MINEABLE raw resources (ore, stone, coal,
-- crude-oil, scrap, ...). These are the true "total raw" terminals: we never
-- decompose them, even when some exotic recipe (e.g. Vulcanus lava casting)
-- incidentally lists them as a product. Built from resource entities.
local raw_items

--- True for Space Age recycling recipes. LuaRecipePrototype does NOT expose
--- `.category` at runtime in this version, but the engine auto-names every
--- recycling recipe `<recipe>-recycling`; that suffix is the reliable signal.
--- Recycling recipes nominally "produce" their inputs back out and would
--- wildly corrupt decomposition, so they must be excluded (R-DEATH-2).
local function is_recycling(recipe_name)
  return recipe_name:sub(-10) == "-recycling"
end

--- Build the set of mineable raw-resource item/fluid names from resource
--- entities (the "total raw" terminals).
local function build_raw_items()
  raw_items = {}
  for _, ent in pairs(prototypes.entity) do
    if ent.type == "resource" then
      local mp = ent.mineable_properties
      if mp and mp.products then
        for _, product in ipairs(mp.products) do
          raw_items[product.name] = true
        end
      end
    end
  end
end

--- Count fluid ingredients of a recipe (used as a tiebreaker — prefer the
--- production path that stays on solids, i.e. the canonical Nauvis chain over
--- exotic fluid-casting alternatives).
local function fluid_ingredient_count(recipe)
  local n = 0
  for _, ing in ipairs(recipe.ingredients) do
    if ing.type == "fluid" then n = n + 1 end
  end
  return n
end

--- Build the item -> producing-recipe index from prototypes.recipe.
-- Excluded: recycling recipes (R-DEATH-2 gotcha) and any recipe producing a
-- mineable raw, so raws always bottom out rather than chaining into a recipe
-- that merely lists them as a byproduct (e.g. lava casting yields stone).
--
-- Selection when several recipes produce the same item, in priority order:
--   1. the recipe whose NAME equals the item name — the canonical-recipe
--      convention (`plastic-bar`, `iron-gear-wheel`, ...). Alternate-planet
--      recipes carry distinct names (`bioplastic`, `casting-iron-gear-wheel`),
--      so this reliably selects the Nauvis production chain (R-SCOPE-1);
--   2. the item is the recipe's FIRST ("main") product;
--   3. fewest fluid ingredients (favours the solid mining/smelting chain);
--   4. lowest recipe name (deterministic final tiebreak).
local function build_recipe_index()
  if raw_items == nil then build_raw_items() end
  recipe_for_item = {}
  local candidates = {}  -- item -> { {name=, canonical=, is_main=, fluids=}, ... }
  for name, recipe in pairs(prototypes.recipe) do
    if not is_recycling(name) then
      local products = recipe.products
      if products then
        local fluids = fluid_ingredient_count(recipe)
        for i, product in ipairs(products) do
          if (product.type == "item" or product.type == "fluid")
              and not raw_items[product.name] then
            local list = candidates[product.name]
            if not list then list = {}; candidates[product.name] = list end
            list[#list + 1] = {
              name = name, canonical = (name == product.name),
              is_main = (i == 1), fluids = fluids,
            }
          end
        end
      end
    end
  end

  for item_name, list in pairs(candidates) do
    local best
    for _, c in ipairs(list) do
      if best == nil then
        best = c
      elseif c.canonical ~= best.canonical then
        if c.canonical then best = c end         -- recipe named after the item
      elseif c.is_main ~= best.is_main then
        if c.is_main then best = c end           -- main product wins
      elseif c.fluids ~= best.fluids then
        if c.fluids < best.fluids then best = c end  -- prefer fewer fluids
      elseif c.name < best.name then
        best = c                                 -- else lowest recipe name
      end
    end
    recipe_for_item[item_name] = prototypes.recipe[best.name]
  end
end

--- How many of `item_name` a recipe yields (sum over matching products,
--- weighting probabilistic products by their probability). Defaults to 1 to
--- avoid divide-by-zero on odd prototypes.
local function recipe_yield(recipe, item_name)
  local total = 0
  for _, product in ipairs(recipe.products) do
    if product.name == item_name then
      local amount = product.amount
      if amount == nil and product.amount_min and product.amount_max then
        amount = (product.amount_min + product.amount_max) / 2
      end
      amount = amount or 0
      total = total + amount * (product.probability or 1)
    end
  end
  if total <= 0 then total = 1 end
  return total
end

--- Recursively accumulate the raw cost of `qty` units of `name` (an item or
--- fluid) into `acc = { solid =, oil = }`. `is_fluid` distinguishes the two
--- namespaces (an item and a fluid can share a name in principle). `seen` is the
--- set of names on the current recursion path, for loop-breaking (R-DEATH-2 #5).
local function accumulate(name, is_fluid, qty, acc, seen, depth)
  if qty <= 0 then return end

  -- Mineable raws and items with no producing recipe are terminals.
  local recipe = (not raw_items[name]) and recipe_for_item[name] or nil

  -- Bottom out: raw / no recipe, on a cycle, or hit the depth backstop.
  if recipe == nil or seen[name] or depth > MAX_DEPTH then
    if is_fluid then
      if OIL_FLUIDS[name] then acc.oil = acc.oil + qty end
    else
      acc.solid = acc.solid + qty
    end
    return
  end

  seen[name] = true
  local yield = recipe_yield(recipe, name)
  local per_unit = qty / yield
  for _, ing in ipairs(recipe.ingredients) do
    if ing.amount and ing.amount > 0 then
      accumulate(ing.name, ing.type == "fluid", per_unit * ing.amount, acc, seen, depth + 1)
    end
  end
  seen[name] = nil
end

--- Compute (solid_count, oil_amount) for an entity from scratch (no caching).
local function compute_for_entity(entity_name)
  local proto = prototypes.entity[entity_name]
  if proto == nil then return 0, 0 end

  local placers = proto.items_to_place_this
  if placers == nil or #placers == 0 then return 0, 0 end

  -- items_to_place_this entries are ItemStackDefinition-like ({name, count}) or
  -- plain item-name strings depending on data; handle both. Take the first.
  local first = placers[1]
  local item_name = type(first) == "table" and first.name or first
  if item_name == nil then return 0, 0 end

  if recipe_for_item == nil then build_recipe_index() end

  local acc = { solid = 0, oil = 0 }
  accumulate(item_name, false, 1, acc, {}, 0)

  return math.floor(acc.solid + 0.5), acc.oil
end

----------------------------------------------------------------- public API

local function cache()
  storage.zomtorio = storage.zomtorio or {}
  storage.zomtorio.raw_cost = storage.zomtorio.raw_cost or {}
  return storage.zomtorio.raw_cost
end

--- (Re)initialise the per-entity cache. The recipe index is session-local
--- (rebuilt lazily) so it is not persisted.
function raw_cost.on_init()
  storage.zomtorio = storage.zomtorio or {}
  storage.zomtorio.raw_cost = {}
end

--- Prototypes may have changed across a mod update — drop the cache and the
--- recipe index so both rebuild against the new data.
function raw_cost.on_configuration_changed()
  storage.zomtorio = storage.zomtorio or {}
  storage.zomtorio.raw_cost = {}
  recipe_for_item = nil
  raw_items = nil
end

--- @return integer solid_count  total solid raw units (1 zombie each, R-DEATH-2)
--- @return number  oil_amount   crude-oil-equivalent fluid in the cost (R-DEATH-4)
function raw_cost.for_entity(entity_name)
  local c = cache()
  local hit = c[entity_name]
  if hit then return hit.solid, hit.oil end

  local solid, oil = compute_for_entity(entity_name)
  c[entity_name] = { solid = solid, oil = oil }
  return solid, oil
end

return raw_cost
