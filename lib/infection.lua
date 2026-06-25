-- S4/S5 — infection of buildings, robots (R-INF) and the player/character (R-PINF).
--
-- A single hit from the infected force infects a non-wall target. Infected
-- entities take damage over time (time-to-death at full health is the configured
-- slider, R-INF-4) and, if they die from it, spawn zombies via the building-death
-- path. Full repair clears the infection (R-INF-5).
--
-- DoT MODEL (elapsed-time). Each infected entity stores { entity, last_tick }.
-- When processed we apply `max_health * (now - last_tick) / infection_ticks` as
-- damage and advance last_tick. So cumulative damage over `infection_ticks`
-- equals exactly max_health (death at full health in the configured time) no
-- matter HOW OFTEN we actually process it — which is what lets processing be
-- throttled (production) or sparse (tests) while timing stays exact.
--
-- The DoT is dealt on the ENEMY force with the "zomtorio-infection" damage type,
-- so the eventual on_entity_died is enemy-caused and lib/spawning.lua handles the
-- zombie spawn (R-INF-3) — this module never spawns directly. The custom type
-- also lets the on-hit handler ignore our own DoT (it must not re-infect).
--
-- The set of infected entities lives in storage and is the source-of-truth
-- contagion (lib/contagion.lua) reads in S6 when deciding what spreads.
--
-- PLAYER (CHARACTER) INFECTION (R-PINF). A bite — enemy-caused damage that dealt
-- actual HEALTH damage (not fully shield-absorbed, R-PINF-3) — infects the
-- character. The player DoT is PER-TICK (few characters, no bucketing) and the
-- module manages the character's health directly each tick: it sets an absolute
-- health value along the DoT trajectory, which OVERWRITES passive regeneration
-- (R-PINF-4). The last value we set is remembered as `floor_health`; if the
-- character's health rises meaningfully ABOVE it, a real heal happened and the
-- infection is cured (R-PINF-5). State is keyed on the CHARACTER ENTITY's
-- unit_number (not a LuaPlayer) so the feature works headless with no connected
-- players — the bite handler and DoT operate purely on character entities.

local config  = require("lib.config")
local planets = require("lib.planets")
local util    = require("lib.util")

local infection = {}

-- Our own DoT damage type — recognised so it can't re-trigger infection.
local INFECTION_DAMAGE_TYPE = "zomtorio-infection"

-- Aim to visit each infected entity roughly this often (ticks). The elapsed-time
-- DoT keeps timing exact regardless, so this is purely a UPS-smoothing knob
-- (R-CONT-7 spirit): spread the set's processing across this many ticks.
local PROCESS_PERIOD = 30

-- A net health gain above this (HP) while infected counts as a real heal -> cure
-- (R-PINF-5). Small enough to ignore float noise from setting absolute health.
local HEAL_EPSILON = 0.5

--------------------------------------------------------------------- storage
-- storage.zomtorio.infection.infected : unit_number -> { entity = <LuaEntity>,
--                                                         last_tick = <tick> }
-- storage.zomtorio.infection.cursor   : saved next() key for round-robin sweep.

local function state()
  storage.zomtorio = storage.zomtorio or {}
  local z = storage.zomtorio
  z.infection = z.infection or {}
  local inf = z.infection
  inf.infected = inf.infected or {}
  inf.cursor = inf.cursor or nil
  return inf
end

-- storage.zomtorio.player_infection : character unit_number -> { character =
--   <LuaEntity>, floor_health = <number> }. Keyed on the character entity (not a
--   LuaPlayer) so it works headless with no connected players. `floor_health` is
--   the health we last set along the DoT trajectory — the baseline for both
--   regen-suppression and heal-detection.
local function player_state()
  storage.zomtorio = storage.zomtorio or {}
  local z = storage.zomtorio
  z.player_infection = z.player_infection or {}
  return z.player_infection
end

-- Idempotent: only creates missing tables, never wipes live state — control.lua
-- runs this on BOTH new game and on_configuration_changed, so a mod update must
-- not orphan the infected set already present in an existing save.
function infection.on_init()
  state()
  player_state()
end

--------------------------------------------------------------------- overrides
-- Runtime-global settings can only be written by their owning mod, so the test
-- harness (a separate mod) can't drive them; these single internal hooks let a
-- test pin the setting / time-to-death deterministically. nil -> live setting.
local enabled_override
local player_enabled_override
local ticks_override

local function enabled()
  if enabled_override ~= nil then return enabled_override end
  return config.building_infection_enabled()
end

