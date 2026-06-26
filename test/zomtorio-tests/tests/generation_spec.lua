-- S10a — enemy generation tuning (R-GEN-2/3) + balance (R-BAL-1/2) + dense map
-- settings (R-GEN-3).
--
-- Prototype tuning is verified by reading prototypes at runtime; map settings by
-- reading game.map_settings after horde.on_init(). Vanilla baselines are hardcoded
-- from the unmodded base data (small-biter: speed 0.2, max_health 15, collision
-- box +/-0.2; biter-spawner: max_count_of_owned_units 7; enemy_expansion cooldowns
-- 14400/216000) so a regression in the tuning shows up as a failed comparison.
--
-- Some prototype fields are NOT exposed on LuaEntityPrototype at runtime —
-- pollution_to_join_attack and build_base_evolution_requirement among them (the
-- task brief flagged this; verified against the runtime API). Those rules are
-- exercised at the data stage and can't be asserted on the live prototype, so the
-- relevant tests below assert what IS observable and note the gap.

local T = require("harness.runner")

local config = require("__Zomtorio__.lib.config")
local horde  = require("__Zomtorio__.lib.horde")
local tiers  = require("__Zomtorio__.lib.tiers")

-- Vanilla (unmodded) baselines.
local VANILLA_SMALL_BITER_SPEED  = 0.2
local VANILLA_SMALL_BITER_HEALTH = 15
local VANILLA_SMALL_BITER_HALF_BOX = 0.2   -- collision box is +/-0.2
local VANILLA_SPAWNER_OWNED      = 7       -- biter-spawner max_count_of_owned_units
local VANILLA_MIN_EXPANSION_CD   = 14400   -- enemy_expansion default min cooldown
local VANILLA_MAX_EXPANSION_CD   = 216000  -- enemy_expansion default max cooldown
local PUNCH_DAMAGE               = 8       -- player punch (zomtorio-zombie-melee)

----------------------------------------------------------------- biters tuned
T.test("small-biter is tuned slow and weak with a shrunken collision box (R-GEN/R-BAL)", function(t)
  local p = prototypes.entity["small-biter"]
  t.assert.not_nil(p, "small-biter prototype should exist")

  -- Speed cut hard below vanilla (data-final-fixes divides by 4 => 0.05).
  t.assert.is_true(p.speed < VANILLA_SMALL_BITER_SPEED * 0.5,
    string.format("small-biter speed %.4f should be << vanilla %.2f", p.speed, VANILLA_SMALL_BITER_SPEED))

  -- Health low (clamped to one-punch, see R-BAL-1 test) and well under vanilla.
  t.assert.is_true(p.get_max_health() < VANILLA_SMALL_BITER_HEALTH,
    string.format("small-biter health %.2f should be < vanilla %d", p.get_max_health(), VANILLA_SMALL_BITER_HEALTH))

  -- Collision box shrunk (x0.2): half-width should be ~0.04, well under vanilla 0.2.
  local box = p.collision_box
  local half_w = (box.right_bottom.x - box.left_top.x) / 2
  t.assert.is_true(half_w < VANILLA_SMALL_BITER_HALF_BOX * 0.5,
    string.format("small-biter collision half-width %.3f should be << vanilla %.2f", half_w, VANILLA_SMALL_BITER_HALF_BOX))
end)

----------------------------------------------- night-variant ratio preserved
T.test("the night variant keeps the day x (1+speedup) ratio after tuning", function(t)
  local day = prototypes.entity["small-biter"]
  local night = prototypes.entity["small-biter-zomtorio-night"]
  t.assert.not_nil(night, "small-biter-zomtorio-night should exist")

  -- Tuning matched both day and night forms (name match catches both), so the
  -- baked ratio (1 + night_speedup) survives. Allow a hair of float tolerance.
  local expected = day.speed * (1 + config.night_speedup())
  t.assert.at_least(expected - 0.0001, night.speed, "night speed >= day x (1+speedup)")
  t.assert.at_least(night.speed, expected + 0.0001, "night speed <= day x (1+speedup)")
end)

------------------------------------------------------------- cluster speed tuned
T.test("a horde cluster moves at the tuned day-zombie pace, not vanilla pace", function(t)
  local cluster = prototypes.entity[tiers.SWARM.small]
  t.assert.not_nil(cluster, "zomtorio-swarm-small prototype should exist")
  local day = prototypes.entity["small-biter"]
  -- Cluster speed was divided by 4 just like the day biter, so they match.
  t.assert.at_least(day.speed - 0.0001, cluster.speed, "cluster speed >= tuned day biter")
  t.assert.at_least(cluster.speed, day.speed + 0.0001, "cluster speed <= tuned day biter")
end)

