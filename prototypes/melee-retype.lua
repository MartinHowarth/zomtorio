-- S8 — retype the character's melee attack to the custom "zomtorio-zombie-melee"
-- damage type so a player punch is unambiguous to detect at runtime (and can be
-- made enemy-only / multi-kill by the tech-gated script in lib/melee.lua).
--
-- FIELD FOUND: data.raw.character.character.tool_attack_result — a "direct"
-- attack whose action_delivery.target_effects carries the damage effect:
--   tool_attack_result.action_delivery.target_effects = {
--     type = "damage", damage = { amount = 8, type = "physical" } }
-- target_effects may be a single effect table OR an array of effect tables, so we
-- walk it defensively and retype every "damage" effect's type, keeping the amount.

local function retype_damage_effects(effects)
  if type(effects) ~= "table" then return end
  -- A single effect: it has a `type` key directly.
  if effects.type then
    if effects.type == "damage" and effects.damage then
      effects.damage.type = "zomtorio-zombie-melee"
    end
    return
  end
  -- Otherwise it's an array of effects.
  for _, eff in pairs(effects) do
    retype_damage_effects(eff)
  end
end

local character = data.raw.character and data.raw.character.character
if character and character.tool_attack_result then
  local delivery = character.tool_attack_result.action_delivery
  if delivery then
    -- action_delivery may itself be a single delivery or an array.
    if delivery.target_effects then
      retype_damage_effects(delivery.target_effects)
    else
      for _, d in pairs(delivery) do
        if type(d) == "table" and d.target_effects then
          retype_damage_effects(d.target_effects)
        end
      end
    end
  end
end