local function player_enabled()
  if player_enabled_override ~= nil then return player_enabled_override end
  return config.player_infection_enabled()
end

local function infection_ticks()
  if ticks_override ~= nil then return ticks_override end
  return config.infection_ticks()
end

--------------------------------------------------------------------- helpers

--- The enemy (infected) force, or nil if it somehow doesn't exist.
local function enemy_force()
  return game.forces[util.ENEMY_FORCE]
end

--- Can this entity be infected at all? Valid, identifiable (unit_number),
--- destructible, not on the enemy force, and not an excluded type (walls/gates
--- per R-INF-2/R-DEATH-3; characters are S5; units are zombies themselves).
local function is_infectable(entity)
  if not (entity and entity.valid) then return false end
  if not entity.unit_number then return false end
  if util.is_enemy_force(entity.force) then return false end
  local t = entity.type
  if t == "wall" or t == "gate" or t == "character" or t == "unit" then return false end
  if (entity.max_health or 0) <= 0 then return false end
  return true
end

--- Apply elapsed-time DoT to one infected record. Returns false if the record
--- should be dropped (invalid / cured / it died), true if it remains infected.
local function process(rec, now)
  local e = rec.entity
  if not (e and e.valid) then return false end

  -- Cure check BEFORE damage: a fully-repaired entity clears (R-INF-5). This must
  -- precede the DoT, else repair-to-max would never be observed (we'd re-damage
  -- it on the same visit). The infecting seed (see infect()) guarantees a freshly
  -- infected entity is below max, so this can't cure it spuriously.
  if e.get_health_ratio() >= 1 then return false end

  local ticks = infection_ticks()
  if ticks and ticks > 0 then
    local dt = now - rec.last_tick
    if dt > 0 then
      local dmg = e.max_health * dt / ticks
      rec.last_tick = now
      e.damage(dmg, enemy_force(), INFECTION_DAMAGE_TYPE)
      -- damage() may have killed it; the resulting on_entity_died (enemy-caused)
      -- drives the spawn elsewhere. Drop our record either way.
      if not e.valid then return false end
    end
  end
  return true
end

--------------------------------------------------------------------- public

--- Infect an entity now (public — also called by contagion in S6). Idempotent:
--- already-infected or non-infectable entities are no-ops. Applies one tiny seed
--- of DoT so health drops just below max, so the repair-cure check can't fire on
--- a freshly-infecting hit that the engine fully resisted.
function infection.infect(entity)
  if not is_infectable(entity) then return end
  local inf = state()
  local un = entity.unit_number
  if inf.infected[un] then return end  -- idempotent

  local now = game.tick
  inf.infected[un] = { entity = entity, last_tick = now }

  -- Seed: nudge health just below max so a fully-healthy infected entity is
  -- never mistaken for "fully repaired" on its first process.
  if entity.get_health_ratio() >= 1 then
    entity.damage(1, enemy_force(), INFECTION_DAMAGE_TYPE)
  end
end

--- Is this entity currently infected? (Read by contagion.)
function infection.is_infected(entity)
  if not (entity and entity.valid and entity.unit_number) then return false end
  return state().infected[entity.unit_number] ~= nil
end

--- Is this character currently player-infected (R-PINF)?
function infection.is_player_infected(character)
  if not (character and character.valid and character.unit_number) then return false end
  return player_state()[character.unit_number] ~= nil
end

--- True if this damage event was caused by the enemy (infected) force: either the
--- damaging force IS the enemy force, or the (valid) cause entity is on it.
local function is_enemy_caused(event)
  if util.is_enemy_force(event.force) then return true end
  local cause = event.cause
  return cause and cause.valid and util.is_enemy_force(cause.force) or false
end

--- Mark a character infected now (R-PINF-2). Idempotent; baseline `floor_health`
--- is the character's current (post-bite) health.
local function infect_character(character)
  local ps = player_state()
  local un = character.unit_number
  if ps[un] then return end  -- idempotent
  ps[un] = { character = character, floor_health = character.health }
end

--- Player (character) bite path of on_entity_damaged. Caller guarantees the
--- self-DoT early-out and planets guard already ran.
local function on_character_damaged(event)
  if not player_enabled() then return end  -- R-PINF-1
  local entity = event.entity
  -- A valid character not on the enemy force (zombies are characters? no — units;
  -- but never infect an enemy-force character defensively).
  if util.is_enemy_force(entity.force) then return end
  if not is_enemy_caused(event) then return end
  -- Health-damage signal: the hit actually reduced health. A bite fully absorbed
  -- by shields deals 0 health damage (final_damage_amount == 0) -> no infection
  -- (R-PINF-3). (Sim note: shields intercept before the health-damage event, so
  -- final_damage_amount > 0 is the spec-faithful "took a real bite" check.)
  if not (event.final_damage_amount and event.final_damage_amount > 0) then return end
  infect_character(entity)
