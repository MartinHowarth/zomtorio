-- Minimal step-based test harness for headless Factorio (--benchmark) runs.
--
-- Factorio's Lua sandbox has NO coroutine library, so a test cannot "pause"
-- mid-function. Instead a test is a sequence of STEPS that run across ticks:
--
--   T.test("name", function(t) ... end)                  -- single step, tick 0
--   T.test("name", {
--     function(t) t.thing = build(t) end,                -- step 1, immediately
--     { after = 480, fn = function(t) assert_on(t.thing) end },  -- step 2, +480 ticks
--   })
--
-- `t` (the context) is shared across a test's steps, so steps communicate via
-- it (t.furnace, t.belts, ...). Assertions raise a Lua error; the scheduler
-- catches it (pcall) and records the test as failed.
--
-- Results are written to script-output/test-results.json and logged, with a
-- sentinel "ZOMTORIO-TESTS-DONE". The bash runner derives exit status from the
-- results file.

local world = require("harness.world")

local runner = {}

local tests = {}          -- { name=, steps={ {after=, fn=}, ... } }
local results = {}        -- { name=, status=, error= }
local state = {
  idx = 0, step = 0, resume_tick = 0,
  ctx = nil, failed = nil, started = false, finished = false, visual = false,
}
local SPEED = 60                 -- headless fast-forward (benchmark)
local INTER_TEST_VISUAL = 90     -- ticks between tests in visual mode, to watch

