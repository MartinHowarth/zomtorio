-- S11 settings sweep: the one behavioural wiring this stage changed — the overall
-- horde-size multiplier (R-HORDE-7) now applies in the unified spawner, so EVERY
-- generation source (death cascade, swarm events, night escalation) scales by it.
-- (The other settings are each exercised by their feature's own spec: building/
-- player infection on/off + time-to-death in infection specs, the cap and burst in
-- horde_spec, swarm on/off + intensity + frequency in swarm_spec, expansion-rate /
-- nest density / pollution cost / night-speedup in generation_spec & night_spec.)

local T     = require("harness.runner")
local horde = require("__zomtorio__.lib.horde")
local tiers = require("__zomtorio__.lib.tiers")

-- Sum the population of all small clusters near a position (cap pinned to 0 means
-- every spawned zombie folds into a cluster, so this is the full spawned count).
local function cluster_pop(surface, pos)
  local total = 0
  for _, c in ipairs(surface.find_entities_filtered {
    name = tiers.HORDE.small, position = pos, radius = 48,
  }) do
    total = total + (horde.pop_of(c) or 0)
  end
  return total
end

local function reset()
  horde.reset_state()
  horde.set_cap_override(0)            -- fold everything into inspectable clusters
  horde.set_size_multiplier_override(nil)
end

T.test("horde-size multiplier scales a spawn (R-HORDE-7)", function(t)
  reset()
  horde.set_size_multiplier_override(2)
  local o = t.test_origin
  t.world.clear(t.surface, o)
  horde.spawn(t.surface, o, 10, "small", "enemy")
  t.assert.equal(20, cluster_pop(t.surface, o), "10 requested x2 multiplier = 20")
  horde.set_size_multiplier_override(nil)
end)

T.test("default horde-size multiplier (1.0) leaves the count unchanged", function(t)
  reset()
  local o = t.test_origin
  t.world.clear(t.surface, o)
  horde.spawn(t.surface, o, 10, "small", "enemy")
  t.assert.equal(10, cluster_pop(t.surface, o), "x1.0 default = unchanged")
end)

-- A low multiplier must never silently drop a positive request to zero — a
-- building destroyed by zombies still yields at least one zombie (R-DEATH-2).
T.test("a low multiplier still yields at least one zombie", function(t)
  reset()
  horde.set_size_multiplier_override(0.1)
  local o = t.test_origin
  t.world.clear(t.surface, o)
  horde.spawn(t.surface, o, 4, "small", "enemy")   -- 4 * 0.1 = 0.4 -> floors to 1
  t.assert.equal(1, cluster_pop(t.surface, o), "positive request never rounds to 0")
  horde.set_size_multiplier_override(nil)
end)
