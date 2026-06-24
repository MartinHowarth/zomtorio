-- S10 — enemy generation: map/force tuning and escalating swarm events (R-GEN).
--
-- At init this applies the denser, more aggressive map settings (expansion,
-- unit groups) on top of the prototype tuning done in data-final-fixes.
--
-- Swarm events (R-GEN-5, default on) are telegraphed night-bound assaults layered
-- on top of pollution-based generation: the player is warned in advance, the
-- event fires at night, and its spawning-period length scales with evolution
-- (~10% of a night at evolution 0, a full night at 1.0). Both frequency and
-- intensity grow with evolution. All spawns route through the unified spawner.

local swarm = {}

function swarm.on_init() end
function swarm.on_configuration_changed() end
function swarm.on_runtime_setting_changed(event) end
function swarm.on_tick(event) end

return swarm
