--- Zombies
-- @module zombies
local utils = require("libs/utils")

local zombies = {}

local IRON_PER_BITER = 5
local COPPER_PER_SPITTER = 5
local MEDIUM_OIL_THRESHOLD = 0
local BIG_OIL_THRESHOLD = 50


zombies.on_eat_building = function(event)
  if event.force.name == 'enemy' then
    local death_position = event.entity.position
    local recipes = game.recipe_prototypes
    local raw_ingredients
    if recipes[event.entity.name] == nil then
      return
    end

    -- Cache the recipe cost calculation.
    if global.recipe_cache[event.entity.name] ~= nil then
      raw_ingredients = global.recipe_cache[event.entity.name]
    else
      raw_ingredients = utils.rawingredients(recipes[event.entity.name])
      global.recipe_cache[event.entity.name] = raw_ingredients
    end

    local biter_type = 'small-biter'
    local spitter_type = 'small-spitter'

    if raw_ingredients['crude-oil'] == nil then
      raw_ingredients['crude-oil'] = 0
    end

    -- If there is oil, then the biters will eat it to mutate stronger!
    -- Upgrade the types of biters spawned based on how much oil is present in the raw ingredients.
    if raw_ingredients['crude-oil'] > BIG_OIL_THRESHOLD then
      biter_type = 'big-biter'
      spitter_type = 'big-spitter'
    elseif raw_ingredients['crude-oil'] > MEDIUM_OIL_THRESHOLD then
      biter_type = 'medium-biter'
      spitter_type = 'medium-spitter'
    end

    spawn_based_on_ingredient(
            raw_ingredients,
            'iron-ore',
            IRON_PER_BITER,
            biter_type,
            1,
            death_position,
            event.force
    )
    spawn_based_on_ingredient(
            raw_ingredients,
            'copper-ore',
            COPPER_PER_SPITTER,
            spitter_type,
            1,
            death_position,
            event.force
    )

  end
end

function spawn_based_on_ingredient(raw_ingredients, ingredient_name, ingredient_per_spawn, spawn_name, minimum_spawn, position, spawn_force)
    local surface = global.main_surface
    if raw_ingredients[ingredient_name] then
      local num_biter = math.floor(raw_ingredients[ingredient_name] / ingredient_per_spawn)
      -- Always spawn at least one spitter, if any copper was used
      if raw_ingredients[ingredient_name] > 0 then
        num_biter = math.max(num_biter, minimum_spawn)
      end
      for i=1,num_biter do
        local spawn_position = surface.find_non_colliding_position(spawn_name, position, 20, 2)
        if position ~= nil then
          local biter = surface.create_entity { name = spawn_name, position = spawn_position, force = spawn_force }
        end
      end
    end
end

return zombies

--------- Old code below, might use for spawning attack waves later based on total pollution???

--local COST_PER_ZOMBIE = 100
--local MIN_SECONDS_BETWEEN_SPAWN = 1
--
--zombies.spawn_zombies = function(spawn, force)
--  local surface = global.main_surface
--  local actual_pos = surface.find_non_colliding_position('small-biter', spawn, 20, 2)
--
--  -- Don't init immediately... necessary for some reason.
--  if global.all_zombies_group == nil and (global.pollution_unspent > 0) then
--      global.all_zombies_group = surface.create_unit_group({ position = global.player.position, force = 'enemy' })
--      global.all_zombies_group.set_command({
--          type = defines.command.attack,
--          target = global.player.character,
--          distraction = defines.distraction.by_damage
--        }
--      )
--  end
--
--  if actual_pos then
--    while (global.pollution_unspent > 0) do
--      global.pollution_unspent = global.pollution_unspent - COST_PER_ZOMBIE
--    --for _ = 1, quant do
--    --  if (global.pollution_unspent > 0) then
--    --    global.pollution_unspent = global.pollution_unspent - COST_PER_ZOMBIE
--    --  else
--    --    break
--    --  end
--      local biter = surface.create_entity { name = "small-biter", position = actual_pos, force = force }
--      actual_pos = surface.find_non_colliding_position('small-biter', spawn, 20, 2)
--      --group.add_member(biter)
--      --group.set_command({
--      --  type = defines.command.go_to_location,
--      --  destination = target_entity.position,
--      --  distraction = defines.distraction.by_anything
--      --})
--      global.all_zombies_group.add_member(biter)
--    end
--  end
--  ---- Force all zombies to keep moving.
--  ---- Use a for loop and break so this only happens if there is at least one zombie
--  --for _, _ in ipairs(all_zombies_group.members) do
--  --  all_zombies_group.start_moving()
--  --  break
--  --end
--end
--
--zombies.on_tick = function(event)
--  if event.tick % (60 * MIN_SECONDS_BETWEEN_SPAWN) == 1 then
--    if global.player == nil then
--      for _, player in ipairs(game.connected_players) do
--        global.player = player
--        break
--      end
--    end
--
--    for _, player in ipairs(game.connected_players) do
--      --local position = player.position
--      local position = {x = 100, y = 100}
--      zombies.spawn_zombies(position, 'enemy')
--    end
--  end
--end
--
--zombies.init = function()
--  global.all_zombies_group = nil  -- TODO: Make zombie group per-player
--end
