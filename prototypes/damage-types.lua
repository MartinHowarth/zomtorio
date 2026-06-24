-- Custom damage types Zomtorio adds.
--
-- "zomtorio-infection": the per-tick damage-over-time the infection DoT applies
-- (S4). It is its own type so the infect-on-hit handler can recognise and ignore
-- our own DoT (DoT must not re-trigger infection), and because buildings have no
-- resistance to a brand-new type the DoT lands in full — making the time-to-death
-- math exact (cumulative damage over the configured ticks == max_health).
--
-- "zomtorio-zombie-melee" (S8) — the character's no-ammo attack is retyped to it
-- so upgraded swarm-melee hits are unambiguous to detect and can be made
-- enemy-only. Added in its own stage.

data:extend({
  {
    type = "damage-type",
    name = "zomtorio-infection",
  },
})
