-- S7 tests: corpse drops, the corpse/kiln prototypes, and reanimation
-- (R-CORPSE-1..7). Loads the real modules from the linked main mod via the
-- __zomtorio__ require path so the drop logic and prototype config under test are
-- the production code.
--
-- Why we call corpses.on_entity_died / swarm.on_entity_damaged DIRECTLY: each mod
-- has its OWN Lua state and `storage`. The swarm instance loaded here shares the
-- storage our swarm.spawn writes to, so its clusters (and the corpses their hits
-- drop) are inspectable from here. Corpses themselves are ground entities visible
-- to every mod, so we count them straight off the surface.

local T       = require("harness.runner")
local corpses = require("__zomtorio__.lib.corpses")
local swarm   = require("__zomtorio__.lib.swarm")
local tiers   = require("__zomtorio__.lib.tiers")

local CORPSE_ITEM = "zomtorio-corpse"

--- Total corpse items lying on the ground near `pos` (the engine splits a spilled
--- stack into one item-on-ground entity per stack-portion, each carrying a stack).
local function ground_corpses(surface, pos, radius)
  local found = surface.find_entities_filtered {
    name = "item-on-ground", position = pos, radius = radius or 16,
  }
  local total = 0
  for _, e in ipairs(found) do
    if e.valid and e.stack and e.stack.valid_for_read and e.stack.name == CORPSE_ITEM then
      total = total + e.stack.count
    end
  end
  return total
end

-- ------------------------------------------------------- kill -> corpse (R-CORPSE-2)
T.test("an individual zombie death drops a corpse", function(t)
  local o = t.test_origin
  t.world.clear(t.surface, o)
  local biter = t.world.place(t.surface, "small-biter", o, { force = "enemy" })

  corpses.on_entity_died { entity = biter, damage_type = { name = "physical" } }

  t.assert.at_least(1, ground_corpses(t.surface, o), "physical kill drops a corpse")
end)

-- ----------------------------------------- flame/explosion/no_corpse -> none (R-CORPSE-4)
T.test("a flame kill drops no corpse", function(t)
  local o = t.test_origin
  t.world.clear(t.surface, o)
  local biter = t.world.place(t.surface, "small-biter", o, { force = "enemy" })

  corpses.on_entity_died { entity = biter, damage_type = { name = "fire" } }

  t.assert.equal(0, ground_corpses(t.surface, o), "fire kill is dead-dead, no corpse")
end)

T.test("an explosion kill drops no corpse", function(t)
  local o = t.test_origin
  t.world.clear(t.surface, o)
  local biter = t.world.place(t.surface, "small-biter", o, { force = "enemy" })

  corpses.on_entity_died { entity = biter, damage_type = { name = "explosion" } }

  t.assert.equal(0, ground_corpses(t.surface, o), "explosion kill is dead-dead, no corpse")
end)

T.test("the no_corpse flag (double-tap) drops nothing", function(t)
  local o = t.test_origin
  t.world.clear(t.surface, o)

  corpses.drop(t.surface, o, 5, "physical", true)

  t.assert.equal(0, ground_corpses(t.surface, o), "no_corpse suppresses the drop")
end)

-- A non-zombie (player force) death drops nothing — only enemy units do.
T.test("a non-enemy unit death drops no corpse", function(t)
  local o = t.test_origin
  t.world.clear(t.surface, o)
  local biter = t.world.place(t.surface, "small-biter", o, { force = "player" })

  corpses.on_entity_died { entity = biter, damage_type = { name = "physical" } }

  t.assert.equal(0, ground_corpses(t.surface, o), "only enemy zombies drop corpses")
end)

-- A swarm-unit cluster's OWN death must NOT drop corpses here (its population
-- kills are dropped by lib/swarm at the hit) — otherwise it double-counts.
T.test("a swarm-unit cluster death drops no corpse via on_entity_died", function(t)
  swarm.reset_state()
  swarm.set_cap_override(0)
  local o = t.test_origin
  t.world.clear(t.surface, o)
  swarm.spawn(t.surface, o, 5, "small", "enemy")
  local found = t.surface.find_entities_filtered {
    name = tiers.SWARM.small, position = o, radius = 32,
  }
  local cluster = found[1]
  t.assert.not_nil(cluster, "cluster should exist")

  corpses.on_entity_died { entity = cluster, damage_type = { name = "physical" } }

  t.assert.equal(0, ground_corpses(t.surface, o), "cluster death excluded from per-individual drop")
end)

