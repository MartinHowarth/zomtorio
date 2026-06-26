-- S9 — night aggression (R-NIGHT).
--
-- At night on Nauvis, zombies move faster than during the day (default +100%,
-- slider-controlled, R-NIGHT-1/2), and still a touch slower than a vanilla biter
-- (the S10 tuning sets day speed to ~vanilla/4, so 2x day < vanilla).
--
-- MECHANISM (verified in-sim — three approaches probed):
--   * sticker target_movement_modifier: does NOT speed units up (the base
--     changelog says so explicitly; an attack-move probe confirmed no effect).
--   * writing LuaEntity.speed: the field accepts the write and reads back, but
--     AI movement ignores it (probe: same displacement as an un-written unit).
--   * faster-prototype NIGHT VARIANT + entity swap: WORKS. An attack-commanded
--     "small-biter-zomtorio-night" (movement_speed 0.4) covered ~2x the distance
--     of a plain small-biter (0.2) over the same ticks.
-- So a unit's speed is fixed by its prototype's movement_speed; the only lever is
-- which prototype it is. lib/night.lua swaps enemy units near a player to their
-- faster night variant at night, and back to the day prototype by day. The
-- variants are built in prototypes/night.lua with movement_speed * (1 + speedup).
--
-- UPS SAFETY: there is no requirement to boost every off-screen zombie, and a
-- whole-surface find_entities_filtered per tick is unacceptable. The sweep only
-- swaps enemy units NEAR a player/character (where speed is actually observed),
-- throttled to every SWEEP_PERIOD ticks. Swapping is idempotent (a unit already
-- in the right day/night form is skipped), so re-running the sweep is cheap.
-- (R-SCOPE-1: Nauvis-only via planets.is_active.)

local planets = require("lib.planets")
local util    = require("lib.util")
local swarm   = require("lib.swarm")
local tiers   = require("lib.tiers")

local night = {}

-- Night when the surface is more than half-dark. Verified: at solar noon
-- darkness == 0.0, at midnight darkness == 0.85 on Nauvis.
local NIGHT_THRESHOLD = 0.5

-- Suffix that turns a day enemy prototype into its faster night variant. Shared
-- with the data stage via tiers so the two never drift.
local NIGHT_SUFFIX = tiers.NIGHT_SUFFIX

-- Throttle: run the sweep only every Nth tick (cheap on the other ticks).
local SWEEP_PERIOD = 30

-- Radius around each character to act on enemy units within. Generous enough to
-- cover what's on screen; the sweep cost scales with units in this circle, not
-- with the whole surface.
local SWEEP_RADIUS = 48

--------------------------------------------------------------------- helpers

