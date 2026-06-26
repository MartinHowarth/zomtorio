-- S6 — infection contagion: spread along the flow of goods (R-CONT).
--
-- Three vectors, all bounded by a single fixed per-tick work budget K so spread
-- can slow but the frame rate never does (R-CONT-7):
--   * Movers (inserters/loaders/mining drills): a throttled round-robin sweep
--     over a maintained registry. An actively-transferring mover whose source is
--     infected (or which is itself infected) infects itself and its drop target.
--   * Belts: an infected belt that has items on it spreads downstream via
--     belt_neighbours on a travel-time timer that is shorter on faster belts.
--     The frontier is the SET of infected belts pending spread, seeded by an
--     infection listener (any belt that becomes infected by any means lands here).
--   * Fluids: any infected entity with a fluidbox (pipe, tank, pump, OR a
--     fluid-emitting machine like a refinery/boiler) holding fluid spreads to ALL
--     its fluid-connected neighbours (no readable flow direction) on a short fixed
--     timer. A parallel frontier, seeded by the same infection listener.
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

-- Any infected entity WITH A FLUIDBOX seeds the pipe-spread frontier — not just
-- pipes/tanks/pumps but refineries, chemical plants, boilers, fluid-recipe assemblers,
-- etc. So an infected machine that emits (or holds) fluid passes infection to the
-- pipes attached to it, and vice-versa. Detected at infect-time via has_fluidbox().

-- Max fluidboxes to scan per entity when spreading (safety cap; even a refinery has
-- only a handful). Factorio 2.1 removed LuaEntity.fluidbox/.neighbours — fluid is
-- accessed directly on the entity now — so there's no count member; we just scan
-- indices until get_fluid_box_neighbours errors on an out-of-range one.
local MAX_FLUIDBOXES = 8

-- Pipes have no exposed flow rate, so we can't scale the spread delay by speed the
-- way belts do (belt_speed). Fluid equalises across a connected segment quickly, so
-- use a short fixed travel time before an infected pipe spreads to its neighbours.
local PIPE_DELAY = 15

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

-- A conduit is sampled only periodically (every ~delay ticks), so a belt that is
-- actually flowing can read empty in the instant we look (gap between items) and we
-- would miss it. To avoid that without sampling more often (which would cost UPS), we
-- remember the last tick a conduit was seen carrying and treat it as still active for
-- this window after — so spread keeps up with intermittent flow. Perf-free: it's just
-- a stored timestamp, no extra scanning.
local ACTIVE_WINDOW = 180

--------------------------------------------------------------------- storage
-- storage.zomtorio.contagion.movers       : unit_number -> LuaEntity (registry)
-- storage.zomtorio.contagion.mover_cursor : saved next() key, round-robin sweep
-- storage.zomtorio.contagion.belts        : unit_number -> { entity, spread_at }
--                                            (the FRONTIER of infected belts)
-- storage.zomtorio.contagion.belt_cursor  : saved next() key for the belt sweep
-- storage.zomtorio.contagion.pipes        : unit_number -> { entity, spread_at }
--                                            (the FRONTIER of infected pipes)
-- storage.zomtorio.contagion.pipe_cursor  : saved next() key for the pipe sweep

local function state()
  storage.zomtorio = storage.zomtorio or {}
  local z = storage.zomtorio
  z.contagion = z.contagion or {}
  local c = z.contagion
  c.movers = c.movers or {}
  c.mover_cursor = c.mover_cursor or nil
  c.belts = c.belts or {}
  c.belt_cursor = c.belt_cursor or nil
  c.pipes = c.pipes or {}
  c.pipe_cursor = c.pipe_cursor or nil
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

--- True if the entity has at least one fluidbox (pipe, tank, pump, OR a fluid
--- machine like a refinery/chem-plant/boiler). 2.1 has no fluidbox count member, so
--- we probe: get_fluid_box_neighbours(1) succeeds iff fluidbox #1 exists, errors
--- otherwise. Called only at infect-time, not per tick.
local function has_fluidbox(entity)
  return (pcall(entity.get_fluid_box_neighbours, 1))
end

--- The infection listener: when ANY conduit-like entity becomes infected (mover
--- drop, enemy bite, or upstream spread), add it to the appropriate spread frontier
--- with its own travel-time timer. Belts → belt frontier; anything with a fluidbox
--- (pipes, tanks, pumps, and fluid-emitting machines) → pipe frontier. Idempotent on
--- the unit_number.
local function on_infected(entity)
  if not (entity and entity.valid) then return end
  local un = entity.unit_number
  if not un then return end
  local c = state()
  if BELT_TYPE_SET[entity.type] then
    if c.belts[un] then return end  -- already pending
    c.belts[un] = { entity = entity, spread_at = game.tick + belt_delay(entity) }
  elseif has_fluidbox(entity) or entity.type == "fluid-wagon" then
    -- A fluid wagon has no queryable fluidbox topology (has_fluidbox is false), but
    -- an infected wagon must still spread to the pump docked at it — so route it into
    -- the pipe frontier explicitly; spread_pipe_all has a wagon branch (wagon -> pump).
    if c.pipes[un] then return end
    c.pipes[un] = { entity = entity, spread_at = game.tick + PIPE_DELAY }
  end
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
  c.pipes[un] = nil
