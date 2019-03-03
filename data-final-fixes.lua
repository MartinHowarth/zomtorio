
-- Allow swarming (reduce collision box size)
-- Make biters walk really slowly
for k, unit in pairs(data.raw["unit"]) do
    if (string.find(k, "biter") or string.find(k, "spitter")) and unit.collision_box then
        unit.collision_box = {
        {unit.collision_box[1][1] * 0.2, unit.collision_box[1][2] * 0.2},
        {unit.collision_box[2][1] * 0.2, unit.collision_box[2][2] * 0.2}
        }
        unit.max_health = unit.max_health / 2
        unit.movement_speed = unit.movement_speed / 4
        unit.min_pursue_time = 100000000
        unit.max_pursue_distance = 100000000
        unit.vision_distance = 50
        unit.pollution_to_join_attack = unit.pollution_to_join_attack / 40
    end
end

for k, spawner in pairs(data.raw["unit-spawner"]) do
    spawner.max_count_of_owned_units = 100
    spawner.spawning_spacing = 1
    spawner.max_friends_around_to_spawn = 30
    spawner.spawning_cooldown = { 100, 1 }
end

-- Disable worms early on - base expansion is very aggressive.
data.raw["turret"]["small-worm-turret"].build_base_evolution_requirement = 0.15

for k, settings in pairs(data.raw["map-settings"]) do
    settings.enemy_expansion.max_expansion_distance = 20
    settings.enemy_expansion.friendly_base_influence_radius = 1
    settings.enemy_expansion.friendly_base_influence_radius = 1
    settings.enemy_expansion.settler_group_min_size = 25
    settings.enemy_expansion.settler_group_max_size = 100
    settings.enemy_expansion.max_expansion_cooldown = 2 * 3600
    settings.enemy_expansion.max_expansion_cooldown = 4 * 3600

    settings.unit_group.max_group_gathering_time = 2 * 3600
    settings.unit_group.max_unit_group_size = 10000
    settings.unit_group.max_gathering_unit_groups = 100
    settings.unit_group.max_group_radius = 10.0
    settings.unit_group.min_group_radius = 1.0
    settings.unit_group.max_member_speedup_when_behind = 1.0
    settings.unit_group.max_group_slowdown_factor = 1.0
    settings.unit_group.max_group_member_fallback_factor = 10
    settings.unit_group.member_disown_distance = 50

    settings.steering.default.radius = 0.4
    settings.steering.default.separation_factor = 0.4
    settings.steering.moving.radius = 0.2
    settings.steering.moving.separation_factor = 0.2

end
