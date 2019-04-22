for k, unit in pairs(data.raw["unit"]) do
    if (string.find(k, "biter") or string.find(k, "spitter")) and unit.collision_box then
        -- Allow them to pack closely together to form a more intimidating swarm
        unit.collision_box = {
        {unit.collision_box[1][1] * 0.2, unit.collision_box[1][2] * 0.2},
        {unit.collision_box[2][1] * 0.2, unit.collision_box[2][2] * 0.2}
        }

        -- Make enemies move more slowly
        unit.movement_speed = unit.movement_speed / 4

        -- Make enemies weaker, but cheaper to spawn. Overall increases total biter health needed to deal with.
        unit.max_health = unit.max_health / 4
        unit.pollution_to_join_attack = unit.pollution_to_join_attack / 20

        -- Never stop following once they've got your scent
        unit.min_pursue_time = 100000000
        unit.max_pursue_distance = 100000000
        --unit.vision_distance = 50
    end
end

for k, spawner in pairs(data.raw["unit-spawner"]) do
    spawner.max_count_of_owned_units = 100
    spawner.spawning_spacing = 1
    --spawner.max_friends_around_to_spawn = 30
    spawner.spawning_cooldown = { 100, 1 }
end

-- Disable worms early on - base expansion is very aggressive.
data.raw["turret"]["small-worm-turret"].build_base_evolution_requirement = 0.15

--for k, map_settings in pairs(data.raw["map-settings"]) do
--    map_settings.enemy_expansion.max_expansion_distance = 20
--    map_settings.enemy_expansion.min_base_spacing = 1
--    map_settings.enemy_expansion.enemy_building_influence_radius = 1
--    map_settings.enemy_expansion.friendly_base_influence_radius = 1
--    map_settings.enemy_expansion.settler_group_min_size = 25
--    map_settings.enemy_expansion.settler_group_max_size = 100
--    map_settings.enemy_expansion.min_expansion_cooldown = 2 * 3600
--    map_settings.enemy_expansion.max_expansion_cooldown = 4 * 3600
--
--    map_settings.unit_group.max_group_gathering_time = 5 * 3600  -- want relatively frequent swarms
--    map_settings.unit_group.max_unit_group_size = 10000
--    map_settings.unit_group.max_gathering_unit_groups = 100
--    map_settings.unit_group.max_group_radius = 0.0
--    map_settings.unit_group.min_group_radius = 0.0
--    map_settings.unit_group.max_member_speedup_when_behind = 3.0
--    --settings.unit_group.max_group_slowdown_factor = 1.0
--    --settings.unit_group.max_group_member_fallback_factor = 10
--    map_settings.unit_group.member_disown_distance = 50
--
--    map_settings.steering.default.radius = 0
--    map_settings.steering.default.separation_force = 0
--    map_settings.steering.default.separation_factor = 0.4
--    map_settings.steering.moving.radius = 0
--    map_settings.steering.moving.separation_force = 0
--    map_settings.steering.moving.separation_factor = 20
--    map_settings.steering.moving.force_unit_fuzzy_goto_behavior = true
--
--    map_settings.path_finder.stale_enemy_with_same_destination_collision_penalty = 0
--    map_settings.path_finder.ignore_moving_enemy_collision_distance = 0
--    map_settings.path_finder.enemy_with_different_destination_collision_penalty = 0
--
--end
