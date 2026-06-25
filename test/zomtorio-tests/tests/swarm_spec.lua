-- S10b — escalating swarm events (R-GEN-5) + night escalation (R-GEN-4).
--
-- The state machine lives in swarm.on_tick, gated on swarm_events_enabled,
-- night-bound, evolution-scaled. The headless benchmark has no players, so a
-- placed `character` is the spawn anchor (as in the night/horde tests). Settings
-- and per-surface evolution can't be written by the test mod, so the module
-- exposes override hooks (set_overrides / set_evolution_override) the tests use.
--
-- on_tick self-throttles to a multiple of its TICK_PERIOD; tests therefore pass a
-- synthetic, multiple-of-period `tick` and schedule next_event_tick relative to
-- that same value so the comparisons inside the machine are internally consistent.

local T = require("harness.runner")

local swarm = require("__zomtorio__.lib.swarm")
local horde = require("__zomtorio__.lib.horde")
local tiers = require("__zomtorio__.lib.tiers")

-- A tick that satisfies on_tick's internal throttle (multiple of its period).
local TICK = 6000

local function set_midnight(surface)
  surface.freeze_daytime = true
  surface.daytime = 0.5
end

local function set_noon(surface)
  surface.freeze_daytime = true
  surface.daytime = 0.0
end

--- Reset to a known baseline before each case: clean event state, no overrides,
--- and a clean horde slate so active_count deltas are unambiguous.
local function reset(t)
  swarm.reset_state()       -- map settings + event state + clears overrides
  horde.reset_state()
  horde.set_cap_override(nil)
end

local function tick_event(tick)
  swarm.on_tick { tick = tick }
end

------------------------------------------------------ PURE: spawning-period scaling

T.test("R-GEN-5: spawning period scales ~10% night at evo 0 to a full night at evo 1", function(t)
  local n  = swarm.NIGHT_TICKS
  local p0 = swarm.spawning_period_ticks(0.0, 1.0)
  local p1 = swarm.spawning_period_ticks(1.0, 1.0)

  -- ~10% of a night at evolution 0 (allow a tick of floor() slack each side).
  -- A.at_least(min, actual) asserts actual >= min.
  t.assert.at_least(math.floor(n * 0.10) - 1, p0, "evo0 period >= ~10% of a night")
  t.assert.at_least(p0, math.floor(n * 0.10) + 1, "evo0 period <= ~10% of a night")

  -- A full night at evolution 1.0 (clamped to at most one night).
  t.assert.equal(n, p1, "evo1 period is a full night")

  -- And it grows with evolution.
  t.assert.is_true(p1 > p0, string.format("period grows with evo (p0=%d p1=%d)", p0, p1))
end)

------------------------------------------------------ PURE: frequency scaling

T.test("R-GEN-5: event interval shrinks with evolution and with frequency", function(t)
  local lo_evo = swarm.event_interval_ticks(0.0, 1.0)
  local hi_evo = swarm.event_interval_ticks(1.0, 1.0)
  t.assert.is_true(hi_evo < lo_evo,
    string.format("higher evolution => shorter interval (e0=%d e1=%d)", lo_evo, hi_evo))

  local f1 = swarm.event_interval_ticks(0.3, 1.0)
  local f2 = swarm.event_interval_ticks(0.3, 2.0)
  t.assert.is_true(f2 < f1,
    string.format("higher frequency => shorter interval (f1=%d f2=%d)", f1, f2))
end)

------------------------------------------------------ telegraph fires first

T.test("R-GEN-5: a swarm is telegraphed before it begins", {
  function(t)
    reset(t)
    set_noon(t.surface)                 -- daytime: cannot begin, only warn
    swarm.set_overrides { enabled = true }
    swarm.set_evolution_override(0.2)
    -- Schedule the event just inside the telegraph lead from our synthetic tick.
    swarm.set_next_event_tick(TICK + 1000)
    tick_event(TICK)
  end,
  { after = 1, fn = function(t)
    local s = swarm.get_state()
    t.assert.is_true(s.warned, "the event within the telegraph lead should be warned")
    t.assert.is_false(s.active, "warning alone must not start the event by day")
  end },
})

