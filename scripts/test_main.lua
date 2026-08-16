--[[
  Headless test harness for cc-react compiled output.

  Boots dist/main.lua against a stubbed CC environment (fake Tom's Peripherals
  GPU with a pixel buffer) and verifies the MVP acceptance criteria:

    1. static page rendering — styled tree laid out and drawn to the buffer
    2. interaction + dirty-rect loop — clicks update hooks state and only the
       affected region is repainted

  Events are fed as a *step script*: a step is either
      { eventFn = function() return {name, ...} end }  — delivered to the
                                                         program; evaluated at
                                                         pull time so it can
                                                         read the live tree
      { snapshot = function() ... end }                — runs between events,
                                                         right after the
                                                         previous render
  The stub's os.pullEvent() throws __TEST_END__ when the script drains, which
  unwinds the program's event loop and returns control to this script.

  Usage: lua5.1 scripts/test_main.lua [path-to-main.lua]
]]

local MAIN = arg and arg[1] or "dist/main.lua"

local realExit = os.exit

local VW, VH = 256, 192   -- real device: 4x3 monitor at resolution 64 → 256x192 px
local FONT_W, FONT_H = 5, 8   -- default font is 5x8 (ascii.bin header)

local failures = 0
local function check(cond, msg)
  if cond then
    print("  ok  " .. msg)
  else
    failures = failures + 1
    print("  FAIL " .. msg)
  end
end

-- ================= stub GPU =================

