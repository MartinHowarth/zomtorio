-- S6 — infection contagion: spread along the flow of goods (R-CONT).
--
-- Two vectors, both bounded by a single fixed per-tick work budget K so spread
-- can slow but the frame rate never does (R-CONT-7):
--   * Movers (inserters/loaders/mining drills): a throttled round-robin sweep
--     over a maintained registry. An actively-transferring mover whose source is
--     infected (or which is itself infected) infects itself and its drop target.
--   * Belts: an infected belt that has items on it spreads downstream via
--     belt_neighbours on a travel-time timer that is shorter on faster belts.
--     The frontier is the SET of infected belts pending spread, seeded by an
--     infection listener (any belt that becomes infected by any means lands here).
--
-- No self-expiry; cure is repair or death (R-CONT-4) — we simply stop spreading
-- from anything that is no longer infected/valid. Belts/pipes/inserters are
-- ordinary infectable entities (their DoT/death/zombie-spawn is S3/S4, not here);
-- contagion only decides what to NEWLY infect, by calling infection.infect.

local infection = require("lib.infection")
local planets   = require("lib.planets")

local contagion = {}

-- The mover types we sweep. loader-1x1 is the 2.1 single-tile loader variant.
local MOVER_TYPES = { "inserter", "mining-drill", "loader", "loader-1x1" }
local MOVER_TYPE_SET = {}
for _, t in ipairs(MOVER_TYPES) do MOVER_TYPE_SET[t] = true end

-- Belt-like types whose infection seeds the downstream-spread frontier.
local BELT_TYPE_SET = {
  ["transport-belt"]   = true,
  ["underground-belt"] = true,
  ["splitter"]         = true,
  ["linked-belt"]      = true,
}

-- Fixed per-tick work budget (R-CONT-7): at most this many spread-checks total
-- across BOTH vectors each tick, regardless of how big the world is. Exceeding
-- it just spreads the work over more ticks. Tunable; a test override exists.
local DEFAULT_BUDGET = 256
local budget_override

local function budget()
  return budget_override or DEFAULT_BUDGET
end

-- Belt travel-time model (R-CONT-2): the delay before an infected belt spreads
-- downstream is proportional to 1 / belt_speed, so faster (higher-tier) belts
-- spread sooner. belt_speed is tiles/tick; BELT_TILE is the notional distance the
-- goods must ride (~one belt tile) before reaching the next belt. With the
-- vanilla yellow belt at 0.03125 t/t this gives ~16 ticks; blue at 0.09375 ~6.
local BELT_TILE = 0.5

-- How long to wait before re-checking an infected belt that currently has no
-- items on it (presence gate, R-CONT-2): we don't spread an empty belt, but it
-- may carry items later, so we re-arm rather than drop it.
local BELT_RECHECK = 30

--------------------------------------------------------------------- storage
-- storage.zomtorio.contagion.movers       : unit_number -> LuaEntity (registry)
-- storage.zomtorio.contagion.mover_cursor : saved next() key, round-robin sweep
-- storage.zomtorio.contagion.belts        : unit_number -> { entity, spread_at }
--                                            (the FRONTIER of infected belts)
-- storage.zomtorio.contagion.belt_cursor  : saved next() key for the belt sweep

local function state()
  storage.zomtorio = storage.zomtorio or {}
  local z = storage.zomtorio
  z.contagion = z.contagion or {}
  local c = z.contagion
  c.movers = c.movers or {}
  c.mover_cursor = c.mover_cursor or nil
  c.belts = c.belts or {}
  c.belt_cursor = c.belt_cursor or nil
  return c
end

--------------------------------------------------------------------- helpers

--- Notional delay (ticks) before an infected belt spreads downstream. Inversely
--- proportional to belt speed, clamped to >=1 so spread always advances.
local function belt_delay(entity)
  local proto = entity.prototype
  local speed = proto and proto.belt_speed
  if not (speed and speed > 0) then return BELT_RECHECK end
  return math.max(1, math.ceil(BELT_TILE / speed))
end

