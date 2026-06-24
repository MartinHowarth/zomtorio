-- S7 — corpse drops and reanimation (R-CORPSE).
--
-- A killed zombie drops a burnable corpse item, EXCEPT when killed by flame or
-- explosion damage or a double-tap melee kill ("dead-dead", no drop). Corpse
-- items reanimate into zombies on a spoilage timer wherever they sit (ground,
-- belts, machines, chests). Kiln-dried corpses are a non-spoiling, higher-fuel
-- form produced at a deliberate fuel loss.

local corpses = {}

function corpses.on_init() end
function corpses.on_entity_died(event) end

return corpses
