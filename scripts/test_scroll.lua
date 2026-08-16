--[[
  Headless test for the Scroll viewport (scripts/fixtures/scroll).

  Boots dist/fixture-scroll.lua — a scroll container sitting high on screen —
  and asserts:

    1. layout: the scroll viewport is fixed (120px) while its content is
       measured at the full list height (200px) → scroll range 80px
    2. vertical clipping: a row below the viewport fold but still on screen
       is NOT painted (the background shows instead)
    3. horizontal clipping: a row wider than the viewport is sub-ranged —
       pixels beyond the viewport's right edge are not painted
    4. wheel scrolling with end clamping (dir=+1 = wheel down, matching the
       real device: KeyboardWidget maps delta<0 → +1)
    5. hit-testing through the scroll offset: a button inside the scrolled
       content is clickable once scrolled into view
    6. touch drag scrolling (content follows the finger)

  Usage: lua5.1 scripts/test_scroll.lua [path-to-module.lua]
]]

-- Capture the real os.exit BEFORE the stub replaces _G.os (cc_stub.lua
-- installs a stub os for the program under test).
local realExit = os.exit

local t = require("scripts.cc_stub")
local check = t.check
local boot = t.boot
local stub = t.stub
local findText = t.findText
local findButton = t.findButton
local clickButton = t.clickButton

t.MAIN = arg and arg[1] or "dist/fixture-scroll.lua"

local function scrollNode()
  return t.findNodes(t.uiMod.getTree(), function(n) return n.kind == "scroll" end)[1]
end

-- wheel event over the scroll viewport; dir follows the real-device
-- convention (verified in Tom's Peripherals source: wheel down → dir=+1)
local function wheelOverScroll(dir)
  return function()
    local sc = scrollNode()
    return { "tm_monitor_mouse_scroll", "mon_0", sc.x + 10, sc.y + 10, dir }
  end
end

print("== scroll fixture: layout + clipping ==")
boot({
  {
    snapshot = function()
      local sc = scrollNode()
      check(sc ~= nil, "scroll container present")
      check(sc.h == 120, "viewport height is 120px (" .. tostring(sc.h) .. ")")
      check(sc.contentH == 200, "content measured at the full height (200px)")
      check(sc.contentH - sc.h == 80, "scroll range is 80px")
      check(sc.scrollY == 0 and sc.scrollX == 0, "starts at offset 0")

      -- vertical clip: row 11 starts at the fold but is still on screen —
      -- its pixels must NOT be painted (the panel background shows instead)
      local row11 = findText(t.uiMod.getTree(), "row 11")
      check(row11 ~= nil, "row 11 present in the tree")
      check(row11.y >= sc.y + sc.h, "row 11 laid out at/below the fold")
      local ref = stub.buf[sc.y - 1][sc.x - 5]      -- panel bg beside the scroll
      local px = stub.buf[row11.y - 1][row11.x + 2] -- 3px into the row glyph
      check(px == ref, "row below the fold is clipped (panel bg, not text)")

      -- the long row and the button are below the fold at offset 0
      local long = findText(t.uiMod.getTree(), "This row")
      check(long ~= nil and long.w > sc.w,
        "long row is wider than the viewport (" .. tostring(long.w) .. " > " .. tostring(sc.w) .. ")")
      local btn = findButton(t.uiMod.getTree(), "Bottom")
      check(btn ~= nil and btn.y >= sc.y + sc.h, "'Bottom' button laid out below the fold")
    end,
  },
  -- wheel down 10 notches (80px) → clamped at maxY=80
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
      check(sc.scrollY == 80, "wheel scrolled to the end (clamped at 80px)")
      local long = findText(t.uiMod.getTree(), "This row")
      check(long.y + long.h - 1 <= sc.y + sc.h - 1, "long row visible at max scroll")
      -- horizontal clip: one pixel right of the viewport edge is not painted
      local ref = stub.buf[sc.y - 1][sc.x - 5]
      local px = stub.buf[long.y - 1][sc.x + sc.w] -- 0-based col = 1-based sc.x+sc.w+1
      check(px == ref, "long row clipped horizontally at the viewport edge")
    end,
  },
  -- click the button now that it has scrolled into view (hit test through
  -- the scroll offset)
  { eventFn = clickButton("Bottom") },
  {
    snapshot = function()
      local clicks = findText(t.uiMod.getTree(), "clicks:")
      check(clicks ~= nil and clicks.text == "clicks: 1",
        "button inside the scroll is clickable after scrolling")
    end,
  },
  -- touch drag: press inside the scroll, drag down 30px → content follows
  -- the finger (scrollY decreases)
  {
    eventFn = function()
      local sc = scrollNode()
      return { "tm_monitor_mouse_click", "mon_0", sc.x + 10, sc.y + 10, 1 }
    end,
  },
  {
    eventFn = function()
      local sc = scrollNode()
      return { "tm_monitor_mouse_drag", "mon_0", sc.x + 10, sc.y + 40, 1 }
    end,
  },
  {
    eventFn = function()
      local sc = scrollNode()
      return { "tm_monitor_mouse_up", "mon_0", sc.x + 10, sc.y + 40, 1 }
    end,
  },
  {
    snapshot = function()
      local sc = scrollNode()
      check(sc.scrollY == 50, "drag scrolled back by the finger delta (50px)")
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
