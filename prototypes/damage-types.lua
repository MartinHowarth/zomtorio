-- Custom damage types Zomtorio adds.
--
-- "zomtorio-infection": the per-tick damage-over-time the infection DoT applies
-- (S4). It is its own type so the infect-on-hit handler can recognise and ignore
-- our own DoT (DoT must not re-trigger infection), and because buildings have no
-- resistance to a brand-new type the DoT lands in full — making the time-to-death
-- math exact (cumulative damage over the configured ticks == max_health).
--
-- "zomtorio-zombie-melee" (S8) — the character's no-ammo attack is retyped to it
-- (prototypes/melee-retype.lua) so a player punch is unambiguous to detect. The
-- BASE punch always kills exactly one zombie (R-MELEE-1), so this type is NOT in
-- horde's multi-kill set; it is only the trigger lib/melee watches for.
--
-- "zomtorio-swarm-melee" (S8) — the bonus AoE damage the tech-gated script emits
-- when a swarm-melee punch lands. It IS a multi-kill type (joins horde's set), so
-- it is what actually mows down a swarm. Kept distinct from the trigger type so
-- the script never reacts to its own AoE (no recursion) and so it stays
-- enemy-only by construction (only ever dealt to enemy-force entities).

data:extend({
  {
    type = "damage-type",
    name = "zomtorio-infection",
  },
  {
    type = "damage-type",
    name = "zomtorio-zombie-melee",
  },
  {
    type = "damage-type",
    name = "zomtorio-swarm-melee",
  },
})
