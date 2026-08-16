--[[
  Headless test harness for cc-react showcase demo compiled output.

  Boots dist/ui.lua against a stubbed CC environment (fake Tom's Peripherals
  GPU with a pixel buffer) and verifies the showcase app end to end:

    1. static page rendering — the Home tab: title, feature list, color
       swatches (all three hex formats), laid out and drawn to the buffer
    2. tab navigation — clicking the tab bar switches the active tab
    3. interaction + dirty-rect loop — Counter tab clicks update hooks state
       and only the affected region is repainted
    4. conditional rendering — the "big number!" badge appears at count >= 5
    5. dynamic lists — Record grows the history rows
    6. scroll container — history list: layout, wheel, clamp, plain-tap
    7. keyboard input — Input tab: click-to-focus, typing, Enter submits,
       Tab focus cycling, blur on outside click
    8. flexbox playground — Layout tab: J+/A+ cycle justify/align values
    9. scroll tab — wheel + click-through of the Bottom button
   10. module contract — start(side) task + debug hooks, startup order,
       1-based GPU coordinates
   11. non-blocking under simpleParallel — start() runs as one task of a
       faithful parallel.waitForAll stub alongside a second task, which also
       receives every event (CC broadcasts to all consumers)

  The CC/GPU stub itself lives in scripts/cc_stub.lua.

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

-- pixel-buffer baselines for dirty-rect assertions
local baseline1, baseline2

-- ================= helpers =================

local function textRows()
  return findNodes(t.uiMod.getTree(), function(n)
    return n.kind == "text" and n.text:sub(1, 1) == "#"
  end)
end

local function inputs()
  return findNodes(t.uiMod.getTree(), function(n) return n.kind == "input" end)
end

local function scrollNode()
  return findNodes(t.uiMod.getTree(), function(n) return n.kind == "scroll" end)[1]
end

-- wheel event over the scroll viewport; dir follows the real device
-- convention (verified in Tom's Peripherals source): dir=+1 = wheel down.
local function wheelOverScroll(dir)
  return function()
    local sc = scrollNode()
    return { "tm_monitor_mouse_scroll", "mon_0", sc.x + 10, sc.y + 10, dir }
  end
end

-- a plain tap (click + up, no movement) inside the scroll viewport
local function tapInScroll()
  return function()
    local sc = scrollNode()
    return { "tm_monitor_mouse_click", "mon_0", sc.x + 10, sc.y + 10, 1 }
  end
end

local function tapUpInScroll()
  return function()
    local sc = scrollNode()
    return { "tm_monitor_mouse_up", "mon_0", sc.x + 10, sc.y + 10, 1 }
  end
end

-- tap the first input (click-to-focus)
local function clickFirstInput()
  return function()
    local inp = inputs()[1]
    local x, y = t.centerOf(inp)
    return { "tm_monitor_touch", x, y, false }
  end
end

local function keyboardChar(c)
  return function() return { "tm_keyboard_char", "kb_0", c } end
end

local function keyboardKey(k)
  return function() return { "tm_keyboard_key", "kb_0", k, false } end
end

local KEY_ENTER = 257
local KEY_TAB = 258
local KEY_LSHIFT = 340

-- ================= tests =================

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

print("== home tab: static page rendering ==")
boot({
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

      local featHead = findText(tree, "all 8 features:")
      check(featHead ~= nil, "feature heading with plural() found ('all 8 features:')")
      check(findText(tree, "useState / useEffect hooks") ~= nil,
        "first feature row rendered (mapped from lib/features.ts)")
      check(findText(tree, "multi-file import") ~= nil,
        "last feature row rendered")
      check(title.y + title.h <= featHead.y,
        "title sits above the feature list (column layout)")

      local swatch = findNodes(tree, function(n)
        return n.kind == "box" and n.style and n.style.backgroundColor == "#f80"
      end)[1]
      check(swatch ~= nil and swatch.w == 28 and swatch.h == 12,
        "a #rgb color swatch box rendered with the right size (theme string parsed at draw time)")
      check(findText(tree, "#rgb #rrggbb #aarrggbb") ~= nil,
        "color format caption present")

      local drawn = countNonBg(stub.buf)
      check(drawn > 200, "buffer has drawn content (" .. drawn .. " non-black px)")
      check(stub.synced >= 1, "gpu.sync() called at least once")
    end,
  },
})

print("== tab navigation + counter interaction ==")
boot({
  { eventFn = clickButton("Counter") },
  {
    snapshot = function()
      local tree = t.uiMod.getTree()
      local heading = findText(tree, "state + effects")
      local countText = findText(tree, "Count:")
      check(heading ~= nil and countText ~= nil, "counter tab active: heading + Count shown")
      check(countText.text == "Count: 0", "initial count is 0")
      check(findText(tree, "cc-react") == nil,
        "home tab unmounted while counter tab is active")
      check(heading.y + heading.h <= countText.y,
        "heading above the counter (column layout)")

      local btnPlus = findButton(tree, "+")
      local btnReset = findButton(tree, "Reset")
      local btnRecord = findButton(tree, "Record")
      check(btnPlus ~= nil and btnReset ~= nil and btnRecord ~= nil, "all counter buttons present")
      check(btnPlus.y > countText.y, "buttons below the counter")
      baseline1 = deepCopy(stub.buf)
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
      local heading = findText(tree, "state + effects")
      check(regionDiff(baseline1, stub.buf, countText.x, countText.y,
        countText.x + countText.w - 1, countText.y + countText.h - 1) > 0,
        "counter text region repainted")
      check(regionDiff(baseline1, stub.buf, heading.x, heading.y,
        heading.x + heading.w - 1, heading.y + heading.h - 1) == 0,
        "heading region untouched (dirty-rect precision)")
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
      local rows = textRows()
      check(#rows == 2, "two history rows rendered (#5, #5)")
      baseline2 = deepCopy(stub.buf)
    end,
  },
  -- one more click: only the counter should repaint (heading + badge untouched)
  { eventFn = clickButton("+") },
  {
    snapshot = function()
      local tree = t.uiMod.getTree()
      local countText = findText(tree, "Count:")
      check(countText.text == "Count: 6", "count is 6 after one more click")
      local heading = findText(tree, "state + effects")
      local badge = findNodes(tree, function(n) return n.text == "big number!" end)[1]
      check(regionDiff(baseline2, stub.buf, heading.x, heading.y,
        heading.x + heading.w - 1, heading.y + heading.h - 1) == 0,
        "heading untouched on single click (dirty-rect precision)")
      check(regionDiff(baseline2, stub.buf, badge.x, badge.y,
        badge.x + badge.w - 1, badge.y + badge.h - 1) == 0,
        "badge untouched on single click (dirty-rect precision)")
      check(regionDiff(baseline2, stub.buf, countText.x, countText.y,
        countText.x + countText.w - 1, countText.y + countText.h - 1) > 0,
        "counter region repainted")
    end,
  },
})

print("== off-screen content is skipped, not crashed ==")
-- Record 14 times: the history list grows far beyond its 48px viewport; the
-- rows are clipped inside the scroll container (never drawn off-screen).
boot({
  { eventFn = clickButton("Counter") },
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
      local rows = textRows()
      check(#rows == 14, "14 history rows in the tree")
      check(true, "program survived growing content beyond the viewport")
    end,
  },
})

print("== scroll container (Counter history: layout, wheel, clamp, tap) ==")
boot({
  { eventFn = clickButton("Counter") },
  -- 12 records: content (140px) overflows the 48px viewport
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
      check(sc.contentH - sc.h == 92, "scroll range is content - viewport (92px)")
      local rows = textRows()
      check(#rows == 12, "12 rows in the tree")
      check(rows[1].y == sc.y, "first row at the top of the viewport")
    end,
  },
  -- wheel down one notch → content scrolls up by scrollStep (8px)
  { eventFn = wheelOverScroll(1) },
  {
    snapshot = function()
      local sc = scrollNode()
      check(sc.scrollY == 8, "wheel down scrolls by scrollStep (8px)")
      local rows = textRows()
      check(rows[1].y == sc.y - 8, "first row moved up by 8px")
      -- the strip the first row vacated shows the panel background again
      local ref = stub.buf[sc.y - 1][sc.x - 5]
      local px = stub.buf[sc.y - 1][rows[1].x + 1] -- was row-1 text at offset 0
      check(px == ref, "scrolled-away row repainted to background (no residue)")
    end,
  },
  -- eleven more notches: 8+88=96 → clamped at maxY=92
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  {
    snapshot = function()
      local sc = scrollNode()
      check(sc.scrollY == 92, "scroll clamps at the end (maxY=92)")
      local rows = textRows()
      check(rows[1].y == sc.y - 92, "first row is 92px above the viewport top")
      check(rows[12].y + rows[12].h - 1 <= sc.y + sc.h - 1, "last row visible at max scroll")
    end,
  },
  -- wheel up twenty times → clamped back at 0
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
      local rows = textRows()
      check(rows[1].y == sc.y, "first row back at the top")
    end,
  },
  -- a plain tap inside the scroll does not scroll
  { eventFn = tapInScroll() },
  { eventFn = tapUpInScroll() },
  {
    snapshot = function()
      local sc = scrollNode()
      check(sc.scrollY == 0, "a plain tap does not scroll")
    end,
  },
  -- wheel over a visible child row still scrolls the container (ancestor
  -- lookup through the hit node)
  { eventFn = wheelOverScroll(1) },
  {
    snapshot = function()
      local sc = scrollNode()
      check(sc.scrollY == 8, "wheel over a row scrolls the container (8px)")
    end,
  },
})

print("== keyboard input + focus management (Input tab) ==")
boot({
  { eventFn = clickButton("Input") },
  {
    snapshot = function()
      local tree = t.uiMod.getTree()
      local ins = inputs()
      check(#ins == 3, "three inputs rendered")
      check(ins[1].placeholder == "your name" and ins[2].placeholder == "a note"
        and ins[3].placeholder == "long text scrolls in the box",
        "placeholders shown while empty")
      check(findText(tree, "Tab / Shift+Tab cycles focus") ~= nil, "focus hint present")
      check(t.uiMod.getFocused() == nil, "nothing focused initially")
    end,
  },
  -- click the first input: focus + cursor at the click
  { eventFn = clickFirstInput() },
  {
    snapshot = function()
      check(t.uiMod.getFocused() ~= nil, "clicking the input focuses it")
      local st = t.uiMod.getInputState(t.uiMod.getFocused())
      check(st ~= nil and st.cursor == 0, "cursor starts at 0 (clicked before any text)")
    end,
  },
  -- type "ada": text flows through onChange → controlled value + greeting
  { eventFn = keyboardChar("a") },
  { eventFn = keyboardChar("d") },
  { eventFn = keyboardChar("a") },
  {
    snapshot = function()
      local tree = t.uiMod.getTree()
      local ins = inputs()
      check(ins[1].value == "ada", "typed text reached the controlled value (ada)")
      check(findText(tree, "typing: ada") ~= nil, "greeting shows 'typing: ada'")
      check(findText(tree, "last key: -1") ~= nil,
        "char events do not touch the raw key line (still -1)")
    end,
  },
  -- Enter fires onSubmit
  { eventFn = keyboardKey(KEY_ENTER) },
  {
    snapshot = function()
      local tree = t.uiMod.getTree()
      check(findText(tree, "hello, ada!") ~= nil, "Enter submitted the name ('hello, ada!')")
      check(findText(tree, "submits: 1") ~= nil, "submits counter incremented")
      check(findText(tree, "last key: 257") ~= nil, "onKey received the raw Enter key code (257)")
    end,
  },
  -- Tab moves focus to the second input; typing goes there
  { eventFn = keyboardKey(KEY_TAB) },
  { eventFn = keyboardChar("b") },
  {
    snapshot = function()
      local ins = inputs()
      check(ins[1].value == "ada" and ins[2].value == "b",
        "Tab cycled focus: note got 'b', name stayed 'ada'")
      check(findText(t.uiMod.getTree(), "hello, ada!") ~= nil,
        "greeting unchanged (still the submitted name)")
    end,
  },
  -- Shift+Tab moves focus back to the first input
  { eventFn = keyboardKey(KEY_LSHIFT) },
  { eventFn = keyboardKey(KEY_TAB) },
  { eventFn = keyboardChar("x") },
  {
    snapshot = function()
      local ins = inputs()
      check(ins[1].value == "adax" and ins[2].value == "b",
        "Shift+Tab cycled focus back: name got 'x' (adax)")
    end,
  },
  -- clicking outside the inputs blurs (focus ring + cursor disappear)
  {
    eventFn = function()
      local heading = findText(t.uiMod.getTree(), "keyboard input + focus")
      local x, y = t.centerOf(heading)
      return { "tm_monitor_touch", x, y, false }
    end,
  },
  {
    snapshot = function()
      check(t.uiMod.getFocused() == nil, "clicking outside blurs the focused input")
    end,
  },
})

print("== flexbox playground (Layout tab) ==")
boot({
  { eventFn = clickButton("Layout") },
  {
    snapshot = function()
      local tree = t.uiMod.getTree()
      check(findText(tree, "justify: flex-start") ~= nil, "playground starts at justify: flex-start")
      check(findText(tree, "align: flex-start") ~= nil, "playground starts at align: flex-start")
      check(findText(tree, "asymmetric padding/margin") ~= nil,
        "padding/margin showcase present")
    end,
  },
  { eventFn = clickButton("J+") },
  {
    snapshot = function()
      check(findText(t.uiMod.getTree(), "justify: center") ~= nil, "J+ cycles justify to 'center'")
    end,
  },
  { eventFn = clickButton("J+") },
  { eventFn = clickButton("J+") },
  { eventFn = clickButton("J+") },
  { eventFn = clickButton("A+") },
  {
    snapshot = function()
      check(findText(t.uiMod.getTree(), "justify: space-around") ~= nil,
        "justify wraps through flex-end/space-between to space-around")
      check(findText(t.uiMod.getTree(), "align: center") ~= nil, "A+ cycles align to 'center'")
    end,
  },
  -- J- steps back one value
  { eventFn = clickButton("J-") },
  {
    snapshot = function()
      check(findText(t.uiMod.getTree(), "justify: space-between") ~= nil, "J- steps back to space-between")
    end,
  },
})

print("== scroll tab: wheel + click-through ==")
boot({
  { eventFn = clickButton("Scroll") },
  {
    snapshot = function()
      local tree = t.uiMod.getTree()
      check(findText(tree, "clicks: 0 clicks") ~= nil, "scroll tab: plural() info line ('clicks: 0 clicks')")
      check(findText(tree, "row 1") ~= nil, "first scroll row rendered")
      local sc = scrollNode()
      check(sc ~= nil and sc.contentH == 180, "scroll content is 180px tall (12 rows + long row + button)")
    end,
  },
  -- wheel down 12 times → clamped at maxY=70 (content 180 - viewport 110)
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  { eventFn = wheelOverScroll(1) },
  {
    snapshot = function()
      local sc = scrollNode()
      check(sc.scrollY == 70, "scroll clamps at maxY=70 (got " .. tostring(sc.scrollY) .. ")")
      local bottom = findButton(t.uiMod.getTree(), "Bottom")
      check(bottom ~= nil and bottom.y + bottom.h - 1 <= sc.y + sc.h - 1,
        "Bottom button visible after full scroll (click-through)")
    end,
  },
  -- click the Bottom button → click-through works after scrolling
  { eventFn = clickButton("Bottom") },
  {
    snapshot = function()
      check(findText(t.uiMod.getTree(), "clicks: 1 click") ~= nil,
        "Bottom button click-through incremented the counter ('clicks: 1 click')")
    end,
  },
})

print("== fresh boot starts clean ==")
boot({
  { eventFn = clickButton("Counter") },
  {
    snapshot = function()
      local countText = findText(t.uiMod.getTree(), "Count:")
      check(countText ~= nil and countText.text == "Count: 0", "fresh program starts at Count: 0")
    end,
  },
})

print("== network tab: mount fetch without a client reports the error ==")
-- The demo's Network tab auto-fetches on mount (useRequest). With no HTTP
-- client injected (the main program does that in-game), every fetch resolves
-- with { ok = false, error = "http client not set: ..." } through the real
-- default worker path — the tab shows the error instead of crashing.
boot({
  { eventFn = clickButton("Network") },
  {
    snapshot = function()
      local tree = t.uiMod.getTree()
      check(findText(tree, "network: async/await + fetch") ~= nil, "network tab rendered")
      check(findText(tree, "press a button") ~= nil, "status line in its initial state")
      check(findText(tree, "error: network error") ~= nil,
        "useRequest mount fetch error is shown (long no-client message collapsed by shortError)")
    end,
  },
})

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
      check(findText(tree, "cc-react") ~= nil, "parallel: home tab rendered first")
      check(stub.synced >= 1, "parallel: gpu.sync() called during the initial render")
    end,
  },
  { eventFn = clickButton("Counter") },
  { eventFn = clickButton("+") },
  {
    snapshot = function()
      local countText = findText(t.uiMod.getTree(), "Count:")
      check(countText ~= nil and countText.text == "Count: 1", "parallel: click processed by the UI task")
      check(#secondTaskEvents >= 1 and secondTaskEvents[1] == "tm_monitor_touch",
        "parallel: second task received the same touch event (broadcast)")
    end,
  },
  { eventFn = clickButton("Record") },
  {
    snapshot = function()
      local rows = textRows()
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
