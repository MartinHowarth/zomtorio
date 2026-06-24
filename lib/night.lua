-- S9 — night aggression (R-NIGHT).
--
-- At night on Nauvis, zombies move faster than during the day (default +100%,
-- slider-controlled), and should still be a touch slower than a vanilla biter.

local night = {}

function night.on_init() end
function night.on_tick(event) end

--- Is it currently night on the home surface? (Shared with swarm-event timing.)
function night.is_night(surface) return false end

return night
