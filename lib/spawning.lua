-- S3 — buildings become zombie sources on death (R-DEATH).
--
-- When a non-wall building dies to something on the infected force (NOT to the
-- player's own actions: deconstruction, mining, blueprint removal, own weapons),
-- spawn zombies equal to its total-raw solid cost (raw_cost), at a tier chosen
-- by whether its cost involved oil. Routes through horde.spawn (R-HORDE-6).

local spawning = {}

function spawning.on_entity_died(event) end

return spawning
