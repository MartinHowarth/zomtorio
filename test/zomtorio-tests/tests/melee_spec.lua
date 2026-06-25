-- S8 tests: swarm melee + the double-tap toggle (R-MELEE-1..5). Loads the real
-- modules from the linked main mod via the __zomtorio__ require path.
--
-- HARNESS NOTES (see horde_spec / corpses_spec headers):
--  * Each mod has its own Lua `storage`; we drive handlers DIRECTLY so they read
--    the storage these calls write to.
--  * The headless benchmark has NO connected players, so double-tap can't be
--    toggled for a real player — we pin the answer via melee.set_double_tap_override.
--  * entity.damage(...) fires real engine events handled by the MAIN mod (separate
--    storage), so we DON'T test cluster multi-kill through the engine. Instead we
--    test the AoE on real individual biters in the world (entity.damage affects
--    them directly), and the base-1-kill rule purely through horde, and the
--    double-tap corpse suppression by calling corpses.on_entity_died directly.

local T       = require("harness.runner")
local melee   = require("__zomtorio__.lib.melee")
local horde   = require("__zomtorio__.lib.horde")
local corpses = require("__zomtorio__.lib.corpses")
local tiers   = require("__zomtorio__.lib.tiers")

local BASE_MELEE  = "zomtorio-zombie-melee"
local SWARM_MELEE = "zomtorio-swarm-melee"
local TIER_1 = "zomtorio-swarm-melee-1"
local TIER_2 = "zomtorio-swarm-melee-2"

-- Clean slate for the modules we touch.
local function reset()
  horde.reset_state()
  melee.reset_state()
  melee.set_double_tap_override(nil)
end

-- Reset every tech we research during these tests so cases don't bleed.
local function clear_tech()
  local techs = game.forces.player.technologies
  for _, name in ipairs({ TIER_1, TIER_2 }) do
    if techs[name] then techs[name].researched = false end
  end
end

local function ground_corpses(surface, pos, radius)
  local found = surface.find_entities_filtered {
    name = "item-on-ground", position = pos, radius = radius or 16,
  }
  local total = 0
  for _, e in ipairs(found) do
    if e.valid and e.stack and e.stack.valid_for_read and e.stack.name == "zomtorio-corpse" then
      total = total + e.stack.count
    end
  end
  return total
end

-- Count living enemy biters near a position.
local function count_biters(surface, pos, radius)
  return #surface.find_entities_filtered {
    name = "small-biter", position = pos, radius = radius or 8, force = "enemy",
  }
end

-- ------------------------------------------------ base punch kills 1 (R-MELEE-1)
-- With NO tech, a base "zombie-melee" hit on a cluster removes exactly one
-- population — proving the base type is single-kill, not a horde multi-kill type.
T.test("a base melee punch kills exactly one zombie on a cluster", function(t)
  reset()
  horde.set_cap_override(0)  -- force a cluster, no burst
  local o = t.test_origin
  t.world.clear(t.surface, o)
  horde.spawn(t.surface, o, 10, "small", "enemy")
  local found = t.surface.find_entities_filtered {
    name = tiers.HORDE.small, position = o, radius = 32,
  }
  local cluster = found[1]
  t.assert.not_nil(cluster, "cluster should exist")
  t.assert.equal(10, horde.pop_of(cluster), "starts at pop 10")

  local single = horde.single_health("small")
  cluster.damage(single * 5, "player", "physical")  -- realistic health side-effect
  horde.on_entity_damaged {
    entity = cluster,
    damage_type = { name = BASE_MELEE },
    original_damage_amount = single * 5,
    final_damage_amount = single * 5,
  }

  t.assert.equal(9, horde.pop_of(cluster), "base punch kills exactly 1 (R-MELEE-1)")
end)

-- ------------------------------ Tier-1 AoE multi-kills a swarm, enemy-only (R-MELEE-2/4)
T.test("Tier-1 swarm melee multi-kills a swarm and never harms friendlies", function(t)
  reset()
  clear_tech()
  game.forces.player.technologies[TIER_1].researched = true

  local o = t.test_origin
  t.world.clear(t.surface, o, 12)

  -- Several enemy biters tightly clustered around the strike point.
  local biters = {}
  for i = 1, 6 do
    local p = { x = o.x + (i % 3) * 0.6 - 0.6, y = o.y + math.floor(i / 3) * 0.6 - 0.3 }
    biters[i] = t.world.place(t.surface, "small-biter", p, { force = "enemy" })
  end
  local before = count_biters(t.surface, o, 6)
  t.assert.at_least(2, before, "several biters placed")

  -- A friendly entity inside the AoE radius must be untouched (no friendly fire).
  local chest = t.world.place(t.surface, "iron-chest", { x = o.x + 1, y = o.y }, { force = "player" })
  local chest_hp = chest.health

  -- The dealer is a character so kills attribute to the player.
  local dealer = t.world.place(t.surface, "character", { x = o.x - 3, y = o.y }, { force = "player" })

  melee.on_entity_damaged {
    entity = biters[1],
    force = game.forces.player,
    cause = dealer,
    damage_type = { name = BASE_MELEE },
    original_damage_amount = 8,
    final_damage_amount = 8,
  }

  local after = count_biters(t.surface, o, 6)
  t.assert.is_true(after < before, "Tier-1 AoE killed multiple biters in the swarm")
  t.assert.is_true(chest.valid and chest.health == chest_hp,
    "the friendly chest is unharmed (enemy-only, R-MELEE-4)")
end)

