-- S9 — night aggression (R-NIGHT-1/2, R-SCOPE-1).
--
-- The headless benchmark has no players, so a placed `character` entity is the
-- proximity anchor (as in the swarm burst tests). Day/night is forced by
-- freezing daytime and setting surface.daytime (verified writable: noon -> 0.0,
-- midnight -> 0.5 with darkness ~0.85).
--
-- The night boost is delivered by swapping enemy units to a faster night-variant
-- prototype (the only mechanism that actually moves a `unit` faster in 2.1 — see
-- lib/night.lua header). Tests therefore assert on the swapped prototype.

local T = require("harness.runner")

local night  = require("__zomtorio__.lib.night")
local config = require("__zomtorio__.lib.config")
local swarm  = require("__zomtorio__.lib.swarm")
local tiers  = require("__zomtorio__.lib.tiers")

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
  -- Step 1: just settle darkness. surface.darkness eases toward the daytime-implied
  -- value over many ticks (and from a starting point set by the previous test), so
  -- a fixed short wait is unreliable across suite orderings — wait, then assert it
  -- has actually crossed the night threshold in step 2.
  function(t)
    set_midnight(t.surface)
  end,
  { after = 90, fn = function(t)
    t.assert.is_true(night.is_night(t.surface),
      "precondition: darkness has settled to night (darkness=" ..
      string.format("%.2f", t.surface.darkness) .. ")")

    -- Build the scene and sweep ATOMICALLY within this one step (a single tick, a
    -- single synchronous function) so the live mod — which also runs a night sweep
    -- and cranks enemy generation — cannot race us: clear any stray live enemy,
    -- place a fresh anchor + a fresh biter, sweep, and assert, all before control
    -- returns to the engine. A biter placed microseconds before the sweep can't be
    -- destroyed or duplicated by the live mod mid-function.
    t.world.clear(t.surface, t.test_origin, 12)
    local char = t.world.place(t.surface, "character", t.test_origin, { force = "player" })
    char.destructible = false
    t.world.place(t.surface, "small-biter",
      { x = t.test_origin.x + 6, y = t.test_origin.y }, { force = "enemy" })

    night.sweep_now()

    local found = t.surface.find_entities_filtered {
      type = "unit", force = "enemy", position = t.test_origin, radius = 16,
    }
    local variant, names = nil, {}
    for _, u in pairs(found) do
      names[#names + 1] = u.name
      if night.is_night_variant(u.name) then variant = u; break end
    end
    t.assert.not_nil(variant,
      "a nearby enemy unit should be swapped to its night variant at night" ..
      " [enemies={" .. table.concat(names, ",") .. "}]")
  end },
})

------------------------------------------- no flip-flop (stutter) regression

-- BUG (flagged): at night, zombies visibly stuttered slow<->fast every sweep. Cause:
-- the target was `night_now and night_variant_of(u) or day_form_of(u)`; for a unit
-- ALREADY a night variant, night_variant_of returned nil (no double-suffix proto), so
-- it fell through to day_form_of and swapped it BACK to day every sweep. This test
-- defends the fix: a unit already in its night variant must be LEFT ALONE by a second
-- sweep (same unit_number, not destroyed+recreated).
T.test("a night variant is not re-swapped on the next sweep (no stutter)", {
  function(t)
    set_midnight(t.surface)
  end,
  { after = 90, fn = function(t)
    t.assert.is_true(night.is_night(t.surface), "precondition: night has settled")
    t.world.clear(t.surface, t.test_origin, 12)
    local char = t.world.place(t.surface, "character", t.test_origin, { force = "player" })
    char.destructible = false
    t.world.place(t.surface, "small-biter",
      { x = t.test_origin.x + 6, y = t.test_origin.y }, { force = "enemy" })

    night.sweep_now()  -- day -> night variant

    local function find_variant()
      for _, u in pairs(t.surface.find_entities_filtered {
        type = "unit", force = "enemy", position = t.test_origin, radius = 16,
      }) do
        if night.is_night_variant(u.name) then return u end
      end
      return nil
    end
    local v1 = find_variant()
    t.assert.not_nil(v1, "first sweep makes it a night variant")
    local un = v1.unit_number

    night.sweep_now()  -- second sweep: must NOT touch the already-night unit

    local v2 = find_variant()
    t.assert.not_nil(v2, "still a night variant after a second sweep (not flipped to day)")
    t.assert.equal(un, v2.unit_number,
      "the SAME entity persists — it was not destroyed+recreated (no flip-flop)")
  end },
})

------------------------------------------- night swaps a swarm cluster too

-- Swarms (clusters) speed up at night like loose biters: the sweep swaps a cluster
-- to its night-variant cluster, carrying the population record across. Built and
-- swept ATOMICALLY in one step (like the test above) so the live mod's own sweep
-- can't race our (separate-module) state. Uses swarm.fold for a deterministic pop.
T.test("night swaps a swarm cluster to its night variant, preserving population", {
  function(t)
    set_midnight(t.surface)
  end,
  { after = 90, fn = function(t)
    t.assert.is_true(night.is_night(t.surface),
      "precondition: darkness has settled to night")
    t.world.clear(t.surface, t.test_origin, 16)
    local char = t.world.place(t.surface, "character", t.test_origin, { force = "player" })
    char.destructible = false
    swarm.reset_state()
    swarm.fold(t.surface, { x = t.test_origin.x + 6, y = t.test_origin.y },
      25, "small", "enemy")              -- a pop-25 day cluster, no cap/multiplier

    night.sweep_now()

    local found = t.surface.find_entities_filtered {
      name = tiers.SWARM_ALL, position = t.test_origin, radius = 16,
    }
    local cluster = found[1]
    t.assert.not_nil(cluster, "a cluster should still exist after the swap")
    t.assert.is_true(night.is_night_variant(cluster.name),
      "the swarm is swapped to its night-variant cluster [name=" ..
      (cluster and cluster.name or "nil") .. "]")
    t.assert.equal(25, swarm.pop_of(cluster),
      "the swarm's population is preserved across the swap")
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
    -- it covers ~2x. A PROPORTIONAL margin (>= 1.4x) keeps this robust against AI
    -- noise AND against the S10 dense-swarm speed/4 tuning, which shrinks the
    -- absolute distances so a fixed additive margin no longer fits the window.
    t.assert.at_least(d_day * 1.4, d_night,
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