-- ------------------------------------------- swarm cluster kills DROP corpses
-- A normal hit removes 1 population and that 1 zombie drops a corpse.
T.test("a normal cluster hit drops corpses for the zombies killed", function(t)
  swarm.reset_state()
  swarm.set_cap_override(0)  -- no individuals, no burst -> pure decrement
  local o = t.test_origin
  t.world.clear(t.surface, o)
  swarm.spawn(t.surface, o, 10, "small", "enemy")
  local found = t.surface.find_entities_filtered {
    name = tiers.SWARM.small, position = o, radius = 32,
  }
  local cluster = found[1]
  t.assert.not_nil(cluster, "cluster should exist")

  cluster.damage(5, "player", "physical")
  swarm.on_entity_damaged {
    entity = cluster,
    damage_type = { name = "physical" },
    original_damage_amount = 5,
    final_damage_amount = 5,
  }

  t.assert.equal(1, ground_corpses(t.surface, o), "a normal hit kills 1 -> 1 corpse")
end)

-- An explosion multi-kills in swarm, but explosion is a no-corpse damage type
-- (R-CORPSE-4): the killed zombies leave NO corpses.
T.test("an explosive cluster hit drops no corpses", function(t)
  swarm.reset_state()
  swarm.set_cap_override(0)
  local o = t.test_origin
  t.world.clear(t.surface, o)
  swarm.spawn(t.surface, o, 60, "small", "enemy")
  local found = t.surface.find_entities_filtered {
    name = tiers.SWARM.small, position = o, radius = 32,
  }
  local cluster = found[1]
  t.assert.not_nil(cluster, "cluster should exist")

  local single = swarm.single_health("small")
  local dmg = single * 7
  cluster.damage(dmg, "player", "explosion")
  swarm.on_entity_damaged {
    entity = cluster,
    damage_type = { name = "explosion" },
    original_damage_amount = dmg,
    final_damage_amount = dmg,
  }

  t.assert.equal(0, ground_corpses(t.surface, o), "explosion kills are dead-dead")
end)

-- ----------------------------------------------- prototype config (R-CORPSE-3/5/6)
T.test("the corpse item is burnable and (default) reanimates", function(t)
  local corpse = prototypes.item[CORPSE_ITEM]
  t.assert.not_nil(corpse, "corpse item exists")
  t.assert.at_least(1, corpse.fuel_value, "corpse has a positive fuel value")
  -- Reanimation defaults ON: a positive spoil time and a spoil trigger.
  t.assert.at_least(1, corpse.get_spoil_ticks(), "corpse has a positive spoil time")
  t.assert.not_nil(corpse.spoil_to_trigger_result, "corpse has a spoil trigger")
end)

T.test("the kiln-dried corpse never spoils and is worth more fuel", function(t)
  local corpse = prototypes.item[CORPSE_ITEM]
  local dried  = prototypes.item["zomtorio-kiln-dried-corpse"]
  t.assert.not_nil(dried, "kiln-dried item exists")
  t.assert.equal(0, dried.get_spoil_ticks(), "kiln-dried does not spoil")
  t.assert.is_true(dried.fuel_value > corpse.fuel_value,
    "kiln-dried is worth more fuel per item")
end)

-- --------------------------------------------------- kiln ratio (R-CORPSE-6)
T.test("the drying recipe consumes 5 corpses and yields 2 kiln-dried", function(t)
  local r = prototypes.recipe["zomtorio-kiln-dried-corpse"]
  t.assert.not_nil(r, "drying recipe exists")

  local in_corpse = 0
  for _, ing in ipairs(r.ingredients) do
    if ing.name == CORPSE_ITEM then in_corpse = ing.amount end
  end
  t.assert.equal(5, in_corpse, "consumes 5 corpses")

  local out_dried = 0
  for _, p in ipairs(r.products) do
    if p.name == "zomtorio-kiln-dried-corpse" then out_dried = p.amount end
  end
  t.assert.equal(2, out_dried, "yields 2 kiln-dried")
end)