--- The infection listener: when ANY belt-like entity becomes infected (mover
--- drop, enemy bite, or upstream belt), add it to the spread frontier with its
--- own travel-time timer. Idempotent on the unit_number (re-arms an existing
--- entry's timer is fine; first-seen sets it).
local function on_infected(entity)
  if not (entity and entity.valid) then return end
  if not BELT_TYPE_SET[entity.type] then return end
  local un = entity.unit_number
  if not un then return end
  local c = state()
  if c.belts[un] then return end  -- already pending
  c.belts[un] = { entity = entity, spread_at = game.tick + belt_delay(entity) }
end

--- True if `entity` is a registerable mover on the active surface.
local function is_registerable_mover(entity)
  if not (entity and entity.valid and entity.unit_number) then return false end
  if not MOVER_TYPE_SET[entity.type] then return false end
  return planets.is_active(entity.surface)
end

--------------------------------------------------------------------- registry

-- Idempotent: creates missing storage tables and tops up the mover registry by
-- scanning the active surface once, but never wipes live state. control.lua runs
-- this on BOTH new game and on_configuration_changed, so an update must not
-- orphan the registry/frontier in an existing save. Also (re)registers the
-- infection listener — add_infect_listener is itself idempotent on the fn, so
-- running on_init again on a config change does not double-register.
function contagion.on_init()
  local c = state()

  infection.add_infect_listener(on_infected)

  -- One-time mover scan of the active surface. find_entities_filtered is costly
  -- and used ONLY here (never per-tick); on_built keeps the registry current
  -- afterwards.
  if game and game.surfaces then
    for _, surface in pairs(game.surfaces) do
      if planets.is_active(surface) then
        local found = surface.find_entities_filtered { type = MOVER_TYPES }
        for _, e in pairs(found) do
          if e.valid and e.unit_number then
            c.movers[e.unit_number] = e
          end
        end
      end
    end
  end
end

--- A mover (and only a mover) joins the registry when built on the active surface.
function contagion.on_built(event)
  local e = event and event.entity
  if not is_registerable_mover(e) then return end
  state().movers[e.unit_number] = e
end

--- Any removal (mined/destroyed/died) drops the entity from both the mover
--- registry and the belt frontier. The event entity's unit_number is still
--- readable here (the engine fires this before the entity is fully gone).
function contagion.on_removed(event)
  local e = event and event.entity
  if not e then return end
  local un = e.unit_number
  if not un then return end
  local c = state()
  c.movers[un] = nil
  c.belts[un] = nil
end

--------------------------------------------------------------------- mover step

--- Resolve a mover's transfer: returns active, source, dest.
---   * inserter: active iff its hand carries an item; pickup/drop targets.
---   * mining-drill: active iff status==working; source is ore (never infected),
---     so a drill only spreads when the DRILL ITSELF is infected; drop_target dest.
---   * loader / loader-1x1: best-effort. loader_type "input" feeds the belt FROM
---     the container (source=container, dest=the connected belt); "output" feeds
---     the container FROM the belt (source=belt, dest=container). active iff its
---     transport lines carry items. NOTE: the belt side is read via belt_neighbours
---     rather than a dedicated accessor, which is a simplification — inserters and
---     drills are the priority vectors; loaders are handled simply.
local function resolve_mover(m)
  local t = m.type
  if t == "inserter" then
    local hs = m.held_stack
    local active = hs and hs.valid_for_read or false
    return active, m.pickup_target, m.drop_target
  elseif t == "mining-drill" then
    local active = m.status == defines.entity_status.working
    return active, nil, m.drop_target  -- source is ore: never infected
  elseif t == "loader" or t == "loader-1x1" then
    -- Presence on the loader's own transport lines == carrying.
    local active = false
    local n = m.get_max_transport_line_index and m.get_max_transport_line_index() or 0
    for i = 1, n do
      local line = m.get_transport_line(i)
      if line and line.get_item_count() > 0 then active = true; break end
    end
    local container = m.loader_container
    -- The belt this loader connects to (best-effort via belt_neighbours).
    local bn = m.belt_neighbours
    local belt = bn and ((bn.outputs and bn.outputs[1]) or (bn.inputs and bn.inputs[1])) or nil
    if m.loader_type == "output" then
      return active, belt, container       -- belt -> container
    else
      return active, container, belt        -- container -> belt
    end
  end
  return false, nil, nil
end

--- Process up to `count` movers from the round-robin cursor. Returns the number
--- actually examined (charged against the budget).
local function sweep_movers(c, count)
  local movers = c.movers
  local key = c.mover_cursor
  local done = 0
  while done < count do
    local un, m = next(movers, key)
    if un == nil then
      un, m = next(movers, nil)
      if un == nil then break end  -- registry empty
    end
    key = un

    if not (m and m.valid) then
      -- Drop invalid; advance cursor past the removed entry first.
      key = next(movers, un)
      movers[un] = nil
    else
      local active, source, dest = resolve_mover(m)
      local self_infected = infection.is_infected(m)
      local source_infected = source and infection.is_infected(source) or false
      if active and (source_infected or self_infected) then
        if source_infected then infection.infect(m) end
        if dest then infection.infect(dest) end
      end
    end

    done = done + 1
  end
  c.mover_cursor = key
  return done
end

--------------------------------------------------------------------- belt step

--- Does this belt currently carry any items? (Presence gate, R-CONT-2.)
local function belt_has_items(belt)
  local n = belt.get_max_transport_line_index and belt.get_max_transport_line_index() or 0
  for i = 1, n do
    local line = belt.get_transport_line(i)
    if line and line.get_item_count() > 0 then return true end
  end
  return false
end

--- Infect every downstream belt-connectable neighbour of `belt`. The infection
--- listener adds each to the frontier with its own timer.
local function spread_belt_downstream(belt)
  local bn = belt.belt_neighbours
  if bn and bn.outputs then
    for _, nb in pairs(bn.outputs) do
      if nb and nb.valid then infection.infect(nb) end
    end
  end
  -- The far end of an underground belt is reached via this accessor, not
  -- belt_neighbours.
  if belt.type == "underground-belt" then
    local far = belt.underground_belt_neighbour
    -- Only an INPUT underground feeds its output end downstream.
    if far and far.valid and belt.belt_to_ground_type == "input" then
      infection.infect(far)
    end
  end
  -- Linked belts hop to their paired endpoint.
  if belt.type == "linked-belt" then
    local lk = belt.linked_belt_neighbour
    if lk and lk.valid and belt.linked_belt_type == "input" then
      infection.infect(lk)
    end
  end
end

--- Process up to `count` belts from the frontier cursor. Returns the number
--- examined (charged against the budget).
---
--- An infected belt is a PERSISTENT source while it stays infected (R-CONT-4):
--- after it spreads we re-arm its travel-time timer rather than dropping it, so
--- it keeps infecting belts that are built (or cured-then-reinfected) downstream
--- LATER — not just the neighbours present on the first pass. (Dropping after one
--- spread was a bug: extending an infected line, or a belt that spread before its
--- downstream had items, would never infect the new/late belt.) Re-infecting an
--- already-infected neighbour is an idempotent no-op, and the re-armed timer stops
--- a belt being processed twice in the same sweep. Only invalid or cured belts
--- leave the frontier. Per-tick work stays bounded by the budget (R-CONT-7).
local function sweep_belts(c, count, now)
  local belts = c.belts
  local key = c.belt_cursor
  local done = 0
  -- Infecting downstream mutates `belts` (via the on_infected listener), which is
  -- undefined to do mid-next(); collect the belts to spread and do it after the walk.
  local to_spread
  while done < count do
    local un, rec = next(belts, key)
    if un == nil then
      un, rec = next(belts, nil)
      if un == nil then break end
    end
    key = un

    local e = rec.entity
    local remove = false
    if not (e and e.valid) then
      remove = true                                   -- gone (mined/destroyed)
    elseif not infection.is_infected(e) then
      remove = true                                   -- cured or died (R-CONT-4)
    elseif now < rec.spread_at then
      -- Not yet its travel time; leave it pending.
    elseif not belt_has_items(e) then
      rec.spread_at = now + BELT_RECHECK              -- empty: re-arm (R-CONT-2)
    else
      to_spread = to_spread or {}
      to_spread[#to_spread + 1] = e
      rec.spread_at = now + belt_delay(e)             -- spread + re-arm (persistent)
    end

    if remove then
      key = next(belts, un)
      belts[un] = nil
    end

    done = done + 1
  end
  c.belt_cursor = key

  if to_spread then
    for _, e in ipairs(to_spread) do
      if e.valid then spread_belt_downstream(e) end
    end
  end
  return done
end

--------------------------------------------------------------------- per-tick

--- Throttled sweep: split the single budget K between the two vectors (half to
--- movers, the remainder to belts), resuming each from its own round-robin cursor
--- so every entry is eventually visited. Total per-tick work is bounded by K
--- (R-CONT-7) no matter how large the registry/frontier grow.
function contagion.on_tick(event)
  local c = state()
  local k = budget()
  local now = (event and event.tick) or game.tick

  local mover_budget = math.ceil(k / 2)
  local spent = sweep_movers(c, mover_budget)
  -- Give belts the remaining budget (so an empty registry doesn't waste budget).
  local belt_budget = k - spent
  if belt_budget > 0 then
    sweep_belts(c, belt_budget, now)
  end
end

--------------------------------------------------------------------- test API

--- Test-only: pin (or, with nil, release) the per-tick work budget K so a test
--- can prove the throttle bounds work (R-CONT-7).
function contagion.set_budget_override(n)
  budget_override = n
end

--- Debug/test accessor: sizes of the mover registry and belt frontier (real mod
--- state), for diagnosing where a contagion chain stalls.
function contagion.debug_counts()
  local c = state()
  return { movers = table_size(c.movers), belts = table_size(c.belts) }
end

--- Test-only: hard-reset all bookkeeping. Production on_init is idempotent
--- (preserves live state across a config change); tests that need a clean slate
--- call this instead. Does NOT touch the (module-local) listener registration.
function contagion.reset_state()
  storage.zomtorio = storage.zomtorio or {}
  storage.zomtorio.contagion = {
    movers = {}, mover_cursor = nil, belts = {}, belt_cursor = nil,
  }
end

-- Register the belt-frontier listener at MODULE LOAD, not only in on_init. The
-- listener list is module-local Lua state that resets on every save load,
-- whereas on_init runs only on new game / config change — so registering solely
-- in on_init would leave the listener missing after a plain load. This append
-- touches neither game nor storage (safe at load time), and add_infect_listener
-- is idempotent, so it coexists with the on_init call.
infection.add_infect_listener(on_infected)

return contagion
