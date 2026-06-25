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
local function set_immunity(n)      return remote.call(DEBUG, "set_immunity_ticks", n) end

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

-- =====================================================================
-- D. Long chain: infection must propagate ALL the way down, not just one hop
--    (catches the "worked once but stopped" report). 6 belts fed by a powered
--    inserter from an infected chest; the tail belt must end up infected.
-- =====================================================================
T.test("REAL: contagion propagates down a long (6-belt) chain to the end", {
  function(t)
    local o = t.test_origin
    t.world.clear(t.surface, o, 18)
    set_ticks(36000)  -- keep everything alive while it propagates
    t.world.power_region(t.surface, { x = o.x + 3, y = o.y })
    t.chest = t.world.place(t.surface, "steel-chest", { x = o.x - 1, y = o.y })
    t.world.insert(t.chest, "iron-plate", 500)
    t.ins = t.world.place(t.surface, "inserter", { x = o.x, y = o.y },
                          { direction = defines.direction.west })
    t.belts = t.world.belt_line(t.surface, { x = o.x + 1, y = o.y },
                                defines.direction.east, 6, "transport-belt")
  end,
  { after = 90, fn = function(t)
    t.assert.is_true(t.ins.energy and t.ins.energy > 0, "inserter powered")
    bite(t.chest)
    t.assert.is_true(is_infected(t.chest), "chest infected by bite")
  end },
  -- Each yellow-belt hop is ~16 ticks; 6 belts + the mover step settle well
  -- inside this window.
  { after = 600, fn = function(t)
    t.assert.is_true(is_infected(t.belts[1]), "belt1 infected (head)")
    t.assert.is_true(is_infected(t.belts[3]), "belt3 infected (mid chain)")
    t.assert.is_true(is_infected(t.belts[6]),
      "belt6 infected — infection reached the END of the chain")
  end },
})

-- =====================================================================
-- E. A belt built downstream AFTER the upstream belt was already infected must
--    still get infected (R-CONT-4: a belt is a persistent source until cured/
--    dead, not a one-shot spreader). This is the "didn't continue / didn't work
--    a second time" case: extend an infected line and the extension must catch.
-- =====================================================================
T.test("REAL: a belt added downstream after infection still gets infected", {
  function(t)
    local o = t.test_origin
    t.world.clear(t.surface, o, 16)
    set_ticks(36000)
    t.world.power_region(t.surface, { x = o.x + 2, y = o.y })
    t.chest = t.world.place(t.surface, "steel-chest", { x = o.x - 1, y = o.y })
    t.world.insert(t.chest, "iron-plate", 500)
    t.ins = t.world.place(t.surface, "inserter", { x = o.x, y = o.y },
                          { direction = defines.direction.west })
    -- Start with a SHORT line (just belt1).
    t.belts = t.world.belt_line(t.surface, { x = o.x + 1, y = o.y },
                                defines.direction.east, 1, "transport-belt")
  end,
  { after = 90, fn = function(t)
    bite(t.chest)
  end },
  -- belt1 is infected and has items but (so far) no downstream neighbour.
  { after = 240, fn = function(t)
    t.assert.is_true(is_infected(t.belts[1]), "belt1 infected before extension")
    -- NOW extend the line: build belt2 downstream of belt1.
    t.belt2 = t.world.place(t.surface, "transport-belt", { x = t.belts[1].position.x + 1,
                            y = t.belts[1].position.y }, { direction = defines.direction.east })
  end },
  -- The already-infected belt1 must spread onto the newly-built belt2.
  { after = 240, fn = function(t)
    t.assert.is_true(is_infected(t.belt2),
      "belt built downstream AFTER infection got infected (R-CONT-4 persistent source)")
  end },
})

-- =====================================================================
-- F. Pipes spread infection through the fluid network, in ALL directions, while
--    they hold fluid (presence-gated) — the fluid analogue of belt spread.
-- =====================================================================
T.test("REAL: an infected pipe holding fluid spreads to connected pipes", {
  function(t)
    local o = t.test_origin
    t.world.clear(t.surface, o, 12)
    set_ticks(36000)  -- keep the segment alive while it propagates
    t.pipes = {}
    for i = 0, 2 do
      t.pipes[i + 1] = t.world.place(t.surface, "pipe", { x = o.x + i, y = o.y })
    end
    -- Fill the (now connected) segment so the presence gate is open.
    for _, p in ipairs(t.pipes) do p.insert_fluid { name = "water", amount = 100 } end
    bite(t.pipes[1])
  end,
  { after = 3, fn = function(t)
    t.assert.is_true(is_infected(t.pipes[1]), "pipe1 infected by the bite")
  end },
  -- PIPE_DELAY is ~15 ticks/hop; two hops + sweep cadence settle well inside this.
  { after = 150, fn = function(t)
    t.assert.is_true(is_infected(t.pipes[2]), "pipe2 infected (fluid spread)")
    t.assert.is_true(is_infected(t.pipes[3]),
      "pipe3 infected (fluid spread reached the far end, all directions)")
  end },
})

