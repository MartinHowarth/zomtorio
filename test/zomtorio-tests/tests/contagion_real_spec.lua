-- REAL-PLAY contagion + infection tests (R-INF-3/4, R-CONT-1/2/3).
--
-- Unlike contagion_spec / contagion_e2e_spec, this file does NOT `require` the
-- zomtorio lib modules. Doing so would load a SECOND private copy of each module
-- into this (test) mod's Lua VM with its own `storage`, so calling infect()/
-- on_tick() there would prove nothing about the live mod. Instead these tests:
--
--   * trigger infection only through REAL engine events — an enemy-force
--     LuaEntity.damage() raises on_entity_damaged in the live mod, which infects;
--   * build a REAL powered factory and let items actually move, so the live mod's
--     own per-tick sweep sees genuine inserter swings and belt contents;
--   * advance real ticks and let the LIVE mod's on_tick run (no manual on_tick,
--     no faked held_stack, no set_ticks_override on a private copy);
--   * observe only real effects — health loss, death — and the live mod's real
--     state via the "zomtorio-debug" remote interface.
--
-- This is the harness that would have caught the real-play breakage the faked
-- tests masked.

local T = require("harness.runner")

local DEBUG = "zomtorio-debug"
local function is_infected(e)       return remote.call(DEBUG, "is_infected", e) end
local function set_ticks(n)         return remote.call(DEBUG, "set_infection_ticks", n) end

local function enemy() return game.forces.enemy end

--- Deal a real enemy-force bite so the LIVE mod infects `e` exactly as a biter
--- attack would. Returns nothing; assert via is_infected afterwards.
local function bite(e)
  e.damage(5, enemy(), "physical")
end

-- =====================================================================
-- A. DoT actually applies and kills, in the live mod (R-INF-3/4).
--    No power, no movers — just: bite a building, let the live on_tick run,
--    watch it lose health and die. (The faked tests masked this by overriding
--    the DoT to ~zero on a private module copy.)
-- =====================================================================
T.test("REAL: an infected building loses health over time and dies", {
  function(t)
    local o = t.test_origin
    t.world.clear(t.surface, o, 12)
    set_ticks(120)  -- fast death (~2s) so the test is quick but real
    t.chest = t.world.place(t.surface, "steel-chest", o)
    t.max = t.chest.max_health
    bite(t.chest)
  end,
  -- Right after the bite the live mod must have infected it.
  { after = 3, fn = function(t)
    t.assert.is_true(is_infected(t.chest), "chest infected by a real enemy bite")
    t.assert.is_true(t.chest.health < t.max, "infect seed dropped health below max")
  end },
  -- Mid-way: health is measurably dropping (DoT is really being applied).
  { after = 40, fn = function(t)
    t.assert.is_true(t.chest.valid and t.chest.health < t.max * 0.8,
      "DoT is reducing health (got " ..
      tostring(t.chest.valid and t.chest.health or "dead") .. "/" .. tostring(t.max) .. ")")
  end },
  -- By well past the configured time-to-death it must be gone.
  { after = 120, fn = function(t)
    t.assert.is_true(not t.chest.valid, "infected building died from the DoT")
  end },
})

