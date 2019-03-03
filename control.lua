
local pollution = require("libs/pollution")
local zombies = require("libs/zombies")


script.on_event({defines.events.on_tick},
   function (event)
       pollution.check_pollution()
       zombies.on_tick(event)
   end
)

local function onInit()
  global.main_surface = game.surfaces['nauvis']
  pollution.init()
  zombies.init()
  for _, player in ipairs(game.connected_players) do
    player.insert{name="burner-mining-drill", count=100}
  end
end

script.on_init(onInit)
