-- S5 tests: player (character) infection (R-PINF-1..5, R-SCOPE-1). Loads the real
-- module from the linked main mod via __zomtorio__ and drives it directly.
--
-- CRUCIAL: the headless benchmark has NO connected players, so the whole feature
-- is keyed on the CHARACTER ENTITY (its unit_number), never a LuaPlayer. Tests
-- create a bare `character` entity and call the module functions directly.
--
-- The player DoT is PER-TICK (not elapsed-time), so to advance it we call
-- on_tick once per simulated tick — a plain `for` loop within one step works.

local T         = require("harness.runner")
local infection = require("__zomtorio__.lib.infection")

local function reset()
  infection.reset_state()
  infection.set_enabled_override(nil)
  infection.set_player_enabled_override(nil)
  infection.set_ticks_override(nil)
end

-- Make a bare character at the test origin on a cleared tile.
local function make_character(t)
  local o = t.test_origin
  t.world.clear(t.surface, o)
  return t.surface.create_entity { name = "character", position = o, force = "player" }
end

-- Synthesize a hit on `char` and dispatch it to the handler.
local function hit(char, opts)
  opts = opts or {}
  infection.on_entity_damaged {
    entity = char,
    force = opts.force or game.forces.enemy,
    original_damage_amount = opts.amount or 5,
    final_damage_amount = opts.final ~= nil and opts.final or 5,
    damage_type = { name = "physical" },
  }
end

-- Run the per-tick player DoT n times.
local function tick_n(n)
  for _ = 1, n do infection.on_tick { tick = game.tick } end
end

-- ---------------------------------------------------------- bite infects
T.test("a bite that deals health damage infects the player (R-PINF-2/3)", function(t)
  reset()
  local char = make_character(t)
  t.assert.not_nil(char, "character should be created")

  hit(char, { final = 5 })

  t.assert.is_true(infection.is_player_infected(char), "health-damage bite => infected")
end)

-- ---------------------------------------------------------- shield-absorbed
T.test("a shield-absorbed bite does NOT infect (R-PINF-3)", function(t)
  reset()
  local char = make_character(t)

  hit(char, { final = 0 })  -- fully absorbed: no health damage

  t.assert.is_false(infection.is_player_infected(char), "shield-absorbed => not infected")
end)

-- ---------------------------------------------------------- non-enemy damage
T.test("non-enemy damage does not infect the player", function(t)
  reset()
  local char = make_character(t)

  hit(char, { force = game.forces.player, final = 5 })

  t.assert.is_false(infection.is_player_infected(char), "friendly damage => not infected")
end)

-- ---------------------------------------------------------- setting off
T.test("player infection does nothing when the setting is off (R-PINF-1)", function(t)
  reset()
  infection.set_player_enabled_override(false)
  local char = make_character(t)

  hit(char, { final = 5 })

  t.assert.is_false(infection.is_player_infected(char), "setting off => not infected")
end)

-- ---------------------------------------------------------- DoT kills in time
-- Per-tick DoT with a 120-tick time-to-death: ~120 on_tick calls remove ~max_health.
T.test("the DoT lowers health and kills in the configured time (R-PINF-2)", function(t)
  reset()
  infection.set_ticks_override(120)
  local char = make_character(t)
  local maxhp = char.max_health
  hit(char, { final = 5 })
  t.assert.is_true(infection.is_player_infected(char), "infected at t0")

  -- Half the time-to-death: alive, health roughly dropped.
  tick_n(60)
  t.assert.is_true(char.valid, "alive at half the time-to-death")
  local ratio = char.health / maxhp
  t.assert.is_true(ratio < 0.9 and ratio > 0.2, "roughly half-dead: " .. ratio)

  -- Past the full time-to-death: dead, record cleared.
  tick_n(70)  -- 130 total
  t.assert.is_false(char.valid, "dead by the configured time-to-death")
  t.assert.is_false(infection.is_player_infected(char), "record cleared on death")
end)

-- ---------------------------------------------------------- regen suppression
-- A tiny passive-regen bump (below HEAL_EPSILON) is discarded: the health stays
-- on the DoT trajectory and the infection is NOT cured (R-PINF-4).
T.test("passive regen is suppressed while infected (R-PINF-4)", function(t)
  reset()
  infection.set_ticks_override(600)
  local char = make_character(t)
  hit(char, { final = 5 })

  tick_n(30)
  local before = char.health
  t.assert.is_true(before < char.max_health, "DoT dropped health")

  -- Simulate a tiny passive regen tick (below HEAL_EPSILON of 0.5).
  char.health = char.health + 0.2
  tick_n(1)

  t.assert.is_true(infection.is_player_infected(char), "tiny regen does NOT cure")
  t.assert.is_true(char.health < before, "health continues on the DoT trajectory")
end)

-- ---------------------------------------------------------- net heal cures
-- A real heal (above HEAL_EPSILON) clears the infection and stops the DoT,
-- leaving the character at the healed value (R-PINF-5).
T.test("a net health gain cures the player (R-PINF-5)", function(t)
  reset()
  infection.set_ticks_override(600)
  local char = make_character(t)
  hit(char, { final = 5 })

  tick_n(30)
  t.assert.is_true(char.health < char.max_health, "DoT dropped health")

  -- A real heal (medikit / fish), well above HEAL_EPSILON but staying below max
  -- so the engine doesn't clamp the value we then assert on.
  local healed = math.min(char.health + 50, char.max_health - 1)
  char.health = healed
  tick_n(1)

  t.assert.is_false(infection.is_player_infected(char), "net heal => cured")
  t.assert.equal(healed, char.health, "DoT stopped; character left at the healed value")
end)
