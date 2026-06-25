-- S9 — night aggression (R-NIGHT-1/2, R-SCOPE-1).
--
-- The headless benchmark has no players, so a placed `character` entity is the
-- proximity anchor (as in the horde burst tests). Day/night is forced by
-- freezing daytime and setting surface.daytime (verified writable: noon -> 0.0,
-- midnight -> 0.5 with darkness ~0.85).
--
-- The night boost is delivered by swapping enemy units to a faster night-variant
-- prototype (the only mechanism that actually moves a `unit` faster in 2.1 — see
-- lib/night.lua header). Tests therefore assert on the swapped prototype.

local T = require("harness.runner")

local night  = require("__zomtorio__.lib.night")
local config = require("__zomtorio__.lib.config")

local function set_midnight(surface)
  surface.freeze_daytime = true
  surface.daytime = 0.5
end

local function set_noon(surface)
  surface.freeze_daytime = true
  surface.daytime = 0.0
end

--- Find the (single) enemy unit near a position, whatever its current name.
local function enemy_near(surface, pos)
  local found = surface.find_entities_filtered {
    type = "unit", force = "enemy", position = pos, radius = 16,
  }
  return found[1]
end

------------------------------------------------------------------- is_night

T.test("is_night is true at midnight and false at noon (R-NIGHT-1)", {
  function(t)
    set_midnight(t.surface)
  end,
  { after = 5, fn = function(t)
    t.assert.is_true(night.is_night(t.surface), "midnight should read as night")
    set_noon(t.surface)
  end },
  { after = 5, fn = function(t)
    t.assert.is_false(night.is_night(t.surface), "noon should not read as night")
  end },
})

------------------------------------------------- night swaps to the fast variant

T.test("night swaps a nearby enemy unit to its faster night variant", {
  function(t)
    t.world.clear(t.surface, t.test_origin, 12)
    set_midnight(t.surface)
    t.char  = t.world.place(t.surface, "character", t.test_origin, { force = "player" })
    t.world.place(t.surface, "small-biter",
      { x = t.test_origin.x + 6, y = t.test_origin.y }, { force = "enemy" })
  end,
  { after = 5, fn = function(t)
    -- The mod's own night.on_tick is also live in the harness, so we assert the
    -- END state (variant) after forcing a sweep rather than the pre-sweep state.
    night.sweep_now()
  end },
  { after = 5, fn = function(t)
    local u = enemy_near(t.surface, t.test_origin)
    t.assert.not_nil(u, "the (swapped) enemy unit should still exist")
    t.assert.is_true(night.is_night_variant(u.name),
      "a nearby enemy unit should be swapped to its night variant at night")
  end },
})

--------------------------------------------- the variant is faster by the setting

-- target_movement_modifier / unit.speed don't drive `unit` movement (verified),
-- so the boost lives in the night variant's prototype movement_speed. Assert the
-- variant's speed is (1 + night_speedup()) x the day prototype's (R-NIGHT-2).
T.test("the night variant's speed honours the night-speedup setting (R-NIGHT-2)", function(t)
  local day   = prototypes.entity["small-biter"]
  local night_name = night.night_variant_of("small-biter")
  t.assert.not_nil(night_name, "a night variant of small-biter should exist")
  local nightp = prototypes.entity[night_name]
  local expected = day.speed * (1 + config.night_speedup())
  -- floating-point bake: allow a hair of tolerance via at_least + upper bound.
  t.assert.at_least(expected - 0.0001, nightp.speed, "variant speed >= 1+speedup x day")
  t.assert.at_least(nightp.speed, expected + 0.0001, "variant speed <= 1+speedup x day")
end)

-------------------------------- the variant actually moves faster (behavioural)

-- Drive both with an ATTACK command (combat AI runs at full movement_speed;
-- go_to_location over open ground stalls and is not a reliable speed signal).
T.test("the night variant out-travels the day unit under attack (R-NIGHT-1)", {
  function(t)
    t.world.clear(t.surface, t.test_origin, 40)
    set_midnight(t.surface)
    local p = t.test_origin
    t.target = t.world.place(t.surface, "stone-wall", { x = p.x + 30, y = p.y + 1 }, { force = "player" })
    t.day  = t.world.place(t.surface, "small-biter", { x = p.x, y = p.y }, { force = "enemy" })
    t.night = t.world.place(t.surface, night.night_variant_of("small-biter"),
      { x = p.x, y = p.y + 2 }, { force = "enemy" })
    t.day_start = t.day.position; t.night_start = t.night.position
    for _, b in ipairs({ t.day, t.night }) do
      b.commandable.set_command { type = defines.command.attack, target = t.target }
    end
  end,
  { after = 60, fn = function(t)
    local function dist(a, b) local dx=a.x-b.x; local dy=a.y-b.y; return math.sqrt(dx*dx+dy*dy) end
    local d_day   = t.day.valid   and dist(t.day.position, t.day_start)     or 0
    local d_night = t.night.valid and dist(t.night.position, t.night_start) or 0
    -- The variant should clearly out-travel the day unit; with the default +100%
    -- it covers ~2x. Conservative margin keeps it robust against AI noise.
    t.assert.at_least(d_day + 3.0, d_night,
      string.format("night variant should out-travel day unit (day=%.2f night=%.2f)", d_day, d_night))
  end },
})

------------------------------------------------- day swaps variants back

T.test("day swaps a lingering night variant back to its day prototype", {
  function(t)
    t.world.clear(t.surface, t.test_origin, 12)
    set_noon(t.surface)
    t.char = t.world.place(t.surface, "character", t.test_origin, { force = "player" })
    -- Seed a night variant directly (as if left over from the night).
    t.world.place(t.surface, night.night_variant_of("small-biter"),
      { x = t.test_origin.x + 6, y = t.test_origin.y }, { force = "enemy" })
  end,
  { after = 5, fn = function(t)
    -- NOTE: the mod's own night.on_tick is also live in the harness and may have
    -- already swapped this seeded variant back (the production sweep does exactly
    -- this job at noon near a character). So we don't assert the pre-sweep state;
    -- we force a sweep and assert the END state, which is what the rule promises.
    night.sweep_now()
  end },
  { after = 5, fn = function(t)
    local u = enemy_near(t.surface, t.test_origin)
    t.assert.not_nil(u, "the (swapped) enemy unit should still exist")
    t.assert.equal("small-biter", u.name, "by day the variant is swapped back to the day prototype")
  end },
})