--------------------------------------------------------------- R-BAL-1 one-punch
T.test("R-BAL-1: small-biter dies to a single 8-damage punch", function(t)
  local p = prototypes.entity["small-biter"]
  t.assert.at_least(p.get_max_health(), PUNCH_DAMAGE,
    string.format("small-biter health %.2f must be <= punch damage %d", p.get_max_health(), PUNCH_DAMAGE))
end)

------------------------------------------------------- R-BAL-2 tier toughness order
-- R-BAL-2 ("tougher past evo ~1.3") is realised through the tier MIX, not by
-- scaling a prototype at runtime: medium and big stay progressively tougher than
-- small even after the /4, and higher evolution shifts spawns toward them.
T.test("R-BAL-2: tier health is strictly ordered small < medium < big", function(t)
  local s = prototypes.entity[tiers.INDIVIDUAL.small].get_max_health()
  local m = prototypes.entity[tiers.INDIVIDUAL.medium].get_max_health()
  local b = prototypes.entity[tiers.INDIVIDUAL.big].get_max_health()
  t.assert.is_true(s < m, string.format("small (%.1f) < medium (%.1f)", s, m))
  t.assert.is_true(m < b, string.format("medium (%.1f) < big (%.1f)", m, b))
end)

----------------------------------------------------------------- nests denser
T.test("R-GEN-3: a biter-spawner sustains far more units than vanilla", function(t)
  local sp = prototypes.entity["biter-spawner"]
  t.assert.not_nil(sp, "biter-spawner prototype should exist")
  -- max_count_of_owned_units IS exposed at runtime (double). Tuned base 50 x
  -- nest_rate (default 2.0) => 100, vs vanilla 7.
  t.assert.is_true(sp.max_count_of_owned_units > VANILLA_SPAWNER_OWNED,
    string.format("spawner owned-unit cap %.0f should exceed vanilla %d",
      sp.max_count_of_owned_units, VANILLA_SPAWNER_OWNED))
end)

------------------------------------ R-GEN-2 / worms: documented runtime gaps
-- pollution_to_join_attack and build_base_evolution_requirement are NOT exposed
-- on LuaEntityPrototype at runtime, so the cranked pollution recruitment (R-GEN-2)
-- and the worm evolution push-back are applied at the data stage but can't be read
-- back from the live prototype here. We assert the prototypes at least exist so a
-- rename/removal is still caught; the value changes are covered by the data-stage
-- code and the mod loading clean.
T.test("R-GEN-2 / worms: affected prototypes exist (value gap noted, not runtime-readable)", function(t)
  t.assert.not_nil(prototypes.entity["small-biter"], "small-biter (pollution recruitment target) exists")
  t.assert.not_nil(prototypes.entity["small-worm-turret"], "small-worm-turret (evolution push-back target) exists")
end)

--------------------------------------------------------- map settings applied
T.test("R-GEN-3: horde.on_init applies denser map settings", {
  function(t)
    horde.on_init()
  end,
  { after = 1, fn = function(t)
    local exp = game.map_settings.enemy_expansion
    -- Far shorter expansion cooldowns than the engine defaults => denser, more
    -- frequent expansion.
    t.assert.is_true(exp.min_expansion_cooldown < VANILLA_MIN_EXPANSION_CD,
      string.format("min expansion cooldown %d should be < vanilla %d", exp.min_expansion_cooldown, VANILLA_MIN_EXPANSION_CD))
    t.assert.is_true(exp.max_expansion_cooldown < VANILLA_MAX_EXPANSION_CD,
      string.format("max expansion cooldown %d should be < vanilla %d", exp.max_expansion_cooldown, VANILLA_MAX_EXPANSION_CD))

    -- Dense, large, tightly-packed unit groups.
    local ug = game.map_settings.unit_group
    t.assert.at_least(500, ug.max_unit_group_size, "unit groups are large (>=500)")
    t.assert.is_true(ug.max_group_radius <= 10, "groups are packed tight (small radius)")
  end },
})

------------------------------------ map settings rescale with expansion-rate
-- on_runtime_setting_changed re-applies; the cooldowns are derived from the live
-- expansion-rate, so re-running keeps them below vanilla. (The default rate 2.0
-- already halves the 2-minute base min cooldown to 60s.)
T.test("R-GEN-7: expansion-rate change re-applies map settings", {
  function(t)
    horde.on_runtime_setting_changed({ setting = "zomtorio-expansion-rate" })
  end,
  { after = 1, fn = function(t)
    local exp = game.map_settings.enemy_expansion
    t.assert.is_true(exp.min_expansion_cooldown < VANILLA_MIN_EXPANSION_CD,
      "min expansion cooldown stays below vanilla after re-apply")
  end },
})
