-- S10b — escalating swarm events (R-GEN-5) + night escalation (R-GEN-4).
--
-- The state machine lives in horde.on_tick, gated on horde_events_enabled,
-- night-bound, evolution-scaled. The headless benchmark has no players, so a
-- placed `character` is the spawn anchor (as in the night/horde tests). Settings
-- and per-surface evolution can't be written by the test mod, so the module
-- exposes override hooks (set_overrides / set_evolution_override) the tests use.
--
-- on_tick self-throttles to a multiple of its TICK_PERIOD; tests therefore pass a
-- synthetic, multiple-of-period `tick` and schedule next_event_tick relative to
-- that same value so the comparisons inside the machine are internally consistent.

local T = require("harness.runner")

local horde = require("__Zomtorio__.lib.horde")
local swarm = require("__Zomtorio__.lib.swarm")
local tiers = require("__Zomtorio__.lib.tiers")

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
  horde.reset_state()       -- map settings + event state + clears overrides
  swarm.reset_state()
  swarm.set_cap_override(nil)
end

local function tick_event(tick)
  horde.on_tick { tick = tick }
end

------------------------------------------------------ PURE: spawning-period scaling

T.test("R-GEN-5: spawning period scales ~10% night at evo 0 to a full night at evo 1", function(t)
  local n  = horde.NIGHT_TICKS
  local p0 = horde.spawning_period_ticks(0.0, 1.0)
  local p1 = horde.spawning_period_ticks(1.0, 1.0)

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
  local lo_evo = horde.event_interval_ticks(0.0, 1.0)
  local hi_evo = horde.event_interval_ticks(1.0, 1.0)
  t.assert.is_true(hi_evo < lo_evo,
    string.format("higher evolution => shorter interval (e0=%d e1=%d)", lo_evo, hi_evo))

  local f1 = horde.event_interval_ticks(0.3, 1.0)
  local f2 = horde.event_interval_ticks(0.3, 2.0)
  t.assert.is_true(f2 < f1,
    string.format("higher frequency => shorter interval (f1=%d f2=%d)", f1, f2))
end)

------------------------------------------------------ telegraph fires first

T.test("R-GEN-5: a swarm is telegraphed before it begins", {
  function(t)
    reset(t)
    set_noon(t.surface)                 -- daytime: cannot begin, only warn
    horde.set_overrides { enabled = true }
    horde.set_evolution_override(0.2)
    -- Schedule the event just inside the telegraph lead from our synthetic tick.
    horde.set_next_event_tick(TICK + 1000)
    tick_event(TICK)
  end,
  { after = 1, fn = function(t)
    local s = horde.get_state()
    t.assert.is_true(s.warned, "the event within the telegraph lead should be warned")
    t.assert.is_false(s.active, "warning alone must not start the event by day")
  end },
})

------------------------------------------------------ event is night-bound

T.test("R-GEN-5: the event only begins at night, not by day", {
  function(t)
    reset(t)
    set_noon(t.surface)
    horde.set_overrides { enabled = true }
    horde.set_evolution_override(0.5)
    horde.set_next_event_tick(TICK)     -- due now
    tick_event(TICK)
  end,
  { after = 1, fn = function(t)
    t.assert.is_false(horde.get_state().active, "due but daytime => not active")
    -- Now force night and tick again: it should begin.
    set_midnight(t.surface)
  end },
  { after = 5, fn = function(t)
    horde.set_next_event_tick(TICK)     -- still due (reset cleared nothing)
    tick_event(TICK)
  end },
  { after = 1, fn = function(t)
    t.assert.is_true(horde.get_state().active, "due AND night => active")
  end },
})

------------------------------------------------------ forced (debug) horde trigger

