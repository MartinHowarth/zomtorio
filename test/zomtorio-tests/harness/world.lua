-- Helpers for building test factories programmatically.
--
-- Everything here is just thin sugar over the runtime API (create_entity,
-- insert, get_transport_line, ...). The point is that "build a factory" in a
-- test is: place entities, wire them with belts/inserters, insert starter
-- items, advance ticks, then read state back.

local world = {}

--- Destroy all non-character entities in a box around `center` so a test starts
--- from a clean slate at its origin.
function world.clear(surface, center, radius)
  radius = radius or 24
  -- Test origins can land in ungenerated chunks; force them to exist first so
  -- set_tiles / create_entity have real ground to work with.
  surface.request_to_generate_chunks(center, math.ceil(radius / 32) + 1)
  surface.force_generate_chunk_requests()
  local area = {
    { center.x - radius, center.y - radius },
    { center.x + radius, center.y + radius },
  }
  for _, e in pairs(surface.find_entities_filtered { area = area }) do
    if e.valid and e.type ~= "character" then e.destroy() end
  end
  -- ensure ground is buildable (remove water/cliffs by forcing grass)
  local tiles = {}
  for x = center.x - radius, center.x + radius do
    for y = center.y - radius, center.y + radius do
      tiles[#tiles + 1] = { name = "grass-1", position = { x = x, y = y } }
    end
  end
  surface.set_tiles(tiles, true)
end

--- Place an entity. opts: { force, direction, recipe }.
function world.place(surface, name, position, opts)
  opts = opts or {}
  local e = surface.create_entity {
    name = name,
    position = position,
    force = opts.force or "player",
    direction = opts.direction,
    raise_built = opts.raise_built ~= false, -- raise events by default
  }
  if e and opts.recipe then e.set_recipe(opts.recipe) end
  return e
end

--- Place a straight run of belts of `length` tiles from `start` in `direction`.
--- Returns the list of belt entities.
function world.belt_line(surface, start, direction, length, name)
  name = name or "transport-belt"
  local dx, dy = 0, 0
  if direction == defines.direction.east then dx = 1
  elseif direction == defines.direction.west then dx = -1
  elseif direction == defines.direction.south then dy = 1
  else dy = -1 end
  local belts = {}
  for i = 0, length - 1 do
    belts[#belts + 1] = world.place(surface, name,
      { x = start.x + dx * i, y = start.y + dy * i }, { direction = direction })
  end
  return belts
end

function world.insert(entity, name, count)
  return entity.insert { name = name, count = count or 1 }
end

--- Count items of `name` anywhere in the entity's inventories.
function world.count(entity, name)
  return entity.get_item_count(name)
end

--- Total count of `name` across both lines of a transport belt.
function world.belt_count(belt, name)
  local total = 0
  for i = 1, 2 do
    local line = belt.get_transport_line(i)
    if line then total = total + line.get_item_count(name) end
  end
  return total
end

--- Put an item onto a belt's line (1 or 2). Returns true if it fit.
function world.belt_insert(belt, name, line_index)
  local line = belt.get_transport_line(line_index or 1)
  return line and line.insert_at_back { name = name } or false
end

return world
