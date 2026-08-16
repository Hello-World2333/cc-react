--[[
  Headless test harness for cc-react demo compiled output.

  Boots dist/ui.lua against a stubbed CC environment (fake Tom's Peripherals
  GPU with a pixel buffer) and verifies the MVP acceptance criteria plus the
  module contract:

    1. static page rendering — styled tree laid out and drawn to the buffer
    2. interaction + dirty-rect loop — clicks update hooks state and only the
       affected region is repainted
    3. module shape — the compiled file returns a table with a start(side)
       task function; the GPU side is passed explicitly
    4. non-blocking under simpleParallel — start() runs as one task of a
       faithful parallel.waitForAll stub alongside a second task, which also
       receives every event (CC broadcasts to all consumers)

  The CC/GPU stub itself lives in scripts/cc_stub.lua (shared with
  scripts/test_multiimport.lua); the demo assertions are here.

  Usage: lua5.1 scripts/test_main.lua [path-to-module.lua]
]]

-- Capture the real os.exit BEFORE the stub replaces _G.os (cc_stub.lua
-- installs a stub os for the program under test).
local realExit = os.exit

local t = require("scripts.cc_stub")
local check = t.check
local boot = t.boot
local stub = t.stub
local findNodes = t.findNodes
local findText = t.findText
local findButton = t.findButton
local clickButton = t.clickButton
local regionDiff = t.regionDiff
local countNonBg = t.countNonBg
local deepCopy = t.deepCopy
local VW, VH = t.VW, t.VH

t.MAIN = arg and arg[1] or "dist/ui.lua"

-- ================= tests =================

local before1, before3

print("== module contract ==")
boot({
  {
    snapshot = function()
      check(type(t.uiMod.start) == "function" and type(t.uiMod.getTree) == "function",
        "module returns a table with start() + debug hooks")
      check(stub.wrapCalls[1] == "left",
        "start(side) wraps the GPU on the passed side ('left')")
      check(stub.order[1] == "refreshSize" and stub.order[2] == "setSize"
        and stub.order[3] == "getSize",
        "startup order refreshSize -> setSize -> getSize ("
        .. table.concat(stub.order, " > ") .. ")")
    end,
  },
})

