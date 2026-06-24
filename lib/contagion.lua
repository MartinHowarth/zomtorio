-- S6 — infection contagion: spread along the flow of goods (R-CONT).
--
-- Two vectors, both bounded by a fixed per-tick work budget so spread can slow
-- but the frame rate never does (R-CONT-7):
--   * Movers (inserters/loaders/mining drills): a throttled round-robin sweep
--     over a maintained registry. An actively-transferring mover whose source is
--     infected infects itself and its drop target.
--   * Belts: an infected belt that has items on it spreads downstream via
--     belt_neighbours on a travel-time timer that is shorter on faster belts.
--
-- No self-expiry; cure is repair or death (R-CONT-4). Conduits (belts, pipes,
-- inserters) are infectable, take DoT, and spawn zombies on death (R-CONT-5).

local contagion = {}

function contagion.on_init() end
function contagion.on_built(event) end
function contagion.on_removed(event) end
function contagion.on_tick(event) end

return contagion
