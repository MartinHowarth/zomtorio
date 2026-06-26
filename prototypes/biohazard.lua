-- Alt-mode biohazard marker drawn over infected buildings (a red warning
-- triangle with a black biohazard symbol). Rendered at runtime by lib/infection
-- via rendering.draw_sprite with only_in_alt_mode = true, so — like the
-- frozen/unpowered status icons — it shows only while the player holds Alt and
-- never affects the building's operation.

data:extend({
  {
    type = "sprite",
    name = "zomtorio-biohazard",
    filename = "__Zomtorio__/graphics/biohazard.png",
    width = 64,
    height = 64,
    flags = { "icon" },
  },
})
