-- S2 — the horde population model and the unified cap-aware spawner.
--
-- A "horde unit" is one entity that stands in for N individual zombies
-- (population kept in storage; health = pop x single-zombie health). This keeps
-- enormous effective numbers cheap (R-HORDE-2/3).
--
-- On hit (R-HORDE-4/5): a normal hit kills one zombie's worth; an explosive or
-- upgraded-melee hit kills floor(damage / single-zombie-health). If the dynamic
-- cap has room and a player is near, the cluster bursts into individuals;
-- otherwise it just loses population. Dies at population 0.
--
-- spawn() is the single entry point every source routes through (R-HORDE-6 /
-- R-GEN-6): it creates individuals up to the dynamic cap, folding any overflow
-- into higher-population horde units rather than discarding it.

local horde = {}

function horde.on_init() end
function horde.on_entity_damaged(event) end

--- Unified spawner. Create `count` zombies of `tier` for `force` near `pos` on
--- `surface`: individuals up to the cap, overflow folded into horde units.
function horde.spawn(surface, pos, count, tier, force) end

return horde
