-- S6 WHITE-BOX UNIT tests: the contagion spread ALGORITHM (R-CONT-1..7).
--
-- IMPORTANT — what these are and are NOT. `require("__zomtorio__.lib.contagion")`
-- loads a SEPARATE private copy of the module into THIS (test) mod's Lua VM with
-- its own `storage`; it is NOT the live mod's instance. So these tests drive
-- contagion.on_tick / on_built / on_removed by hand and fake mover activity
-- (held_stack.set_stack) / belt contents to verify the spread LOGIC deterministically
-- and fast: belt travel-time topology, the presence gate, the per-tick throttle,
-- conduit death. They prove the algorithm is correct in isolation.
--
-- They do NOT prove the live mod actually spreads in real play — faking activity
-- and calling on_tick manually sidesteps real power, real inserter swings, the live
-- per-tick sweep, and the real DoT. That integration is proven separately, against
-- the LIVE mod (real power, real item flow, real enemy bites, live on_tick, and a
-- negative idle/unpowered case), in contagion_real_spec.lua. Keep both: these for
-- fast algorithm coverage, that one for real-play truth.

local T         = require("harness.runner")
local contagion = require("__zomtorio__.lib.contagion")
local infection = require("__zomtorio__.lib.infection")

local function reset()
  infection.reset_state()
  infection.set_enabled_override(nil)
  infection.set_ticks_override(nil)
  contagion.reset_state()
  contagion.set_budget_override(nil)
  -- The on_infected belt listener is registered once at on_init; ensure it's
  -- present for tests that rely on belt seeding (idempotent).
  contagion.on_init()
end

local function tick_contagion()
  contagion.on_tick { tick = game.tick }
end

-- Make an inserter carry an item so its held_stack reads as valid_for_read.
local function arm_inserter(ins, item)
  local hs = ins.held_stack
  if hs then hs.set_stack { name = item or "iron-plate", count = 1 } end
  return hs and hs.valid_for_read or false
end

-- ---------------------------------------------------------- mover spreads (R-CONT-1)
T.test("an active mover spreads infection from an infected source to its dest", {
  function(t)
    reset()
    local o = t.test_origin
    t.world.clear(t.surface, o)
    -- source chest -> inserter -> dest chest, laid out so pickup/drop resolve.
    t.source = t.world.place(t.surface, "steel-chest", { x = o.x - 1, y = o.y })
    t.ins    = t.world.place(t.surface, "inserter", { x = o.x, y = o.y },
                             { direction = defines.direction.west })
    t.dest   = t.world.place(t.surface, "steel-chest", { x = o.x + 1, y = o.y })
    -- Stage items so the inserter actually picks up and swings (gives valid
    -- pickup/drop targets), then we also hand-arm it for determinism.
    t.world.insert(t.source, "iron-plate", 50)
    contagion.on_built { entity = t.ins }
    infection.infect(t.source)
    t.assert.is_true(infection.is_infected(t.source), "source infected at t0")
  end,
  { after = 60, fn = function(t)
    -- Let the inserter engage with the staged items, then force its hand full so
    -- "active" is unambiguous regardless of swing phase.
    arm_inserter(t.ins)
    tick_contagion()
    t.assert.is_true(infection.is_infected(t.ins), "active mover infects ITSELF (R-CONT-1)")
    t.assert.is_true(infection.is_infected(t.dest), "and its DESTINATION (R-CONT-1)")
  end },
})

-- ---------------------------------------------------------- idle mover (R-CONT-3)
T.test("an idle mover does not spread", {
  function(t)
    reset()
    local o = t.test_origin
    t.world.clear(t.surface, o)
    t.source = t.world.place(t.surface, "steel-chest", { x = o.x - 1, y = o.y })
    t.ins    = t.world.place(t.surface, "inserter", { x = o.x, y = o.y },
                             { direction = defines.direction.west })
    t.dest   = t.world.place(t.surface, "steel-chest", { x = o.x + 1, y = o.y })
    -- No items anywhere: the inserter hand stays empty -> not active.
    contagion.on_built { entity = t.ins }
    infection.infect(t.source)
  end,
  { after = 30, fn = function(t)
    -- Ensure the hand is genuinely empty (clear any stray pickup).
    local hs = t.ins.held_stack
    if hs and hs.valid_for_read then hs.clear() end
    tick_contagion()
    t.assert.is_false(infection.is_infected(t.dest),
      "idle mover (empty hand) does not spread (R-CONT-3)")
  end },
})

