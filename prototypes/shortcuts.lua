-- S8 — the double-tap per-player toggle shortcut (R-MELEE-5), modelled on the
-- mech-armour speed-boost toggle: unlocked by a melee technology, then toggled
-- on/off per player. While ON, melee kills are dead-dead (no corpse) — handled in
-- lib/melee.lua (is_dead_dead) which the corpse-drop paths consult.
--
-- action = "lua" + toggleable = true makes pressing it fire on_lua_shortcut and
-- carry a toggled visual state we drive via player.set_shortcut_toggled.
-- technology_to_unlock ties its base availability to the Tier-2 melee tech; the
-- runtime additionally manages availability per force on research (lib/melee).
--
-- Reuse base shortcut-toolbar art so the icon is valid without new assets.

data:extend({
  {
    type = "shortcut",
    name = "zomtorio-double-tap",
    order = "z[zomtorio]-a[double-tap]",
    action = "lua",
    toggleable = true,
    localised_name = { "shortcut.zomtorio-double-tap" },
    technology_to_unlock = "zomtorio-swarm-melee-2",
    icon = "__base__/graphics/icons/shortcut-toolbar/mip/new-blueprint-x56.png",
    icon_size = 56,
    small_icon = "__base__/graphics/icons/shortcut-toolbar/mip/new-blueprint-x24.png",
    small_icon_size = 24,
  },
})