------------------------------------------------------ event is night-bound

T.test("R-GEN-5: the event only begins at night, not by day", {
  function(t)
    reset(t)
    set_noon(t.surface)
    swarm.set_overrides { enabled = true }
    swarm.set_evolution_override(0.5)
    swarm.set_next_event_tick(TICK)     -- due now
    tick_event(TICK)
  end,
  { after = 1, fn = function(t)
    t.assert.is_false(swarm.get_state().active, "due but daytime => not active")
    -- Now force night and tick again: it should begin.
    set_midnight(t.surface)
  end },
  { after = 5, fn = function(t)
    swarm.set_next_event_tick(TICK)     -- still due (reset cleared nothing)
    tick_event(TICK)
  end },
  { after = 1, fn = function(t)
    t.assert.is_true(swarm.get_state().active, "due AND night => active")
  end },
})

------------------------------------------------------ active event spawns via horde

T.test("R-GEN-5/6: an active swarm spawns zombies near a player via the unified spawner", {
  function(t)
    reset(t)
    t.world.clear(t.surface, t.test_origin, 64)
    set_midnight(t.surface)
    swarm.set_overrides { enabled = true, intensity = 1.0 }
    swarm.set_evolution_override(0.3)
    horde.set_cap_override(10000)       -- pin so spawns become individuals (countable)
    t.char = t.world.place(t.surface, "character", t.test_origin, { force = "player" })
    -- Drive the event active, then tick on a burst boundary.
    swarm.set_next_event_tick(TICK)
    tick_event(TICK)
    t.before = horde.active_count()
  end,
  { after = 1, fn = function(t)
    t.assert.is_true(swarm.get_state().active, "event should be active")
    -- A burst lands on the burst-period boundary; TICK is a multiple of it.
    tick_event(TICK)
  end },
  { after = 1, fn = function(t)
    t.assert.is_true(horde.active_count() > t.before,
      string.format("active swarm should spawn zombies (before=%d after=%d)",
        t.before, horde.active_count()))
  end },
})

------------------------------------------------------ disabled => no event

T.test("R-GEN-5: disabling swarm events suppresses them entirely", {
  function(t)
    reset(t)
    t.world.clear(t.surface, t.test_origin, 64)
    set_midnight(t.surface)
    swarm.set_overrides { enabled = false }
    swarm.set_evolution_override(0.5)
    horde.set_cap_override(10000)
    t.char = t.world.place(t.surface, "character", t.test_origin, { force = "player" })
    swarm.set_next_event_tick(TICK)
    t.before = horde.active_count()
    tick_event(TICK)
  end,
  { after = 1, fn = function(t)
    t.assert.is_false(swarm.get_state().active,
      "with events disabled the event must never become active")
  end },
})

------------------------------------------------------ R-GEN-4 night escalation

T.test("R-GEN-4: night escalation spawns at night (and not by day) without an event", {
  function(t)
    reset(t)
    t.world.clear(t.surface, t.test_origin, 64)
    swarm.set_overrides { enabled = false, night_assault = 2.0 }  -- no swarm event
    swarm.set_evolution_override(0.4)
    horde.set_cap_override(10000)
    t.char = t.world.place(t.surface, "character", t.test_origin, { force = "player" })

    -- Day first: the trickle must not fire.
    set_noon(t.surface)
    t.day_before = horde.active_count()
    -- NIGHT_BURST_PERIOD is 300; TICK is a multiple, so we're on a trickle boundary.
    tick_event(TICK)
    t.day_after = horde.active_count()
  end,
  { after = 1, fn = function(t)
    t.assert.equal(t.day_before, t.day_after, "no night escalation by day")
    set_midnight(t.surface)
  end },
  { after = 5, fn = function(t)
    t.night_before = horde.active_count()
    tick_event(TICK)
  end },
  { after = 1, fn = function(t)
    t.assert.is_true(horde.active_count() > t.night_before,
      string.format("night escalation should spawn at night (before=%d after=%d)",
        t.night_before, horde.active_count()))
  end },
})