end

--------------------------------------------------------------------- mover step

-- A mover with no energy is NOT transferring, even if it sits frozen mid-swing
-- with an item still in hand: R-CONT-1 spreads only on ACTIVE transfer. The engine
-- reports this as a status, so gate on it — an unpowered inserter (no_power) or an
-- unfuelled burner one (no_fuel) can't spread. (low_power is left OUT: a browning-out
-- mover is still slowly transferring.)
local NONOPERATIONAL_STATUS = {
  [defines.entity_status.no_power] = true,
  [defines.entity_status.no_fuel]  = true,
}

local function powered(m)
  return not NONOPERATIONAL_STATUS[m.status]
end

--- Resolve a mover's transfer: returns active, source, dest.
---   * inserter: active iff powered AND its hand carries an item; pickup/drop targets.
---   * mining-drill: active iff status==working; source is ore (never infected),
---     so a drill only spreads when the DRILL ITSELF is infected; drop_target dest.
---   * loader / loader-1x1: best-effort. loader_type "input" feeds the belt FROM
---     the container (source=container, dest=the connected belt); "output" feeds
---     the container FROM the belt (source=belt, dest=container). active iff powered
---     AND its transport lines carry items. NOTE: the belt side is read via
---     belt_neighbours rather than a dedicated accessor, which is a simplification —
---     inserters and drills are the priority vectors; loaders are handled simply.
local function resolve_mover(m)
  local t = m.type
  if t == "inserter" then
    local hs = m.held_stack
    local active = powered(m) and hs and hs.valid_for_read or false
    return active, m.pickup_target, m.drop_target
  elseif t == "mining-drill" then
    local active = m.status == defines.entity_status.working
    return active, nil, m.drop_target  -- source is ore: never infected
  elseif t == "loader" or t == "loader-1x1" then
    -- Presence on the loader's own transport lines == carrying, but only while powered.
    local active = false
    local n = (powered(m) and m.get_max_transport_line_index)
      and m.get_max_transport_line_index() or 0
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
  -- The cursor is saved across ticks; the entry it points at may have been removed
  -- since (a mover mined/destroyed/died via on_removed — death-by-DoT is common),
  -- and next() raises "invalid key to 'next'" on a key no longer in the table.
  -- Restart the round-robin from the top if the saved cursor went stale.
  if key ~= nil and movers[key] == nil then key = nil end
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

--------------------------------------------------------------------- pipe step

--- Does this pipe currently hold any fluid? (Presence gate, the fluid analogue of
--- belt_has_items.) get_fluid_count() with no name returns the total across the
--- entity's fluidboxes.
local function pipe_has_fluid(pipe)
  -- pcall-guarded: a fluid wagon may not expose get_fluid_count; if we can't measure
  -- presence, don't gate it out (treat as carrying), so wagon -> pump spread proceeds.
  local ok, n = pcall(function() return pipe.get_fluid_count() end)
  if not ok then return true end
  return (n or 0) > 0
end

--- Is `pos` inside `box` (a LuaEntity bounding_box), allowing `margin` tiles of slack?
--- Used to confirm a pump's serviced rail sits under a fluid wagon.
local function point_in_box(pos, box, margin)
  margin = margin or 0
  local lt = box.left_top or box[1]
  local rb = box.right_bottom or box[2]
  local lx, ly = lt.x or lt[1], lt.y or lt[2]
  local rx, ry = rb.x or rb[1], rb.y or rb[2]
  return pos.x >= lx - margin and pos.x <= rx + margin
     and pos.y >= ly - margin and pos.y <= ry + margin
end

