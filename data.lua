
-- Allow swarming (reduce collision box size)
-- Make biters walk really slowly
for k, unit in pairs(data.raw["unit"]) do
    if (string.find(k, "biter") or string.find(k, "spitter")) and unit.collision_box then
        unit.collision_box = {
        {unit.collision_box[1][1] * 0.20, unit.collision_box[1][2] * 0.20},
        {unit.collision_box[2][1] * 0.20, unit.collision_box[2][2] * 0.20}
        }
        unit.movement_speed = 0.01
    end
end