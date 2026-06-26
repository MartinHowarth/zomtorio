# Zomtorio

**Turns Factorio's biters into an overwhelming zombie horde.** Enemies come in far
larger numbers and are individually much weaker - a swarm to be mown down, not a
handful of bullet-sponges. Your destroyed buildings become sources of new zombies,
infection creeps through your factory along the flow of goods, and the dead don't
always stay dead.

## Trailer

<video src="zomtorio-trailer-480p.mp4" controls width="100%">
  Your viewer can't play the embedded video -
  <a href="zomtorio-trailer-480p.mp4">watch the trailer</a> directly.
</video>

[▶ Watch the trailer](zomtorio-trailer-480p.mp4)

## Features at a glance

- **Swarm hordes** - enemies are weak, slow, and tightly packed, but vastly more numerous; huge numbers are represented cheaply by "horde unit" clusters under a configurable active-zombie cap.
- **Buildings become zombie sources** - a building the horde destroys spawns zombies equal to its total raw resource cost; walls/gates exempt; your own demolition never spawns anything.
- **Infection + contagion** - a horde hit infects a building/robot (damage-over-time, cured by full repair) and spreads downstream through the factory along the flow of goods (inserters, loaders, drills, belts), bounded so it never costs UPS.
- **Player infection** - bites that get through your shields infect you; regen is suppressed until any heal cures it.
- **Biohazard alt-mode marker** - infected buildings show a red biohazard warning triangle in alt-mode (like the frozen/no-power icons), with no effect on operation.
- **Corpses & reanimation** - kills drop burnable corpses that reanimate into zombies (spoilage) wherever they sit; kiln-dry them to store safely, at a fuel loss. Fire/explosions leave no corpse.
- **Melee tech + Double Tap** - researchable swarm multi-kill (two tiers) and a toggle for clean, corpse-free melee kills.
- **Night & swarm events** - zombies move faster at night; telegraphed, evolution-scaling swarm events strike at night on top of pollution-driven attacks.
- **Denser, cheaper enemies** - pollution recruits far more attackers, nests and expansion are cranked up, all tunable.
- **Fully configurable** - see the settings table below.

## What changes

### The horde
- Enemies are weak, slow, pack tightly, and pursue relentlessly once they have your
  scent - but there are *far* more of them.
- Huge numbers stay cheap: a **horde unit** is a single entity that stands in for a
  whole cluster of zombies, carrying a population count. Hit one and it either
  bursts into individual zombies (if there's room under the active-zombie cap and
  you're nearby) or simply loses population. Explosives and upgraded melee kill many
  at once.
- A configurable **active-zombie cap** keeps UPS in check: overflow folds into
  abstract clusters instead of being discarded, so the zombies still exist.

### Buildings become zombie sources
- When the horde destroys one of your buildings, it spawns zombies equal to the
  building's **total raw resource cost** (1 zombie per unit of mined ore). Bigger,
  costlier buildings make bigger hordes. Walls and gates are exempt.
- Destroying your *own* buildings (mining, deconstruction, your own weapons) never
  spawns zombies.

### Infection
- A single hit from the horde infects a building, robot, belt, or inserter: it takes
  damage over time and, if it dies, spawns zombies. **Fully repairing it cures it.**
- Infection **spreads through the factory along the flow of goods** - inserters,
  loaders and mining drills carry it downstream when they move items from an infected
  source, and belts carry it along their length while items ride them. A part of the
  factory with no item movement doesn't spread it. "Let it all die and rebuild" is a
  valid (brutal) containment strategy.
- **You** get infected too if a zombie bites through your health (shields protect
  you). Infection suppresses your natural regen - but any real heal (a fish, a
  medikit, anything) clears it.

### Corpses
- Killed zombies drop a **corpse item** that's burnable as fuel - the reward for
  fighting this enemy. But corpses **reanimate** into new zombies on a timer
  (spoilage), wherever they sit: ground, belts, chests, machines. Burn them or
  **kiln-dry** them (a non-spoiling, store-forever form, at a deliberate fuel loss)
  before they hatch.
- Zombies killed by **fire or explosives** are destroyed outright and leave no corpse.

### Melee & technology
- Your bare-handed punch kills one zombie, as in vanilla. Two technologies grow it:
  **Tier 1** (automation science) lets melee multi-kill a swarm; **Tier 2** (with
  logistic science) hits harder and unlocks **Double Tap** - a toggle that makes
  your melee kills "dead-dead" (no corpse, no reanimation) at the cost of the fuel.

### Night & swarm events
- Zombies move faster at night (configurable).
- **Telegraphed swarm events** ("a swarm approaches in N days") strike at night and
  grow with evolution - rarer and brief early on, frequent and lasting the whole
  night at full evolution - layered on top of the usual pollution-driven attacks.

## Settings

| Setting | Default | Effect |
|---|---|---|
| Horde size multiplier | 1.0 | Overall multiplier on zombies generated. |
| Active zombie cap | 1000 | Max individual zombies; overflow becomes clusters (CPU tuning). |
| Building infection | on | Buildings hit by the horde become infected. |
| Infection time-to-death | 300 s | Time for an infected building (full health) to die (30 s–10 min). |
| Post-repair immunity | 15 s | After a cure, how long an entity resists re-infection (0 disables). |
| Player infection | on | Bites infect you; healing cures it. |
| Night speedup | +100% | How much faster zombies move at night (startup). |
| Corpse reanimation | on | Corpses spoil into zombies (startup). |
| Reanimation time | 10 min | How long a corpse takes to reanimate (startup). |
| Bot corpse collection | on | Construction bots mark dropped corpses for collection. |
| Pollution cost per zombie | 0.05× | Lower = pollution recruits far more attackers (startup). |
| Nest spawn rate | 2.0× | How much faster nests produce enemies (startup). |
| Base expansion rate | 2.0× | How aggressively bases expand. |
| Night assault escalation | 1.5× | How much larger night attacks are. |
| Swarm events | on | Telegraphed escalating night assaults. |
| Swarm intensity / frequency | 1.0× | Scale event spawn rate/duration and how often they occur. |

Settings marked *(startup)* bake into prototypes and need a restart to change.

## Development

The mod has an automated, headless test suite - see [`test/README.md`](test/README.md).
Run it with `./test/run-tests.sh`.
