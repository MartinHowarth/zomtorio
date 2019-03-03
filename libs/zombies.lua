--- Zombies
-- @module zombies

local zombies = {}

local COST_PER_ZOMBIE = 100
local MIN_SECONDS_BETWEEN_SPAWN = 1

zombies.spawn_zombies = function(spawn, force)
  local surface = global.main_surface
  local actual_pos = surface.find_non_colliding_position('small-biter', spawn, 20, 2)

  -- Don't init immediately... necessary for some reason.
  if global.all_zombies_group == nil and (global.pollution_unspent > 0) then
      global.all_zombies_group = surface.create_unit_group({ position = global.player.position, force = 'enemy' })
      global.all_zombies_group.set_command({
          type = defines.command.attack,
          target = global.player.character,
          distraction = defines.distraction.by_damage
        }
      )
  end

  if actual_pos then
    while (global.pollution_unspent > 0) do
      global.pollution_unspent = global.pollution_unspent - COST_PER_ZOMBIE
    --for _ = 1, quant do
    --  if (global.pollution_unspent > 0) then
    --    global.pollution_unspent = global.pollution_unspent - COST_PER_ZOMBIE
    --  else
    --    break
    --  end
      local biter = surface.create_entity { name = "small-biter", position = actual_pos, force = force }
      actual_pos = surface.find_non_colliding_position('small-biter', spawn, 20, 2)
      --group.add_member(biter)
      --group.set_command({
      --  type = defines.command.go_to_location,
      --  destination = target_entity.position,
      --  distraction = defines.distraction.by_anything
      --})
      global.all_zombies_group.add_member(biter)
    end
  end
  ---- Force all zombies to keep moving.
  ---- Use a for loop and break so this only happens if there is at least one zombie
  --for _, _ in ipairs(all_zombies_group.members) do
  --  all_zombies_group.start_moving()
  --  break
  --end
end

zombies.on_tick = function(event)
  if event.tick % (60 * MIN_SECONDS_BETWEEN_SPAWN) == 1 then
    if global.player == nil then
      for _, player in ipairs(game.connected_players) do
        global.player = player
        break
      end
    end

    for _, player in ipairs(game.connected_players) do
      --local position = player.position
      local position = {x = 100, y = 100}
      zombies.spawn_zombies(position, 'enemy')
    end
  end
end

zombies.init = function()
  global.all_zombies_group = nil  -- TODO: Make zombie group per-player
end

return zombies
