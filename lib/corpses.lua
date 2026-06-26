-- S7 — corpse drops and reanimation (R-CORPSE).
--
-- A killed zombie drops a burnable corpse item on the ground (R-CORPSE-2/3),
-- EXCEPT when killed by flame ("fire") or explosion damage, or by a double-tap
-- melee kill ("dead-dead") — those leave no corpse (R-CORPSE-4). Dropped corpses
-- spoil into zombies on a timer wherever they sit; that reanimation is purely
-- data-driven (prototypes/corpse-spoilage.lua), so this module only handles the
-- drop. Kiln-dried corpses are a non-spoiling form produced by a recipe, so they
-- need no runtime code here either.

local config  = require("lib.config")
local planets = require("lib.planets")
local tiers   = require("lib.tiers")
local melee   = require("lib.melee")
local util    = require("lib.util")

local corpses = {}

local CORPSE_ITEM = "zomtorio-corpse"

-- Damage types that destroy a zombie utterly: no corpse, so it can never
-- reanimate (R-CORPSE-4). Flame is "fire" in vanilla.
local NO_CORPSE_DAMAGE = { fire = true, explosion = true }

-- Test-only override of the bot-collection setting. Runtime-global settings can
-- only be written by their owning mod, so the test harness (a separate mod) can't
-- set the setting; this hook lets a test pin it. nil -> the live setting is used.
-- Mirrors horde.lua's cap_override pattern.
local bot_collect_override

--- Whether dropped corpses are marked for bot collection (R bot-collect setting).
local function bot_collect()
  if bot_collect_override ~= nil then return bot_collect_override end
  return config.bot_collect_corpses()
end

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

  -- 2.1: spill_item_stack returns the item-on-ground entities it created.
  local dropped = surface.spill_item_stack {
    position = position,
    stack = { name = CORPSE_ITEM, count = count },
    enable_looted = false,
    allow_belts = true,
  }

  -- Bot collection (Feature B): mark each dropped corpse for deconstruction by the
  -- player force so construction/logistic bots haul them in. The corpses then sit
  -- in storage where they STILL reanimate on the spoil timer unless burned or
  -- kiln-dried first — the intended tension, not a free cleanup.
  if bot_collect() and dropped then
    local player_force = game.forces["player"]
    if player_force then
      for _, item_entity in ipairs(dropped) do
        if item_entity and item_entity.valid then
          item_entity.order_deconstruction(player_force)
        end
      end
    end
  end
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
  if tiers.SWARM_TO_TIER[e.name] ~= nil then return end  -- a cluster, not an individual

  -- A double-tap melee kill is dead-dead: no corpse, so it can't reanimate
  -- (R-MELEE-5). Melee types are otherwise NOT no-corpse — they drop normally.
  local no_corpse = melee.is_dead_dead(event)
  local dtype = event.damage_type and event.damage_type.name
  corpses.drop(e.surface, e.position, 1, dtype, no_corpse)
end

-- NOTE: the corpse-reanimation interception (on_trigger_created_entity) lives in
-- lib/horde.lua, NOT here. Factorio forbids require() at runtime, so this handler
-- can't lazily reach horde; and a top-level corpses->horde require would cycle
-- (horde already requires corpses for corpse drops). horde already owns the cap
-- (cap_room/track/fold), so the handler is cleanest there. See horde.on_trigger_created_entity.

--- Test-only: pin (or, with nil, release) the bot-collection setting. See
--- `bot_collect_override` above; mirrors horde.set_cap_override.
function corpses.set_bot_collect_override(b)
  bot_collect_override = b
end

return corpses