--- Is `name` a night variant we created?
local function is_night_variant(name)
  return name:sub(-#NIGHT_SUFFIX) == NIGHT_SUFFIX
end

--- The night variant of a day prototype, or nil if none exists.
local function night_variant_of(name)
  local variant = name .. NIGHT_SUFFIX
  return prototypes.entity[variant] and variant or nil
end

--- The day prototype a night variant came from, or nil if `name` isn't one.
local function day_form_of(name)
  if not is_night_variant(name) then return nil end
  local day = name:sub(1, #name - #NIGHT_SUFFIX)
  return prototypes.entity[day] and day or nil
end

--- Replace `unit` with a same-position, same-force unit of `new_name`, carrying
--- over its command so the swap is seamless. Returns the new entity or nil.
local function swap_to(surface, unit, new_name)
  if not (unit and unit.valid) then return nil end
  local pos, force = unit.position, unit.force
  -- Preserve the active command so a swapped attacker keeps charging.
  local cmd
  local ok, cmdable = pcall(function() return unit.commandable end)
  if ok and cmdable and cmdable.valid then cmd = cmdable.command end
  -- raise_destroy so the registries that track enemy units (swarm cap accounting,
  -- the contagion mover registry) drop the old unit cleanly: a swapped unit that
  -- was a swarm-tracked individual frees its cap slot rather than leaking it. The
  -- replacement is a plain new enemy unit (not re-registered as a tracked
  -- individual) — acceptable for v1; S10 reconciles spawn/cap ownership.
  unit.destroy { raise_destroy = true }
  local new = surface.create_entity { name = new_name, position = pos, force = force }
  if new and new.valid and cmd then
    pcall(function() new.commandable.set_command(cmd) end)
  end
  return new
end

--------------------------------------------------------------------- public

--- Is it currently night on the given surface? Nauvis-guarded (R-SCOPE-1) so
--- off-Nauvis surfaces never read as night for our purposes. Shared with
--- swarm-event timing (S10).
function night.is_night(surface)
  if not (surface and surface.valid) then return false end
  if not planets.is_active(surface) then return false end
  return surface.darkness > NIGHT_THRESHOLD
end

function night.on_init()
  -- No persistent state: the sweep is stateless and idempotent (the swap target
  -- is derived from the current day/night state each pass). Kept for symmetry
  -- with the other modules' init contract.
end

--- Where to anchor the sweep: every observed point on the surface — placed
--- characters AND connected players' controller positions (so it also works in
--- sandbox/editor/spectator, where there is NO character but the player still has a
--- position; bug: night speed never changed in sandbox because we only looked for
--- characters). Deduped on a coarse grid so a player WITH a character isn't swept
--- twice. Empty headless (no players, no characters) => the sweep is a no-op.
local function anchor_positions(surface)
  local seen, anchors = {}, {}
  local function add(pos)
    if not pos then return end
    local key = math.floor(pos.x / SWEEP_RADIUS) .. ":" .. math.floor(pos.y / SWEEP_RADIUS)
    if not seen[key] then
      seen[key] = true
      anchors[#anchors + 1] = pos
    end
  end
  for _, char in pairs(surface.find_entities_filtered { type = "character" }) do
    if char.valid then add(char.position) end
  end
  for _, player in pairs(game.connected_players) do
    if player.valid and player.surface == surface then
      local ok, pos = pcall(function() return player.position end)
      if ok then add(pos) end
    end
  end
  return anchors
end

--- Swap one enemy unit toward the correct day/night form, or skip it if it is
--- ALREADY in that form. CRITICAL: only day->night at night and night->day by day
--- (and never touch a unit already correct). The old single-expression form
--- (`night_now and night_variant_of(u) or day_form_of(u)`) swapped a NIGHT variant
--- BACK to day at night — night_variant_of returns nil for an already-night unit,
--- so it fell through to day_form_of — and the next sweep re-swapped it, making
--- zombies visibly stutter slow<->fast every sweep. This split fixes that.
local function swap_unit(surface, u, night_now)
  local target
  if night_now then
    if not is_night_variant(u.name) then target = night_variant_of(u.name) end
  else
    if is_night_variant(u.name) then target = day_form_of(u.name) end
  end
  if not target then return end

  if tiers.SWARM_TO_TIER[u.name] then
    -- A cluster (swarm): swap via swarm so its population record (pop, health,
    -- label) is carried across rather than orphaned.
    swarm.swap_cluster(u, target)
  else
    -- An individual: preserve cap accounting across the destroy+recreate swap — if
    -- it was a tracked individual, re-track the replacement so the cap count doesn't
    -- drift down (see swarm.track).
    local was_tracked = swarm.is_tracked(u.unit_number)
    local new = swap_to(surface, u, target)
    if was_tracked and new and new.valid then swarm.track(new) end
  end
end

--- Per-tick entry (control.lua fans this out). Self-throttled to SWEEP_PERIOD.
--- At night it swaps nearby enemy day-units to their faster night variant; by
--- day it swaps any lingering night variants back. Only ever touches enemy units
--- near an observed point — the deliberate UPS-safe scoping (see file header).
function night.on_tick(event)
  if event.tick % SWEEP_PERIOD ~= 0 then return end

  local surface = game.surfaces[util.HOME_SURFACE]
  if not (surface and surface.valid and planets.is_active(surface)) then return end

  local night_now = surface.darkness > NIGHT_THRESHOLD

  for _, pos in ipairs(anchor_positions(surface)) do
    local units = surface.find_entities_filtered {
      type = "unit", force = util.ENEMY_FORCE, position = pos, radius = SWEEP_RADIUS,
    }
    for _, u in pairs(units) do
      if u.valid then swap_unit(surface, u, night_now) end
    end
  end
end

--------------------------------------------------------------------- test API

--- Test-only: force the sweep regardless of the tick throttle, so a test need
--- not advance to a multiple of SWEEP_PERIOD.
function night.sweep_now()
  night.on_tick { tick = 0 }
end

--- Test/helper: the night-variant name for a day prototype (nil if none).
night.night_variant_of = night_variant_of

--- Test/helper: true if a name is one of our night variants.
night.is_night_variant = is_night_variant

return night