-- =====================================================================
-- G. Negative: an infected pipe with NO fluid must not spread (presence gate).
-- =====================================================================
T.test("REAL: an empty (fluidless) infected pipe does not spread", {
  function(t)
    local o = t.test_origin
    t.world.clear(t.surface, o, 12)
    set_ticks(36000)
    t.p1 = t.world.place(t.surface, "pipe", { x = o.x, y = o.y })
    t.p2 = t.world.place(t.surface, "pipe", { x = o.x + 1, y = o.y })  -- connected, empty
    bite(t.p1)
  end,
  { after = 3, fn = function(t)
    t.assert.is_true(is_infected(t.p1), "empty pipe infected by the bite")
  end },
  { after = 200, fn = function(t)
    t.assert.is_false(is_infected(t.p2),
      "an empty (fluidless) infected pipe must NOT spread to its neighbour")
  end },
})

-- =====================================================================
-- H. Storage tanks propagate too (R: tanks/pumps spread). A fluid-filled tank,
--    once infected, must spread to the pipes connected to it — proving the
--    get_fluid_box_neighbours path works for multi-tile conduits, not just pipes.
-- =====================================================================
T.test("REAL: an infected fluid-filled storage tank spreads to connected pipes", {
  function(t)
    local o = t.test_origin
    t.world.clear(t.surface, o, 14)
    set_ticks(36000)
    t.tank = t.world.place(t.surface, "storage-tank", o)  -- 3x3 centred at o
    -- Ring the tank with pipes so at least one sits on a real fluid connection point
    -- (we don't hard-code the tank's exact connection offsets).
    t.pipes = {}
    local ring = { { 0, -2 }, { 2, 0 }, { 0, 2 }, { -2, 0 },
                   { -1, -2 }, { 1, -2 }, { -1, 2 }, { 1, 2 },
                   { -2, -1 }, { -2, 1 }, { 2, -1 }, { 2, 1 } }
    for _, d in ipairs(ring) do
      local p = t.world.place(t.surface, "pipe", { x = o.x + d[1], y = o.y + d[2] })
      if p then t.pipes[#t.pipes + 1] = p end
    end
    t.tank.insert_fluid { name = "water", amount = 2000 }
    bite(t.tank)
  end,
  { after = 3, fn = function(t)
    t.assert.is_true(is_infected(t.tank), "tank infected by the bite")
  end },
  { after = 150, fn = function(t)
    local any = false
    for _, p in ipairs(t.pipes) do
      if p.valid and is_infected(p) then any = true; break end
    end
    t.assert.is_true(any, "an infected fluid-filled tank spread to a connected pipe")
  end },
})

-- =====================================================================
-- I. A fluid-emitting MACHINE (not a pipe/tank/pump) spreads to attached pipes —
--    the refinery case. A boiler always has fluidboxes; fill it, infect it, and a
--    connected pipe must get infected (proves has_fluidbox catches machines too).
-- =====================================================================
T.test("REAL: an infected fluid machine (boiler) spreads to attached pipes", {
  function(t)
    local o = t.test_origin
    t.world.clear(t.surface, o, 14)
    set_ticks(36000)
    t.boiler = t.world.place(t.surface, "boiler", o)
    t.pipes = {}
    for dx = -3, 3 do
      for dy = -3, 3 do
        if math.abs(dx) >= 2 or math.abs(dy) >= 2 then  -- ring outside the footprint
          local p = t.world.place(t.surface, "pipe", { x = o.x + dx, y = o.y + dy })
          if p then t.pipes[#t.pipes + 1] = p end
        end
      end
    end
    t.boiler.insert_fluid { name = "water", amount = 200 }
    bite(t.boiler)
  end,
  { after = 3, fn = function(t)
    t.assert.is_true(is_infected(t.boiler), "boiler infected by the bite")
  end },
  { after = 150, fn = function(t)
    local any = false
    for _, p in ipairs(t.pipes) do
      if p.valid and is_infected(p) then any = true; break end
    end
    t.assert.is_true(any, "an infected fluid-holding machine spread to a connected pipe")
  end },
})

-- =====================================================================
-- J. Post-repair immunity (R-INF-5 follow-up): a just-cured entity can't be
--    re-infected during the immunity window, so a cure sticks long enough to clear
--    a region; after the window it's re-infectable again.
-- =====================================================================
T.test("REAL: a repaired entity is briefly immune to re-infection, then re-infectable", {
  function(t)
    local o = t.test_origin
    t.world.clear(t.surface, o, 10)
    set_ticks(36000)        -- slow DoT: we control the cure ourselves
    set_immunity(180)       -- 3s immunity window
    t.chest = t.world.place(t.surface, "steel-chest", o)
    t.max = t.chest.max_health
    bite(t.chest)
  end,
  { after = 3, fn = function(t)
    t.assert.is_true(is_infected(t.chest), "infected by the bite")
    -- "Repair" to full; the live DoT sweep observes the cure on its next visit
    -- (round-robin, up to ~PROCESS_PERIOD ticks away with other infected present).
    t.chest.health = t.max
  end },
  { after = 60, fn = function(t)
    t.assert.is_false(is_infected(t.chest), "fully repaired -> cured")
    -- Immediately bite again: must be blocked by the immunity window.
    bite(t.chest)
  end },
  { after = 10, fn = function(t)
    t.assert.is_false(is_infected(t.chest),
      "a just-repaired entity must resist re-infection during the immunity window")
  end },
  -- After the window expires, it can be infected again.
  { after = 200, fn = function(t)
    bite(t.chest)
  end },
  { after = 5, fn = function(t)
    t.assert.is_true(is_infected(t.chest),
      "after the immunity window expires, the entity is re-infectable")
  end },
})

-- =====================================================================
-- K. Directional fluid spread: an infected machine spreads DOWNSTREAM (to its
--    output pipes) but NOT UPSTREAM (back into its input/supply pipes). Uses an oil
--    refinery, which has clearly directional input (crude) and output (petroleum)
--    fluidbox connections.
-- =====================================================================
T.test("REAL: an infected machine spreads downstream but not into its input pipe", {
  function(t)
    local o = t.test_origin
    t.world.clear(t.surface, o, 18)
    set_ticks(36000)
    t.ref = t.world.place(t.surface, "oil-refinery", o, { recipe = "basic-oil-processing" })
    -- Place a pipe at every input- and output-connection point so we can check both
    -- directions. target_position is the tile a connecting pipe sits on.
    t.in_pipes, t.out_pipes = {}, {}
    for i = 1, 8 do
      local ok, conns = pcall(t.ref.get_fluid_box_pipe_connections, i)
      if not ok then break end
      for _, c in pairs(conns) do
        local tp = c.target_position
        if tp then
          local p = t.world.place(t.surface, "pipe", tp)
          if p then
            if c.flow_direction == "input" then t.in_pipes[#t.in_pipes + 1] = p
            elseif c.flow_direction == "output" then t.out_pipes[#t.out_pipes + 1] = p end
          end
        end
      end
    end
    t.ref.insert_fluid { name = "crude-oil", amount = 100 }  -- gives the refinery fluid
    bite(t.ref)
  end,
  { after = 3, fn = function(t)
    t.assert.at_least(1, #t.in_pipes, "placed at least one input-side pipe")
    t.assert.at_least(1, #t.out_pipes, "placed at least one output-side pipe")
    t.assert.is_true(is_infected(t.ref), "refinery infected by the bite")
  end },
  { after = 150, fn = function(t)
    local out_hit = false
    for _, p in ipairs(t.out_pipes) do if p.valid and is_infected(p) then out_hit = true end end
    t.assert.is_true(out_hit, "infection flowed DOWNSTREAM to an output pipe")
    for _, p in ipairs(t.in_pipes) do
      t.assert.is_false(p.valid and is_infected(p),
        "infection must NOT flow upstream into the refinery's input pipe")
    end
  end },
})

-- =====================================================================
-- L. An infected pump infects the fluid wagon beside it. The pump<->wagon transfer
--    isn't a fluidbox connection (the wagon shows in no fluid API), so we detect it
--    by proximity — which doesn't need a real train connection, so it's testable here.
-- =====================================================================
T.test("REAL: an infected pump infects an adjacent fluid wagon", {
  function(t)
    local o = t.test_origin
    t.world.clear(t.surface, o, 16)
    set_ticks(36000)
    for x = o.x - 6, o.x + 6, 2 do
      t.surface.create_entity { name = "straight-rail", position = { x = x, y = o.y },
        direction = defines.direction.east, force = "player" }
    end
    t.wagon = t.surface.create_entity { name = "fluid-wagon", position = { x = o.x, y = o.y },
      direction = defines.direction.east, force = "player" }
    local wp = t.wagon.position
    -- A pump within PUMP_WAGON_RADIUS of the wagon, holding fluid (so it spreads).
    t.pump = t.world.place(t.surface, "pump", { x = wp.x, y = wp.y + 2 })
    if t.pump then t.pump.insert_fluid { name = "water", amount = 100 }; bite(t.pump) end
  end,
  { after = 3, fn = function(t)
    t.assert.not_nil(t.pump, "pump placed near the wagon")
    t.assert.is_true(is_infected(t.pump), "pump infected by the bite")
  end },
  { after = 150, fn = function(t)
    t.assert.is_true(t.wagon.valid and is_infected(t.wagon),
      "an infected pump infected the fluid wagon beside it")
  end },
})
