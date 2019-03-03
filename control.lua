
local pollution = require("libs/pollution")
local zombies = require("libs/zombies")


script.on_event({defines.events.on_tick},
   function (event)
       --pollution.check_pollution()
       --zombies.on_tick(event)
   end
)

local function onInit()
  global.main_surface = game.surfaces['nauvis']
  global.player = nil
  --pollution.init()
  --zombies.init()
end

script.on_init(onInit)
