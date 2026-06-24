-- S4/S5 — infection of buildings, robots (R-INF) and the player (R-PINF).
--
-- A single hit from the infected force infects a non-wall target. Infected
-- entities take damage over time (time-to-death at full health is the
-- configured slider) and, if they die from it, spawn zombies via the
-- building-death path. Full repair clears the infection (R-INF-5).
--
-- Player: bitten (health damage only, shields exempt) => infected; passive
-- regen suppressed; any net heal clears it (R-PINF).
--
-- The set of infected entities lives in storage and is also the source-of-truth
-- contagion (lib/contagion.lua) reads when deciding what spreads.

local infection = {}

function infection.on_init() end
function infection.on_entity_damaged(event) end
function infection.on_tick(event) end

--- Is this entity currently infected? (Read by contagion.)
function infection.is_infected(entity) return false end

--- Infect an entity now (used by contagion spread + the on-hit path).
function infection.infect(entity) end

return infection
