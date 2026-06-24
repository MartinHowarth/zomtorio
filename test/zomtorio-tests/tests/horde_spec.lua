-- S2 tests: the horde population model + unified cap-aware spawner
-- (R-HORDE-2..6). Loads the real module from the linked main mod via the
-- __zomtorio__ require path, so the spawner, cap accounting and hit logic under
-- test are the production code.
--
-- IMPORTANT — why we call horde.on_entity_damaged DIRECTLY instead of via the
-- engine event: each mod has its OWN Lua state and `storage`. The horde module
-- instance loaded here (in the test mod) has the storage that our horde.spawn
-- writes to; the main mod's registered on_entity_damaged handler reads the main
-- mod's (separate) storage and so can't see our test clusters. Calling the
-- handler on this instance with a synthesized event is the only way to exercise
-- the real hit logic against the cluster we just spawned. We still apply the
-- engine damage first (entity.damage) so health-side effects are realistic.
--
-- on_init() resets storage (incl. the cap's individual_count) before each test
-- so cap accounting is deterministic. Runtime-global settings can only be
-- written by their OWNING mod, so this (separate) test mod cannot set the cap
-- setting; instead we pin the cap through horde.set_cap_override, the single
-- internal hook the runtime exposes for exactly this purpose.

local T     = require("harness.runner")
local horde = require("__zomtorio__.lib.horde")
local tiers = require("__zomtorio__.lib.tiers")

local DEFAULT_CAP = 1000

local function set_cap(n)
  horde.set_cap_override(n)
end

-- Reset both the cap and our storage so each test starts from a known state.
local function reset(cap)
  set_cap(cap or DEFAULT_CAP)
  horde.on_init()
end

--- Find the (single) tracked horde unit near a position, by prototype name.
local function find_cluster(surface, pos, tier)
  local name = (tiers.HORDE)[tier or "small"]
  local found = surface.find_entities_filtered { name = name, position = pos, radius = 32 }
  return found[1]
end

--- Hit a horde unit: apply the real engine damage, then drive the handler on the
--- module instance whose storage holds the cluster (see header note).
local function hit(entity, amount, damage_type)
  entity.damage(amount, "player", damage_type)
  -- The handler only reads event.damage_type.name and original_damage_amount,
  -- so a minimal event table mirrors what the engine would deliver.
  horde.on_entity_damaged {
    entity = entity,
    damage_type = { name = damage_type },
    original_damage_amount = amount,
  }
end

-- ----------------------------------------------------------------- pop math
-- Force a cluster by spawning into a zero-room cap: every zombie folds into a
-- horde unit. Assert the unit exists with the expected pop and clamped health.
T.test("spawn into a full cap creates a cluster with the right pop and health", function(t)
  reset(50)
  -- Fill the cap so there is no individual room: spawn exactly the cap first.
  horde.spawn(t.surface, t.test_origin, 50, "small", "enemy")
  t.assert.equal(50, horde.active_count(), "cap should be full of individuals")

  -- Now spawn 30 more of a clean tier elsewhere: all must fold into a cluster.
  local o = { x = t.test_origin.x + 40, y = t.test_origin.y }
  t.world.clear(t.surface, o)
  horde.spawn(t.surface, o, 30, "small", "enemy")

  local cluster = find_cluster(t.surface, o, "small")
  t.assert.not_nil(cluster, "a horde-unit cluster should exist")
  t.assert.equal(30, horde.pop_of(cluster), "cluster pop should be the overflow")

  local single = horde.single_health("small")
  local expected = math.min(30 * single, cluster.max_health)
  if expected < 1 then expected = 1 end
  t.assert.equal(expected, cluster.health, "cluster health should track pop x single")
end)

-- ------------------------------------------------------------ normal-hit kill
-- A normal (physical) hit kills exactly one zombie's worth: pop drops by 1.
-- No character is placed, so it never bursts -> it just loses population.
T.test("a normal hit removes one population", function(t)
  reset(0)  -- cap full so the spawn folds into a cluster
  local o = t.test_origin
  t.world.clear(t.surface, o)
  horde.spawn(t.surface, o, 10, "small", "enemy")
  local cluster = find_cluster(t.surface, o, "small")
  t.assert.not_nil(cluster, "cluster should exist")
  t.assert.equal(10, horde.pop_of(cluster), "starts at pop 10")

  hit(cluster, 5, "physical")
  t.assert.equal(9, horde.pop_of(cluster), "physical hit kills exactly 1")
end)

-- ----------------------------------------------------------- explosion kills
-- An explosion kills floor(damage / single-zombie-health) (R-HORDE-5).
T.test("an explosive hit multi-kills proportional to damage", function(t)
  reset(0)
  local o = t.test_origin
  t.world.clear(t.surface, o)
  horde.spawn(t.surface, o, 60, "small", "enemy")
  local cluster = find_cluster(t.surface, o, "small")
  t.assert.not_nil(cluster, "cluster should exist")

  local single = horde.single_health("small")
  local dmg = single * 7 + 1            -- floor(dmg/single) == 7
  local expected_kills = math.floor(dmg / single)
  hit(cluster, dmg, "explosion")
  t.assert.equal(60 - expected_kills, horde.pop_of(cluster),
    "explosion kills floor(damage/single)")
end)

-- ---------------------------------------------------------------- cap -> cluster
-- count >> cap: individuals fill exactly the cap (room), the rest fold into a
-- cluster. (R-HORDE-6: overflow is never discarded.)
T.test("spawning past the cap fills the cap then folds the rest into a cluster", function(t)
  reset(20)
  local o = t.test_origin
  t.world.clear(t.surface, o)
  horde.spawn(t.surface, o, 120, "small", "enemy")
  t.assert.equal(20, horde.active_count(), "individuals == cap room")

  -- Total population standing in the world is preserved: cap individuals + the
  -- cluster pop should equal the requested count.
  local cluster = find_cluster(t.surface, o, "small")
  t.assert.not_nil(cluster, "overflow cluster should exist")
  t.assert.equal(100, horde.pop_of(cluster), "cluster holds count - cap")
end)

-- --------------------------------------------------------------------- burst
-- With cap room AND a character within burst radius, a hit bursts the cluster
-- into individuals: the cluster entity is gone and active_count rises.
T.test("a hit bursts a cluster into individuals when a player is near", function(t)
  reset(DEFAULT_CAP)
  local o = t.test_origin
  t.world.clear(t.surface, o)

  -- Force a cluster (not individuals) by spawning while the cap is momentarily
  -- full, then restore room so the hit can burst.
  set_cap(0)
  horde.spawn(t.surface, o, 12, "small", "enemy")
  local cluster = find_cluster(t.surface, o, "small")
  t.assert.not_nil(cluster, "cluster should exist before burst")
  set_cap(DEFAULT_CAP)

  -- A character nearby acts as the player proximity anchor.
  t.world.place(t.surface, "character", { x = o.x + 2, y = o.y }, { force = "player" })

  local before = horde.active_count()
  hit(cluster, 5, "physical")  -- kills 1, bursts the other 11

  t.assert.is_false(cluster.valid, "the cluster entity should be gone after bursting")
  t.assert.at_least(before + 11, horde.active_count(),
    "the 11 survivors should now be tracked individuals")
end)

-- ------------------------------------------------------------ death at pop 0
-- Reducing a small cluster's pop to 0 via hits destroys it and clears its record.
T.test("a cluster dies and is cleared when its population reaches 0", function(t)
  reset(0)  -- no cap room, no character -> hits only decrement
  local o = t.test_origin
  t.world.clear(t.surface, o)
  horde.spawn(t.surface, o, 3, "small", "enemy")
  local cluster = find_cluster(t.surface, o, "small")
  t.assert.not_nil(cluster, "cluster should exist")

  for _ = 1, 3 do
    if cluster.valid then hit(cluster, 5, "physical") end
  end
  t.assert.is_false(cluster.valid, "cluster destroyed at pop 0")
  t.assert.equal(nil, horde.pop_of(cluster), "its storage record is cleared")
end)
