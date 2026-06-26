-- All player-facing configuration (see CLAUDE.local.md "Configuration summary").
--
-- Two classes of setting:
--   * startup  — bakes into prototypes at the data stage (corpse spoilage, the
--                per-zombie pollution cost, nest output). Cannot change mid-save.
--   * runtime-global — read by control-stage scripts; one value for the whole map,
--                changeable in an existing save. Used for everything script-driven.
--
-- Setting names are the contract between this file, the locale, and the runtime
-- config reader (lib/config.lua). Keep them in sync.

data:extend({
  -- ----------------------------------------------------------------- startup
  -- Corpse reanimation uses the spoilage system, whose timer (spoil_ticks) and
  -- result are prototype fields fixed at the data stage — hence startup.
  {
    type = "bool-setting",
    name = "zomtorio-corpse-reanimation",
    setting_type = "startup",
    default_value = true,
    order = "c-a",
  },
  {
    type = "double-setting",
    name = "zomtorio-reanimation-minutes",
    setting_type = "startup",
    default_value = 10.0,
    minimum_value = 1.0,
    maximum_value = 60.0,
    order = "c-b",
  },
  -- Pollution cost per recruited zombie, as a multiplier of vanilla
  -- pollution_to_join_attack. < 1 means cheaper => far more attackers (R-GEN-2).
  {
    type = "double-setting",
    name = "zomtorio-pollution-cost-multiplier",
    setting_type = "startup",
    default_value = 0.05,
    minimum_value = 0.001,
    maximum_value = 1.0,
    order = "g-a",
  },
  -- Nest output multiplier: scales spawner spawn rate / owned-unit count (R-GEN-3).
  {
    type = "double-setting",
    name = "zomtorio-nest-spawn-rate",
    setting_type = "startup",
    default_value = 2.0,
    minimum_value = 1.0,
    maximum_value = 10.0,
    order = "g-b",
  },
  -- Night speedup as a fraction added to daytime speed (R-NIGHT): 1.0 = +100%.
  -- STARTUP, not runtime-global: the speed boost is delivered by a sticker whose
  -- target_movement_modifier is a prototype constant baked at the data stage
  -- (the engine has no live per-unit speed setter for `unit` entities), so the
  -- slider can only take effect on a restart. Still a slider — the honest way to
  -- honor R-NIGHT-2 given the engine constraint. Read via config.night_speedup().
  {
    type = "double-setting",
    name = "zomtorio-night-speedup",
    setting_type = "startup",
    default_value = 1.0,
    minimum_value = 0.0,
    maximum_value = 3.0,
    order = "d-a",
  },

  -- ---------------------------------------------------------- runtime-global
  -- Overall horde-size multiplier applied to generated counts (R-HORDE-7).
  {
    type = "double-setting",
    name = "zomtorio-zombie-count-multiplier",
    setting_type = "runtime-global",
    default_value = 1.0,
    minimum_value = 0.1,
    maximum_value = 100.0,
    order = "a-a",
  },
  -- Dynamic cap on the number of individual (real) active zombies (R-HORDE-6).
  -- Overflow folds into higher-population horde units rather than being discarded.
  {
    type = "int-setting",
    name = "zomtorio-zombie-cap",
    setting_type = "runtime-global",
    default_value = 1000,
    minimum_value = 50,
    maximum_value = 100000,
    order = "a-b",
  },
  -- Per-nest swarm budget (lib/nest.lua): once the global cap is full, engine nest
  -- output folds into a LOCAL cluster at the nest. These bound how big that local
  -- swarm grows, interpolated on local chunk pollution from base (pristine nest) up
  -- to max (heavily polluted nest), so an un-triggered nest can't grow an infinite
  -- swarm while busy nests still field large ones.
  {
    type = "int-setting",
    name = "zomtorio-nest-swarm-base",
    setting_type = "runtime-global",
    default_value = 50,
    minimum_value = 1,
    maximum_value = 10000,
    order = "a-c",
  },
  {
    type = "int-setting",
    name = "zomtorio-nest-swarm-max",
    setting_type = "runtime-global",
    default_value = 1000,
    minimum_value = 1,
    maximum_value = 100000,
    order = "a-d",
  },
  -- Bot collection of dropped corpses (Feature B): when on, dropped corpses are
  -- marked for deconstruction so construction/logistic bots haul them to storage
  -- (where they still reanimate unless burned/kiln-dried — the intended tension).
  {
    type = "bool-setting",
    name = "zomtorio-bot-collect-corpses",
    setting_type = "runtime-global",
    default_value = true,
    order = "c-c",
  },
  -- Building infection (R-INF-1).
  {
    type = "bool-setting",
    name = "zomtorio-building-infection",
    setting_type = "runtime-global",
    default_value = true,
    order = "b-a",
  },
  -- Time from infection to death at full health, in seconds (R-INF-4): 30s–10min.
  {
    type = "int-setting",
    name = "zomtorio-infection-seconds",
    setting_type = "runtime-global",
    default_value = 300,
    minimum_value = 30,
    maximum_value = 600,
    order = "b-b",
  },
  -- Post-repair immunity window, in seconds (R-INF-5 follow-up). After an infected
  -- entity is fully repaired (cured) it can't be re-infected for this long, so a cure
  -- can stick long enough to clear a region before infected neighbours re-seed it.
  -- 0 disables (cured entities are immediately re-infectable).
  {
    type = "int-setting",
    name = "zomtorio-repair-immunity-seconds",
    setting_type = "runtime-global",
    default_value = 15,
    minimum_value = 0,
    maximum_value = 120,
    order = "b-b2",
  },
  -- Player infection (R-PINF-1).
  {
    type = "bool-setting",
    name = "zomtorio-player-infection",
    setting_type = "runtime-global",
    default_value = true,
    order = "b-c",
  },
  -- Base expansion / spread rate multiplier (R-GEN-3, R-GEN-7).
  {
    type = "double-setting",
    name = "zomtorio-expansion-rate",
    setting_type = "runtime-global",
    default_value = 2.0,
    minimum_value = 0.1,
    maximum_value = 10.0,
    order = "g-c",
  },
  -- Night assault escalation multiplier (R-GEN-4).
  {
    type = "double-setting",
    name = "zomtorio-night-assault-multiplier",
    setting_type = "runtime-global",
    default_value = 1.5,
    minimum_value = 1.0,
    maximum_value = 10.0,
    order = "g-d",
  },
  -- Escalating swarm events (R-GEN-5): on/off + intensity & frequency scaling.
  {
    type = "bool-setting",
    name = "zomtorio-horde-events",
    setting_type = "runtime-global",
    default_value = true,
    order = "e-a",
  },
  {
    type = "double-setting",
    name = "zomtorio-horde-intensity",
    setting_type = "runtime-global",
    default_value = 1.0,
    minimum_value = 0.1,
    maximum_value = 10.0,
    order = "e-b",
  },
  {
    type = "double-setting",
    name = "zomtorio-horde-frequency",
    setting_type = "runtime-global",
    default_value = 1.0,
    minimum_value = 0.1,
    maximum_value = 10.0,
    order = "e-c",
  },
})