print("== single-run interaction scenario (acceptance #1 + #2) ==")
boot({
  -- after the initial render: verify the static page
  {
    snapshot = function()
      local tree = t.uiMod.getTree()
      check(tree ~= nil, "boot: root tree exists")
      check(t.uiMod.getViewport() == VW and select(2, t.uiMod.getViewport()) == VH,
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
      local tree = t.uiMod.getTree()
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
      local countText = findText(t.uiMod.getTree(), "Count:")
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
      local tree = t.uiMod.getTree()
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
      local tree = t.uiMod.getTree()
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
      local tree = t.uiMod.getTree()
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
      local tree = t.uiMod.getTree()
      local rows = findNodes(tree, function(n)
        return n.kind == "text" and n.text:sub(1, 1) == "#"
      end)
      check(#rows == 14, "14 history rows in the tree")
      -- no "Out of boundary" was thrown: off-screen rows were skipped
      check(true, "program survived growing content beyond the viewport")
    end,
  },
})

print("== scroll container (Scroll: layout, clip, wheel, clamp, drag) ==")
local function scrollNode()
  return findNodes(t.uiMod.getTree(), function(n) return n.kind == "scroll" end)[1]
end
local function historyRows()
  return findNodes(t.uiMod.getTree(), function(n)
    return n.kind == "text" and n.text:sub(1, 1) == "#"
  end)
end
-- wheel event over the scroll viewport; dir follows the real device
-- convention (verified in Tom's Peripherals source): dir=+1 = wheel down.
local function wheelOverScroll(dir)
  return function()
    local sc = scrollNode()
    return { "tm_monitor_mouse_scroll", "mon_0", sc.x + 10, sc.y + 10, dir }
  end
end

boot({
  -- 12 records: content (140px) overflows the 96px viewport
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
      local sc = scrollNode()
      check(sc ~= nil, "scroll container present after 12 records")
      check(sc.scrollY == 0 and sc.scrollX == 0, "scroll starts at offset 0")
      check(sc.contentH == 140, "content height is the full list height (" .. tostring(sc.contentH) .. ")")
      check(sc.contentH - sc.h == 44, "scroll range is content - viewport (44px)")
      local rows = historyRows()
      check(#rows == 12, "12 rows in the tree")
      check(rows[1].y == sc.y, "first row at the top of the viewport")
      -- (pixel-level clipping at the fold is asserted by the dedicated scroll
      -- fixture — scripts/test_scroll.lua; in the demo the fold lies below
      -- the 192px screen, so scrolled-out rows are off-screen anyway)
    end,
  },
  -- wheel down one notch → content scrolls up by scrollStep (8px)
  { eventFn = wheelOverScroll(1) },
  {
    snapshot = function()
      local sc = scrollNode()
      check(sc.scrollY == 8, "wheel down scrolls by scrollStep (8px)")
      local rows = historyRows()
      check(rows[1].y == sc.y - 8, "first row moved up by 8px")
      -- the strip the first row vacated shows the panel background again
      local ref = stub.buf[sc.y - 1][sc.x - 5]
      local px = stub.buf[sc.y - 1][rows[1].x + 1] -- was row-1 text at offset 0
      check(px == ref, "scrolled-away row repainted to background (no residue)")
    end,
  },
  -- five more notches: 8+40=48 → clamped at maxY=44
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  {
    snapshot = function()
      local sc = scrollNode()
      check(sc.scrollY == 44, "scroll clamps at the end (maxY=44)")
      local rows = historyRows()
      check(rows[1].y == sc.y - 44, "first row is 44px above the viewport top")
      check(rows[12].y + rows[12].h - 1 <= sc.y + sc.h - 1, "last row visible at max scroll")
    end,
  },
  -- wheel up ten times → clamped back at 0
  { eventFn = wheelOverScroll(-1) },
  { eventFn = wheelOverScroll(-1) },
  { eventFn = wheelOverScroll(-1) },
  { eventFn = wheelOverScroll(-1) },
  { eventFn = wheelOverScroll(-1) },
  { eventFn = wheelOverScroll(-1) },
  { eventFn = wheelOverScroll(-1) },
  { eventFn = wheelOverScroll(-1) },
  { eventFn = wheelOverScroll(-1) },
  { eventFn = wheelOverScroll(-1) },
  {
    snapshot = function()
      local sc = scrollNode()
      check(sc.scrollY == 0, "scroll clamps at the start (0)")
      local rows = historyRows()
      check(rows[1].y == sc.y, "first row back at the top")
    end,
  },
  -- a plain tap inside the scroll (click + up, no movement) does not scroll;
  -- the demo's scroll mostly hangs below the 192px test screen, so the tap
  -- uses the small on-screen strip at its top (drag + click-through tests
  -- live in scripts/test_scroll.lua where the viewport is fully visible)
  {
    eventFn = function()
      local sc = scrollNode()
      return { "tm_monitor_mouse_click", "mon_0", sc.x + 10, sc.y + 10, 1 }
    end,
  },
  {
    eventFn = function()
      local sc = scrollNode()
      return { "tm_monitor_mouse_up", "mon_0", sc.x + 10, sc.y + 10, 1 }
    end,
  },
  {
    snapshot = function()
      local sc = scrollNode()
      check(sc.scrollY == 0, "a plain tap does not scroll")
    end,
  },
  -- wheel over a visible child row still scrolls the container (ancestor
  -- lookup through the hit node)
  {
    eventFn = function()
      local rows = historyRows()
      return { "tm_monitor_mouse_scroll", "mon_0", rows[1].x + 2, rows[1].y + 2, 1 }
    end,
  },
  {
    snapshot = function()
      local sc = scrollNode()
      check(sc.scrollY == 8, "wheel over a row scrolls the container (8px)")
    end,
  },
})

print("== fresh boot starts clean ==")
boot({})
local countText = findText(t.uiMod.getTree(), "Count:")
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

print("== runs as a simpleParallel task (parallel.waitForAll) ==")
-- A second task shares the scheduler. CC broadcasts every event to all
-- consumers, so the second task sees the same events as the UI task while
-- the UI keeps rendering.
local secondTaskEvents = {}
local parallelTask = function()
  while true do
    local e = { os.pullEvent() }
    secondTaskEvents[#secondTaskEvents + 1] = e[1]
  end
end

boot({
  -- the parallel scheduler's first resume carries an empty event, so the UI
  -- task renders its first frame before the first real event is pulled
  {
    snapshot = function()
      local tree = t.uiMod.getTree()
      check(tree ~= nil, "parallel: initial frame rendered before the first event")
      local countText = findText(tree, "Count:")
      check(countText ~= nil and countText.text == "Count: 0", "parallel: initial count is 0")
      check(stub.synced >= 1, "parallel: gpu.sync() called during the initial render")
    end,
  },
  { eventFn = clickButton("+") },
  {
    snapshot = function()
      local countText = findText(t.uiMod.getTree(), "Count:")
      check(countText.text == "Count: 1", "parallel: click processed by the UI task")
      check(#secondTaskEvents >= 1 and secondTaskEvents[1] == "tm_monitor_touch",
        "parallel: second task received the same touch event (broadcast)")
    end,
  },
  { eventFn = clickButton("Record") },
  {
    snapshot = function()
      local rows = findNodes(t.uiMod.getTree(), function(n)
        return n.kind == "text" and n.text:sub(1, 1) == "#"
      end)
      check(#rows == 1, "parallel: record processed after the + click")
      check(#secondTaskEvents >= 2, "parallel: second task saw both events")
    end,
  },
}, parallelTask)

print("")
if t.failures == 0 then
  print("ALL TESTS PASSED")
  realExit(0)
else
  print(t.failures .. " TEST(S) FAILED")
  realExit(1)
end