-- horde.force_event (the /zomtorio-horde command) starts a horde RIGHT NOW even in
-- daylight and even with the on/off setting disabled — and a daytime tick within
-- the forced window must not end it (a forced event bypasses the dawn end).
T.test("force_event starts a horde now and survives daylight (debug trigger)", function(t)
  reset(t)
  set_noon(t.surface)                       -- daytime: a scheduled event couldn't start
  horde.set_overrides { enabled = false }   -- and events are even disabled
  horde.set_evolution_override(0.5)

  horde.force_event(1)                       -- force a 1-minute horde
  local s = horde.get_state()
  t.assert.is_true(s.active, "forced horde is active immediately")
  t.assert.not_nil(s.forced_until, "forced window is set")

  -- A throttle-aligned daytime tick just inside the window must NOT end it.
  local fu = s.forced_until
  local tk = fu - (fu % 60) - 60
  horde.on_tick { tick = tk }
  t.assert.is_true(horde.get_state().active, "forced horde persists through daylight")
end)

------------------------------------------------------ horde targets the factory

-- DEFENDS the sandbox/no-player bug: the horde used to anchor on a player CHARACTER,
-- so with no player present `/zomtorio-horde` chose no origin and spawned NOTHING.
-- Now it targets the FACTORY (player buildings) — origin is ~10 chunks beyond the
-- factory edge and it spawns even with no character. (factory_override pins a
-- deterministic factory so the test doesn't depend on stray entities on the shared
-- surface; chunks at the far origin are force-generated so placement can succeed.)
T.test("a horde targets the factory and spawns with NO player present (sandbox)", {
  function(t)
    reset(t)
    horde.set_factory_override {
      center = { x = t.test_origin.x, y = t.test_origin.y },
      radius = 50,
      buildings = {
        { x = t.test_origin.x + 50, y = t.test_origin.y },
        { x = t.test_origin.x - 50, y = t.test_origin.y },
      },
    }
    horde.set_overrides { enabled = true }
    horde.set_evolution_override(0.3)
    swarm.set_cap_override(10000)          -- spawns become countable individuals
    t.before = swarm.active_count()
    horde.force_event(1)                   -- NO character placed anywhere
  end,
  { after = 1, fn = function(t)
    local st = horde.get_state()
    t.assert.not_nil(st.origin, "an origin was chosen from the factory (no player needed)")
    local c = st.factory_center
    local d = math.sqrt((st.origin.x - c.x) ^ 2 + (st.origin.y - c.y) ^ 2)
    -- origin sits radius (50) + 10 chunks (320) = ~370 from the factory centre.
    -- at_least(min, actual) asserts actual >= min; flip args for the upper bound.
    t.assert.at_least(369, d, "origin is >= ~radius+10 chunks from the factory centre")
    t.assert.at_least(d, 371, "origin is <= ~radius+10 chunks from the factory centre")

    -- Force-generate the far origin's chunks, then drive one burst and confirm it
    -- actually SPAWNED (the bug was: nothing spawned with no player).
    local o = st.origin
    t.surface.request_to_generate_chunks(o, 2)
    t.surface.force_generate_chunk_requests()
    local pe = st.period_end_tick
    local tk = pe - (pe % 60) - 60         -- a burst tick safely inside the window
    horde.on_tick { tick = tk }
    t.assert.is_true(swarm.active_count() > t.before,
      string.format("a horde spawns with no player (before=%d after=%d)",
        t.before, swarm.active_count()))
  end },
})

------------------------------------------------------ marches on the nearest edge