--- Infect every fluid-connected neighbour of `conduit`, in ALL directions (a fluid
--- network has no readable flow direction). Factorio 2.1 removed LuaEntity.fluidbox /
--- .neighbours; the connections now come from LuaEntity.get_fluid_box_neighbours(i),
--- which returns { { entity = <connected entity>, index = <its fluidbox index> }, ... }
--- per fluidbox. This reports true fluid topology — adjacent pipes, the far end of a
--- pipe-to-ground across the underground gap, and connected tanks/pumps/machines — so
--- it works for any fluid entity regardless of footprint. Every infected fluid entity
--- (machines included) re-enters the pipe frontier via the infection listener
--- (has_fluidbox), so fluid infection propagates through the whole connected network.
local function spread_pipe_all(conduit)
  -- Spread DOWNSTREAM only. get_fluid_box_pipe_connections(i) gives, per connection,
  -- a flow_direction ("input" / "output" / "input-output") and the target entity.
  -- We skip pure "input" connections: spreading through one would push infection
  -- UPSTREAM, back into what feeds this entity (e.g. from a machine's input port into
  -- its supply pipe). "output" and "input-output" carry it onward. Plain pipe↔pipe
  -- connections are all "input-output", so pipe runs stay bidirectional (a pipe has no
  -- readable flow direction); only directional MACHINE ports gate the spread. This is
  -- also why a supply pipe still infects the machine it feeds: the pipe's side of that
  -- connection is "input-output", only the machine's side is "input".
  -- (LuaEntity methods are bound closures: pass ONLY the fluidbox index.)
  for i = 1, MAX_FLUIDBOXES do
    local ok, conns = pcall(conduit.get_fluid_box_pipe_connections, i)
    if not ok then break end                 -- index past this entity's fluidboxes
    if type(conns) == "table" then
      for _, conn in pairs(conns) do
        if conn.flow_direction ~= "input" then
          local nb = conn.target
          if nb and nb.valid then infection.infect(nb) end
        end
      end
    end
  end
  -- Pump <-> fluid-wagon: the transfer is NOT a fluidbox connection (the wagon shows
  -- in NEITHER get_fluid_box_pipe_connections NOR get_fluid_box_neighbours — verified
  -- in-game). But a pump DOES report the rails it services via pump_input_rail_targets
  -- / pump_output_rail_targets (2.1.7+); the serviced fluid wagon is the one sitting on
  -- one of those rails. Precise (only the actual serviced rail), and direction-agnostic
  -- (a wagon loaded via the output rail or drained via the input rail both count), like
  -- an inserter infecting a cargo wagon either way. pcall-guarded so older 2.1 (without
  -- these members) degrades gracefully to no wagon spread.
  -- Only a POWERED pump actually moves fluid to/from the wagon (same rule as movers):
  -- an unpowered pump isn't transferring, so it neither infects nor is infected by the
  -- wagon.
  if conduit.type == "pump" and powered(conduit) then
    for _, prop in ipairs({ "pump_input_rail_targets", "pump_output_rail_targets" }) do
      local ok, rails = pcall(function() return conduit[prop] end)
      if ok and type(rails) == "table" then
        for _, rail in pairs(rails) do
          if rail and rail.valid then
            local wagons = conduit.surface.find_entities_filtered {
              area = rail.bounding_box, type = "fluid-wagon",
            }
            for _, w in pairs(wagons) do
              if w.valid then infection.infect(w) end
            end
          end
        end
      end
    end
  end

  -- The REVERSE of the pump branch: an infected fluid WAGON infects the pump(s)
  -- docked at it (and the pump then spreads to its pipe). Same non-fluidbox link,
  -- read the other way: a pump services the wagon iff one of its rail targets sits
  -- under the wagon. Search pumps near the wagon, then confirm via the rail target.
  if conduit.type == "fluid-wagon" then
    local box = conduit.bounding_box
    local area = {
      { box.left_top.x - 2, box.left_top.y - 2 },
      { box.right_bottom.x + 2, box.right_bottom.y + 2 },
    }
    local pumps = conduit.surface.find_entities_filtered { type = "pump", area = area }
    for _, pump in pairs(pumps) do
      if pump.valid then
        local services = false
        for _, prop in ipairs({ "pump_input_rail_targets", "pump_output_rail_targets" }) do
          local ok, rails = pcall(function() return pump[prop] end)
          if ok and type(rails) == "table" then
            for _, rail in pairs(rails) do
              if rail and rail.valid and point_in_box(rail.position, box, 1) then
                services = true
              end
            end
          end
        end
        -- Only infect a pump that is actually pumping (powered): an unpowered pump
        -- docked at an infected wagon isn't transferring fluid, so it stays clean.
        if services and powered(pump) then infection.infect(pump) end
      end
    end
  end
end