-- ------------------------------------------ fuel-loss invariant (R-CORPSE-7)
T.test("drying loses energy overall (R-CORPSE-7 invariant)", function(t)
  local corpse_fuel = prototypes.item[CORPSE_ITEM].fuel_value
  local dried_fuel  = prototypes.item["zomtorio-kiln-dried-corpse"].fuel_value
  t.assert.is_true(dried_fuel > corpse_fuel, "kiln-dried denser per item")
  t.assert.is_true(2 * dried_fuel < 5 * corpse_fuel, "5->2 loop loses energy overall")
end)

-- ------------------------------------- reanimation -> enemy zombie (R-CORPSE-5)
-- Force a corpse stack to fully spoil in a chest and step a tick; assert a biter
-- on the ENEMY force hatched nearby. If forcing spoilage isn't supported headless
-- the test degrades to asserting the trigger is configured to make an enemy biter.
T.test("a spoiled corpse reanimates into an enemy zombie", {
  function(t)
    local o = t.test_origin
    t.world.clear(t.surface, o, 24)
    t.chest = t.world.place(t.surface, "steel-chest", o)
    t.world.insert(t.chest, CORPSE_ITEM, 1)

    -- Try to drive the stack to fully spoiled. LuaItemStack.spoil_percent is the
    -- 2.1 hook; guard it so a future API change degrades gracefully.
    local inv = t.chest.get_inventory(defines.inventory.chest)
    local stack = inv and inv[1]
    t.forced = false
    if stack and stack.valid_for_read then
      local ok = pcall(function() stack.spoil_percent = 1.0 end)
      t.forced = ok
    end
  end,
  { after = 5, fn = function(t)
    local o = t.test_origin
    if t.forced then
      local biters = t.surface.find_entities_filtered {
        name = "small-biter", position = o, radius = 16, force = "enemy",
      }
      t.assert.at_least(1, #biters, "the spoiled corpse hatched an enemy zombie")
    else
      -- Fallback: forcing spoilage unsupported headless. Assert the prototype
      -- trigger is wired to create an enemy-force small-biter. Read-back shape is
      -- the runtime SpoilToTriggerResult concept: `trigger` is an array of trigger
      -- items, each with an array of action_delivery (NOT the flat data-table shape).
      local trig = prototypes.item[CORPSE_ITEM].spoil_to_trigger_result
      t.assert.not_nil(trig, "corpse spoil trigger configured")
      local item = trig.trigger[1]
      t.assert.not_nil(item, "trigger has at least one item")
      local delivery = item.action_delivery[1]
      t.assert.not_nil(delivery, "trigger item has an action delivery")
      local eff = delivery.source_effects[1]
      t.assert.equal("small-biter", eff.entity_name, "spoils into a small-biter")
      t.assert.is_true(eff.as_enemy == true, "the hatched zombie is on the enemy force")
    end
  end },
})

-- ============================================================================
-- Feature A: reanimation routed through the dynamic cap (R-HORDE-6 / R-GEN-6).
--
-- Real spoilage takes ~10 minutes, so we test the interception path by directly
-- synthesizing the on_trigger_created_entity event the spoilage trigger raises
-- (trigger_created_entity = true) for each hatched zombie.
-- ============================================================================

-- A reanimated zombie while the cap has room stays a real individual AND now
-- counts against the cap (so a pile can't blow past the cap).
T.test("a reanimated zombie under the cap is tracked as an individual", function(t)
  swarm.reset_state()
  swarm.set_cap_override(1000)
  local o = t.test_origin
  t.world.clear(t.surface, o)
  local biter = t.world.place(t.surface, "small-biter", o, { force = "enemy" })

  swarm.on_trigger_created_entity { entity = biter }

  t.assert.is_true(biter.valid, "under-cap reanimation stays a real individual")
  t.assert.is_true(swarm.is_tracked(biter.unit_number), "and now counts against the cap")
end)

-- When the cap is full the hatched individual is removed and folded into a
-- cluster; a pile reanimating near the same spot MERGES into one growing cluster.
T.test("a reanimated zombie over the cap folds into a cluster (and merges)", function(t)
  swarm.reset_state()
  swarm.set_cap_override(0)  -- cap full: everything must fold
  local o = t.test_origin
  t.world.clear(t.surface, o)

  local b1 = t.world.place(t.surface, "small-biter", o, { force = "enemy" })
  swarm.on_trigger_created_entity { entity = b1 }
  t.assert.is_false(b1.valid, "over-cap reanimation is removed (folded)")

  local b2 = t.world.place(t.surface, "small-biter", o, { force = "enemy" })
  swarm.on_trigger_created_entity { entity = b2 }

  local clusters = t.surface.find_entities_filtered {
    name = tiers.SWARM.small, position = o, radius = 16,
  }
  local total_pop = 0
  for _, c in ipairs(clusters) do total_pop = total_pop + (swarm.pop_of(c) or 0) end
  t.assert.equal(1, #clusters, "two reanimations near the same spot merge into one cluster")
  t.assert.equal(2, total_pop, "the merged cluster holds both folded zombies")
end)

-- swarm.fold merges into a nearby existing cluster of the same tier and applies
-- NO swarm-size multiplier (overflow is not a fresh generation source).
T.test("swarm.fold merges into a nearby cluster without multiplier", function(t)
  swarm.reset_state()
  swarm.set_cap_override(0)
  swarm.set_size_multiplier_override(10)  -- would 10x if fold wrongly applied it
  local o = t.test_origin
  t.world.clear(t.surface, o)

  swarm.fold(t.surface, o, 3, "small", "enemy")
  swarm.fold(t.surface, { x = o.x + 2, y = o.y }, 2, "small", "enemy")

  local clusters = t.surface.find_entities_filtered {
    name = tiers.SWARM.small, position = o, radius = 16,
  }
  t.assert.equal(1, #clusters, "the second fold merged into the first cluster")
  t.assert.equal(5, swarm.pop_of(clusters[1]), "merged pop is 3+2 with no multiplier applied")

  swarm.set_size_multiplier_override(nil)
end)

-- Trigger-created entities that aren't OUR reanimated zombies are left untouched:
-- no tracking, no fold, entity not destroyed.
T.test("non-zombie trigger-created entities are ignored", function(t)
  swarm.reset_state()
  swarm.set_cap_override(0)
  local o = t.test_origin
  t.world.clear(t.surface, o)

  -- A neutral-force tree: wrong type and wrong force, so the handler must skip it.
  local tree = t.surface.create_entity { name = "tree-01", position = o }
  if tree then
    swarm.on_trigger_created_entity { entity = tree }
    t.assert.is_true(tree.valid, "an unrelated trigger-created entity is untouched")
  end

  -- A player-force biter is the right type but the wrong force: also skipped.
  local friendly = t.world.place(t.surface, "small-biter",
    { x = o.x + 3, y = o.y }, { force = "player" })
  swarm.on_trigger_created_entity { entity = friendly }
  t.assert.is_true(friendly.valid, "a non-enemy unit is not folded")
  t.assert.is_false(swarm.is_tracked(friendly.unit_number), "and not tracked")

  local clusters = t.surface.find_entities_filtered {
    name = tiers.SWARM.small, position = o, radius = 16,
  }
  t.assert.equal(0, #clusters, "no cluster created from ignored entities")
end)

-- ============================================================================
-- Feature B: bot collection marks dropped corpses for deconstruction.
-- ============================================================================
T.test("bot collection marks dropped corpses for deconstruction", function(t)
  local o = t.test_origin
  t.world.clear(t.surface, o)

  corpses.set_bot_collect_override(true)
  corpses.drop(t.surface, o, 3, "physical")

  local items = t.surface.find_entities_filtered {
    name = "item-on-ground", position = o, radius = 16,
  }
  t.assert.at_least(1, #items, "corpses were dropped")
  for _, e in ipairs(items) do
    t.assert.is_true(e.to_be_deconstructed(), "each dropped corpse is marked for deconstruction")
  end

  corpses.set_bot_collect_override(nil)
end)

T.test("with bot collection off corpses are not marked", function(t)
  local o = t.test_origin
  t.world.clear(t.surface, o)

  corpses.set_bot_collect_override(false)
  corpses.drop(t.surface, o, 3, "physical")

  local items = t.surface.find_entities_filtered {
    name = "item-on-ground", position = o, radius = 16,
  }
  t.assert.at_least(1, #items, "corpses were dropped")
  for _, e in ipairs(items) do
    t.assert.is_false(e.to_be_deconstructed(), "dropped corpses are NOT marked when off")
  end

  corpses.set_bot_collect_override(nil)
end)
