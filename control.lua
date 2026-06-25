-- Control stage: wire engine events to the feature modules. Each module owns its
-- own behaviour and storage; this file is only the switchboard. Per-surface
-- guards (Nauvis-only, R-SCOPE-1) live inside the modules that need them.

local raw_cost  = require("lib.raw_cost")
local horde     = require("lib.horde")
local spawning  = require("lib.spawning")
local infection = require("lib.infection")
local contagion = require("lib.contagion")
local corpses   = require("lib.corpses")
local melee     = require("lib.melee")
local night     = require("lib.night")
local swarm     = require("lib.swarm")

-- Modules with first-time setup. raw_cost runs first: others depend on its cache.
local INIT_ORDER = { raw_cost, horde, infection, contagion, corpses, melee, night, swarm }

local function on_init()
  storage.zomtorio = storage.zomtorio or {}
  for _, m in ipairs(INIT_ORDER) do
    if m.on_init then m.on_init() end
  end
end

-- Prototypes/recipes can change across mod updates; recompute derived caches and
-- re-apply map settings.
local function on_configuration_changed()
  storage.zomtorio = storage.zomtorio or {}
  for _, m in ipairs(INIT_ORDER) do
    if m.on_init then m.on_init() end
  end
  if raw_cost.on_configuration_changed then raw_cost.on_configuration_changed() end
  if swarm.on_configuration_changed then swarm.on_configuration_changed() end
end

script.on_init(on_init)
script.on_configuration_changed(on_configuration_changed)

------------------------------------------------------------------- per-tick
-- One on_tick fan-out; each consumer self-throttles to its own cadence/budget.
script.on_event(defines.events.on_tick, function(event)
  infection.on_tick(event)
  contagion.on_tick(event)
  night.on_tick(event)
  swarm.on_tick(event)
end)

------------------------------------------------------------------- damage
-- NOTE: intentionally UNFILTERED. The three consumers between them care about a
-- broad span of damaged entities (horde units, every infectable building/robot/
-- character, and every enemy unit for melee), so a LuaEntityDamagedEventFilter
-- union would exclude little. Each module early-outs cheaply (one type/name/
-- validity check before any work), which is the real safeguard against per-hit cost.
script.on_event(defines.events.on_entity_damaged, function(event)
  infection.on_entity_damaged(event)
  horde.on_entity_damaged(event)
  melee.on_entity_damaged(event)
end)

------------------------------------------------------------------- death
-- The single canonical on_entity_died dispatch. NOTE: on_entity_died must NOT
-- also appear in remove_events below — a second script.on_event for the same
-- event id replaces this handler rather than adding to it.
script.on_event(defines.events.on_entity_died, function(event)
  spawning.on_entity_died(event)
  corpses.on_entity_died(event)
  horde.on_entity_died(event)
  contagion.on_removed(event)  -- a dead entity also leaves the mover registry
end)

------------------------------------------------------------------- reanimation
-- A spoiled corpse hatched a zombie; route it through the dynamic cap.
script.on_event(defines.events.on_trigger_created_entity, function(event)
  horde.on_trigger_created_entity(event)
end)

------------------------------------------------------------------- build/remove
-- Maintains the contagion mover registry.
local build_events = {
  defines.events.on_built_entity,
  defines.events.on_robot_built_entity,
  defines.events.script_raised_built,
  defines.events.script_raised_revive,
  defines.events.on_space_platform_built_entity,
}
for _, e in ipairs(build_events) do
  script.on_event(e, function(event) contagion.on_built(event) end)
end

-- Non-death removals only (death is handled above so we don't re-register
-- on_entity_died and clobber that handler).
local remove_events = {
  defines.events.on_player_mined_entity,
  defines.events.on_robot_mined_entity,
  defines.events.script_raised_destroy,
  defines.events.on_space_platform_mined_entity,
}
for _, e in ipairs(remove_events) do
  script.on_event(e, function(event)
    contagion.on_removed(event)
    horde.on_removed(event)  -- a mined/destroyed individual must free its cap slot
  end)
end

------------------------------------------------------------------- shortcuts
script.on_event(defines.events.on_lua_shortcut, function(event)
  melee.on_toggle_shortcut(event)
end)

------------------------------------------------------------------- research
-- Unlock the double-tap shortcut for a force once the melee tech is researched.
script.on_event(defines.events.on_research_finished, function(event)
  melee.on_research_finished(event)
end)

------------------------------------------------------------------- players
-- Drop per-player melee toggle state when a player is removed.
script.on_event(defines.events.on_player_removed, function(event)
  melee.on_player_removed(event)
end)

------------------------------------------------------------------- settings
script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  swarm.on_runtime_setting_changed(event)
end)

------------------------------------------------------------------- debug remote
-- A tiny introspection interface so the (separate) test harness mod can observe
-- THIS mod's real runtime state and effects. A test that `require`s our lib files
-- gets its own private copy of each module with its own `storage`, so it can never
-- see what the live mod actually infected — it must ask across the mod boundary.
-- remote.call is an in-process call (LuaEntity args pass by reference), so the
-- handlers operate on the real mod's storage. Registered at script load so it
-- exists after every load, not only on_init.
remote.add_interface("zomtorio-debug", {
  -- Force-infect an entity directly (for testing). Obeys the same rules as a real
  -- bite (walls/gates/enemy units excluded), then takes the DoT / spreads / shows
  -- the biohazard marker like any infection. Example from the console:
  --   /c remote.call("zomtorio-debug", "infect", game.player.selected)
  infect = function(entity) infection.infect(entity) end,
  -- Is this entity in the live building-infection set?
  is_infected = function(entity) return infection.is_infected(entity) end,
  -- Is this character in the live player-infection set?
  is_player_infected = function(character) return infection.is_player_infected(character) end,
  -- Size of the live infected-building set.
  infected_count = function() return infection.debug_infected_count() end,
  -- { movers=, belts= } sizes of the live contagion registry/frontier.
  contagion_counts = function() return contagion.debug_counts() end,
  -- Override the live time-to-death (ticks) so tests can drive a fast DoT; nil
  -- restores the configured setting.
  set_infection_ticks = function(n) infection.set_ticks_override(n) end,
})
