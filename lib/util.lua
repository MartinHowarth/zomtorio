-- Small shared helpers used across the runtime modules.

local util = {}

-- v1 is Nauvis-only (R-SCOPE-1). Every gameplay hook guards on this so other
-- planets are untouched and per-planet mechanics can slot in later.
util.HOME_SURFACE = "nauvis"

function util.is_active_surface(surface)
  return surface and surface.valid and surface.name == util.HOME_SURFACE
end

-- The infected force is vanilla's "enemy" force. Centralised so intent reads
-- clearly and a future split (e.g. a dedicated zombie force) is a one-line change.
util.ENEMY_FORCE = "enemy"

function util.is_enemy_force(force)
  return force and force.valid and force.name == util.ENEMY_FORCE
end

return util
