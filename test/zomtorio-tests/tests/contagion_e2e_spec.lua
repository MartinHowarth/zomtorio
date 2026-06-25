-- S6 end-to-end: the WHOLE downstream contagion chain in one test (R-CONT-1,2,3).
--
-- assembler1 --[inserter1]--> belt1 -> belt2 -> belt3 --[inserter2]--> assembler2
--
-- Infecting assembler1 must, link by link, end up infecting assembler2:
--   * mover step  : active inserter1 (source = infected assembler1) infects itself
--                   + its drop_target belt1 (R-CONT-1).
--   * belt steps  : belt1 (has items) spreads to belt2 on its travel-time timer,
--                   belt2 -> belt3 likewise (R-CONT-2). ~16 ticks per hop @ yellow.
--   * mover step  : active inserter2 (source = infected belt3) infects itself
--                   + its drop_target assembler2.
--
-- Intermediate assertions localise any break in the chain; the FINAL assertion is
-- that assembler2 is infected. We pin a huge time-to-death so the DoT can't kill a
-- chain entity before the chain completes (we want them alive AND infected).
--
-- Geometry note: an inserter's pickup_target / drop_target are computed lazily and
-- only resolve after the inserter has updated for a few ticks AND its source has an
-- accessible inventory — so the assemblers get a recipe (an output slot for the
-- inserter to target) and we verify the geometry only after a short wait, never at
-- t0 (where both targets read nil).

local T         = require("harness.runner")
local contagion = require("__zomtorio__.lib.contagion")
local infection = require("__zomtorio__.lib.infection")

local function reset()
  infection.reset_state()
  infection.set_enabled_override(nil)
  infection.set_ticks_override(nil)
  contagion.reset_state()
  contagion.set_budget_override(nil)
  contagion.on_init()  -- (re)register the belt-frontier listener
end

local function tick_contagion()
  contagion.on_tick { tick = game.tick }
end

local function arm_inserter(ins, item)
  local hs = ins.held_stack
  if hs then hs.set_stack { name = item or "iron-plate", count = 1 } end
  return hs and hs.valid_for_read or false
end

-- Keep all three belts carrying items so the presence-gate stays OPEN across the
-- whole run (items advance/leave during the multi-tick waits, so top up).
local function load_belts(belts)
  for _, b in ipairs(belts) do
    if b.valid then
      if b.get_transport_line(1).get_item_count("iron-plate") == 0 then
        b.get_transport_line(1).insert_at_back { name = "iron-plate" }
      end
      if b.get_transport_line(2).get_item_count("iron-plate") == 0 then
        b.get_transport_line(2).insert_at_back { name = "iron-plate" }
      end
    end
  end
end

