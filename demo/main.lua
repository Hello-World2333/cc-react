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

-- Network stack (milestone 3): the MAIN PROGRAM builds the docs/lib HTTP
-- client (it owns the IP stack config) and hands the instance to the UI
-- module. fetch() in the app (demo/App.tsx) queues a job for the networkLoop
-- worker (composed inside ui.start()), which runs this blocking client and
-- reports back through an event — the UI's await continuation never blocks
-- the render loop.
--
-- Adjust the interface to your computer: side = the network card side
-- (peripheral.wrap), ip/mask/gateway = your LAN config. Omit `dnsServer`
-- when all fetch URLs use IP literals (the demo default targets
-- 192.168.1.50). Without a network card the client build fails here and the
-- demo keeps running with fetch reporting the error on screen.
local httpClient
local okStack, stackErr = pcall(function()
  local IP = require("lib.ip")
  local HTTP = require("lib.http")
  local ipIface = IP.new({
    mode = "host",
    interfaces = {
      { side = "back", channel = 1, ip = "192.168.1.10", mask = "255.255.255.0", gateway = "192.168.1.1" },
    },
  })
  return HTTP.newClient(ipIface, {
    dnsServer = "8.8.8.8", -- optional: DNS server for hostnames in fetch URLs
    timeout = 10,          -- HTTP timeout, seconds
  })
end)
if okStack then
  ui.setHttpClient(httpClient)
else
  print("cc-react demo: network stack init failed (fetch will report errors): " .. tostring(stackErr))
end

-- The UI task: start(side) initializes the GPU, renders the first frame and
-- then loops on os.pullEvent, yielding to the parallel scheduler between
-- events. start() ALSO composes the network worker loop (networkLoop) via
-- parallel.waitForAll, so this single task covers both the UI and fetch().
-- The side comes from the command line, defaulting to "left".
local side = arg and arg[1] or "left"
simpleParallel.add(function() ui.start(side) end)

-- Other network tasks (e.g. an HTTP server from docs/lib) join here too:
--   simpleParallel.add(function() serverLoop() end)

simpleParallel.start()
