--[[
  Shared headless test harness for cc-react compiled output.

  Boots a compiled cc-react module (t.MAIN) against a stubbed CC environment
  (fake Tom's Peripherals GPU with a pixel buffer) and provides tree/buffer
  inspection helpers. Used by scripts/test_main.lua (demo module) and
  scripts/test_multiimport.lua (multi-file fixture module).

  The stub faithfully mirrors the real device:
    - GPU draw calls are 1-based and throw "Out of boundary" below (1,1)
    - drawText requires explicit Number fg/bg and throws when the text would
      extend past the viewport edge
    - os.pullEvent yields inside a coroutine (parallel scheduler) and consumes
      the step script directly from the main coroutine
    - parallel.waitForAll mirrors CC: Tweaked's rom/apis/parallel.lua: the
      first resume carries an EMPTY event, later events are broadcast to all
      consumers (no stealing)

  Events are fed as a *step script*: a step is either
      { eventFn = function() return {name, ...} end }  — delivered to the
                                                        program; evaluated at
                                                        pull time so it can
                                                        read the live tree
      { snapshot = function() ... end }                — runs between events,
                                                        right after the
                                                        previous render
  The stub's event source throws __TEST_END__ when the script drains, which
  unwinds the UI task (or the parallel scheduler) and returns control to the
  test file.
]]

-- 4x4 monitors at resolution 64 → 256x256 px. Taller than the original
-- 256x192 so the demo's full UI (header + controls + input + history) fits
-- on screen — the README recommends a 3x4 (192x256) layout for the demo.
local VW, VH = 256, 256
local FONT_W, FONT_H = 5, 8   -- default font is 5x8 (ascii.bin header)

-- CC: Tweaked exposes table.unpack (Lua 5.2 compat); plain Lua 5.1 only has
-- the global unpack, so mirror the CC environment.
if not table.unpack then table.unpack = unpack end

local t = {}
t.VW, t.VH = VW, VH
t.MAIN = "dist/ui.lua"   -- module under test; the test file overrides it

t.failures = 0
function t.check(cond, msg)
  if cond then
    print("  ok  " .. msg)
  else
    t.failures = t.failures + 1
    print("  FAIL " .. msg)
  end
end

-- ================= stub GPU =================

t.stub = {
  steps = {},            -- step script (eventFn / snapshot)
  queue = {},            -- os.queueEvent'd events (drained before the steps)
  buf = nil,             -- buf[y][x], 0-based ARGB pixels
  synced = 0,
  calls = {},            -- recorded GPU calls (for dirty-rect assertions)
  order = {},            -- recorded startup call order
  wrapCalls = {},        -- peripheral.wrap sides (start(side) contract)
}

local function makeBuffer()
  local b = {}
  for y = 0, VH - 1 do
    b[y] = {}
    for x = 0, VW - 1 do b[y][x] = 0xFF000000 end
  end
  return b
end

local function setPixel(b, x, y, c)
  if x >= 0 and x < VW and y >= 0 and y < VH then b[y][x] = c end
end

local function fillRect(b, x, y, w, h, c)
  for yy = y, y + h - 1 do
    for xx = x, x + w - 1 do setPixel(b, xx, yy, c) end
  end
end

-- Deterministic pseudo-glyph: fills most of the char cell, leaving a pattern
-- of holes derived from the char code, so different strings differ on screen.
local function drawCharCell(b, x, y, ch, fg, size)
  local seed = string.byte(ch)
  for yy = 0, FONT_H * size - 1 do
    for xx = 0, FONT_W * size - 1 do
      if (seed + xx * 3 + yy * 5) % 7 ~= 0 then
        setPixel(b, x + xx, y + yy, fg)
      end
    end
  end
end

local function drawText(b, x, y, text, fg, bg, size, pad)
  size = size or 1
  pad = pad or 1 -- mod default: 1px between chars
  local cw = (FONT_W + pad) * size
  local ch = FONT_H * size
  if bg then fillRect(b, x, y, cw * #text, ch, bg) end
  for i = 1, #text do
    drawCharCell(b, x + (i - 1) * cw, y, text:sub(i, i), fg, size)
  end
end

local fakeGpu = {
  getSize = function()
    t.stub.order[#t.stub.order + 1] = "getSize"
    return VW, VH, 3, 4, 64
  end,
  setSize = function()
    t.stub.order[#t.stub.order + 1] = "setSize"
  end,
  refreshSize = function()
    t.stub.order[#t.stub.order + 1] = "refreshSize"
  end,
  fill = function(c)
    t.stub.calls[#t.stub.calls + 1] = { "fill", c }
    if t.stub.buf then fillRect(t.stub.buf, 0, 0, VW, VH, c) end
  end,
  filledRectangle = function(x, y, w, h, c)
    -- mirror the real GPU: 1-based, throws when x or y < 1 (far edge clamps)
    if x < 1 or y < 1 then error("Out of boundary", 0) end
    t.stub.calls[#t.stub.calls + 1] = { "filledRectangle", x, y, w, h, c }
    if t.stub.buf then fillRect(t.stub.buf, x, y, w, h, c) end
  end,
  rectangle = function(x, y, w, h, c)
    if x < 1 or y < 1 then error("Out of boundary", 0) end
    t.stub.calls[#t.stub.calls + 1] = { "rectangle", x, y, w, h, c }
    if t.stub.buf then
      for xx = x, x + w - 1 do
        setPixel(t.stub.buf, xx, y, c)
        setPixel(t.stub.buf, xx, y + h - 1, c)
      end
      for yy = y, y + h - 1 do
        setPixel(t.stub.buf, x, yy, c)
        setPixel(t.stub.buf, x + w - 1, yy, c)
      end
    end
  end,
  drawText = function(x, y, text, fg, bg, size, pad)
    -- mirror the real GPU: fg/bg must be Numbers (nil → Bad argument #5)
    if fg == nil or bg == nil then error("Bad argument: (expected Number)", 0) end
    -- mirror the real GPU: throws when the text would extend past the edge
    size = size or 1
    pad = pad or 1
    local tw = (FONT_W + pad) * #text * size
    local th = FONT_H * size
    if x < 1 or y < 1 or x + tw - 1 > VW or y + th - 1 > VH then
      error("Out of boundary", 0)
    end
    t.stub.calls[#t.stub.calls + 1] = { "drawText", x, y, text, fg, bg, size, pad }
    if t.stub.buf then drawText(t.stub.buf, x, y, text, fg, bg, size, pad) end
  end,
  getTextLength = function(text, size, pad)
    size = size or 1
    pad = pad or 1
    return (FONT_W + pad) * #text * size
  end,
  sync = function() t.stub.synced = t.stub.synced + 1 end,
}

-- ================= stub CC environment =================

_G.peripheral = {
  wrap = function(side)
    t.stub.wrapCalls[#t.stub.wrapCalls + 1] = side
    return fakeGpu
  end,
}

-- Main-coroutine event source: consumes one step-script entry. os.queueEvent
-- events (e.g. the network bridge's job/completion notifications between the
-- UI task and the network worker task) are drained FIRST, so a chain of
-- queued events resolves before the next scripted step runs. Runs a snapshot
-- inline, or evaluates an eventFn and returns its tuple. Throws __TEST_END__
-- when the script drains.
local function pullEventDirect()
  if #t.stub.queue > 0 then
    local ev = table.remove(t.stub.queue, 1)
    return ev[1], ev[2], ev[3], ev[4], ev[5], ev[6]
  end
  if #t.stub.steps == 0 then
    error("__TEST_END__", 0)
  end
  local step = table.remove(t.stub.steps, 1)
  if step.snapshot then
    step.snapshot()
    return pullEventDirect()
  end
  local ev = step.eventFn()
  return ev[1], ev[2], ev[3], ev[4], ev[5], ev[6]
end

-- CC broadcasts events to every consumer. Mirror CC's parallel contract:
-- inside a task coroutine os.pullEvent yields to the scheduler (which
-- resumes the task with the next event); in the main coroutine it consumes
-- the step script directly (standalone start(), or the scheduler's own pull).
local function osPullEvent()
  if coroutine.running() ~= nil then
    return coroutine.yield()
  end
  return pullEventDirect()
end

_G.os = {
  pullEvent = osPullEvent,
  shutdown = function() end,
  -- the cursor blink uses os.startTimer/cancelTimer; a single fixed id is
  -- enough for the step-script (tests feed {"timer", 1} to tick the blink)
  startTimer = function() return 1 end,
  cancelTimer = function() end,
  -- the network bridge (fetch) signals the worker task and reports results
  -- through queued events; pullEventDirect drains them before the step script
  queueEvent = function(name, ...)
    t.stub.queue[#t.stub.queue + 1] = { name, ... }
  end,
}
-- CC global; the runtime no longer sleeps at startup (refreshSize is
-- blocking), but keep a stub in case any future code path calls it.
_G.sleep = function() end

-- Faithful minimal parallel.waitForAll stub (modeled on CC: Tweaked's
-- rom/apis/parallel.lua): each task runs in a coroutine; the first resume
-- happens with an EMPTY event (so tasks run their initial code — the UI
-- task renders its first frame — before the first real event), then every
-- pulled event is delivered to tasks whose filter (the value their
-- os.pullEvent yielded) is nil or matches the event name.
-- Events are pulled via osPullEvent (NOT pullEventDirect) so this stub is
-- re-entrant: ui.start() internally composes its loops with another
-- parallel.waitForAll, and when that nested scheduler runs inside a task
-- coroutine its pullEvent yields to THIS scheduler instead of consuming the
-- step script directly.
_G.parallel = {
  waitForAll = function(...)
    local threads = {}
    local count = select("#", ...)
    for i = 1, count do
      threads[i] = { co = coroutine.create(select(i, ...)), filter = nil }
    end
    local event = {} -- first iteration: empty event, like real CC
    while true do
      local i = 1
      while i <= count do
        local th = threads[i]
        local resumeWith
        if th.filter == nil or th.filter == event[1] or event[1] == "terminate" then
          resumeWith = event
        end
        if resumeWith then
          local ok, param = coroutine.resume(th.co, table.unpack(resumeWith, 1, #resumeWith))
          if not ok then error("parallel task failed: " .. tostring(param), 0) end
          if coroutine.status(th.co) == "dead" then
            table.remove(threads, i)
            count = count - 1
            i = i - 1
          end
          th.filter = param
        end
        i = i + 1
      end
      if count == 0 then return end
      event = { osPullEvent() }
    end
  end,
}

-- ================= boot =================

t.uiMod = nil

-- Load the compiled module, then run its start() — either standalone or as
-- one task of parallel.waitForAll (when extraTask is given). The step script
-- drives it until it drains (the event source throws __TEST_END__).
-- preStart(t.uiMod) runs after the module loads and before start() — used by
-- the network tests to install a stubbed backend before the first fetch.
function t.boot(steps, extraTask, preStart)
  t.stub.steps = steps or {}
  t.stub.queue = {}
  t.stub.buf = makeBuffer()
  t.stub.synced = 0
  t.stub.calls = {}
  t.stub.order = {}
  t.stub.wrapCalls = {}
  local ok, res = pcall(dofile, t.MAIN)
  if not ok then
    error("test harness: boot failed: " .. tostring(res))
  end
  if type(res) ~= "table" or type(res.start) ~= "function" then
    error("test harness: " .. t.MAIN .. " does not return a module with a start() function")
  end
  t.uiMod = res
  if preStart then preStart(t.uiMod) end
  local run = function()
    if extraTask then
      _G.parallel.waitForAll(function() t.uiMod.start("left") end, extraTask)
    else
      t.uiMod.start("left")
    end
  end
  local ok2, err = pcall(run)
  if ok2 then
    error("test harness: the program returned without throwing __TEST_END__")
  end
  if not tostring(err):find("__TEST_END__") then
    error("test harness: the program failed: " .. tostring(err))
  end
end

-- ================= helpers over the live tree =================

function t.findNodes(root, pred)
  local out = {}
  local function walk(n)
    if pred(n) then out[#out + 1] = n end
    for i = 1, #n.children do walk(n.children[i]) end
  end
  if root then walk(root) end
  return out
end

function t.findText(root, prefix)
  return t.findNodes(root, function(n)
    return n.kind == "text" and n.text and n.text:sub(1, #prefix) == prefix
  end)[1]
end

function t.findButton(root, label)
  return t.findNodes(root, function(n) return n.kind == "button" and n.label == label end)[1]
end

function t.centerOf(n)
  return n.x + math.floor(n.w / 2), n.y + math.floor(n.h / 2)
end

-- build an eventFn that clicks the button with `label` at its *current* center
function t.clickButton(label)
  return function()
    local b = t.findButton(t.uiMod.getTree(), label)
    if not b then error("test harness: button '" .. label .. "' not found in tree") end
    local x, y = t.centerOf(b)
    return { "tm_monitor_touch", x, y, false }
  end
end

function t.regionDiff(a, b, x1, y1, x2, y2)
  local d = 0
  for y = y1 - 1, y2 - 1 do
    for x = x1 - 1, x2 - 1 do
      if a[y][x] ~= b[y][x] then d = d + 1 end
    end
  end
  return d
end

function t.countNonBg(buf)
  local n = 0
  for y = 0, VH - 1 do
    for x = 0, VW - 1 do
      if buf[y][x] ~= 0xFF000000 then n = n + 1 end
    end
  end
  return n
end

function t.deepCopy(buf)
  local out = {}
  for y = 0, VH - 1 do
    out[y] = {}
    for x = 0, VW - 1 do out[y][x] = buf[y][x] end
  end
  return out
end

return t
