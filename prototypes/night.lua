-- S9 — night aggression prototypes (R-NIGHT-1/2).
--
-- ENGINE CONSTRAINT (verified in-sim, see lib/night.lua header): there is no
-- runtime way to speed up a single `unit` entity in 2.1 — sticker
-- target_movement_modifier is explicitly NOT applied to units (base changelog),
-- and writing LuaEntity.speed does not change AI movement. The only lever is the
-- prototype's movement_speed, which is fixed at the data stage. So the night
-- boost is delivered by NIGHT VARIANT unit prototypes: a faster clone of each
-- base zombie. lib/night.lua swaps enemy units near a player to their night
-- variant at night and back to the day prototype by day.
--
-- The speed factor (1 + speedup) is baked here from the night-speedup STARTUP
-- setting; config.night_speedup() reads the same setting at runtime so the two
-- agree. v1 covers the base vanilla biters (S10 will add the dense zombie
-- prototypes; this file is structured to clone whatever the day prototypes are).

local tiers = require("lib.tiers")

local speedup = settings.startup["zomtorio-night-speedup"].value or 1.0
local factor = 1 + speedup

-- Day prototype name -> night variant name. lib/night.lua reads this mapping.
-- Keyed on the vanilla biters/spitters AND the horde-unit clusters (so swarms
-- speed up at night too, not just loose individuals). The clusters already exist
-- here because prototypes.entities is required before this file (see data.lua).
local NIGHT_VARIANTS = {
  "small-biter", "medium-biter", "big-biter", "behemoth-biter",
  "small-spitter", "medium-spitter", "big-spitter", "behemoth-spitter",
}
for _, cluster_name in pairs(tiers.SWARM) do
  NIGHT_VARIANTS[#NIGHT_VARIANTS + 1] = cluster_name
end

for _, base_name in ipairs(NIGHT_VARIANTS) do
  local base = data.raw.unit[base_name]
  if base then
    local night = table.deepcopy(base)
    night.name = base_name .. tiers.NIGHT_SUFFIX
    night.movement_speed = (base.movement_speed or 0.1) * factor
    -- Reuse the BASE entity's display name + a shared description, so the renamed
    -- variant doesn't render "unknown key: entity-name.<...>-zomtorio-night" in the
    -- tooltip (its auto-derived locale key doesn't exist). The cluster bases
    -- ("zomtorio-swarm-small" etc.) and the vanilla biters both have an
    -- entity-name.<base> key, so this resolves for every variant.
    night.localised_name = { "entity-name." .. base_name }
    night.localised_description = { "zomtorio.night-variant-desc" }
    -- Night variants are an internal swap target, not a separately-spawnable or
    -- map-listed enemy. Hide from selection/listings; keep collision/combat.
    night.hidden = true
    -- A night variant must never itself be remapped or counted as a "day" unit.
    data:extend({ night })
  end
end
