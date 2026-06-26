# Zomtorio tests

Headless, autonomous test harness for Zomtorio. Builds real factories in a real
(headless) Factorio simulation, advances ticks, and asserts on the result — no
GUI, no Steam, no clicking.

## Running

```bash
./test/run-tests.sh
```

Exit code is `0` if all tests pass, non-zero otherwise. Results are printed and
also written to `test/.factorio-data/script-output/test-results.json`.

### Requirements

- The Linux **headless** Factorio server, extracted at `~/factorio-headless/factorio`
  (override with `FACTORIO_SERVER=/path/to/factorio`). Download:
  `https://factorio.com/get-download/<version>/headless/linux64`.
- Runs natively in WSL — no Windows/Steam needed for tests.

### Env overrides

| Var | Default | Meaning |
|-----|---------|---------|
| `FACTORIO_SERVER` | `~/factorio-headless/factorio` | headless install dir |
| `ENABLE_SPACE_AGE` | `1` | Space Age DLC on by default (mod requires it); `0` forces base-only |
| `BENCH_TICKS` | `30000` | ticks to run; must exceed the sum of all test waits |
| `TEST_FILTER` | (unset) | run only tests whose name contains this substring |

Run a single test, e.g. the contagion chain:

```bash
TEST_FILTER="end to end" ./test/run-tests.sh
```

> Note: spoilage and quality are Space-Age feature flags (`ENABLE_SPACE_AGE=1`).
> Tests that rely on corpse-spoilage reanimation will need it on.

## How it works

- The server's heavily-modded user profile is never touched; tests run in an
  isolated, gitignored data dir (`test/.factorio-data/`) with its own mod list
  (base + harness, DLC off by default).
- We run via `--benchmark` (not `--start-server`): a multiplayer server does not
  advance ticks until a player connects, but `--benchmark` ticks the map at max
  speed, runs mod scripts, and exits on its own.
- `zomtorio-tests` is loaded as an unzipped mod with an optional dependency on
  `zomtorio` (`? zomtorio`), so the harness runs standalone now and will pick up
  the main mod automatically once its `info.json` declares `factorio_version 2.1`.

## Writing tests

Factorio's Lua sandbox has **no `coroutine` library**, so a test can't pause
mid-function. A test is therefore a sequence of **steps** that run across ticks.
The context `t` is shared between a test's steps.

```lua
local T = require("harness.runner")

-- Single step (runs at tick 0):
T.test("biter spawns on enemy force", function(t)
  local b = t.world.place(t.surface, "small-biter", t.test_origin, { force = "enemy" })
  t.assert.equal("enemy", b.force.name)
end)

-- Multi-step with a wait (let production/DoT/belts advance between steps):
T.test("furnace smelts ore", {
  function(t)
    t.world.clear(t.surface, t.test_origin)
    t.furnace = t.world.place(t.surface, "stone-furnace", t.test_origin)
    t.world.insert(t.furnace, "coal", 5)
    t.world.insert(t.furnace, "iron-ore", 10)
  end,
  { after = 480, fn = function(t)            -- +480 ticks
    t.assert.at_least(1, t.world.count(t.furnace, "iron-plate"))
  end },
})
```

Add new spec files under `zomtorio-tests/tests/` and `require` them from
`zomtorio-tests/tests/all.lua`.

### Context (`t`) and helpers

- `t.surface` — the Nauvis surface.
- `t.test_origin` — a clean `{x,y}` unique to each test (so setups never overlap).
- `t.assert` — `is_true / is_false / not_nil / equal / at_least`.
- `t.world` — factory-building helpers: `clear`, `place`, `belt_line`, `insert`,
  `count`, `belt_count`, `belt_insert` (see `harness/world.lua`).

## Layout

```
test/
  run-tests.sh                  # the runner (isolated env, benchmark, report)
  zomtorio-tests/               # the harness mod (loaded only in test runs)
    info.json
    control.lua
    harness/runner.lua          # step scheduler, assertions, result reporting
    harness/world.lua           # factory-building helpers
    tests/all.lua               # spec aggregator
    tests/smoke_spec.lua        # example/sanity tests
  .factorio-data/               # gitignored isolated runtime (recreated each run)
```