--- Generic conduit-frontier sweep, shared by belts and pipes. Processes up to
--- `count` entries from a round-robin cursor and returns the number examined
--- (charged against the budget). `fname`/`cname` are the storage field names of the
--- frontier table and its saved cursor; `has_contents`, `spread_fn` and `delay_fn`
--- are the conduit-specific behaviour (presence gate, neighbour-infect, travel time).
---
--- A conduit is a PERSISTENT source while it stays infected (R-CONT-4): after it
--- spreads we re-arm its travel-time timer rather than dropping it, so it keeps
--- infecting conduits built (or cured-then-reinfected) downstream LATER, not just the
--- neighbours present on the first pass. Re-infecting an already-infected neighbour
--- is an idempotent no-op, and the re-armed timer stops a conduit being processed
--- twice in one sweep. Only invalid or cured conduits leave the frontier. Per-tick
--- work stays bounded by the budget (R-CONT-7).
local function sweep_frontier(c, fname, cname, count, now, has_contents, spread_fn, delay_fn)
  local frontier = c[fname]
  local key = c[cname]
  -- Saved cursor may point at an entry removed since last tick (mined/destroyed/died
  -- via on_removed); next() raises "invalid key to 'next'" on a stale key. Restart
  -- the walk from the top if so.
  if key ~= nil and frontier[key] == nil then key = nil end
  local done = 0
  -- Infecting neighbours mutates `frontier` (via the on_infected listener), which is
  -- undefined to do mid-next(); collect entries to spread and do it after the walk.
  local to_spread
  while done < count do
    local un, rec = next(frontier, key)
    if un == nil then
      un, rec = next(frontier, nil)
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
      -- Not yet its travel time, but STILL sample presence every visit so
      -- `last_active` tracks flow. A single item can ride all the way across a belt
      -- (a yellow belt tile is ~32 ticks) between two spread_at instants, so sampling
      -- only when the timer is ready would miss that lone item entirely — the belt
      -- would then need a SECOND item to be present at some later sample before it
      -- ever spread (the sluggish "needs another item" behaviour seen in play). The
      -- cost is bounded by the per-tick budget like every other visit (R-CONT-7).
      if has_contents(e) then rec.last_active = now end
    else
      -- Active if it carries now OR carried within ACTIVE_WINDOW — so intermittent
      -- flow (a gap between items at the sampling instant) doesn't stall spread
      -- without us sampling more often. (R-CONT-2/3.)
      local has = has_contents(e)
      if has then rec.last_active = now end
      if has or (rec.last_active and now - rec.last_active < ACTIVE_WINDOW) then
        to_spread = to_spread or {}
        to_spread[#to_spread + 1] = e
        rec.spread_at = now + delay_fn(e)             -- spread + re-arm (persistent)
      else
        rec.spread_at = now + BELT_RECHECK            -- idle: re-arm (R-CONT-2)
      end
    end

    if remove then
      key = next(frontier, un)
      frontier[un] = nil
    end

    done = done + 1
  end
  c[cname] = key

  if to_spread then
    for _, e in ipairs(to_spread) do
      if e.valid then spread_fn(e) end
    end
  end
  return done
end

local function pipe_delay() return PIPE_DELAY end

local function sweep_belts(c, count, now)
  return sweep_frontier(c, "belts", "belt_cursor", count, now,
    belt_has_items, spread_belt_downstream, belt_delay)
end

local function sweep_pipes(c, count, now)
  return sweep_frontier(c, "pipes", "pipe_cursor", count, now,
    pipe_has_fluid, spread_pipe_all, pipe_delay)
end

--------------------------------------------------------------------- per-tick

--- Throttled sweep: split the single budget K across the three vectors (movers,
--- belts, pipes), resuming each from its own round-robin cursor so every entry is
--- eventually visited. Each vector gets up to a third, but unspent budget (an empty
--- registry/frontier) rolls on to the next vector so nothing is wasted. Total
--- per-tick work is bounded by K (R-CONT-7) no matter how large they grow.
function contagion.on_tick(event)
  local c = state()
  local k = budget()
  local now = (event and event.tick) or game.tick

  local share = math.ceil(k / 3)
  local spent = sweep_movers(c, share)
  spent = spent + sweep_belts(c, math.min(share, k - spent), now)
  local pipe_budget = k - spent
  if pipe_budget > 0 then
    sweep_pipes(c, pipe_budget, now)
  end
end

--------------------------------------------------------------------- test API

--- Test-only: pin (or, with nil, release) the per-tick work budget K so a test
--- can prove the throttle bounds work (R-CONT-7).
function contagion.set_budget_override(n)
  budget_override = n
end

--- Debug/test accessor: sizes of the mover registry and belt/pipe frontiers (real
--- mod state), for diagnosing where a contagion chain stalls.
function contagion.debug_counts()
  local c = state()
  return { movers = table_size(c.movers), belts = table_size(c.belts),
           pipes = table_size(c.pipes) }
end

--- Test-only: hard-reset all bookkeeping. Production on_init is idempotent
--- (preserves live state across a config change); tests that need a clean slate
--- call this instead. Does NOT touch the (module-local) listener registration.
function contagion.reset_state()
  storage.zomtorio = storage.zomtorio or {}
  storage.zomtorio.contagion = {
    movers = {}, mover_cursor = nil, belts = {}, belt_cursor = nil,
    pipes = {}, pipe_cursor = nil,
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
