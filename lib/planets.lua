-- Per-surface configuration. v1 is Nauvis-only (R-SCOPE-1); this module is the
-- seam where per-planet mechanics (Gleba spores, Vulcanus burning, Fulgora
-- scrap golems, Aquilo freezing) will slot in later without touching callers.
--
-- For now it answers one question: does Zomtorio act on this surface?

local util = require("lib.util")

local planets = {}

function planets.is_active(surface)
  return util.is_active_surface(surface)
end

return planets
