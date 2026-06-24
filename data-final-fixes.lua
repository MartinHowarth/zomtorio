-- Data stage, final fixes: tune EXISTING prototypes after every other mod has
-- had its say. This is where the dense-swarm feel is dialled in (collision,
-- speed, health, recruitment cost), worms are pushed back, the character's
-- melee is retyped for detection, and corpse spoilage is configured.

require("prototypes.tuning")          -- S10: dense-swarm tuning of base enemies
require("prototypes.melee-retype")    -- S8: retype character tool_attack_result
require("prototypes.corpse-spoilage") -- S7: wire spoil_to_trigger_result on corpses
