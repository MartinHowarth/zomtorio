-- S7 — corpse drops and reanimation (R-CORPSE).
--
-- A killed zombie drops a burnable corpse item on the ground (R-CORPSE-2/3),
-- EXCEPT when killed by flame ("fire") or explosion damage, or by a double-tap
-- melee kill ("dead-dead") — those leave no corpse (R-CORPSE-4). Dropped corpses
-- spoil into zombies on a timer wherever they sit; that reanimation is purely
-- data-driven (prototypes/corpse-spoilage.lua), so this module only handles the
-- drop. Kiln-dried corpses are a non-spoiling form produced by a recipe, so they
-- need no runtime code here either.

local planets = require("lib.planets")
local tiers   = require("lib.tiers")
local util    = require("lib.util")

local corpses = {}

local CORPSE_ITEM = "zomtorio-corpse"

-- Damage types that destroy a zombie utterly: no corpse, so it can never
-- reanimate (R-CORPSE-4). Flame is "fire" in vanilla.
local NO_CORPSE_DAMAGE = { fire = true, explosion = true }

-- Reanimation is data-driven (spoilage); no per-tick or persistent state needed.
function corpses.on_init() end

--- Drop `count` corpse items at `position` on `surface`, UNLESS the kill leaves
--- nothing to drop: `no_corpse` (the S8 double-tap flag) or a flame/explosion
--- `damage_type_name` (R-CORPSE-4). Nauvis-only (R-SCOPE-1).
---
--- We spill ONE stack of `count` and let the engine split it into ground items
--- (which then spoil/reanimate wherever they land), rather than looping per item.
function corpses.drop(surface, position, count, damage_type_name, no_corpse)
  count = math.floor(count or 0)
  if count <= 0 then return end
  if not (surface and surface.valid) then return end
  if not planets.is_active(surface) then return end
  if no_corpse then return end
  if damage_type_name and NO_CORPSE_DAMAGE[damage_type_name] then return end

  surface.spill_item_stack {
    position = position,
    stack = { name = CORPSE_ITEM, count = count },
    enable_looted = false,
    allow_belts = true,
  }
end

--- An individual zombie died: drop one corpse for it. We deliberately EXCLUDE
--- horde-unit clusters here — their population kills are dropped by lib/horde at
--- the moment of the hit, so letting a cluster's own death also drop corpses
--- would double-count. An individual zombie is a `unit` on the enemy force that
--- is NOT one of our cluster prototypes.
function corpses.on_entity_died(event)
  local e = event and event.entity
  if not (e and e.valid) then return end
  if e.type ~= "unit" then return end
  if not util.is_enemy_force(e.force) then return end
  if tiers.HORDE_TO_TIER[e.name] ~= nil then return end  -- a cluster, not an individual

  local dtype = event.damage_type and event.damage_type.name
  corpses.drop(e.surface, e.position, 1, dtype)
end

return corpses