-- =====================================================================
-- B. Full powered chain, end to end, driven entirely by the live mod
--    (R-CONT-1/2). assembler1 --[ins1]--> belt1->belt2->belt3 --[ins2]--> a2.
-- =====================================================================
T.test("REAL: contagion spreads down a powered chain to the far assembler", {
  function(t)
    local o = t.test_origin
    t.world.clear(t.surface, o, 16)
    set_ticks(36000)  -- ~10 min: keep the whole chain alive while it propagates
    t.world.power_region(t.surface, { x = o.x + 2, y = o.y })

    -- a1 produces iron-gear-wheel from iron-plate so ins1 always has something to
    -- pick (real activity). Geometry/direction mirror contagion_e2e_spec, which
    -- verified these targets resolve in real Factorio.
    t.a1 = t.world.place(t.surface, "assembling-machine-1", { x = o.x - 2, y = o.y },
                         { recipe = "iron-gear-wheel" })
    t.world.insert(t.a1, "iron-plate", 200)
    t.ins1 = t.world.place(t.surface, "inserter", { x = o.x, y = o.y },
                           { direction = defines.direction.west })
    t.belts = t.world.belt_line(t.surface, { x = o.x + 1, y = o.y },
                                defines.direction.east, 3, "transport-belt")
    t.ins2 = t.world.place(t.surface, "inserter", { x = o.x + 4, y = o.y },
                           { direction = defines.direction.west })
    -- a2 takes iron-gear-wheel as an INPUT (automation-science-pack: copper +
    -- gears) so ins2 can really drop a gear into it (real activity at the tail).
    t.a2 = t.world.place(t.surface, "assembling-machine-1", { x = o.x + 6, y = o.y },
                         { recipe = "automation-science-pack" })
  end,

  -- Let power settle + inserters resolve their targets and start swinging.
  { after = 90, fn = function(t)
    -- Power sanity: ins1 must actually be powered & working, else the rest of the
    -- test is meaningless (this is the gap the old tests papered over).
    t.assert.is_true(t.ins1.energy and t.ins1.energy > 0,
      "inserter1 has electric power (energy=" .. tostring(t.ins1.energy) .. ")")
    t.assert.is_true(t.ins1.pickup_target == t.a1, "ins1 picks from a1")
    t.assert.is_true(t.ins1.drop_target == t.belts[1], "ins1 drops onto belt1")
    t.assert.is_true(t.ins2.drop_target == t.a2, "ins2 drops into a2")
    -- Kick off the chain: a real bite on the head.
    bite(t.a1)
    t.assert.is_true(is_infected(t.a1), "a1 infected by the bite")
  end },

  -- The live mover sweep should infect ins1 + belt1 once ins1 swings.
  { after = 180, fn = function(t)
    t.assert.is_true(is_infected(t.ins1), "ins1 infected (live mover sweep)")
    t.assert.is_true(is_infected(t.belts[1]), "belt1 infected (ins1 drop)")
  end },

  -- Belt travel-time spread carries it down the line.
  { after = 240, fn = function(t)
    t.assert.is_true(is_infected(t.belts[2]), "belt2 infected (belt spread)")
    t.assert.is_true(is_infected(t.belts[3]), "belt3 infected (belt spread)")
  end },

  -- Tail mover infects ins2 + a2: the whole chain has propagated, for real.
  { after = 240, fn = function(t)
    t.assert.is_true(is_infected(t.ins2), "ins2 infected (live mover sweep)")
    t.assert.is_true(is_infected(t.a2),
      "a2 infected END TO END through the live mod with real power + real flow")
  end },
})

-- =====================================================================
-- C. Negative: with no activity, nothing spreads (R-CONT-3). An infected source
--    whose inserter has NO power must not infect downstream; an infected belt
--    with NO items must not infect the next belt.
-- =====================================================================
T.test("REAL: an idle / unpowered section does not spread infection", {
  function(t)
    local o = t.test_origin
    t.world.clear(t.surface, o, 16)
    set_ticks(36000)  -- keep everything alive so we test spread, not death
    -- NOTE: deliberately NO power_region — the inserter can never swing.
    t.a1 = t.world.place(t.surface, "steel-chest", { x = o.x - 1, y = o.y })
    t.world.insert(t.a1, "iron-plate", 50)
    t.ins1 = t.world.place(t.surface, "inserter", { x = o.x, y = o.y },
                           { direction = defines.direction.west })
    t.belts = t.world.belt_line(t.surface, { x = o.x + 1, y = o.y },
                                defines.direction.east, 2, "transport-belt")
    -- An infected belt with no items on it (separate from the chain above).
    t.idle_belt = t.world.place(t.surface, "transport-belt", { x = o.x, y = o.y + 3 },
                                { direction = defines.direction.east })
    t.dn_belt = t.world.place(t.surface, "transport-belt", { x = o.x + 1, y = o.y + 3 },
                              { direction = defines.direction.east })
  end,

  { after = 30, fn = function(t)
    bite(t.a1)
    bite(t.idle_belt)
    t.assert.is_true(is_infected(t.a1), "source chest infected")
    t.assert.is_true(is_infected(t.idle_belt), "idle belt infected")
  end },

  -- Give it ample time; with no power and no belt items, nothing must spread.
  { after = 300, fn = function(t)
    t.assert.is_false(is_infected(t.ins1),
      "unpowered inserter must NOT get infected (no activity, R-CONT-3)")
    t.assert.is_false(is_infected(t.belts[1]),
      "downstream of an idle inserter must NOT get infected")
    t.assert.is_false(is_infected(t.dn_belt),
      "an itemless infected belt must NOT spread downstream (presence gate)")
  end },
})
