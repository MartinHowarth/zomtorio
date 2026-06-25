-- S7 — wire reanimation onto the corpse item via the spoilage system
-- (R-CORPSE-1/5). Runs at data-final-fixes so the zombie entity it spawns is
-- guaranteed to exist and the startup gate has settled.
--
-- Gated on the `zomtorio-corpse-reanimation` startup setting: when OFF the corpse
-- gets NO spoilage, becoming a stable fuel that never reanimates. When ON, each
-- corpse item in a stack spawns one zombie when it spoils, wherever it sits
-- (ground, belt, machine, chest) — that is the whole point of using spoilage.
--
-- CRITICAL: trigger-created entities default to the NEUTRAL force and would not
-- be hostile. We mirror Space Age's pentapod-egg (data.raw.item["pentapod-egg"]),
-- which hatches HOSTILE pentapods from exactly this mechanic: the create-entity
-- effect carries `as_enemy = true`, which places the new unit on the enemy force.

local corpse = data.raw.item["zomtorio-corpse"]

if corpse and settings.startup["zomtorio-corpse-reanimation"].value then
  local minutes = settings.startup["zomtorio-reanimation-minutes"].value
  corpse.spoil_ticks = math.max(1, math.floor(minutes * 3600))  -- 60 ticks/s * 60

  -- The reanimated zombie is an individual small-biter on the enemy force. The
  -- structure (direct trigger -> instant delivery -> create-entity with
  -- as_enemy) is copied from the pentapod-egg so freshly-spoiled corpses are
  -- immediately hostile, and a non-colliding-position fallback mirrors the egg's
  -- so a corpse spoiling in a tight space still hatches.
  corpse.spoil_to_trigger_result = {
    items_per_trigger = 1,
    trigger = {
      type = "direct",
      action_delivery = {
        type = "instant",
        source_effects = {
          {
            type = "create-entity",
            entity_name = "small-biter",
            affects_target = true,
            show_in_tooltip = true,
            as_enemy = true,                 -- => enemy force, hostile zombie
            -- Raise on_trigger_created_entity per hatched zombie so the runtime
            -- can route reanimations through the dynamic cap (R-HORDE-6 /
            -- R-GEN-6): under-cap ones stay individuals, overflow folds into a
            -- cluster. See lib/corpses.on_trigger_created_entity.
            trigger_created_entity = true,
            find_non_colliding_position = true,
            offset_deviation = { { -2, -2 }, { 2, 2 } },
            non_colliding_fail_result = {
              type = "direct",
              action_delivery = {
                type = "instant",
                source_effects = {
                  {
                    type = "create-entity",
                    entity_name = "small-biter",
                    affects_target = true,
                    as_enemy = true,
                    trigger_created_entity = true,
                    offset_deviation = { { -1, -1 }, { 1, 1 } },
                  },
                },
              },
            },
          },
        },
      },
    },
  }
end
