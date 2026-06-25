-- Central reader for all Zomtorio settings. One place that knows setting names,
-- so the rest of the runtime asks for meaning ("infection time-to-death in
-- ticks") rather than poking the settings table with string keys.
--
-- Runtime-global settings are read live each call (cheap, and picks up changes);
-- callers that need to react to a change hook on_runtime_mod_setting_changed.
-- Startup settings are read at the data stage by the prototype files directly.

local config = {}

local function global_value(name)
  local s = settings.global[name]
  return s and s.value
end

local function startup_value(name)
  local s = settings.startup[name]
  return s and s.value
end

------------------------------------------------------------------- horde / cap
function config.horde_size_multiplier() return global_value("zomtorio-horde-size-multiplier") end
function config.zombie_cap()            return global_value("zomtorio-zombie-cap") end

------------------------------------------------------------------- infection
function config.building_infection_enabled() return global_value("zomtorio-building-infection") end
function config.player_infection_enabled()   return global_value("zomtorio-player-infection") end

--- Ticks for an infected entity at full health to die (R-INF-4).
function config.infection_ticks()
  return math.floor((global_value("zomtorio-infection-seconds") or 300) * 60)
end

------------------------------------------------------------------- night
--- Fraction added to daytime movement speed at night (R-NIGHT); 1.0 = +100%.
--- STARTUP setting: the sticker that delivers the boost bakes this into its
--- target_movement_modifier at the data stage (= 1 + this), so it can't be read
--- live. config.lua and prototypes/night.lua MUST agree on this conversion.
function config.night_speedup() return startup_value("zomtorio-night-speedup") or 1.0 end

------------------------------------------------------------------- corpses
--- Whether dropped corpses are marked for construction/logistic-bot collection.
function config.bot_collect_corpses() return global_value("zomtorio-bot-collect-corpses") end

------------------------------------------------------------------- generation
function config.expansion_rate()           return global_value("zomtorio-expansion-rate") end
function config.night_assault_multiplier() return global_value("zomtorio-night-assault-multiplier") end
function config.swarm_events_enabled()     return global_value("zomtorio-swarm-events") end
function config.swarm_intensity()          return global_value("zomtorio-swarm-intensity") end
function config.swarm_frequency()          return global_value("zomtorio-swarm-frequency") end

return config
