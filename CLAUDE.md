# Zomtorio

Turns Factorio's biters into a zombie horde: enemies come in overwhelming numbers,
individually weak, and your own destroyed buildings become sources of new zombies.

- **Target:** Factorio **2.1 + Space Age** (hard dependency — relies on the spoilage
  system for corpse reanimation).
- **Scope (v1):** acts on **Nauvis only** (`lib/planets.lua` / `lib/util.is_active_surface`);
  other planets are untouched but not broken. Structured so per-planet mechanics can be
  added later.

This file is the map from **what the mod does** to **where it lives**. It is intentionally
pointer-level — read the named module for detail. (`CLAUDE.local.md`, gitignored, holds the
full requirement spec `R-*` and working notes.)

---

## Terminology

Two words mean distinct things; the code now matches these names exactly:

| Term | What it is | Module | Entity prototypes |
|---|---|---|---|
| **swarm** | one entity standing in for **N** zombies (cheap mass) | `lib/swarm.lua` | `zomtorio-swarm-small/medium/big` |
| **horde** | a telegraphed **attack wave** from a direction | `lib/horde.lua` | (no entity — a spawn schedule) |

Note `zomtorio-swarm-melee` (tech/damage type) and the `/zomtorio-horde` command are named
for their meaning too (melee that cuts a *swarm*; the command that triggers a *horde*).

---

## The swarm unit (mass without CPU cost) — `lib/swarm.lua`

- A **swarm** is a single `unit` entity that represents a population of N zombies (population
  in `storage`, keyed by `unit_number`). Prototypes: `prototypes/entities.lua` (a green-tinted
  clump of biters per tier; health is fixed one-shot headroom, not population).
- **Hit handling:** a normal hit removes **1** from the population; explosive / fire / upgraded
  swarm-melee remove `floor(damage_dealt / single-zombie-health)`. The script owns every death
  (the entity is never engine-killed); it dies at population 0. An alt-mode label shows the count.
- **Dynamic cap & overflow:** `swarm.spawn()` is the single cap-aware spawner every source
  routes through. It creates real individuals up to a configurable cap, then **folds** overflow
  into swarm units near the spawn point (merging into a nearby swarm within radius 8). When a
  swarm is hit and the cap has room and a player is near, it **bursts** into individuals.
- Setting: `zomtorio-zombie-cap` (CPU tuning), `zomtorio-zombie-count-multiplier` (overall count).

## Zombie sources

- **Building death cascade** — `lib/spawning.lua` + `lib/raw_cost.lua`. A non-wall building
  destroyed **by the enemy force** (never by the player / their own weapons / deconstruction)
  spawns zombies equal to its **total raw resource cost** (recursive recipe decomposition,
  cached in `storage`; fluids don't add to the count). Always the basic tier (numbers, not
  strength). Walls/gates excluded.
- **Engine nest output** — `lib/nest.lua` (via `on_entity_spawned`). Biter-spawner output is
  routed through the same cap: kept as a real individual under the cap (and counted), else
  folded into a **local swarm at the nest**. A per-nest budget (measured from nearby swarm
  population, scaled by local pollution between `zomtorio-nest-swarm-base`..`-max`) caps how big
  a nest's local swarm grows so an un-triggered nest can't grow forever.
- **Map / nest tuning** — `prototypes/tuning.lua` (dense, weak, slow, cheap-pollution biters;
  denser spawners) + `lib/horde.lua` `apply_map_settings` (aggressive expansion, tight unit
  groups). Settings: `zomtorio-pollution-cost-multiplier`, `zomtorio-nest-spawn-rate`,
  `zomtorio-expansion-rate`.
- **Hordes (telegraphed attack waves)** — `lib/horde.lua`. Periodic, **night-bound**, telegraphed
  ~1 day ahead; frequency and duration scale with evolution (~10% of a night at evo 0 → a full
  night at evo 1). A horde appears from **one random direction ~10 chunks beyond the factory
  edge**, marches on the factory, and is marked on the map (a traveling "Horde" chart tag + a
  `[gps]` chat warning). Plus a smaller ambient **night-escalation** trickle around the player.
  Settings: `zomtorio-horde-events` (on/off), `-horde-intensity`, `-horde-frequency`,
  `-night-assault-multiplier`. Manual trigger: **`/zomtorio-horde [minutes]`**.

## Infection — `lib/infection.lua`, `lib/contagion.lua`

