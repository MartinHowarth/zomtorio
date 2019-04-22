local utils = {}

local exclude = {
  ["used-up-uranium-fuel-cell"] = true,
}

utils.rawingredients = function(recipe)
  ret = getRawIngredients(recipe, exclude)
  return ret
end

function getIngredients(recipe)
  local ingredients = {}
  for i, ingredient in pairs(recipe.ingredients) do
    if (ingredient.name and ingredient.amount) then
      ingredients[ingredient.name] = ingredient.amount
    elseif (ingredient[1] and ingredient[2]) then
      ingredients[ingredient[1]] = ingredient[2]
    end
  end
  return ingredients
end

function getProducts(recipe)
  local products = {}
  if (recipe.products) then
    for i, product in pairs(recipe.products) do
      local amount
      if product.amount ~= nil then
        amount = product.amount
      else
        amount = product.amount_max
      end

      if (product.name and amount) then
        products[product.name] = amount
      end
    end
  elseif (recipe.main_product) then
    local amount = 1
    if (recipe.result_count) then
      amount = recipe.result_count
    end
    products[recipe.main_product] = amount
  end
  return products
end

function getRecipes(item)
  local recipes = {}
  for i, recipe in pairs(game.recipe_prototypes) do
    local products = getProducts(recipe)
    for product, amount in pairs(products) do
      if (product == item) then
        table.insert(recipes, recipe)
      end
    end
  end
  return recipes
end

function getRawIngredients(recipe, excluded)
  local raw_ingredients = {}
  for name, amount in pairs(getIngredients(recipe)) do
    -- Do not use an item as its own ingredient
    if (excluded[name]) then
      return { ERROR_INFINITE_LOOP = name }
    end
    local excluded_ingredients = { [name] = true }
    for k, v in pairs(excluded) do
      excluded_ingredients[k] = true
    end

    -- Recursively find the sub-ingredients for each ingredient
    -- There might be more than one recipe to choose from
    local subrecipes = {}
    local loop_error = nil
    for i, subrecipe in pairs(getRecipes(name)) do
      local subingredients = getRawIngredients(subrecipe, excluded_ingredients)
      if (subingredients.ERROR_INFINITE_LOOP) then
        loop_error = subingredients.ERROR_INFINITE_LOOP
      else
        local value = 0
        for subproduct, subamount in pairs(getProducts(subrecipe)) do
          value = value + subamount
        end

        local divisor = 0
        for subingredient, subamount in pairs(subingredients) do
          divisor = divisor + subamount
        end

        if (divisor == 0) then
          divisor = 1
        end

        table.insert(subrecipes, { recipe = subrecipe, ingredients = subingredients, value = value / divisor })
      end
    end

    if (#subrecipes == 0) then
      if (loop_error and loop_error ~= name) then
        -- This branch of the recipe tree is invalid
        return { ERROR_INFINITE_LOOP = loop_error }
      else
        -- This is a raw resource
        if (raw_ingredients[name]) then
          raw_ingredients[name] = raw_ingredients[name] + amount
        else
          raw_ingredients[name] = amount
        end

      end
    else
      -- Pick the cheapest recipe
      local best_recipe = nil
      local best_value = 0
      for i, subrecipe in pairs(subrecipes) do
        if (best_value < subrecipe.value) then
          best_value = subrecipe.value
          best_recipe = subrecipe
        end
      end

      local multiple = 0
      for subname, subamount in pairs(getProducts(best_recipe.recipe)) do
        multiple = multiple + subamount
      end

      for subname, subamount in pairs(best_recipe.ingredients) do
        if (raw_ingredients[subname]) then
          raw_ingredients[subname] = raw_ingredients[subname] + amount * subamount / multiple
        else
          raw_ingredients[subname] = amount * subamount / multiple
        end
      end
    end
  end

  return raw_ingredients
end

return utils
