-- Tests for lib/nest.lua: cap-aware interception of engine nest output
-- (R-GEN-1/6, R-HORDE-6). on_entity_spawned routes a spawner's unit through the
-- global cap so a saturated world forms LOCAL swarm clusters at the nest instead of
-- unlimited loose individuals, with a pollution-scaled per-nest budget that stops a
-- nest growing an infinite swarm.
--
-- White-box, same approach as horde_spec: we require the real modules from the
-- linked main mod (so the logic under test IS production code) and drive
-- nest.on_entity_spawned with a synthesized event. We can't wait for a real
-- spawner's cadence deterministically, but the event payload (entity + spawner) is
-- exactly what the engine delivers, so the routing logic is exercised faithfully.

local T     = require("harness.runner")
local nest  = require("__zomtorio__.lib.nest")
local swarm = require("__zomtorio__.lib.swarm")
local tiers = require("__zomtorio__.lib.tiers")

--- Spawn a real enemy biter near `pos` to stand in for one a spawner just emitted.
local function make_biter(surface, pos)
  return surface.create_entity {
    name = tiers.INDIVIDUAL.small, position = pos, force = "enemy",
  }
end

--- The (single) tracked cluster near a position.
local function find_cluster(surface, pos)
  local found = surface.find_entities_filtered {
    name = tiers.SWARM.small, position = pos, radius = 32,
  }
  return found[1]
end

local function reset(cap)
  swarm.set_cap_override(cap)
  swarm.reset_state()
  nest.set_budget_override(nil)
end

-- The whole feature hinges on the engine raising on_entity_spawned when a spawner
-- emits a unit. Confirm the event id is actually present in this engine build (the
-- one API unknown from research) so control.lua's guarded registration really wires.
T.test("the engine exposes on_entity_spawned", function(t)
  t.assert.not_nil(defines.events.on_entity_spawned,
    "on_entity_spawned must exist for nest interception to fire")
end)

-- Under the cap: nest output stays a real individual AND counts against the cap, so
-- the engine's own owned-unit limit governs loose biters until the cap fills.
T.test("under the cap, nest output stays a tracked individual", function(t)
  reset(1000)
  local o = t.test_origin
  t.world.clear(t.surface, o)
  local biter = make_biter(t.surface, o)
  t.assert.not_nil(biter, "test biter created")

  local before = swarm.active_count()
  nest.on_entity_spawned { entity = biter }
  t.assert.is_true(biter.valid, "the individual is kept (not folded) under the cap")
  t.assert.equal(before + 1, swarm.active_count(), "it now counts against the cap")
end)

-- Cap full: nest output is destroyed and folded into a LOCAL cluster at the nest,
-- and successive spawns grow that same cluster (R-HORDE-6 overflow, formed locally).
T.test("over the cap, nest output folds into a growing local cluster", function(t)
  reset(0)               -- no individual room -> everything folds
  nest.set_budget_override(1000)  -- budget well above what this test reaches
  local o = t.test_origin
  t.world.clear(t.surface, o)

  local b1 = make_biter(t.surface, o)
  nest.on_entity_spawned { entity = b1 }
  t.assert.is_false(b1.valid, "the over-cap individual is removed")
  local cluster = find_cluster(t.surface, o)
  t.assert.not_nil(cluster, "a local cluster formed at the nest")
  t.assert.equal(1, swarm.pop_of(cluster), "cluster holds the folded zombie")

  local b2 = make_biter(t.surface, o)
  nest.on_entity_spawned { entity = b2 }
  t.assert.equal(2, swarm.pop_of(cluster), "the next spawn grows the same local cluster")
end)

-- Cap full AND the local swarm at its budget: the nest is saturated, so further
-- output is throttled (dropped) and the cluster does NOT keep growing -- the guard
-- against an infinite swarm when a nest's attack never triggers.
T.test("at the nest budget, further output is throttled (no infinite swarm)", function(t)
  reset(0)
  nest.set_budget_override(2)  -- a tiny budget so we hit saturation fast
  local o = t.test_origin
  t.world.clear(t.surface, o)

  -- Fold up to the budget.
  local b1 = make_biter(t.surface, o); nest.on_entity_spawned { entity = b1 }
  local b2 = make_biter(t.surface, o); nest.on_entity_spawned { entity = b2 }
  local cluster = find_cluster(t.surface, o)
  t.assert.not_nil(cluster, "cluster formed")
  t.assert.equal(2, swarm.pop_of(cluster), "cluster filled to the budget")

  -- One more: local swarm (2) >= budget (2) -> throttled, cluster unchanged.
  local b3 = make_biter(t.surface, o)
  nest.on_entity_spawned { entity = b3 }
  t.assert.is_false(b3.valid, "the saturating spawn is dropped")
  t.assert.equal(2, swarm.pop_of(cluster), "the swarm does not grow past its budget")
end)

-- Non-enemy or off-Nauvis spawns are ignored (R-SCOPE-1 / friendly units untouched).
T.test("a non-enemy unit is ignored", function(t)
  reset(1000)
  local o = t.test_origin
  t.world.clear(t.surface, o)
  -- A player-force unit must not be touched or counted.
  local biter = t.surface.create_entity {
    name = tiers.INDIVIDUAL.small, position = o, force = "player",
  }
  t.assert.not_nil(biter, "player-force unit created")
  local before = swarm.active_count()
  nest.on_entity_spawned { entity = biter }
  t.assert.is_true(biter.valid, "left untouched")
  t.assert.equal(before, swarm.active_count(), "not counted against the cap")
end)
