-- S11 settings sweep: the one behavioural wiring this stage changed — the overall
-- swarm-size multiplier (R-HORDE-7) now applies in the unified spawner, so EVERY
-- generation source (death cascade, swarm events, night escalation) scales by it.
-- (The other settings are each exercised by their feature's own spec: building/
-- player infection on/off + time-to-death in infection specs, the cap and burst in
-- horde_spec, swarm on/off + intensity + frequency in swarm_spec, expansion-rate /
-- nest density / pollution cost / night-speedup in generation_spec & night_spec.)

local T     = require("harness.runner")
local swarm = require("__Zomtorio__.lib.swarm")
local tiers = require("__Zomtorio__.lib.tiers")

-- Sum the population of all small clusters near a position (cap pinned to 0 means
-- every spawned zombie folds into a cluster, so this is the full spawned count).
local function cluster_pop(surface, pos)
  local total = 0
  for _, c in ipairs(surface.find_entities_filtered {
    name = tiers.SWARM.small, position = pos, radius = 48,
  }) do
    total = total + (swarm.pop_of(c) or 0)
  end
  return total
end

local function reset()
  swarm.reset_state()
  swarm.set_cap_override(0)            -- fold everything into inspectable clusters
  swarm.set_size_multiplier_override(nil)
end

T.test("swarm-size multiplier scales a spawn (R-HORDE-7)", function(t)
  reset()
  swarm.set_size_multiplier_override(2)
  local o = t.test_origin
  t.world.clear(t.surface, o)
  swarm.spawn(t.surface, o, 10, "small", "enemy")
  t.assert.equal(20, cluster_pop(t.surface, o), "10 requested x2 multiplier = 20")
  swarm.set_size_multiplier_override(nil)
end)

T.test("default swarm-size multiplier (1.0) leaves the count unchanged", function(t)
  reset()
  local o = t.test_origin
  t.world.clear(t.surface, o)
  swarm.spawn(t.surface, o, 10, "small", "enemy")
  t.assert.equal(10, cluster_pop(t.surface, o), "x1.0 default = unchanged")
end)

-- A low multiplier must never silently drop a positive request to zero — a
-- building destroyed by zombies still yields at least one zombie (R-DEATH-2).
T.test("a low multiplier still yields at least one zombie", function(t)
  reset()
  swarm.set_size_multiplier_override(0.1)
  local o = t.test_origin
  t.world.clear(t.surface, o)
  swarm.spawn(t.surface, o, 4, "small", "enemy")   -- 4 * 0.1 = 0.4 -> floors to 1
  t.assert.equal(1, cluster_pop(t.surface, o), "positive request never rounds to 0")
  swarm.set_size_multiplier_override(nil)
end)

-- Regression: bursting re-spawns an ALREADY-scaled surviving population, so it
-- must NOT re-apply the multiplier (else a high multiplier multiplies twice).
T.test("bursting does not re-apply the swarm-size multiplier", function(t)
  swarm.reset_state()
  local o = t.test_origin
  t.world.clear(t.surface, o)
  -- Build a pop-10 cluster at multiplier 1 (cap full so it folds into a cluster).
  swarm.set_cap_override(0)
  swarm.set_size_multiplier_override(1)
  swarm.spawn(t.surface, o, 10, "small", "enemy")
  local cluster = t.surface.find_entities_filtered {
    name = tiers.SWARM.small, position = o, radius = 48,
  }[1]
  t.assert.not_nil(cluster, "cluster should exist")

  -- Now open the cap and set a HIGH multiplier; a character nearby lets a hit burst.
  swarm.set_cap_override(1000)
  swarm.set_size_multiplier_override(3)
  t.world.place(t.surface, "character", { x = o.x + 2, y = o.y }, { force = "player" })
  local before = swarm.active_count()

  cluster.damage(5, "player", "physical")          -- kills 1 -> 9 survivors burst
  swarm.on_entity_damaged {
    entity = cluster, damage_type = { name = "physical" },
    original_damage_amount = 5, final_damage_amount = 5,
  }

  -- 9 survivors, NOT 9*3: the multiplier must not apply to an existing population.
  t.assert.equal(9, swarm.active_count() - before, "burst survivors are not re-scaled")
  swarm.set_size_multiplier_override(nil)
end)
