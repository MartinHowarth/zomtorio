-- S1 — total-raw cost decomposition.
--
-- The runtime API exposes a recipe's direct ingredients but NOT its fully
-- decomposed "total raw" cost (the recipe-tooltip figure). We compute it once
-- per entity by recursively expanding producing recipes down to raw resources,
-- and cache the result in storage (computed at on_init / on_configuration_changed).
--
-- Returns, per entity prototype: a count of solid mined raws (iron/copper/stone/
-- coal/uranium ore — 1 zombie each, R-DEATH-2) and whether any fluid (notably
-- oil) is involved (feeds zombie tier, R-DEATH-4). Fluids do not add to the count.

local raw_cost = {}

-- Filled in at S1.
function raw_cost.on_init() end
function raw_cost.on_configuration_changed() end

--- @return integer solid_count, boolean has_oil
function raw_cost.for_entity(entity_name) return 0, false end

return raw_cost