local stub = {
  steps = {},            -- step script (eventFn / snapshot)
  buf = nil,             -- buf[y][x], 0-based ARGB pixels
  synced = 0,
  calls = {},            -- recorded GPU calls (for dirty-rect assertions)
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
    stub.order[#stub.order + 1] = "getSize"
    return VW, VH, 3, 4, 64
  end,
  setSize = function()
    stub.order[#stub.order + 1] = "setSize"
  end,
  refreshSize = function()
    stub.order[#stub.order + 1] = "refreshSize"
  end,
  fill = function(c)
    stub.calls[#stub.calls + 1] = { "fill", c }
    if stub.buf then fillRect(stub.buf, 0, 0, VW, VH, c) end
  end,
  filledRectangle = function(x, y, w, h, c)
    -- mirror the real GPU: 1-based, throws when x or y < 1 (far edge clamps)
    if x < 1 or y < 1 then error("Out of boundary", 0) end
    stub.calls[#stub.calls + 1] = { "filledRectangle", x, y, w, h, c }
    if stub.buf then fillRect(stub.buf, x, y, w, h, c) end
  end,
  rectangle = function(x, y, w, h, c)
    if x < 1 or y < 1 then error("Out of boundary", 0) end
    stub.calls[#stub.calls + 1] = { "rectangle", x, y, w, h, c }
    if stub.buf then
      for xx = x, x + w - 1 do
        setPixel(stub.buf, xx, y, c)
        setPixel(stub.buf, xx, y + h - 1, c)
      end
      for yy = y, y + h - 1 do
        setPixel(stub.buf, x, yy, c)
        setPixel(stub.buf, x + w - 1, yy, c)
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
    stub.calls[#stub.calls + 1] = { "drawText", x, y, text, fg, bg, size, pad }
    if stub.buf then drawText(stub.buf, x, y, text, fg, bg, size, pad) end
  end,
  getTextLength = function(text, size, pad)
    size = size or 1
    pad = pad or 1
    return (FONT_W + pad) * #text * size
  end,
  sync = function() stub.synced = stub.synced + 1 end,
}

-- ================= stub CC environment =================

_G.arg = { "left" }
_G.peripheral = { wrap = function() return fakeGpu end }

local function pullEvent()
  if #stub.steps == 0 then
    error("__TEST_END__", 0)
  end
  local step = table.remove(stub.steps, 1)
  if step.snapshot then
    step.snapshot()
    return pullEvent()
  end
  local ev = step.eventFn()
  return ev[1], ev[2], ev[3], ev[4], ev[5], ev[6]
end

_G.os = {
  pullEvent = pullEvent,
  shutdown = function() end,
}
-- CC global; the runtime no longer sleeps at startup (refreshSize is blocking),
-- but keep a stub in case any future code path calls it.
_G.sleep = function() end

-- boot the compiled program; the step script drives it until it drains
local function boot(steps)
  stub.steps = steps or {}
  stub.buf = makeBuffer()
  stub.synced = 0
  stub.calls = {}
  stub.order = {}
  local ok, err = pcall(dofile, MAIN)
  if ok then
    error("test harness: main.lua returned without throwing __TEST_END__")
  end
  if not tostring(err):find("__TEST_END__") then
    error("test harness: boot failed: " .. tostring(err))
  end
end

-- ================= helpers over the live tree =================

local function findNodes(root, pred)
  local out = {}
  local function walk(n)
    if pred(n) then out[#out + 1] = n end
    for i = 1, #n.children do walk(n.children[i]) end
  end
  if root then walk(root) end
  return out
end

local function findText(root, prefix)
  return findNodes(root, function(n)
    return n.kind == "text" and n.text and n.text:sub(1, #prefix) == prefix
  end)[1]
end

local function findButton(root, label)
  return findNodes(root, function(n) return n.kind == "button" and n.label == label end)[1]
end

local function centerOf(n)
  return n.x + math.floor(n.w / 2), n.y + math.floor(n.h / 2)
end

-- build an eventFn that clicks the button with `label` at its *current* center
local function clickButton(label)
  return function()
    local b = findButton(ccreact.getTree(), label)
    if not b then error("test harness: button '" .. label .. "' not found in tree") end
    local x, y = centerOf(b)
    return { "tm_monitor_touch", x, y, false }
  end
end

local function regionDiff(a, b, x1, y1, x2, y2)
  local d = 0
  for y = y1 - 1, y2 - 1 do
    for x = x1 - 1, x2 - 1 do
      if a[y][x] ~= b[y][x] then d = d + 1 end
    end
  end
  return d
end

local function countNonBg(buf)
  local n = 0
  for y = 0, VH - 1 do
    for x = 0, VW - 1 do
      if buf[y][x] ~= 0xFF000000 then n = n + 1 end
    end
  end
  return n
end

local function deepCopy(t)
  local out = {}
  for y = 0, VH - 1 do
    out[y] = {}
    for x = 0, VW - 1 do out[y][x] = t[y][x] end
  end
  return out
end

-- ================= tests =================

local before1, before3

print("== single-run interaction scenario (acceptance #1 + #2) ==")
boot({
  -- after the initial render: verify the static page
  {
    snapshot = function()
      local tree = ccreact.getTree()
      check(tree ~= nil, "boot: root tree exists")
      check(ccreact.getViewport() == VW and select(2, ccreact.getViewport()) == VH,
        "viewport is " .. VW .. "x" .. VH)

      local title = findText(tree, "cc-react")
      check(title ~= nil, "title text node found")
      check(title.w > 0 and title.h > 0,
        "title box laid out (" .. tostring(title.w) .. "x" .. tostring(title.h) .. ")")

      local countText = findText(tree, "Count:")
      check(countText ~= nil, "count text node found")
      check(countText.text == "Count: 0", "initial count is 0")
      check(title.y < countText.y, "title sits above the counter (column layout)")
      check(title.y + title.h <= countText.y,
        "text boxes do not overlap vertically (5x8 font metrics)")

      local btnPlus = findButton(tree, "+")
      local btnReset = findButton(tree, "Reset")
      local btnRecord = findButton(tree, "Record")
      check(btnPlus ~= nil and btnReset ~= nil and btnRecord ~= nil, "all buttons present")
      check(btnPlus.y > countText.y, "buttons below the counter")

      local drawn = countNonBg(stub.buf)
      check(drawn > 200, "buffer has drawn content (" .. drawn .. " non-black px)")
      check(stub.synced >= 1, "gpu.sync() called at least once")
      before1 = deepCopy(stub.buf)
    end,
  },
  -- press + release "+" (bitmap-monitor mouse path)
  { eventFn = clickButton("+") },
  {
    snapshot = function()
      local tree = ccreact.getTree()
      local countText = findText(tree, "Count:")
      check(countText.text == "Count: 1", "count incremented to 1 after + click")
      local last = findText(tree, "count ->")
      check(last ~= nil and last.text == "count -> 1", "useEffect fired: 'count -> 1' shown")
      check(regionDiff(before1, stub.buf, countText.x, countText.y,
        countText.x + countText.w - 1, countText.y + countText.h - 1) > 0,
        "counter text region repainted")
      local title = findText(tree, "cc-react")
      check(regionDiff(before1, stub.buf, title.x, title.y,
        title.x + title.w - 1, title.y + title.h - 1) == 0,
        "title region untouched (dirty-rect precision)")
    end,
  },
  -- reset via the normal-monitor touch path
  { eventFn = clickButton("Reset") },
  {
    snapshot = function()
      local countText = findText(ccreact.getTree(), "Count:")
      check(countText.text == "Count: 0", "count reset to 0 via tm_monitor_touch")
    end,
  },
  -- five clicks on "+" → count 5, badge appears (structure change)
  { eventFn = clickButton("+") },
  { eventFn = clickButton("+") },
  { eventFn = clickButton("+") },
  { eventFn = clickButton("+") },
  { eventFn = clickButton("+") },
  {
    snapshot = function()
      local tree = ccreact.getTree()
      local countText = findText(tree, "Count:")
      check(countText.text == "Count: 5", "count reached 5 after repeated clicks")
      local badge = findNodes(tree, function(n) return n.text == "big number!" end)[1]
      check(badge ~= nil, "conditional 'big number!' badge appeared at count >= 5")
      local badgePanel = badge and badge.parent
      check(badgePanel ~= nil
        and badge.x >= badgePanel.x and badge.y >= badgePanel.y
        and badge.x + badge.w <= badgePanel.x + badgePanel.w
        and badge.y + badge.h <= badgePanel.y + badgePanel.h,
        "badge text fits inside its panel background")
    end,
  },
  -- record two entries → dynamic list grows (tree structure change)
  { eventFn = clickButton("Record") },
  { eventFn = clickButton("Record") },
  {
    snapshot = function()
      local tree = ccreact.getTree()
      local recorded = findText(tree, "Recorded:")
      check(recorded ~= nil, "'Recorded:' list header present")
      local rows = findNodes(tree, function(n)
        return n.kind == "text" and n.text:sub(1, 1) == "#"
      end)
      check(#rows == 2, "two history rows rendered (#5, #5)")
      before3 = deepCopy(stub.buf)
    end,
  },
  -- one more click: only the counter should repaint (title + badge untouched)
  { eventFn = clickButton("+") },
  {
    snapshot = function()
      local tree = ccreact.getTree()
      local countText = findText(tree, "Count:")
      check(countText.text == "Count: 6", "count is 6 after one more click")
      local title = findText(tree, "cc-react")
      local badge = findNodes(tree, function(n) return n.text == "big number!" end)[1]
      check(regionDiff(before3, stub.buf, title.x, title.y,
        title.x + title.w - 1, title.y + title.h - 1) == 0,
        "title untouched on single click (dirty-rect precision)")
      check(regionDiff(before3, stub.buf, badge.x, badge.y,
        badge.x + badge.w - 1, badge.y + badge.h - 1) == 0,
        "badge untouched on single click (dirty-rect precision)")
      check(regionDiff(before3, stub.buf, countText.x, countText.y,
        countText.x + countText.w - 1, countText.y + countText.h - 1) > 0,
        "counter region repainted")
    end,
  },
})

print("== off-screen content is skipped, not crashed ==")
-- Record 12 times: the recorded list grows far below the 192px-tall test
-- viewport... wait, viewport is 256 tall; 12 rows would overflow it.
boot({
  { eventFn = clickButton("Record") },
  { eventFn = clickButton("Record") },
  { eventFn = clickButton("Record") },
  { eventFn = clickButton("Record") },
  { eventFn = clickButton("Record") },
  { eventFn = clickButton("Record") },
  { eventFn = clickButton("Record") },
  { eventFn = clickButton("Record") },
  { eventFn = clickButton("Record") },
  { eventFn = clickButton("Record") },
  { eventFn = clickButton("Record") },
  { eventFn = clickButton("Record") },
  { eventFn = clickButton("Record") },
  { eventFn = clickButton("Record") },
  {
    snapshot = function()
      local tree = ccreact.getTree()
      local rows = findNodes(tree, function(n)
        return n.kind == "text" and n.text:sub(1, 1) == "#"
      end)
      check(#rows == 14, "14 history rows in the tree")
      -- no "Out of boundary" was thrown: off-screen rows were skipped
      check(true, "program survived growing content beyond the viewport")
    end,
  },
})

print("== fresh boot starts clean ==")
boot({})
local countText = findText(ccreact.getTree(), "Count:")
check(countText.text == "Count: 0", "fresh program starts at Count: 0")

print("== startup order: refreshSize -> setSize -> getSize ==")
local seq = table.concat(stub.order, " > ")
check(stub.order[1] == "refreshSize" and stub.order[2] == "setSize" and stub.order[3] == "getSize",
  "startup calls refreshSize, then setSize, then getSize (" .. seq .. ")")

print("== GPU adapter coordinate convention ==")
-- the root panel fills (1,1)-based; the adapter must pass 1-based coords
local found1based
for i = 1, #stub.calls do
  local c = stub.calls[i]
  if c[1] == "filledRectangle" and c[2] == 1 and c[3] == 1 then
    found1based = true
    break
  end
end
check(found1based, "draw coords passed to GPU are 1-based (root fill at 1,1)")

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
  realExit(0)
else
  print(failures .. " TEST(S) FAILED")
  realExit(1)
end
