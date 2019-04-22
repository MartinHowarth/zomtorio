
--local pollution = require("libs/pollution")
local zombies = require("libs/zombies")


local function init_settings()

    --if global.player == nil then
    --  for _, player in ipairs(game.connected_players) do
    --    global.player = player
    --    break
    --  end
    --end

    game.map_settings.enemy_expansion.max_expansion_distance = 20
    game.map_settings.enemy_expansion.min_base_spacing = 1
    game.map_settings.enemy_expansion.enemy_building_influence_radius = 1
    game.map_settings.enemy_expansion.friendly_base_influence_radius = 1
    --game.map_settings.enemy_expansion.settler_group_min_size = 25
    --game.map_settings.enemy_expansion.settler_group_max_size = 100
    game.map_settings.enemy_expansion.min_expansion_cooldown = 2 * 3600
    game.map_settings.enemy_expansion.max_expansion_cooldown = 4 * 3600

    -- want frequent swarms
    game.map_settings.unit_group.max_group_gathering_time = 2 * 3600
    -- Fewer groups than normal, but much larger
    game.map_settings.unit_group.max_unit_group_size = 500
    game.map_settings.unit_group.max_gathering_unit_groups = 10

    -- Force the groups to be smaller, so the enemies form a dense swarm
    game.map_settings.unit_group.max_group_radius = 10
    game.map_settings.unit_group.min_group_radius = 0
    game.map_settings.unit_group.max_member_speedup_when_behind = 3.0
    --settings.unit_group.max_group_slowdown_factor = 1.0
    --settings.unit_group.max_group_member_fallback_factor = 10
    game.map_settings.unit_group.member_disown_distance = 50

    game.map_settings.steering.default.radius = 0.1
    --game.map_settings.steering.default.separation_force = 0
    --game.map_settings.steering.default.separation_factor = 0.4
    game.map_settings.steering.moving.radius = 0.1
    --game.map_settings.steering.moving.separation_force = 0
    --game.map_settings.steering.moving.separation_factor = 20
    --game.map_settings.steering.moving.force_unit_fuzzy_goto_behavior = true

    --game.map_settings.path_finder.stale_enemy_with_same_destination_collision_penalty = 0
    --game.map_settings.path_finder.ignore_moving_enemy_collision_distance = 0
    --game.map_settings.path_finder.enemy_with_different_destination_collision_penalty = 0

end

--
--script.on_event({defines.events.on_tick},
--   function (event)
--     --init_settings()
--       --pollution.check_pollution()
--       --zombies.on_tick(event)
--   end
--)

script.on_event({defines.events.on_entity_died},
   function (event)
     zombies.on_eat_building(event)
   end
)


local function onInit()
  global.main_surface = game.surfaces['nauvis']
  global.player = nil
  global.recipe_cache = {}
  init_settings()
  --pollution.init()
  --zombies.init()
end

script.on_init(onInit)
script.on_configuration_changed(onInit)