T.test("infection spreads end to end: assembler -> inserter -> 3 belts -> inserter -> assembler", {
  -- step 1 (t0): build everything. Targets won't have resolved yet, so the
  -- geometry assertions wait for step 2.
  function(t)
    reset()
    infection.set_ticks_override(100000)  -- keep the chain alive, not killed by DoT
    local o = t.test_origin
    t.world.clear(t.surface, o, 40)

    -- assembler1 (3x3) centred at o.x-2 => spans o.x-3 .. o.x-1; its EAST edge
    -- tile is o.x-1, the inserter1 pickup tile. A recipe gives it an output slot
    -- the inserter can target.
    t.a1 = t.world.place(t.surface, "assembling-machine-1", { x = o.x - 2, y = o.y })
    t.a1.set_recipe("iron-gear-wheel")
    -- inserter1: a vanilla inserter reaches one tile. direction WEST => it picks
    -- from the tile to its WEST (o.x-1, the assembler edge) and drops to the tile
    -- to its EAST (o.x+1, belt1).
    t.ins1 = t.world.place(t.surface, "inserter", { x = o.x, y = o.y },
                           { direction = defines.direction.west })
    -- three belts in a straight eastward line at o.x+1, o.x+2, o.x+3.
    t.belts = t.world.belt_line(t.surface, { x = o.x + 1, y = o.y },
                                defines.direction.east, 3, "transport-belt")
    -- inserter2 at o.x+4, direction WEST => picks from o.x+3 (belt3), drops to
    -- o.x+5 (assembler2 west edge).
    t.ins2 = t.world.place(t.surface, "inserter", { x = o.x + 4, y = o.y },
                           { direction = defines.direction.west })
    -- assembler2 centred at o.x+6 => spans o.x+5 .. o.x+7; west edge tile o.x+5.
    t.a2 = t.world.place(t.surface, "assembling-machine-1", { x = o.x + 6, y = o.y })
    t.a2.set_recipe("iron-gear-wheel")

    contagion.on_built { entity = t.ins1 }
    contagion.on_built { entity = t.ins2 }
  end,

  -- step 2 (+30): targets have resolved — verify the full geometry, then infect
  -- the head and run the first mover step (inserter1: infected source -> belt1).
  { after = 30, fn = function(t)
    -- ---- geometry must hold or the chain is meaningless -----------------
    t.assert.is_true(t.ins1.pickup_target == t.a1,
      "inserter1 picks from assembler1 (got " .. tostring(t.ins1.pickup_target and t.ins1.pickup_target.name) .. ")")
    t.assert.is_true(t.ins1.drop_target == t.belts[1],
      "inserter1 drops onto belt1 (got " .. tostring(t.ins1.drop_target and t.ins1.drop_target.name) .. ")")
    local out1 = t.belts[1].belt_neighbours.outputs
    t.assert.is_true(out1[1] == t.belts[2], "belt1 -> belt2 downstream")
    local out2 = t.belts[2].belt_neighbours.outputs
    t.assert.is_true(out2[1] == t.belts[3], "belt2 -> belt3 downstream")
    t.assert.is_true(t.ins2.pickup_target == t.belts[3],
      "inserter2 picks from belt3 (got " .. tostring(t.ins2.pickup_target and t.ins2.pickup_target.name) .. ")")
    t.assert.is_true(t.ins2.drop_target == t.a2,
      "inserter2 drops into assembler2 (got " .. tostring(t.ins2.drop_target and t.ins2.drop_target.name) .. ")")

    -- ---- arm + seed + register -----------------------------------------
    arm_inserter(t.ins1)
    arm_inserter(t.ins2)
    load_belts(t.belts)

    infection.infect(t.a1)
    t.assert.is_true(infection.is_infected(t.a1), "assembler1 infected at t0")

    -- mover step: inserter1's source (assembler1) is infected -> infect ins1 + belt1.
    tick_contagion()
    t.assert.is_true(infection.is_infected(t.ins1), "inserter1 infected (mover step)")
    t.assert.is_true(infection.is_infected(t.belts[1]), "belt1 infected (inserter1 drop)")
  end },

  -- step 3 (+20): belt1 -> belt2 (one travel-time hop, ~16 ticks @ yellow belt).
  { after = 20, fn = function(t)
    load_belts(t.belts)
    tick_contagion(); tick_contagion()
    t.assert.is_true(infection.is_infected(t.belts[2]), "belt2 infected (belt1 hop)")
  end },

  -- step 4 (+20): belt2 -> belt3 (next hop).
  { after = 20, fn = function(t)
    load_belts(t.belts)
    tick_contagion(); tick_contagion()
    t.assert.is_true(infection.is_infected(t.belts[3]), "belt3 infected (belt2 hop)")
  end },

  -- step 5 (+5): final mover step: inserter2's source (belt3) is infected ->
  -- infect ins2 + assembler2. Re-arm (a swing may have completed during the waits).
  { after = 5, fn = function(t)
    load_belts(t.belts)
    arm_inserter(t.ins2)
    tick_contagion(); tick_contagion()
    t.assert.is_true(infection.is_infected(t.ins2), "inserter2 infected (mover step)")
    -- THE end-to-end assertion: infection travelled the whole chain.
    t.assert.is_true(infection.is_infected(t.a2),
      "assembler2 infected END TO END (assembler1 -> ins1 -> 3 belts -> ins2 -> assembler2)")
  end },
})
