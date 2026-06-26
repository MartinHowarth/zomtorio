-- S3 tests: buildings become zombie sources on death (R-DEATH-1..4). Loads the
-- real modules from the linked main mod via the __Zomtorio__ require path.
--
-- IMPORTANT — why we call spawning.on_entity_died DIRECTLY (synthesizing the
-- event): each mod has its OWN Lua state and `storage`. The spawning/swarm
-- module instances loaded here (in the test mod) share the storage that the
-- spawner writes to, so the resulting clusters are inspectable from here; the
-- main mod's registered handler would write the main mod's (separate) storage.
-- The handler only reads the entity's properties, so we pass a LIVE building as
-- event.entity rather than actually destroying it.
--
-- We pin the cap to 0 (swarm.set_cap_override) so EVERY spawned zombie folds
-- into a zomtorio-swarm-* cluster, then sum populations of the clusters near the
-- death position to assert the spawned count. on_init() resets storage first.

local T        = require("harness.runner")
local spawning = require("__Zomtorio__.lib.spawning")
local swarm    = require("__Zomtorio__.lib.swarm")
local tiers    = require("__Zomtorio__.lib.tiers")

-- Total population standing near `pos` across all cluster tiers (cap pinned to 0
-- means no individuals exist, so this is the full spawned count).
local function total_pop(surface, pos)
  local sum = 0
  for _, tier in ipairs(tiers.ORDER) do
    local found = surface.find_entities_filtered {
      name = tiers.SWARM[tier], position = pos, radius = 48,
    }
    for _, c in ipairs(found) do
      sum = sum + (swarm.pop_of(c) or 0)
    end
  end
  return sum
end

--- The first cluster entity (any tier) near `pos`, or nil.
local function find_cluster(surface, pos)
  for _, tier in ipairs(tiers.ORDER) do
    local found = surface.find_entities_filtered {
      name = tiers.SWARM[tier], position = pos, radius = 48,
    }
    if found[1] then return found[1] end
  end
  return nil
end

-- Reset swarm storage and pin the cap to 0 so all spawns fold into clusters.
local function reset()
  swarm.reset_state()
  swarm.set_cap_override(0)
end

-- --------------------------------------------------------- enemy kill -> N
-- An iron-chest (8 solid raw) killed by the enemy force spawns 8 zombies'
-- worth, all folded into a cluster (cap pinned to 0). Multiplier defaults to 1.
T.test("an enemy-caused building death spawns zombies equal to its raw cost", function(t)
  reset()
  local o = t.test_origin
  t.world.clear(t.surface, o)
  local building = t.world.place(t.surface, "iron-chest", o)
  local pos = building.position

  spawning.on_entity_died { entity = building, force = game.forces.enemy }

  t.assert.equal(8, total_pop(t.surface, pos), "iron-chest (raw 8) spawns 8 zombies")
end)

-- The cause-entity path: death force is neutral but the cause is on the enemy
-- force (a biter's projectile etc.). Must still count as enemy-caused.
T.test("a death caused by an enemy entity spawns zombies", function(t)
  reset()
  local o = t.test_origin
  t.world.clear(t.surface, o)
  local building = t.world.place(t.surface, "iron-chest", o)
  local pos = building.position
  local biter = t.world.place(t.surface, "small-biter", { x = o.x + 4, y = o.y },
    { force = "enemy" })

  spawning.on_entity_died {
    entity = building, force = game.forces.neutral, cause = biter,
  }

  t.assert.equal(8, total_pop(t.surface, pos), "enemy cause counts as enemy-caused")
end)

-- ----------------------------------------------- player kill -> no spawn
-- The player's own weapons killing their own building DOES fire on_entity_died,
-- but must spawn nothing (R-DEATH-1).
T.test("a player-caused building death spawns no zombies", function(t)
  reset()
  local o = t.test_origin
  t.world.clear(t.surface, o)
  local building = t.world.place(t.surface, "iron-chest", o)
  local pos = building.position

  spawning.on_entity_died { entity = building, force = game.forces.player }

  t.assert.equal(0, total_pop(t.surface, pos), "player kill spawns nothing")
  t.assert.equal(nil, find_cluster(t.surface, pos), "no cluster created")
end)

-- ----------------------------------------------------- walls/gates -> no spawn
-- Walls and gates are purely-defensive barriers and never spawn (R-DEATH-3).
T.test("a wall death spawns no zombies", function(t)
  reset()
  local o = t.test_origin
  t.world.clear(t.surface, o)
  local wall = t.world.place(t.surface, "stone-wall", o)
  local pos = wall.position

  spawning.on_entity_died { entity = wall, force = game.forces.enemy }

  t.assert.equal(0, total_pop(t.surface, pos), "walls never spawn zombies")
end)

T.test("a gate death spawns no zombies", function(t)
  reset()
  local o = t.test_origin
  t.world.clear(t.surface, o)
  local gate = t.world.place(t.surface, "gate", o)
  local pos = gate.position

  spawning.on_entity_died { entity = gate, force = game.forces.enemy }

  t.assert.equal(0, total_pop(t.surface, pos), "gates never spawn zombies")
end)

-- An environmental death (no force, no cause) is not enemy-caused and must spawn
-- nothing — otherwise scripted/neutral demolition would seed zombies.
T.test("a death with no force or cause spawns no zombies", function(t)
  reset()
  local o = t.test_origin
  t.world.clear(t.surface, o)
  local building = t.world.place(t.surface, "iron-chest", o)
  local pos = building.position

  spawning.on_entity_died { entity = building }

  t.assert.equal(0, total_pop(t.surface, pos), "non-enemy death spawns nothing")
end)

-- ------------------------------------------- building death -> always basic tier
-- Playtest decision (overrides R-DEATH-4): a building death ALWAYS spawns the basic
-- tier, no matter how expensive or oily the building's cost. Spawning high-tier
-- biters from buildings proved too strong; the threat is the sheer NUMBER of basic
-- zombies, not their individual strength. Here an oil-cost building
-- (assembling-machine-3) must still yield only "small"-tier zombies.
T.test("a building death always spawns the basic tier (no oil escalation)", function(t)
  reset()
  local o = t.test_origin
  t.world.clear(t.surface, o)
  local building = t.world.place(t.surface, "assembling-machine-3", o)  -- oil in its cost
  local pos = building.position

  spawning.on_entity_died { entity = building, force = game.forces.enemy }

  -- The basic tier must appear; no medium/big from a building death.
  local small = t.surface.find_entities_filtered {
    name = tiers.SWARM.small, position = pos, radius = 48,
  }
  t.assert.at_least(1, #small, "building death spawns the basic 'small' tier")

  local higher = t.surface.find_entities_filtered {
    name = { tiers.SWARM.medium, tiers.SWARM.big }, position = pos, radius = 48,
  }
  t.assert.equal(0, #higher, "building death must NOT spawn medium/big tiers")
end)
