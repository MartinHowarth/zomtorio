-- Test-harness entry point. Loaded only when the zomtorio-tests mod is enabled
-- (test runs). Registers all specs, then starts the tick scheduler.
local runner = require("harness.runner")
require("tests.all")
runner.start()