end

--- Infect-on-hit. Dispatches by entity type: characters take the player path
--- (R-PINF), everything else the building path (R-INF).
function infection.on_entity_damaged(event)
  -- Never let our own DoT re-trigger infection (applies to BOTH paths).
  if event.damage_type and event.damage_type.name == INFECTION_DAMAGE_TYPE then return end

  local entity = event.entity
  if not (entity and entity.valid) then return end
  if not planets.is_active(entity.surface) then return end  -- R-SCOPE-1

  if entity.type == "character" then
    on_character_damaged(event)
    return
  end

  -- Building path (R-INF).
  if not enabled() then return end  -- R-INF-1
  if not is_enemy_caused(event) then return end
  if not is_infectable(entity) then return end  -- R-INF-2/6
  infection.infect(entity)
end

--- Throttled round-robin sweep (R-CONT-7 spirit). Process a slice of the
--- infected set each tick, sized so each entity is visited ~every PROCESS_PERIOD
--- ticks (with one infected, that's every tick). The elapsed-time DoT keeps
--- timing exact whatever the slice size.
--- Per-tick player DoT (R-PINF-2/4/5). Few characters, so no bucketing: process
--- every infected character every tick. For each record:
---   1. invalid character    -> drop.
---   2. health rose > floor+EPSILON (a real heal) -> CURE: drop, leave it alone.
---   3. otherwise apply one tick of DoT off the floor (discarding any passive
---      regen above it -> regen-suppression), setting absolute health. If that
---      would kill it, .die(); else record the new floor.
local function process_players(now)
  local ps = player_state()
  for un, rec in pairs(ps) do
    local c = rec.character
    if not (c and c.valid) then
      ps[un] = nil
    elseif c.health > rec.floor_health + HEAL_EPSILON then
      ps[un] = nil  -- net heal -> cure (R-PINF-5); leave the character healed
    else
      local ticks = infection_ticks()
      if ticks and ticks > 0 then
        -- Base off the lower of current/floor: passive regen above the floor is
        -- discarded (R-PINF-4); external extra damage below it is respected.
        local base = math.min(c.health, rec.floor_health)
        local dot = c.max_health / ticks
        local new = base - dot
        if new <= 0 then
          local ok = pcall(function() c.die(enemy_force()) end)
          if not ok and c.valid then c.die() end
          ps[un] = nil
        else
          c.health = new
          rec.floor_health = new
        end
      end
    end
  end
end

function infection.on_tick(event)
  local now_p = (event and event.tick) or game.tick
  process_players(now_p)

  local inf = state()
  local infected = inf.infected

  -- Cheap count of the set (Lua has no O(1) size for a sparse table; the set is
  -- small in practice and this is once per tick).
  local count = 0
  for _ in pairs(infected) do count = count + 1 end
  if count == 0 then return end

  local now = (event and event.tick) or game.tick
  local slice = math.ceil(count / PROCESS_PERIOD)

  local key = inf.cursor
  for _ = 1, slice do
    -- Resume the round-robin; wrap to the start when we run off the end.
    local un, rec = next(infected, key)
    if un == nil then
      un, rec = next(infected, nil)
      if un == nil then break end  -- emptied mid-sweep
    end
    key = un
    if not process(rec, now) then
      -- Advance the cursor PAST the entry we're about to remove, so the removal
      -- doesn't strand next()'s key.
      key = next(infected, un)
      infected[un] = nil
    end
  end
  inf.cursor = key
end

--------------------------------------------------------------------- test API

--- Test-only: pin (or, with nil, release) the building-infection enabled flag.
function infection.set_enabled_override(v)
  enabled_override = v
end

--- Test-only: pin (or, with nil, release) the player-infection enabled flag.
function infection.set_player_enabled_override(v)
  player_enabled_override = v
end

--- Test-only: pin (or, with nil, release) the time-to-death in ticks.
function infection.set_ticks_override(n)
  ticks_override = n
end

--- Test-only: hard-reset all bookkeeping. Production on_init is intentionally
--- idempotent (preserves live state across a config change), so tests that need
--- a clean slate between cases call this instead.
function infection.reset_state()
  storage.zomtorio = storage.zomtorio or {}
  storage.zomtorio.infection = { infected = {}, cursor = nil }
  storage.zomtorio.player_infection = {}
end

return infection
