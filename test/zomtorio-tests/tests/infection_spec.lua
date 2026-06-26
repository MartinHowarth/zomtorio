-- S4 tests: infection of buildings and robots (R-INF-1..6, R-SCOPE-1). Loads the
-- real module from the linked main mod via the __zomtorio__ require path.
--
-- We drive on_entity_damaged / on_tick / infect DIRECTLY (synthesizing the
-- event): each mod has its own Lua state and `storage`, so the infection module
-- instance loaded here shares the storage these calls write to — making the
-- infected set inspectable from the test. (The main mod's registered handler
-- would write the main mod's separate storage.)
--
-- The DoT is elapsed-time based, so to advance it we wait N real ticks with the
-- harness `{ after = N }` step form, then call on_tick ONCE — that single call
-- applies N ticks' worth of damage to the (single) infected entity. We pin the
-- time-to-death with set_ticks_override for deterministic, short tests.

local T         = require("harness.runner")
local infection = require("__zomtorio__.lib.infection")

-- Reset state and clear any overrides left by a prior test.
local function reset()
  infection.reset_state()
  infection.set_enabled_override(nil)
  infection.set_ticks_override(nil)
end

-- Synthesize an enemy hit on `entity` and dispatch it to the handler.
local function enemy_hit(entity, dtype)
  infection.on_entity_damaged {
    entity = entity,
    force = game.forces.enemy,
    original_damage_amount = 1,
    final_damage_amount = 1,
    damage_type = { name = dtype or "physical" },
  }
end

-- ---------------------------------------------------------- infect on hit
T.test("an enemy hit infects a non-wall building", function(t)
  reset()
  local o = t.test_origin
  t.world.clear(t.surface, o)
  local building = t.world.place(t.surface, "assembling-machine-1", o)

  enemy_hit(building)

  t.assert.is_true(infection.is_infected(building), "building should be infected")
end)

-- ---------------------------------------------------------- walls/gates excluded
T.test("a wall is not infected by an enemy hit", function(t)
  reset()
  local o = t.test_origin
  t.world.clear(t.surface, o)
  local wall = t.world.place(t.surface, "stone-wall", o)

  enemy_hit(wall)

  t.assert.is_false(infection.is_infected(wall), "walls are excluded (R-INF-2)")
end)

T.test("a gate is not infected by an enemy hit", function(t)
  reset()
  local o = t.test_origin
  t.world.clear(t.surface, o)
  local gate = t.world.place(t.surface, "gate", o)

  enemy_hit(gate)

  t.assert.is_false(infection.is_infected(gate), "gates are excluded (R-INF-2)")
end)

-- ---------------------------------------------------------- setting off
T.test("infection does nothing when the setting is off", function(t)
  reset()
  infection.set_enabled_override(false)
  local o = t.test_origin
  t.world.clear(t.surface, o)
  local building = t.world.place(t.surface, "assembling-machine-1", o)

  enemy_hit(building)

  t.assert.is_false(infection.is_infected(building), "setting off => no infection (R-INF-1)")
end)

-- ---------------------------------------------------------- DoT kills in time
-- With a 120-tick time-to-death, a full-health building infected at t0 should be
-- roughly half-dead by ~60 ticks and DEAD by 130 ticks. Bounds kept loose.
T.test("the DoT kills an infected building in the configured time", {
  function(t)
    reset()
    infection.set_ticks_override(120)
    local o = t.test_origin
    t.world.clear(t.surface, o)
    t.building = t.world.place(t.surface, "assembling-machine-1", o)
    t.maxhp = t.building.max_health
    enemy_hit(t.building)
    t.assert.is_true(infection.is_infected(t.building), "infected at t0")
  end,
  { after = 60, fn = function(t)
    infection.on_tick { tick = game.tick }
    t.assert.is_true(t.building.valid, "alive at half the time-to-death")
    local ratio = t.building.health / t.maxhp
    t.assert.is_true(ratio < 0.8 and ratio > 0.2,
      "roughly half-dead at half the time (loose bounds): " .. ratio)
  end },
  { after = 70, fn = function(t)  -- now ~130 ticks since infection
    infection.on_tick { tick = game.tick }
    t.assert.is_false(t.building.valid, "dead by the configured time-to-death")
    t.assert.is_false(infection.is_infected(t.building), "record removed on death")
  end },
})

-- R-INF-3 end-to-end: a building killed by the infection DoT spawns zombies. The
-- DoT is dealt on the enemy force, so the resulting on_entity_died (handled by
-- the MAIN mod) routes through spawning -> swarm.spawn and creates zombie
-- entities in the shared world. We assert on the WORLD (not test-mod storage),
-- which is what makes this a genuine end-to-end check of the integration.
T.test("an infection death spawns zombies (R-INF-3)", {
  function(t)
    reset()
    infection.set_ticks_override(60)
    local o = t.test_origin
    t.world.clear(t.surface, o)
    t.building = t.world.place(t.surface, "assembling-machine-1", o)
    t.pos = t.building.position
    enemy_hit(t.building)
  end,
  { after = 70, fn = function(t)
    infection.on_tick { tick = game.tick }
    t.assert.is_false(t.building.valid, "building killed by the DoT")
    local zombies = t.surface.find_entities_filtered {
      type = "unit", force = "enemy", position = t.pos, radius = 24,
    }
    t.assert.at_least(1, #zombies, "infection death seeds zombies in the world")
  end },
})

-- ---------------------------------------------------------- slider honoured
-- With a LONG time-to-death (1200 ticks), the building must still be alive well
-- before that (at a quarter of the time) — proving the slider actually scales it.
T.test("time-to-death honours the slider", {
  function(t)
    reset()
    infection.set_ticks_override(1200)
    local o = t.test_origin
    t.world.clear(t.surface, o)
    t.building = t.world.place(t.surface, "assembling-machine-1", o)
    enemy_hit(t.building)
  end,
  { after = 300, fn = function(t)  -- a quarter of 1200 ticks
    infection.on_tick { tick = game.tick }
    t.assert.is_true(t.building.valid, "still alive at 1/4 of a long time-to-death")
    t.assert.is_true(infection.is_infected(t.building), "still infected")
  end },
})

-- ---------------------------------------------------------- repair cures
-- Infect, let the DoT bite, then fully repair (health = max) and process again:
-- the infection clears and the DoT stops, leaving the entity alive (R-INF-5).
T.test("full repair cures an infected building", {
  function(t)
    reset()
    infection.set_ticks_override(600)
    local o = t.test_origin
    t.world.clear(t.surface, o)
    t.building = t.world.place(t.surface, "assembling-machine-1", o)
    enemy_hit(t.building)
  end,
  { after = 60, fn = function(t)
    infection.on_tick { tick = game.tick }
    t.assert.is_true(t.building.health < t.building.max_health, "DoT dropped health")
    -- Simulate a full repair.
    t.building.health = t.building.max_health
  end },
  { after = 60, fn = function(t)
    infection.on_tick { tick = game.tick }
    t.assert.is_false(infection.is_infected(t.building), "fully repaired => cured")
    t.assert.is_true(t.building.valid, "cured entity is still alive")
  end },
  { after = 120, fn = function(t)
    infection.on_tick { tick = game.tick }
    -- DoT must have stopped: health stays full.
    t.assert.equal(t.building.max_health, t.building.health, "DoT stopped after cure")
  end },
})

-- ---------------------------------------------------------- robots infectable
-- R-INF-6: logistic / construction / combat robots are infectable targets.
T.test("a construction robot is infectable", function(t)
  reset()
  local o = t.test_origin
  t.world.clear(t.surface, o)
  local robot = t.surface.create_entity {
    name = "construction-robot", position = o, force = "player",
  }
  t.assert.not_nil(robot, "robot should be created")

  infection.infect(robot)

  t.assert.is_true(infection.is_infected(robot), "robots are infectable (R-INF-6)")
end)

-- Alt-mode biohazard marker: shown over an infected building, cleared on cure.
-- (Rendering works headless — render objects are created even with no client;
-- only_in_alt_mode just governs client display.)
T.test("an infected building shows a biohazard marker, cleared on cure", {
  function(t)
    reset()
    infection.set_ticks_override(600)
    local o = t.test_origin
    t.world.clear(t.surface, o)
    t.b = t.world.place(t.surface, "assembling-machine-1", o)
    enemy_hit(t.b)
    t.assert.is_true(infection.has_marker(t.b), "marker shown while infected")
  end,
  { after = 30, fn = function(t)
    infection.on_tick { tick = game.tick }
    t.b.health = t.b.max_health        -- full repair -> cured on next process
    infection.on_tick { tick = game.tick }
    t.assert.is_false(infection.is_infected(t.b), "cured by repair")
    t.assert.is_false(infection.has_marker(t.b), "marker cleared on cure")
  end },
})
