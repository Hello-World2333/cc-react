--[[
  Headless test for setTimeout and setInterval
  (scripts/fixtures/timer).

  Boots dist/fixture-timer.lua — a panel with two buttons (startTimeout,
  startInterval) and a stopInterval button — and asserts:

    1. setTimeout: clicking startTimeout sets status to 'pending', and after
       a timer event the callback fires and sets status to 'fired'
    2. setInterval: clicking startInterval starts a repeating timer that
       increments a counter on each tick
    3. clearInterval: clicking stopInterval cancels the interval and the
       counter stops incrementing

  Usage: lua5.1 scripts/test_timer.lua [path-to-module.lua]
]]

-- Capture the real os.exit BEFORE the stub replaces _G.os
local realExit = os.exit

local t = require("scripts.cc_stub")
local check = t.check
local boot = t.boot
local stub = t.stub
local findText = t.findText
local findButton = t.findButton

t.MAIN = arg and arg[1] or "dist/fixture-timer.lua"

-- helper: read the current text content of the node matching prefix
local function getStatus(prefix)
  local nodes = t.findNodes(t.uiMod.getTree(), function(n)
    return n.kind == "text" and n.text and n.text:sub(1, #prefix) == prefix
  end)
  return nodes[1] and nodes[1].text
end

-- helper: click a button by label
local function clickBtn(label)
  return function()
    local b = findButton(t.uiMod.getTree(), label)
    if not b then error("test harness: button '" .. label .. "' not found") end
    local x = b.x + math.floor(b.w / 2)
    local y = b.y + math.floor(b.h / 2)
    return { "tm_monitor_touch", x, y, false }
  end
end

-- helper: feed a timer event with a given CC timer id
local function feedTimer(id)
  return function() return { "timer", id } end
end

-- The stub's startTimer returns incrementing ids starting from 1 after each
-- boot() reset. We predict the next id by reading the counter BEFORE the
-- click. The click triggers the JS callback which calls os.startTimer once.

print("== setTimeout: fires callback after delay ==")
boot({
  {
    snapshot = function()
      local tree = t.uiMod.getTree()
      check(tree ~= nil, "boot: root tree exists")
      check(getStatus("timeout:") == "timeout: none",
        "timeout starts as 'none'")
    end,
  },
  -- Click startTimeout: this triggers setTimeout(cb, 100).
  -- os.startTimer will return CC id 1 (first call after boot reset).
  { eventFn = clickBtn("startTimeout") },
  {
    snapshot = function()
      check(getStatus("timeout:") == "timeout: pending",
        "timeout becomes 'pending' after click")
    end,
  },
  -- Feed a timer event with CC id 1 (matches the setTimeout timer)
  { eventFn = feedTimer(1) },
  {
    snapshot = function()
      check(getStatus("timeout:") == "timeout: fired",
        "timeout fires after timer event")
    end,
  },
})

print("== setInterval: repeating timer increments counter ==")
boot({
  {
    snapshot = function()
      check(getStatus("count:") == "count: 0", "interval count starts at 0")
      check(getStatus("status:") == "status: idle", "interval status starts idle")
    end,
  },
  -- Click startInterval: os.startTimer returns CC id 1
  { eventFn = clickBtn("startInterval") },
  {
    snapshot = function()
      check(getStatus("status:") == "status: running",
        "interval status becomes 'running'")
    end,
  },
  -- First tick: CC id 1
  { eventFn = feedTimer(1) },
  {
    snapshot = function()
      check(getStatus("count:") == "count: 1",
        "interval count incremented to 1 after first tick")
    end,
  },
  -- Interval restarts with CC id 2
  { eventFn = feedTimer(2) },
  {
    snapshot = function()
      check(getStatus("count:") == "count: 2",
        "interval count incremented to 2 after second tick")
    end,
  },
  -- Interval restarts with CC id 3
  { eventFn = feedTimer(3) },
  {
    snapshot = function()
      check(getStatus("count:") == "count: 3",
        "interval count incremented to 3 after third tick")
    end,
  },
})

print("== clearInterval: stops the interval ==")
boot({
  {
    snapshot = function()
      check(getStatus("count:") == "count: 0", "fresh interval count at 0")
    end,
  },
  -- Click startInterval: CC id 1
  { eventFn = clickBtn("startInterval") },
  -- First tick: CC id 1 → count = 1
  { eventFn = feedTimer(1) },
  {
    snapshot = function()
      check(getStatus("count:") == "count: 1",
        "interval count at 1 before stop")
    end,
  },
  -- Stop the interval
  { eventFn = clickBtn("stopInterval") },
  {
    snapshot = function()
      check(getStatus("status:") == "status: stopped",
        "interval status becomes 'stopped'")
    end,
  },
  -- More timer events should NOT match the cleared interval (idempotent)
  { eventFn = feedTimer(2) },
  { eventFn = feedTimer(3) },
  {
    snapshot = function()
      check(getStatus("count:") == "count: 1",
        "interval count unchanged after clearInterval")
    end,
  },
})

print("")
if t.failures == 0 then
  print("ALL TESTS PASSED")
  realExit(0)
else
  print(t.failures .. " TEST(S) FAILED")
  realExit(1)
end
