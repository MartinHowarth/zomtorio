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
  horde.reset_state()
end

--- Find the (single) tracked horde unit near a position, by prototype name.
local function find_cluster(surface, pos, tier)
  local name = (tiers.HORDE)[tier or "small"]
  local found = surface.find_entities_filtered { name = name, position = pos, radius = 32 }
  return found[1]
end

--- Hit a horde unit: apply the real engine damage, then drive the handler on the
--- module instance whose storage holds the cluster (see header note).
local function hit(entity, amount, damage_type, final)
  entity.damage(amount, "player", damage_type)
  -- The handler reads damage_type.name and the dealt (final) damage, falling
  -- back to original. `final` defaults to `amount` (a no-resistance hit).
  horde.on_entity_damaged {
    entity = entity,
    damage_type = { name = damage_type },
    original_damage_amount = amount,
    final_damage_amount = final or amount,
  }
end

-- ----------------------------------------------------------------- pop math
-- Force a cluster by spawning into a zero-room cap: every zombie folds into a
-- horde unit. Assert the unit exists with the expected pop and that it sits at full
-- (huge) health — clusters stay at max_health so no single damage instance can wipe
-- the whole swarm; population is tracked in storage, not the health bar.
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
  t.assert.equal(cluster.max_health, cluster.health,
    "cluster stays at full (huge) health — immune to a one-shot; pop lives in storage")
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
  t.assert.equal("10", horde.pop_label_text(cluster), "pop label shows the count")

  hit(cluster, 5, "physical")
  t.assert.equal(9, horde.pop_of(cluster), "physical hit kills exactly 1")
  t.assert.equal("9", horde.pop_label_text(cluster), "pop label tracks the count")
end)

-- A single huge non-explosive/fire hit must still remove only ONE — the cluster's
-- full (huge) health makes it immune to a one-shot wipe (the bug where a strong shot
-- killed a whole small cluster). Only the script removes population.
T.test("a massive single physical hit removes only one (no one-shot wipe)", function(t)
  reset(0)
  local o = t.test_origin
  t.world.clear(t.surface, o)
  horde.spawn(t.surface, o, 8, "small", "enemy")
  local cluster = find_cluster(t.surface, o, "small")
  t.assert.not_nil(cluster, "cluster should exist")

  hit(cluster, 100000, "physical")  -- far more than pop x single-health
  t.assert.is_true(cluster.valid, "cluster survives a massive single physical hit")
  t.assert.equal(7, horde.pop_of(cluster), "still only one removed")
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

-- Multi-kill must count damage DEALT (post-resistance), not the pre-resistance
-- amount: original would kill 20, but only 5 worth is actually dealt.
T.test("explosion multi-kill counts damage dealt, not pre-resistance", function(t)
  reset(0)
  local o = t.test_origin
  t.world.clear(t.surface, o)
  horde.spawn(t.surface, o, 60, "small", "enemy")
  local cluster = find_cluster(t.surface, o, "small")
  t.assert.not_nil(cluster, "cluster should exist")

  local single = horde.single_health("small")
  hit(cluster, single * 20, "explosion", single * 5)
  t.assert.equal(60 - 5, horde.pop_of(cluster), "kills computed from damage dealt")
end)

-- A tracked individual dying must free its cap slot (else the effective cap
-- shrinks over a long game). Exercises horde.on_entity_died's decrement.
T.test("an individual zombie death frees its cap slot", function(t)
  reset(DEFAULT_CAP)
  local o = t.test_origin
  t.world.clear(t.surface, o)
  horde.spawn(t.surface, o, 3, "small", "enemy")  -- cap has room -> 3 real biters
  t.assert.equal(3, horde.active_count(), "3 tracked individuals")

  -- Pick a biter WE tracked: stray biters from other tests can wander into this
  -- radius, and killing an untracked one wouldn't (correctly) change the count.
  local biters = t.surface.find_entities_filtered {
    name = tiers.INDIVIDUAL.small, position = o, radius = 32,
  }
  local victim
  for _, b in ipairs(biters) do
    if horde.is_tracked(b.unit_number) then victim = b; break end
  end
  t.assert.not_nil(victim, "a tracked individual exists in the world")
  horde.on_entity_died { entity = victim }
  t.assert.equal(2, horde.active_count(), "death frees a cap slot")
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
