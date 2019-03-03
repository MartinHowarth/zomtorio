--- Pollution setup
-- @module pollution
-- NPE Scripts to track pollution and control biter evolution

local pollution = {}

pollution.check_pollution = function(_)
  if game.ticks_played % 240 == 0 then
    local pollution_modifier = 1000000000
    local evo = game.forces['enemy'].evolution_factor_by_pollution
    local new_pollution = math.floor((evo - global.last_evo) * pollution_modifier)
    global.last_pollution = new_pollution
    global.pollution_unspent = global.pollution_unspent + new_pollution
    global.last_evo = evo
    game.forces['player'].item_production_statistics.on_flow("pollution",(new_pollution/800))
    pollution.cap_evo_at_max('enemy')
  end
end

pollution.cap_evo_at_max = function(force_name)
  if global.max_evo == nil then global.max_evo = 1 end
  assert(game.forces[force_name], "pollution.cap_evo_at_max: force does not exist")
  if game.forces[force_name].evolution_factor > global.max_evo then
    game.forces[force_name].evolution_factor = global.max_evo
  end
end

pollution.set_max_evo = function(value)
  assert(value > 1 or value < 0, "pollution.set_max_evolution: value given must be between 0 and 1")
  global.max_evo = value
end

pollution.reset = function()
  game.forces['enemy'].reset_evolution()
  global.pollution_unspent = 0
  global.last_evo = 0
end

pollution.init = function()
  --configure evolution
  --game.map_settings.enemy_evolution.time_factor = time or 0.000004
  --game.map_settings.enemy_evolution.destroy_factor = destroy or 0.002
  --game.map_settings.enemy_evolution.pollution_factor = pollute or 0.000015
  --game.map_settings.enemy_evolution.enabled = true

  --global.last_biter = 0
  --global.biter_time = 1500
  --global.hurry_radius = 5
  global.last_evo = 0
  global.max_evo = 1
  global.last_pollution = 0
  global.pollution_unspent = 0

end

return pollution


