-- S8 — swarm melee and the double-tap toggle (R-MELEE).
--
-- Base melee is the vanilla no-ammo attack and kills one zombie per hit. Two
-- technologies grow it: Tier 1 (red science) unlocks enemy-only multi-kill that
-- scales with damage like the explosive rule; Tier 2 (red+green) increases it
-- further. The custom "zombie-melee" damage type makes these hits unambiguous to
-- detect and keeps them friendly-fire-safe.
--
-- Double-tap is a per-player toggle (unlocked by tech, switched via a shortcut):
-- while on, zombie-melee kills are dead-dead and drop no corpse (R-MELEE-5).

local melee = {}

function melee.on_init() end
function melee.on_entity_damaged(event) end
function melee.on_toggle_shortcut(event) end

--- Is double-tap currently on for this player? (Read by the corpse-drop path.)
function melee.double_tap_on(player_index) return false end

return melee
