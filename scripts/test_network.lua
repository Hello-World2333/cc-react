--[[
  Headless test for the network milestone (scripts/fixtures/network):
  async/await → event-driven state machine + the fetch bridge + useRequest.

  Boots dist/fixture-network.lua with the networkLoop task as a second
  simpleParallel task and a stubbed backend (ui.setNetworkBackend), so no
  real TCP is involved — the same job/event flow the real docs/lib HTTP
  client uses in-game:

    fetch()        → queues a job + "ccreact_net_job" event
    networkLoop()  → runs the job via the backend, queues "ccreact_net_done"
    UI event loop  → resolves the future → the await continuation runs

  Scenarios:
    1. async/await: sequential awaits run in order (backend sees /req from
       the useRequest mount fetch, then /one then /two), values flow into
       the continuations, the final state is reached
    2. error path: a failed request resolves with { ok = false, error }
    3. `await` on a non-future passes the value through (JS semantics)
    4. useRequest: fetch on mount (loading → data), refetch, stale-response
       protection (an older response cannot clobber a newer one), and no
       re-fetch on an unrelated re-render
    5. no http client: without ui.setHttpClient, every fetch resolves with
       { ok = false, error = "http client not set: ..." } through the real
       default worker path (no backend stub)

  Usage: lua5.1 scripts/test_network.lua [path-to-module.lua]
]]

-- Capture the real os.exit BEFORE the stub replaces _G.os (cc_stub.lua
-- installs a stub os for the program under test).
local realExit = os.exit

local t = require("scripts.cc_stub")
local check = t.check
local boot = t.boot
local findText = t.findText
local findButton = t.findButton
local clickButton = t.clickButton

t.MAIN = arg and arg[1] or "dist/fixture-network.lua"

-- The network worker task, composed like the main program would:
-- simpleParallel.add(function() ui.networkLoop() end)
local function networkTask()
  return function()
    t.uiMod.networkLoop()
  end
end

local function okResp(body)
  return { ok = true, status = 200, statusText = "OK", body = body }
end

-- ================= scenario 1: sequential awaits =================

print("== async/await: sequential awaits + value flow ==")
local callOrder = {}
boot({
  { eventFn = clickButton("loadBoth") },
  {
    snapshot = function()
      local tree = t.uiMod.getTree()
      check(findText(tree, "A:").text == "A: first",
        "first await's value flowed into A")
      check(findText(tree, "B:").text == "B: second",
        "second await's value flowed into B")
      check(findText(tree, "status:").text == "status: done",
        "status reached 'done' after both awaits")
      check(#callOrder == 3 and callOrder[1]:find("/req", 1, true)
        and callOrder[2]:find("/one", 1, true) and callOrder[3]:find("/two", 1, true),
        "fetches ran in order: mount /req, then /one, then /two ("
        .. table.concat(callOrder, " -> ") .. ")")
    end,
  },
}, networkTask(), function(ui)
  ui.setNetworkBackend(function(url, options)
    callOrder[#callOrder + 1] = url
    if url:find("/one", 1, true) then return okResp("first") end
    if url:find("/two", 1, true) then return okResp("second") end
    return okResp("fallback")
  end)
end)

-- ================= scenario 2: error path =================

print("== async/await: error path ==")
boot({
  { eventFn = clickButton("loadFail") },
  {
    snapshot = function()
      local statusText = findText(t.uiMod.getTree(), "status:")
      check(statusText.text == "status: failed: connection refused",
        "a failed request resolves with { ok=false, error } (got: "
        .. statusText.text .. ")")
    end,
  },
}, networkTask(), function(ui)
  ui.setNetworkBackend(function(url, options)
    if url:find("/fail", 1, true) then return nil, "connection refused" end
    return okResp("x")
  end)
end)

-- ================= scenario 3: await on a non-future =================

print("== await on a non-future passes the value through ==")
boot({
  { eventFn = clickButton("loadPlain") },
  {
    snapshot = function()
      local plain = findText(t.uiMod.getTree(), "plain:")
      check(plain.text == "plain: v=42", "awaiting a non-future passes the value (got: "
        .. plain.text .. ")")
    end,
  },
}, networkTask(), function(ui)
  ui.setNetworkBackend(function(url, options)
    return okResp("x")
  end)
end)

-- ================= scenario 4: useRequest states + stale protection =================

print("== useRequest: mount fetch, loading, refetch, stale protection ==")
local id1, id2
boot({
  -- mount fetch is in flight (deferred by the backend)
  {
    snapshot = function()
      local reqText = findText(t.uiMod.getTree(), "req:")
      check(reqText.text == "req: loading",
        "mount fetch starts in the loading state (got: " .. reqText.text .. ")")
      local jobs = t.uiMod.getNetworkJobs()
      check(#jobs == 1, "one pending network job (" .. #jobs .. ")")
      id1 = jobs[1].id
    end,
  },
  -- refetch while the first request is still pending
  { eventFn = clickButton("refetch") },
  {
    snapshot = function()
      local reqText = findText(t.uiMod.getTree(), "req:")
      check(reqText.text == "req: loading",
        "refetch re-enters the loading state (got: " .. reqText.text .. ")")
      local jobs = t.uiMod.getNetworkJobs()
      check(#jobs == 2, "two pending jobs (mount + refetch) (" .. #jobs .. ")")
      id2 = jobs[2].id
      -- resolve the NEW request first
      t.uiMod.resolveNetworkJob(id2, okResp("fresh"))
    end,
  },
  {
    snapshot = function()
      local reqText = findText(t.uiMod.getTree(), "req:")
      check(reqText.text == "req: fresh", "the newer response wins (got: "
        .. reqText.text .. ")")
      -- now the OLD request resolves late — it must be ignored
      t.uiMod.resolveNetworkJob(id1, okResp("stale"))
    end,
  },
  {
    snapshot = function()
      local reqText = findText(t.uiMod.getTree(), "req:")
      check(reqText.text == "req: fresh",
        "a stale response cannot clobber a newer one (got: " .. reqText.text .. ")")
    end,
  },
  -- an unrelated re-render must not re-fetch (deps unchanged)
  { eventFn = clickButton("count+") },
  {
    snapshot = function()
      local jobs = t.uiMod.getNetworkJobs()
      check(#jobs == 0, "an unrelated re-render does not re-fetch (" .. #jobs .. " pending)")
      local cnt = findText(t.uiMod.getTree(), "count:")
      check(cnt.text == "count: 1", "count updated (got: " .. cnt.text .. ")")
    end,
  },
}, networkTask(), function(ui)
  ui.setNetworkBackend(function(url, options)
    if url:find("/req", 1, true) then
      return false -- defer: resolved manually via resolveNetworkJob
    end
    return okResp("fallback")
  end)
end)

-- ================= scenario 5: no http client =================

print("== no http client reports a clear error ==")
-- No backend and no ui.setHttpClient: the worker's default path reports
-- the missing client and every fetch resolves with { ok = false, error }.
boot({
  {
    snapshot = function()
      local reqText = findText(t.uiMod.getTree(), "req:")
      check(reqText.text:find("http client not set", 1, true) ~= nil,
        "without setHttpClient, fetch resolves with a clear error (got: "
        .. reqText.text .. ")")
    end,
  },
}, networkTask())

print("")
if t.failures == 0 then
  print("ALL TESTS PASSED")
  realExit(0)
else
  print(t.failures .. " TEST(S) FAILED")
  realExit(1)
end