-- ----------------------------------------- Tier-2 hits harder than Tier-1 (R-MELEE-2)
-- small-biter health is small, so a single swarm-melee hit one-shots one biter at
-- either tier; to show Tier 2 hits HARDER, compare damage dealt to a tougher
-- single enemy (a big-biter) under tier-1 vs tier-1+tier-2.
T.test("Tier-2 swarm melee deals more damage than Tier-1", function(t)
  reset()
  clear_tech()
  local force = game.forces.player

  -- Tier 1 only.
  force.technologies[TIER_1].researched = true
  force.technologies[TIER_2].researched = false
  local o1 = t.test_origin
  t.world.clear(t.surface, o1, 8)
  local tough1 = t.world.place(t.surface, "big-biter", o1, { force = "enemy" })
  local full = tough1.health
  local dealer1 = t.world.place(t.surface, "character", { x = o1.x - 3, y = o1.y }, { force = "player" })
  melee.on_entity_damaged {
    entity = tough1, force = force, cause = dealer1,
    damage_type = { name = BASE_MELEE },
    original_damage_amount = 8, final_damage_amount = 8,
  }
  t.assert.is_true(tough1.valid, "a single big-biter survives one tier-1 hit (for comparison)")
  local dmg_t1 = full - tough1.health

  -- Tier 1 + Tier 2.
  force.technologies[TIER_2].researched = true
  local o2 = { x = o1.x + 16, y = o1.y }
  t.world.clear(t.surface, o2, 8)
  local tough2 = t.world.place(t.surface, "big-biter", o2, { force = "enemy" })
  local full2 = tough2.health
  local dealer2 = t.world.place(t.surface, "character", { x = o2.x - 3, y = o2.y }, { force = "player" })
  melee.on_entity_damaged {
    entity = tough2, force = force, cause = dealer2,
    damage_type = { name = BASE_MELEE },
    original_damage_amount = 8, final_damage_amount = 8,
  }
  local dmg_t2 = full2 - (tough2.valid and tough2.health or 0)

  t.assert.is_true(dmg_t2 > dmg_t1, "Tier-2 deals more damage per hit than Tier-1")
end)

-- ------------------------------------ double-tap suppresses corpses (R-MELEE-5)
T.test("double-tap makes a melee kill drop no corpse", function(t)
  reset()
  local o = t.test_origin
  t.world.clear(t.surface, o)
  local biter = t.world.place(t.surface, "small-biter", o, { force = "enemy" })
  local dealer = t.world.place(t.surface, "character", { x = o.x - 3, y = o.y }, { force = "player" })

  melee.set_double_tap_override(true)
  corpses.on_entity_died {
    entity = biter, cause = dealer, damage_type = { name = SWARM_MELEE },
  }
  t.assert.equal(0, ground_corpses(t.surface, o), "double-tap melee kill is dead-dead")
end)

T.test("with double-tap off a melee kill still drops a corpse", function(t)
  reset()
  local o = t.test_origin
  t.world.clear(t.surface, o)
  local biter = t.world.place(t.surface, "small-biter", o, { force = "enemy" })
  local dealer = t.world.place(t.surface, "character", { x = o.x - 3, y = o.y }, { force = "player" })

  melee.set_double_tap_override(false)
  corpses.on_entity_died {
    entity = biter, cause = dealer, damage_type = { name = SWARM_MELEE },
  }
  t.assert.at_least(1, ground_corpses(t.surface, o),
    "melee types are NOT no-corpse without double-tap (R-MELEE-4)")
end)

-- A base-punch melee kill with double-tap OFF also drops a corpse (confirms the
-- base type isn't in the flame/explosion no-corpse set).
T.test("a base-melee kill drops a corpse without double-tap", function(t)
  reset()
  local o = t.test_origin
  t.world.clear(t.surface, o)
  local biter = t.world.place(t.surface, "small-biter", o, { force = "enemy" })

  melee.set_double_tap_override(false)
  corpses.on_entity_died {
    entity = biter, damage_type = { name = BASE_MELEE },
  }
  t.assert.at_least(1, ground_corpses(t.surface, o),
    "base-melee kill drops a corpse normally")
end)
