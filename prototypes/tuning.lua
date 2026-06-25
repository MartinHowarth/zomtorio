-- S10 — dense-swarm tuning of EXISTING prototypes, run at data-final-fixes so it
-- lands on top of every other mod's enemies (and on the night variants and horde
-- clusters this mod already created at the data stage).
--
-- The feel: enemies are individually weak (low health), slow, pack tightly into a
-- dense swarm (tiny collision box), are recruited cheaply by pollution (R-GEN-2),
-- never lose the scent (R-BAL-3), and pour out of much denser nests (R-GEN-3).
--
-- Balance (R-BAL):
--   * R-BAL-1 — the basic zombie (small-biter) dies to one player punch (8 dmg)
--     around evolution 1.0. After max_health/4 small-biter is ~3.75, already <= 8;
--     we clamp it to <= 8 explicitly so the one-punch guarantee can't drift if the
--     vanilla value changes.
--   * R-BAL-2 — "tougher past evo ~1.3" is NOT done by scaling the basic zombie's
--     prototype health (the engine has no runtime per-prototype health scaling, and
--     a prototype's max_health is fixed at the data stage). It is realised through
--     the TIER MIX shifting with evolution: medium/big biters keep progressively
--     higher health than small (after /4 still well above small), and higher
--     evolution shifts spawns toward those tougher tiers. So the curve lives in the
--     spawn-tier selection, not in mutating one prototype's health here.

local tiers = require("lib.tiers")

local pollution_mult = (settings.startup["zomtorio-pollution-cost-multiplier"]
  and settings.startup["zomtorio-pollution-cost-multiplier"].value) or 0.05
local nest_rate = (settings.startup["zomtorio-nest-spawn-rate"]
  and settings.startup["zomtorio-nest-spawn-rate"].value) or 2.0

-- The player's punch deals 8 (the zomtorio-zombie-melee retype keeps amount 8).
-- The basic zombie must die to one punch at evo 1.0 (R-BAL-1).
local PUNCH_DAMAGE = 8

-- Tiny collision so a crowd of zombies overlaps into a dense, intimidating mass.
local COLLISION_SCALE = 0.2
-- Slower than vanilla — at /4, double-speed at night still reads below a vanilla
-- biter (see lib/night.lua header).
local SPEED_DIVISOR = 4
-- Individually weak.
local HEALTH_DIVISOR = 4
-- Never lose the player's scent (R-BAL-3): effectively unbounded pursuit.
local PURSUE_FOREVER = 1e8

--- Scale a bounding box about its own centre by `factor`, in place-safe (returns a
--- fresh box). A box is { {x1,y1}, {x2,y2} } and may carry an orientation 3rd elem.
local function scale_box(box, factor)
  if type(box) ~= "table" or type(box[1]) ~= "table" or type(box[2]) ~= "table" then
    return box
  end
  local scaled = {
    { box[1][1] * factor, box[1][2] * factor },
    { box[2][1] * factor, box[2][2] * factor },
  }
  if box[3] ~= nil then scaled[3] = box[3] end
  return scaled
end

------------------------------------------------------- units (biters & spitters)
-- The name match on "biter"/"spitter" deliberately ALSO catches the
-- *-zomtorio-night variants from prototypes/night.lua, so day and night forms get
-- the same /4 speed treatment and the night/day ratio (1 + speedup) is preserved.
-- It does NOT catch the zomtorio-horde-* clusters (no "biter" in the name) — those
-- are tuned explicitly below so their script-managed health headroom is untouched.
for name, unit in pairs(data.raw.unit) do
  if string.find(name, "biter") or string.find(name, "spitter") then
    if unit.collision_box then
      unit.collision_box = scale_box(unit.collision_box, COLLISION_SCALE)
    end

    if unit.movement_speed then
      unit.movement_speed = unit.movement_speed / SPEED_DIVISOR
    end

    if unit.max_health then
      unit.max_health = unit.max_health / HEALTH_DIVISOR
    end

    -- Cheaper pollution recruitment => far more (weak) attackers (R-GEN-2).
    if unit.pollution_to_join_attack then
      unit.pollution_to_join_attack = unit.pollution_to_join_attack * pollution_mult
    end

    -- Relentless pursuit (R-BAL-3).
    unit.min_pursue_time = PURSUE_FOREVER
    unit.max_pursue_distance = PURSUE_FOREVER
  end
end

-- R-BAL-1: guarantee the basic zombie dies to a single punch at evo 1.0. The /4
-- above already puts small-biter at ~3.75 <= 8; clamp explicitly so the guarantee
-- survives any change to the vanilla base value.
local small = data.raw.unit[tiers.INDIVIDUAL.small]
if small and (not small.max_health or small.max_health > PUNCH_DAMAGE) then
  small.max_health = PUNCH_DAMAGE
end

------------------------------------------------------------------- horde clusters
-- Clusters DON'T contain "biter", so the loop above missed them. A cluster must
-- move at the tuned day-zombie pace (not vanilla pace), and pack tightly like the
-- swarm it represents. Its max_health is deliberately left alone — lib/horde.lua
-- relies on the huge headroom set in prototypes/entities.lua to track population —
-- and so is pollution_to_join_attack (clusters aren't pollution-recruited).
-- Both day AND night cluster forms (HORDE_ALL): the night variant was cloned from
-- the base cluster at the data stage with full speed, so it must get the same /4
-- here or the night/day ratio (1 + speedup) would balloon.
for _, cluster_name in pairs(tiers.HORDE_ALL) do
  local cluster = data.raw.unit[cluster_name]
  if cluster then
    if cluster.movement_speed then
      cluster.movement_speed = cluster.movement_speed / SPEED_DIVISOR
    end
    if cluster.collision_box then
      cluster.collision_box = scale_box(cluster.collision_box, COLLISION_SCALE)
    end
  end
end

------------------------------------------------------------------- spawners (nests)
-- Denser nests (R-GEN-3): more owned units, shorter cooldown, tighter spacing,
-- scaled by the nest-spawn-rate setting (default 2.0). Be defensive: not every
-- unit-spawner mod prototype carries every field.
--
-- Vanilla biter-spawner baseline: max_count_of_owned_units = 7,
-- spawning_cooldown = {360, 150} (= {max, min}), spawning_spacing = ~3.
-- Carry-over (1.1) hard-set 100 owned units / {100, 1} cooldown / spacing 1; we
-- reproduce that intent but scale by the setting so the slider actually matters.
for _, spawner in pairs(data.raw["unit-spawner"]) do
  -- Owned-unit cap scales up with the rate: e.g. rate 2.0 -> 100.
  local base_owned = 50
  spawner.max_count_of_owned_units =
    math.floor(math.max(spawner.max_count_of_owned_units or 7, base_owned * nest_rate))

  -- Higher rate -> shorter cooldown (faster spawning). spawning_cooldown is
  -- {max, min} ticks. Divide by the rate, floored so it never hits zero.
  if type(spawner.spawning_cooldown) == "table" then
    local cd = spawner.spawning_cooldown
    if cd[1] then cd[1] = math.max(20, math.floor(cd[1] / nest_rate)) end
    if cd[2] then cd[2] = math.max(1, math.floor(cd[2] / nest_rate)) end
  end

  -- Tighter spacing packs the spawned swarm together.
  if spawner.spawning_spacing then
    spawner.spawning_spacing = math.min(spawner.spawning_spacing, 1)
  end

  -- More friends allowed nearby before a spawner holds off, so nests stay dense.
  if spawner.max_friends_around_to_spawn then
    spawner.max_friends_around_to_spawn =
      math.floor(spawner.max_friends_around_to_spawn * nest_rate)
  end
end

------------------------------------------------------------------- worms pushed back
-- Base expansion is very aggressive under this tuning; keep worms out of the early
-- game so a fresh start isn't immediately turret-walled (carry-over).
local small_worm = data.raw.turret and data.raw.turret["small-worm-turret"]
if small_worm then
  small_worm.build_base_evolution_requirement =
    math.max(small_worm.build_base_evolution_requirement or 0, 0.15)
end
