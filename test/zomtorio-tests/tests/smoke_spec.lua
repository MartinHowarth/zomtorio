-- Smoke tests: prove the harness can build factories, advance time, and read
-- world state back. These exercise BASE GAME behaviour (Zomtorio isn't required
-- yet) so the testing loop can be validated before the rewrite begins.

local T = require("harness.runner")

-- 1. Trivial: the world exists and we can read it.
T.test("nauvis surface exists", function(t)
  t.assert.not_nil(t.surface, "nauvis surface should exist")
end)

-- 2. Placement: build an entity and confirm it's really there.
T.test("can place and read back an entity", function(t)
  local o = t.test_origin
  t.world.clear(t.surface, o)
  local chest = t.world.place(t.surface, "iron-chest", o)
  t.assert.not_nil(chest, "chest should be created")
  t.assert.is_true(chest.valid, "chest should be valid")
  t.world.insert(chest, "iron-plate", 17)
  t.assert.equal(17, t.world.count(chest, "iron-plate"), "inserted items readable")
end)

-- 3. Production: a fuelled stone furnace smelts ore into plates over time.
--    Proves we can build a working machine and advance ticks to see results.
T.test("stone furnace smelts iron ore into plates", {
  function(t)
    local o = t.test_origin
    t.world.clear(t.surface, o)
    t.furnace = t.world.place(t.surface, "stone-furnace", o)
    t.world.insert(t.furnace, "coal", 5)
    t.world.insert(t.furnace, "iron-ore", 10)
  end,
  { after = 60 * 8, fn = function(t)  -- ~1 plate per 3.2s; wait generously
    t.assert.at_least(1, t.world.count(t.furnace, "iron-plate"),
      "furnace should have produced iron plates")
  end },
})

-- 4. Belts: items placed on a belt move along it (transport-line read-back).
T.test("items travel along a belt line", {
  function(t)
    local o = t.test_origin
    t.world.clear(t.surface, o)
    t.belts = t.world.belt_line(t.surface, o, defines.direction.east, 6)
    t.assert.equal(6, #t.belts, "should have placed 6 belts")
    t.assert.is_true(t.world.belt_insert(t.belts[1], "iron-plate", 1),
      "item should fit on the belt")
  end,
  { after = 120, fn = function(t)
    local total = 0
    for _, b in ipairs(t.belts) do total = total + t.world.belt_count(b, "iron-plate") end
    t.assert.at_least(1, total, "the item should still exist somewhere on the line")
    t.assert.equal(0, t.world.belt_count(t.belts[1], "iron-plate"),
      "item should have moved off the first belt")
  end },
})

-- 5. Enemies: we can spawn biters on the enemy force (core to Zomtorio).
T.test("can spawn a biter on the enemy force", function(t)
  local o = t.test_origin
  t.world.clear(t.surface, o)
  local biter = t.world.place(t.surface, "small-biter", o, { force = "enemy" })
  t.assert.not_nil(biter, "biter should spawn")
  t.assert.equal("enemy", biter.force.name, "biter should be on enemy force")
  t.assert.at_least(1, biter.health, "biter should have health")
end)