-- ---------------------------------------------------------- belt timer (R-CONT-2)
-- A belt line carrying items spreads downstream, but only AFTER its travel-time
-- delay: before the delay nothing happens; after it the next belt is infected.
T.test("a belt with items spreads downstream on a travel-time timer", {
  function(t)
    reset()
    local o = t.test_origin
    t.world.clear(t.surface, o)
    t.belts = t.world.belt_line(t.surface, { x = o.x, y = o.y },
                                defines.direction.east, 2, "transport-belt")
    -- Infect belt1 -> the contagion listener seeds the frontier with a timer.
    infection.infect(t.belts[1])
    t.assert.is_true(infection.is_infected(t.belts[1]), "belt1 infected at t0")
    -- Put items on the first belt so it is presence-gated OPEN.
    t.world.belt_insert(t.belts[1], "iron-plate", 1)
    t.world.belt_insert(t.belts[1], "iron-plate", 2)
    -- Immediately (before the travel delay) it must NOT have spread.
    tick_contagion()
    t.assert.is_false(infection.is_infected(t.belts[2]),
      "downstream belt not yet infected before the travel delay (R-CONT-2)")
  end,
  { after = 30, fn = function(t)
    -- Ensure belt1 still carries items at the moment of the sweep — the staged
    -- ones may have advanced onto belt2 during the wait, so re-stage if needed.
    -- belt_count returns a NUMBER; 0 is truthy in Lua, so compare explicitly.
    if t.world.belt_count(t.belts[1], "iron-plate") == 0 then
      t.world.belt_insert(t.belts[1], "iron-plate", 1)
      t.world.belt_insert(t.belts[1], "iron-plate", 2)
    end
    tick_contagion()
    t.assert.is_true(infection.is_infected(t.belts[2]),
      "downstream belt infected after the travel delay (R-CONT-2)")
  end },
})

-- ---------------------------------------------------------- empty belt (R-CONT-2 gate)
T.test("an empty belt does not spread (presence gate)", {
  function(t)
    reset()
    local o = t.test_origin
    t.world.clear(t.surface, o)
    t.belts = t.world.belt_line(t.surface, { x = o.x, y = o.y },
                                defines.direction.east, 2, "transport-belt")
    -- NO items on the belt.
    infection.infect(t.belts[1])
  end,
  { after = 40, fn = function(t)
    -- Past any plausible travel delay: an empty belt must still not spread.
    tick_contagion()
    tick_contagion()
    t.assert.is_false(infection.is_infected(t.belts[2]),
      "empty belt does not spread downstream (R-CONT-2 presence gate)")
  end },
})

