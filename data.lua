-- Data stage: register all NEW prototypes Zomtorio adds.
-- Tuning of EXISTING base prototypes (biters, spawners, the character's melee)
-- happens in data-final-fixes.lua, so it runs after base/Space Age have loaded.
--
-- Each require below owns one concern; files are no-ops until their stage lands.

require("prototypes.damage-types")   -- S8: the "zombie-melee" damage type
require("prototypes.entities")       -- S2: horde-unit entities (cluster tiers)
require("prototypes.items")          -- S7: corpse + kiln-dried corpse items
require("prototypes.recipes")        -- S7: kiln recipe (fallback corpse-kiln)
require("prototypes.technology")     -- S8: melee upgrade technologies
require("prototypes.shortcuts")      -- S8: double-tap per-player toggle