- **Buildings/robots** (`lib/infection.lua`): a single hit from the enemy force infects a
  non-wall entity; it then takes **damage-over-time** and, if it dies, spawns zombies. Full
  **repair cures** it (then a short re-infection immunity window). Settings:
  `zomtorio-building-infection`, `-infection-seconds` (30s–10min), `-repair-immunity-seconds`.
- **Player** (`lib/infection.lua`): a bite that deals **health** damage (shields exempt) infects
  the player — DoT, passive regen suppressed; **any net heal cures**. Setting:
  `zomtorio-player-infection`.
- **Contagion / supply-chain spread** (`lib/contagion.lua`): infection spreads downstream along
  goods flow under a fixed per-tick work budget (UPS-safe). Three vectors: **movers**
  (inserter/loader/drill that are *actively transferring while powered* — an unpowered mover does
  not spread), **belts** (downstream, presence-gated, travel-time timer ∝ belt speed), **fluids**
  (downstream through pipes/tanks/pumps/fluid-machines; pumps also infect serviced fluid wagons).
  No self-expiry; cure = repair or death.

## Corpses & reanimation — `lib/corpses.lua`, `prototypes/{items,recipes,corpse-spoilage}.lua`

- Killed zombies drop a **corpse item** (burnable fuel) — except kills by **flame / explosion /
  double-tap**, which leave nothing. Corpses **reanimate via spoilage** wherever they sit
  (ground/belt/chest/machine) after a timer. **Kiln-dried** corpses (the corpse-kiln, a
  no-electricity building with a lossy 5→2 recipe) never reanimate but are a net fuel sacrifice.
  Settings: `zomtorio-corpse-reanimation`, `-reanimation-minutes`, `-bot-collect-corpses`.
- **Bounded reanimation (shamblers).** A corpse reanimates into a **shambler**
  (`zomtorio-shambler`: a grey, 60%-speed reanimated zombie) — which drops **no corpse** when
  killed. So the chain is exactly `zombie → corpse → shambler → dead` (one generation, then it
  ends), not an infinite loop. When shamblers fold into a swarm, the swarm tracks its shambler
  count and drops corpses only for the non-shambler share (deterministic error-diffusion split);
  a burst preserves that fraction as shambler individuals.

## Melee & tech — `lib/melee.lua`, `prototypes/{damage-types,technology,shortcuts,melee-retype}.lua`

- Base melee kills exactly one zombie. Two techs unlock/strengthen **enemy-only swarm-melee
  multi-kill**. A per-player **double-tap** toggle (post-tech shortcut) makes melee kills
  dead-dead (no corpse, no reanimation). Double-tap **defaults ON** for a force once the tech is
  researched (a force-level default; players opt *out* to harvest corpse fuel).

## Night aggression — `lib/night.lua`, `prototypes/night.lua`

- At night, zombies near a player move faster (default +100%, still below a vanilla biter).
  Mechanism: faster **night-variant prototypes** swapped in near the player and back by day
  (the only way to change a `unit`'s speed in 2.1). Applies to **both individuals and swarms**
  (swarm swaps preserve the population record via `swarm.swap_cluster`). Setting (startup):
  `zomtorio-night-speedup`.

---

## Layout

- `control.lua` — event switchboard → `lib/*` modules; the `zomtorio-debug` remote interface;
  the `/zomtorio-horde` command.
- `settings.lua` / `lib/config.lua` — all player settings + the central reader.
- `lib/tiers.lua` — shared zombie/swarm tier name constants (+ night-variant maps).
- `lib/util.lua`, `lib/planets.lua` — surface gating (Nauvis-only) and small shared helpers.
- `data.lua` / `data-final-fixes.lua` — register new prototypes / tune existing ones.
- `locale/en/zomtorio.cfg` — all in-game strings (plain hyphens, no em dashes).

## Testing

- `./test/run-tests.sh` — headless Space-Age suite (must stay green). Note it returns when the
  results JSON is written (~30s game-time); the benchmark process keeps ticking to 30000 in the
  background (~150s), so **don't start a second run until that finishes** (they share one data
  dir). Authoritative results: `test/.factorio-data/factorio-current.log`.
- **Integration tests must drive the live mod via real events + the `zomtorio-debug` remote**,
  never `require` the lib modules into the test mod (each mod gets its own module copy + storage).
- `./play.sh` — launch the GUI with only Zomtorio (no test harness); never touches saves.
