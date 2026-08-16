--[[
  cc-react demo main program.

  The compiled cc-react output (dist/ui.lua) is a MODULE, not a standalone
  program: this main program requires it and runs the UI as one task of
  simpleParallel (parallel.waitForAll), so the UI loop is non-blocking and
  future network tasks (the stack in docs/lib, e.g. an HTTP server) join the
  same scheduler.

  Deploy into a CC: Tweaked computer (root):
      ui.lua   <- dist/ui.lua          (compiled cc-react module)
      main.lua <- this file
      lib/     <- simpleParallel.lua + the network stack (docs/lib)

  Run:  lua main.lua          (GPU on 'left')
        lua main.lua right    (GPU on another side)
]]

local simpleParallel = require("lib.simpleParallel")
local ui = require("ui")

-- The UI task: start(side) initializes the GPU, renders the first frame and
-- then loops on os.pullEvent, yielding to the parallel scheduler between
-- events. The side comes from the command line, defaulting to "left".
local side = arg and arg[1] or "left"
simpleParallel.add(function() ui.start(side) end)

-- Future network tasks join here, e.g.:
--   local HTTP = require("lib.http")
--   local ip = IP.new(config)   -- register its loops too
--   simpleParallel.add(function() HTTP.createServer({ ... }) end)

simpleParallel.start()