-- ---------------------------------------------------------- throttle (R-CONT-7)
-- Register many eligible movers, set a small budget, run ONE tick: only ~budget
-- movers can act, so NOT all destinations get infected in a single tick. This
-- proves per-tick work is bounded regardless of registry size.
T.test("the per-tick budget bounds how much spread happens in one tick", {
  function(t)
    reset()
    local o = t.test_origin
    t.world.clear(t.surface, o, 40)
    contagion.set_budget_override(5)  -- tiny budget
    t.n = 50
    t.dests = {}
    for i = 1, t.n do
      local y = o.y + i
      local src = t.world.place(t.surface, "steel-chest", { x = o.x - 1, y = y })
      local ins = t.world.place(t.surface, "inserter", { x = o.x, y = y },
                                { direction = defines.direction.west })
      local dst = t.world.place(t.surface, "steel-chest", { x = o.x + 1, y = y })
      contagion.on_built { entity = ins }
      infection.infect(src)             -- every source infected -> all eligible
      arm_inserter(ins)                 -- every inserter active
      t.dests[i] = dst
    end
  end,
  { after = 5, fn = function(t)
    -- Re-arm every hand (a swing may have completed during the wait) so all
    -- movers are unambiguously active, then run ONE tick.
    for _, d in ipairs(t.dests) do
      -- find the inserter to the left of each dest and arm it
      local ins = t.surface.find_entities_filtered {
        position = { x = d.position.x - 1, y = d.position.y }, type = "inserter",
      }[1]
      if ins then arm_inserter(ins) end
    end
    tick_contagion()
    local infected = 0
    for _, d in ipairs(t.dests) do
      if infection.is_infected(d) then infected = infected + 1 end
    end
    t.assert.is_true(infected < t.n,
      "with a budget of 5, far fewer than " .. t.n ..
      " dests infected in one tick (got " .. infected .. ") (R-CONT-7)")
  end },
})

-- R-CONT-5: conduits (belts/pipes/inserters) are infectable like any building —
-- they take the DoT, die, and spawn a (small) number of zombies on death. The DoT
-- is dealt on the enemy force, so the real on_entity_died routes through the main
-- mod's spawning; we assert zombies appear in the shared world near the dead belt.
T.test("an infected conduit dies and spawns zombies (R-CONT-5)", {
  function(t)
    reset()
    infection.set_ticks_override(60)
    local o = t.test_origin
    t.world.clear(t.surface, o)
    t.belt = t.world.place(t.surface, "transport-belt", o)
    t.pos = t.belt.position
    infection.infect(t.belt)
    t.assert.is_true(infection.is_infected(t.belt), "belt is infectable like any building")
  end,
  { after = 70, fn = function(t)
    infection.on_tick { tick = game.tick }
    t.assert.is_false(t.belt.valid, "the conduit died from the infection DoT")
    local zombies = t.surface.find_entities_filtered {
      type = "unit", force = "enemy", position = t.pos, radius = 24,
    }
    t.assert.at_least(1, #zombies, "a dead conduit spawns a (small) number of zombies")
  end },
})

-- Regression (crash "invalid key to 'next'"): the round-robin cursor is saved
-- across ticks, but an entry it points at can be removed between ticks via
-- on_removed (a belt/inserter that DIED from the DoT — common once contagion is
-- killing conduits). next(table, <removed key>) then raises. Both the belt frontier
-- and the mover registry guard against a stale cursor; this exercises the belt one.
T.test("a belt frontier cursor pointing at an absent key doesn't crash", {
  function(t)
    reset()
    local o = t.test_origin
    t.world.clear(t.surface, o)
    -- A NON-EMPTY frontier (the crash is next(non-empty-table, <absent key>)).
    for i = 0, 3 do
      local b = t.world.place(t.surface, "transport-belt", { x = o.x + i, y = o.y })
      infection.infect(b)
    end
    tick_contagion()
    -- Reproduce the real hazard deterministically: in live play the cursor's belt
    -- dies (on_removed nils it), and a later frontier insertion rehashes the table,
    -- discarding the dead node — so next() is handed a key GENUINELY ABSENT from a
    -- non-empty table and raises "invalid key to 'next'". A chest's unit_number is
    -- never a belt-frontier key, so it stands in for that absent key exactly. (The
    -- test-mod's contagion shares this mod's storage, so we can set the cursor.)
    local chest = t.world.place(t.surface, "steel-chest", { x = o.x, y = o.y + 3 })
    storage.zomtorio.contagion.belt_cursor = chest.unit_number
  end,
  { after = 1, fn = function(t)
    -- Pre-fix this threw "invalid key to 'next'"; the cursor guard must absorb it.
    local ok, err = pcall(tick_contagion)
    t.assert.is_true(ok, "sweep must survive an absent cursor key (got: " .. tostring(err) .. ")")
  end },
})
