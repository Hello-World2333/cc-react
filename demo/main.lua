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

-- Network stack (milestone 3): configure the IP interface + optional DNS
-- server, then run the fetch worker task (networkLoop) alongside the UI.
-- fetch() in the app (demo/App.tsx) queues a job for this worker, which runs
-- the blocking docs/lib HTTP client and reports back through an event — the
-- UI's await continuation never blocks the render loop.
--
-- Adjust the interface to your computer: side = the network card side
-- (peripheral.wrap), ip/mask/gateway = your LAN config. Omit `dns` when all
-- fetch URLs use IP literals (the demo default targets 192.168.1.50).
-- Without a network card, configureNetwork records the error and the demo's
-- Fetch button shows it on screen instead of crashing.
ui.configureNetwork({
  interfaces = {
    { side = "back", channel = 1, ip = "192.168.1.10", mask = "255.255.255.0", gateway = "192.168.1.1" },
  },
  dns = "8.8.8.8",  -- optional: DNS server for hostnames in fetch URLs
  timeout = 10,     -- HTTP timeout, seconds
})

-- The UI task: start(side) initializes the GPU, renders the first frame and
-- then loops on os.pullEvent, yielding to the parallel scheduler between
-- events. The side comes from the command line, defaulting to "left".
local side = arg and arg[1] or "left"
simpleParallel.add(function() ui.start(side) end)

-- The network worker task: processes fetch() jobs (blocking HTTP in its own
-- coroutine, so the UI stays responsive). Other network tasks (e.g. an HTTP
-- server from docs/lib) join here too:
--   simpleParallel.add(function() serverLoop() end)

simpleParallel.add(function() ui.networkLoop() end)

simpleParallel.start()