--- Register a test. `steps` is a function (single step) or an array whose
--- elements are functions or { after = ticks, fn = function }.
function runner.test(name, steps)
  if type(steps) == "function" then steps = { steps } end
  local norm = {}
  for _, s in ipairs(steps) do
    if type(s) == "function" then
      norm[#norm + 1] = { after = 0, fn = s }
    else
      norm[#norm + 1] = { after = s.after or 0, fn = s.fn }
    end
  end
  tests[#tests + 1] = { name = name, steps = norm }
end

------------------------------------------------------------------- assertions
local A = {}
runner.assert = A
local function fail(msg) error(msg, 3) end

function A.is_true(v, msg)  if not v then fail(msg or "expected truthy, got " .. tostring(v)) end end
function A.is_false(v, msg) if v then fail(msg or "expected falsy, got " .. tostring(v)) end end
function A.not_nil(v, msg)  if v == nil then fail(msg or "expected non-nil value") end end

function A.equal(expected, actual, msg)
  if expected ~= actual then
    fail((msg or "values differ") ..
      ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

function A.at_least(min, actual, msg)
  if not actual or actual < min then
    fail((msg or "value too low") ..
      ": expected >= " .. tostring(min) .. ", got " .. tostring(actual))
  end
end

------------------------------------------------------------------- reporting
local function record(name, status, err)
  results[#results + 1] = { name = name, status = status, error = err }
  if state.visual then
    game.print(string.format("[%s] %s%s", status:upper(), name,
      err and ("  --  " .. err) or ""))
  end
end

local function finish()
  state.finished = true
  local passed, failed = 0, 0
  for _, r in ipairs(results) do
    if r.status == "pass" then passed = passed + 1 else failed = failed + 1 end
    log(string.format("[%s] %s%s", r.status:upper(), r.name,
      r.error and ("  --  " .. r.error) or ""))
  end
  log(string.format("ZOMTORIO-TESTS: %d passed, %d failed, %d total",
    passed, failed, #results))

  local json = { '{"passed":' .. passed .. ',"failed":' .. failed ..
    ',"total":' .. #results .. ',"tests":[' }
  for i, r in ipairs(results) do
    local err = (r.error or ""):gsub('[\\"]', "\\%0"):gsub("\n", " ")
    json[#json + 1] = string.format('%s{"name":"%s","status":"%s","error":"%s"}',
      i > 1 and "," or "", r.name:gsub('"', '\\"'), r.status, err)
  end
  json[#json + 1] = "]}"
  helpers.write_file("test-results.json", table.concat(json), false)
  log("ZOMTORIO-TESTS-DONE")
end

------------------------------------------------------------------- scheduler
-- Reset the surface to a clean slate: remove EVERY enemy-force entity (units,
-- spawners, worms — not just units) and any orphan character a previous test left
-- behind. The mod cranks enemy generation, so leftovers would (a) attack the GUI
-- player and pause the run, (b) pollute find_entities_filtered, and (c) pile up
-- and slow the benchmark. The test map is generated with no natural enemy bases
-- (see run-tests.sh --map-gen-settings); this keeps it clean between tests.
local function clear_surface(surface)
  for _, e in pairs(surface.find_entities_filtered { force = "enemy" }) do
    if e.valid then e.destroy() end
  end
  for _, c in pairs(surface.find_entities_filtered { type = "character" }) do
    if c.valid and c.player == nil then c.destroy() end  -- keep player-controlled
  end
end

-- Visual mode has a real player the mod's enemies would otherwise kill (pausing
-- the run); keep connected players invulnerable for the duration of the tests.
local function protect_players()
  for _, p in pairs(game.connected_players) do
    if p.character and p.character.valid then p.character.destructible = false end
  end
end

local function start_test()
  state.idx = state.idx + 1
  local t = tests[state.idx]
  if t == nil then finish(); return false end
  state.step = 0
  state.failed = nil
  clear_surface(game.surfaces["nauvis"])
  protect_players()
  state.ctx = {
    assert = A,
    world = world,
    surface = game.surfaces["nauvis"],
    test_origin = { x = state.idx * 64, y = 0 },
  }
  local gap = state.visual and INTER_TEST_VISUAL or 0
  state.resume_tick = game.tick + gap + (t.steps[1] and t.steps[1].after or 0)
  if state.visual and game.players[1] then
    -- pan the camera to the test setup so it's actually on screen
    game.players[1].teleport(state.ctx.test_origin)
  end
  return true
end

local function tick()
  if state.finished then return end

  if not state.started then
    state.started = true
    state.visual = #game.connected_players > 0  -- GUI client => watchable, normal speed
    log("ZOMTORIO-TESTS-BOOT tick=" .. game.tick ..
      " helpers=" .. tostring(helpers ~= nil) .. " tests=" .. #tests ..
      " visual=" .. tostring(state.visual))
    game.speed = state.visual and 1 or SPEED
    -- Disable enemy expansion so the mod can't grow new bases mid-run, and clear
    -- any enemies the map/mod produced before the first test.
    game.map_settings.enemy_expansion.enabled = false
    clear_surface(game.surfaces["nauvis"])
    protect_players()
    if state.visual then game.print("Zomtorio test harness: running " .. #tests .. " tests...") end
  end

  if state.ctx == nil then
    if not start_test() then return end
  end

  if game.tick < state.resume_tick then return end

  local t = tests[state.idx]
  if state.step >= #t.steps then
    record(t.name, state.failed and "fail" or "pass", state.failed)
    state.ctx = nil
    return
  end

  state.step = state.step + 1
  local ok, err = pcall(t.steps[state.step].fn, state.ctx)
  if not ok and not state.failed then state.failed = tostring(err) end

  local nxt = t.steps[state.step + 1]
  state.resume_tick = game.tick + (nxt and nxt.after or 0)
end

--- Wire up the scheduler. Call once from control.lua after specs are required.
--- If an optional `_filter` module is present (written by run-tests.sh when the
--- TEST_FILTER env var is set), keep only tests whose name contains that
--- substring — so you can run a single test in isolation.
function runner.start()
  local ok, pattern = pcall(require, "_filter")
  if ok and type(pattern) == "string" and pattern ~= "" then
    local kept = {}
    for _, t in ipairs(tests) do
      if string.find(t.name, pattern, 1, true) then kept[#kept + 1] = t end
    end
    tests = kept
  end
  script.on_event(defines.events.on_tick, tick)
end

return runner
