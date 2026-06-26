-- S1 tests: total-raw cost decomposition (R-DEATH-2, R-DEATH-4).
--
-- Loads the real module from the linked main mod via the cross-mod require path
-- __Zomtorio__. The cache lives in storage, which is available at runtime; we
-- (re)initialise it once before asserting.

local T = require("harness.runner")
local raw_cost = require("__Zomtorio__.lib.raw_cost")

raw_cost.on_init()

-- Solid-cost anchors. Verified by reasoning, then confirmed against the run:
--   stone-furnace : recipe is 5 stone (a raw)                     -> 5
--   iron-chest    : 8 iron-plate, each plate = 1 iron-ore (raw)   -> 8
--   wooden-chest  : 2 wood (wood is raw, has no producing recipe) -> 2
T.test("stone-furnace total raw is 5 solid (5 stone)", function(t)
  local n, oil = raw_cost.for_entity("stone-furnace")
  t.assert.equal(5, n, "stone-furnace solid raw")
  t.assert.equal(0, oil, "stone-furnace has no oil")
end)

T.test("iron-chest total raw is 8 solid (8 iron-plate -> 8 iron-ore)", function(t)
  local n, oil = raw_cost.for_entity("iron-chest")
  t.assert.equal(8, n, "iron-chest solid raw")
  t.assert.equal(0, oil, "iron-chest has no oil")
end)

T.test("wooden-chest total raw is 2 solid (2 wood)", function(t)
  local n = raw_cost.for_entity("wooden-chest")
  t.assert.equal(2, n, "wooden-chest solid raw")
end)

-- A larger building decomposes into many raws; assert a sane lower bound rather
-- than an exact figure so the test survives recipe rebalancing.
T.test("assembling-machine-1 decomposes into many raws", function(t)
  local n = raw_cost.for_entity("assembling-machine-1")
  t.assert.at_least(10, n, "assembling-machine-1 solid raw should be substantial")
end)

-- Oil detection (R-DEATH-4): a building whose cost includes plastic (from
-- petroleum-gas) must report oil > 0. assembling-machine-3 needs speed modules
-- / advanced circuits -> plastic -> petroleum-gas. A plain iron building must be
-- oil-free.
T.test("oil-derived building reports oil > 0", function(t)
  local _, oil = raw_cost.for_entity("assembling-machine-3")
  t.assert.is_true(oil > 0, "assembling-machine-3 cost should include oil-chain fluid")
end)

T.test("plain iron building reports oil == 0", function(t)
  local _, oil = raw_cost.for_entity("iron-chest")
  t.assert.equal(0, oil, "iron-chest should have no oil in its cost")
end)

-- Loop safety / robustness: decomposing EVERY placeable entity must complete
-- without error and always return numbers, even across cyclic recipe graphs
-- (uranium reprocessing, Kovarex, barrelling, coal liquefaction).
T.test("for_entity is total and crash-free over all placeable entities", function(t)
  local checked = 0
  for name, proto in pairs(prototypes.entity) do
    local placers = proto.items_to_place_this
    if placers and #placers > 0 then
      local n, oil = raw_cost.for_entity(name)
      t.assert.is_true(type(n) == "number", "solid count must be a number for " .. name)
      t.assert.is_true(type(oil) == "number", "oil amount must be a number for " .. name)
      t.assert.at_least(0, n, "solid count must be non-negative for " .. name)
      checked = checked + 1
    end
  end
  t.assert.at_least(1, checked, "should have checked at least one placeable entity")
end)