-- DEFENDS: the horde marches on the part of the factory CLOSEST to where it spawned
-- (its nearest edge), not the player and not an arbitrary point.
T.test("a horde marches on the factory building nearest its spawn point", {
  function(t)
    reset(t)
    horde.set_factory_override {
      center = { x = 0, y = 0 }, radius = 100,
      buildings = { { x = 100, y = 0 }, { x = -100, y = 0 } },
    }
    horde.set_overrides { enabled = true }
    horde.set_evolution_override(0.0)
    horde.force_event(1)
  end,
  { after = 1, fn = function(t)
    local st = horde.get_state()
    t.assert.not_nil(st.target, "a march target was chosen")
    local function d2(a, b) return (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 end
    local b1, b2 = { x = 100, y = 0 }, { x = -100, y = 0 }
    local nearest = (d2(st.origin, b1) <= d2(st.origin, b2)) and b1 or b2
    t.assert.equal(nearest.x, st.target.x, "target is the building nearest the spawn origin")
    t.assert.equal(nearest.y, st.target.y, "target is the building nearest the spawn origin")
  end },
})

------------------------------------------------------ approaches as a WALL

-- DEFENDS "a wall of zombies, not single file": a horde spawns across multiple
-- columns spread along a broad front (perpendicular to the approach), and the columns
-- aim at DIFFERENT factory points (parallel lanes) rather than one shared target that
-- would re-funnel them into single file. Angle + factory are pinned so the geometry
-- is deterministic; the columns are asserted via debug_wall_columns (no spawning).
T.test("a horde approaches as a wide WALL with spread columns and distinct targets", {
  function(t)
    reset(t)
    -- A wide base: two buildings far apart on the x axis. Pin the approach angle to
    -- pi/2 so the front runs along x (columns spread across the two buildings).
    horde.set_factory_override {
      center = { x = 0, y = 0 }, radius = 120,
      buildings = { { x = 120, y = 0 }, { x = -120, y = 0 } },
    }
    horde.set_overrides { enabled = true }
    horde.set_evolution_override(0.0)
    horde.set_angle_override(math.pi / 2)
    horde.force_event(1)
  end,
  { after = 1, fn = function(t)
    local cols = horde.debug_wall_columns(6000)
    t.assert.at_least(3, #cols, "the horde spreads across multiple columns (not single file)")
    local minx, maxx, miny, maxy = math.huge, -math.huge, math.huge, -math.huge
    for _, c in ipairs(cols) do
      minx = math.min(minx, c.pos.x); maxx = math.max(maxx, c.pos.x)
      miny = math.min(miny, c.pos.y); maxy = math.max(maxy, c.pos.y)
    end
    local span = math.sqrt((maxx - minx) ^ 2 + (maxy - miny) ^ 2)
    t.assert.at_least(100, span, "columns span a broad front (wall width)")
    -- columns must NOT all aim at one point (that funnels into single file)
    local targets = {}
    for _, c in ipairs(cols) do targets[c.target.x .. "," .. c.target.y] = true end
    local n = 0; for _ in pairs(targets) do n = n + 1 end
    t.assert.at_least(2, n, "columns target different factory points (parallel lanes)")
  end },
})

------------------------------------------------------ cohesive movement (unit groups)

-- DEFENDS "advance as a cohesive mass, not single-file chains": each column's members
-- are gathered into a UNIT GROUP and the GROUP is commanded (like a vanilla attack
-- wave), instead of each unit getting its own attack command and pathing the same
-- route independently (which queued them single-file). Asserts a spawned member is a
-- member of a unit group after a burst.
T.test("a horde commands its members as unit groups (cohesive wave, not single file)", {
  function(t)
    reset(t)
    horde.set_factory_override {
      center = { x = t.test_origin.x, y = t.test_origin.y },
      radius = 50,
      buildings = { { x = t.test_origin.x + 50, y = t.test_origin.y } },
    }
    horde.set_overrides { enabled = true }
    horde.set_evolution_override(0.3)
    swarm.set_cap_override(10000)   -- members are real individuals, easy to inspect
    horde.force_event(1)
  end,
  { after = 1, fn = function(t)
    local st = horde.get_state()
    local o = st.origin
    t.surface.request_to_generate_chunks(o, 2)
    t.surface.force_generate_chunk_requests()
    local pe = st.period_end_tick
    local tk = pe - (pe % 60) - 60        -- a burst tick inside the spawning window
    horde.on_tick { tick = tk }

    -- The burst must have gathered its spawned members into unit groups (not commanded
    -- them one-by-one). debug_grouped counts members successfully added to a group.
    t.assert.at_least(1, horde.debug_grouped(),
      "spawned horde members were added to unit groups (cohesive wave, not single file)")
  end },
})

------------------------------------------------------ warning: live population

-- DEFENDS the reported bug: the warning count must NOT drop while the horde merely
-- MOVES/DISPERSES (the old fixed-radius position scan decayed as the marching wall
-- spread past 64 tiles, despite nothing dying). The count now comes from the horde's
-- flagged MEMBERS (swarm.horde_population), so it is position-independent.
T.test("the warning count does NOT drop when the horde disperses (only deaths drop it)", function(t)
  reset(t)
  t.world.clear(t.surface, t.test_origin, 48)
  swarm.set_cap_override(0)                 -- fold the spawn into one cluster
  swarm.set_size_multiplier_override(1)
  horde.start_warning_at(t.test_origin, 100)
  -- 40 flagged horde members -> a pop-40 cluster
  swarm.spawn(t.surface, t.test_origin, 40, "small", "enemy", nil, nil, true)
  horde.update_warning_now()
  t.assert.equal(40, horde.get_state().warning.count, "count starts at the live population (40)")

  -- Move the cluster FAR (well beyond the old 64-tile scan radius). Count must hold.
  local cluster = t.surface.find_entities_filtered {
    name = tiers.swarm_name("biter", "small"), position = t.test_origin, radius = 32,
  }[1]
  t.assert.not_nil(cluster, "the horde cluster exists")
  cluster.teleport { x = t.test_origin.x + 96, y = t.test_origin.y + 96 }
  horde.update_warning_now()
  t.assert.equal(40, horde.get_state().warning.count,
    "dispersing/moving the horde does NOT drop the count")
  swarm.set_size_multiplier_override(nil)
end)

-- DEFENDS that the count DOES fall when the horde is actually killed, and the marker
-- RETIRES once it thins below 25 (so it sticks around for the whole assault, then
-- clears — stragglers can't keep it up forever).
T.test("the warning count drops on real kills and retires below 25", {
  function(t)
    reset(t)
    t.world.clear(t.surface, t.test_origin, 48)
    swarm.set_cap_override(0)
    swarm.set_size_multiplier_override(1)
    horde.start_warning_at(t.test_origin, 100)
    swarm.spawn(t.surface, t.test_origin, 40, "small", "enemy", nil, nil, true)
    horde.update_warning_now()
    t.assert.equal(40, horde.get_state().warning.count, "starts at 40")
  end,
  { after = 1, fn = function(t)
    -- Actually KILL ~20 of the cluster (an explosion multi-kill), dropping it below 25.
    local cluster = t.surface.find_entities_filtered {
      name = tiers.swarm_name("biter", "small"), position = t.test_origin, radius = 32,
    }[1]
    t.assert.not_nil(cluster, "cluster exists")
    local single = swarm.single_health("small")
    swarm.on_entity_damaged {
      entity = cluster, damage_type = { name = "explosion" },
      original_damage_amount = single * 20, final_damage_amount = single * 20,
    }
    horde.update_warning_now()
    t.assert.equal(nil, horde.get_state().warning,
      "the warning retires once the horde is killed below 25")
    swarm.set_size_multiplier_override(nil)
  end },
})

-- DEFENDS the night-horde undercount: night swaps clusters near a player to their
-- faster variant (destroy+recreate). Membership must carry across the swap, or the
-- warning count would drop at dusk/dawn though nothing died.
T.test("night-swapping a horde cluster preserves its warning membership", function(t)
  reset(t)
  t.world.clear(t.surface, t.test_origin, 48)
  swarm.set_cap_override(0)
  swarm.set_size_multiplier_override(1)
  horde.start_warning_at(t.test_origin, 100)
  swarm.spawn(t.surface, t.test_origin, 30, "small", "enemy", nil, nil, true)
  horde.update_warning_now()
  t.assert.equal(30, horde.get_state().warning.count, "starts at 30")

  local cluster = t.surface.find_entities_filtered {
    name = tiers.swarm_name("biter", "small"), position = t.test_origin, radius = 32,
  }[1]
  t.assert.not_nil(cluster, "day cluster exists")
  swarm.swap_cluster(cluster, tiers.swarm_both("biter", "small")[2])  -- -> night variant
  horde.update_warning_now()
  t.assert.equal(30, horde.get_state().warning.count,
    "membership carries across the night swap (count unchanged)")
  swarm.set_size_multiplier_override(nil)
end)

------------------------------------------------------ active event spawns via horde

T.test("R-GEN-5/6: an active swarm spawns zombies near a player via the unified spawner", {
  function(t)
    reset(t)
    t.world.clear(t.surface, t.test_origin, 64)
    set_midnight(t.surface)
    horde.set_overrides { enabled = true, intensity = 1.0 }
    horde.set_evolution_override(0.3)
    swarm.set_cap_override(10000)       -- pin so spawns become individuals (countable)
    t.char = t.world.place(t.surface, "character", t.test_origin, { force = "player" })
    -- Drive the event active, then tick on a burst boundary.
    horde.set_next_event_tick(TICK)
    tick_event(TICK)
    t.before = swarm.active_count()
  end,
  { after = 1, fn = function(t)
    t.assert.is_true(horde.get_state().active, "event should be active")
    -- A burst lands on the burst-period boundary; TICK is a multiple of it.
    tick_event(TICK)
  end },
  { after = 1, fn = function(t)
    t.assert.is_true(swarm.active_count() > t.before,
      string.format("active swarm should spawn zombies (before=%d after=%d)",
        t.before, swarm.active_count()))
  end },
})

------------------------------------------------------ disabled => no event

T.test("R-GEN-5: disabling swarm events suppresses them entirely", {
  function(t)
    reset(t)
    t.world.clear(t.surface, t.test_origin, 64)
    set_midnight(t.surface)
    horde.set_overrides { enabled = false }
    horde.set_evolution_override(0.5)
    swarm.set_cap_override(10000)
    t.char = t.world.place(t.surface, "character", t.test_origin, { force = "player" })
    horde.set_next_event_tick(TICK)
    t.before = swarm.active_count()
    tick_event(TICK)
  end,
  { after = 1, fn = function(t)
    t.assert.is_false(horde.get_state().active,
      "with events disabled the event must never become active")
  end },
})

------------------------------------------------------ R-GEN-4 night escalation

T.test("R-GEN-4: night escalation spawns at night (and not by day) without an event", {
  function(t)
    reset(t)
    t.world.clear(t.surface, t.test_origin, 64)
    horde.set_overrides { enabled = false, night_assault = 2.0 }  -- no swarm event
    horde.set_evolution_override(0.4)
    swarm.set_cap_override(10000)
    t.char = t.world.place(t.surface, "character", t.test_origin, { force = "player" })

    -- Day first: the trickle must not fire.
    set_noon(t.surface)
    t.day_before = swarm.active_count()
    -- NIGHT_BURST_PERIOD is 300; TICK is a multiple, so we're on a trickle boundary.
    tick_event(TICK)
    t.day_after = swarm.active_count()
  end,
  { after = 1, fn = function(t)
    t.assert.equal(t.day_before, t.day_after, "no night escalation by day")
    set_midnight(t.surface)
  end },
  { after = 5, fn = function(t)
    t.night_before = swarm.active_count()
    tick_event(TICK)
  end },
  { after = 1, fn = function(t)
    t.assert.is_true(swarm.active_count() > t.night_before,
      string.format("night escalation should spawn at night (before=%d after=%d)",
        t.night_before, swarm.active_count()))
  end },
})
