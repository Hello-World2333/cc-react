--[[
  Headless test for keyboard input + focus management
  (scripts/fixtures/input).

  Boots dist/fixture-input.lua — a panel with two <Input> fields (name +
  note), a live summary line and an onKey counter — and asserts:

    1. layout + placeholder: empty inputs draw their placeholder; the focus
       ring (border) is the normal color while unfocused
    2. click-to-focus: tapping an input focuses it and places the cursor at
       the clicked character; the border turns into the focus color
    3. typing: tm_keyboard_char inserts at the cursor; the value is reported
       through onChange and rendered back (controlled input)
    4. editing keys (GLFW codes, verified against the mod's source):
       Backspace 259 / Delete 261 / Left 263 / Right 262 / Home 268 /
       End 269 / Enter 257, incl. repeat events
    5. focus cycling: Tab 258 moves to the next input, Shift+Tab back
    6. blur: clicking a non-focusable area drops focus (ring + cursor gone)
    7. cursor blink: {"timer", id} ticks toggle the cursor's visibility
    8. paste: tm_keyboard_paste inserts clipboard text at the cursor
    9. onKey hook: raw (key, isUp) callbacks fire for press and release

  Usage: lua5.1 scripts/test_input.lua [path-to-module.lua]
]]

-- Capture the real os.exit BEFORE the stub replaces _G.os (cc_stub.lua
-- installs a stub os for the program under test).
local realExit = os.exit

local t = require("scripts.cc_stub")
local check = t.check
local boot = t.boot
local stub = t.stub
local findText = t.findText

t.MAIN = arg and arg[1] or "dist/fixture-input.lua"

-- signed int32 the stub buffer stores (colors arrive through __color)
local function signed(c)
  if c > 2147483647 then return c - 4294967296 end
  return c
end
local C_FOCUS = signed(0xFF7EC8FF)       -- focusBorderColor / cursorColor
local C_BORDER = signed(0xFF4A4A5A)      -- default input border
local C_PLACEHOLDER = signed(0xFF6A6A78) -- placeholderColor
local C_BG = signed(0xFF17171E)          -- input background

local function inputNodes()
  return t.findNodes(t.uiMod.getTree(), function(n) return n.kind == "input" end)
end
local function input1() return inputNodes()[1] end
local function input2() return inputNodes()[2] end
local function cursorOf(path)
  local st = t.uiMod.getInputState(path)
  return st and st.cursor
end
local function summaryText()
  local n = findText(t.uiMod.getTree(), "name: ")
  return n and n.text
end

-- event helpers (evaluated at pull time → read the live tree)
local function touchAt(n, xOffset)
  return function()
    local node = n()
    return { "tm_monitor_touch", "mon_0", node.x + xOffset, node.y + 12, false }
  end
end
local function touchOutside(y)
  return function() return { "tm_monitor_touch", "mon_0", 30, y, false } end
end
local function kbKey(key, isRepeat)
  return function() return { "tm_keyboard_key", "kb_0", key, isRepeat == true } end
end
local function kbKeyUp(key)
  return function() return { "tm_keyboard_key_up", "kb_0", key } end
end
local function kbChar(ch)
  return function() return { "tm_keyboard_char", "kb_0", ch } end
end
local function kbPaste(text)
  return function() return { "tm_keyboard_paste", "kb_0", text } end
end
local function timerTick()
  return function() return { "timer", 1 } end
end

print("== input fixture: layout, placeholder, focus ring ==")
boot({
  {
    snapshot = function()
      local tree = t.uiMod.getTree()
      check(tree ~= nil, "boot: root tree exists")

      local inputs = inputNodes()
      check(#inputs == 2, "two input nodes in the tree")
      local in1, in2 = inputs[1], inputs[2]
      check(in1.placeholder == "your name" and in2.placeholder == "a note",
        "placeholders wired to the nodes")
      check(in1.value == "" and in2.value == "", "values start empty")
      check(in1.w == 160 and in1.h == 24,
        "input laid out at its explicit size (" .. tostring(in1.w) .. "x" .. tostring(in1.h) .. ")")
      check(t.uiMod.getFocused() == nil, "nothing focused at boot")

      check(summaryText() == "name: (empty) | note: (empty)",
        "summary shows empty values")
      local lastkey = findText(tree, "lastkey:")
      check(lastkey ~= nil and lastkey.text == "lastkey: -1",
        "onKey counter starts at -1 (no keys yet)")

      -- placeholder glyph painted (first cell of 'your name'); the stub
      -- buffer stores 1-based GPU coords as b[y][x]
      local px = stub.buf[in1.y + 4][in1.x + 4]
      check(px == C_PLACEHOLDER,
        "placeholder text drawn in placeholderColor (0x" .. string.format("%X", px + 4294967296) .. ")")
      -- unfocused border is the default borderColor
      check(stub.buf[in1.y][in1.x] == C_BORDER,
        "unfocused input shows the default border color")
    end,
  },
})

print("== click-to-focus + typing ==")
boot({
  -- tap the left edge of input 1 → focus, cursor at 0
  { eventFn = touchAt(input1, 4) },
  {
    snapshot = function()
      local in1 = input1()
      check(t.uiMod.getFocused() == in1.path, "click focused input 1")
      check(cursorOf(in1.path) == 0, "cursor placed at the tapped character (0)")
      check(stub.buf[in1.y][in1.x] == C_FOCUS,
        "focused input shows the focus-ring border color")
    end,
  },
  -- type "ali"
  { eventFn = kbChar("a") },
  { eventFn = kbChar("l") },
  { eventFn = kbChar("i") },
  {
    snapshot = function()
      local in1 = input1()
      check(in1.value == "ali", "typing built the value 'ali' (controlled)")
      check(cursorOf(in1.path) == 3, "cursor advanced to the end (3)")
      check(summaryText() == "name: ali | note: (empty)",
        "summary reflects the typed value")
      -- cursor is a 2px bar right after the text ("ali" = 18px + 4 padding)
      local cx = in1.x + 4 + 18
      check(stub.buf[in1.y + 6][cx] == C_FOCUS,
        "cursor bar painted at the insertion point (cursorColor)")
    end,
  },
  -- Backspace removes the last char
  { eventFn = kbKey(259) },
  {
    snapshot = function()
      local in1 = input1()
      check(in1.value == "al", "Backspace deleted the last char ('al')")
      check(cursorOf(in1.path) == 2, "cursor moved back with the deletion")
    end,
  },
  -- Left arrow then a char → inserts at the cursor
  { eventFn = kbKey(263) },
  { eventFn = kbChar("x") },
  {
    snapshot = function()
      local in1 = input1()
      check(in1.value == "axl", "Left + char inserted at the cursor ('axl')")
      check(cursorOf(in1.path) == 2, "cursor after the inserted char")
      local lastkey = findText(t.uiMod.getTree(), "lastkey:")
      check(lastkey.text == "lastkey: 263", "onKey fired for the arrow (key=263, press)")
    end,
  },
  -- Home + char → prepend
  { eventFn = kbKey(268) },
  { eventFn = kbChar("Z") },
  {
    snapshot = function()
      local in1 = input1()
      check(in1.value == "Zaxl", "Home + char prepended ('Zaxl')")
      check(cursorOf(in1.path) == 1, "cursor after the prepended char")
    end,
  },
  -- End + char → append
  { eventFn = kbKey(269) },
  { eventFn = kbChar("!") },
  {
    snapshot = function()
      local in1 = input1()
      check(in1.value == "Zaxl!", "End + char appended ('Zaxl!')")
      check(cursorOf(in1.path) == 5, "cursor at the end (5)")
    end,
  },
})

print("== Tab / Shift+Tab focus cycling ==")
boot({
  -- focus input 1 and type a bit
  { eventFn = touchAt(input1, 4) },
  { eventFn = kbChar("Z") },
  { eventFn = kbChar("!") },
  {
    snapshot = function()
      local in1 = input1()
      check(t.uiMod.getFocused() == in1.path, "input 1 focused before Tab")
      check(in1.value == "Z!", "input 1 has 'Z!'")
    end,
  },
  -- Tab → focus input 2
  { eventFn = kbKey(258) },
  {
    snapshot = function()
      local in2 = input2()
      check(t.uiMod.getFocused() == in2.path, "Tab moved focus to input 2")
      check(cursorOf(in2.path) == 0, "input 2 cursor starts at 0")
    end,
  },
  -- type in input 2
  { eventFn = kbChar("h") },
  { eventFn = kbChar("i") },
  {
    snapshot = function()
      local in2 = input2()
      check(in2.value == "hi", "typing went to the focused input 2 ('hi')")
      check(summaryText() == "name: Z! | note: hi", "summary shows both values")
    end,
  },
  -- Shift+Tab → back to input 1 (shift key tracked separately)
  { eventFn = kbKey(340) },
  { eventFn = kbKey(258) },
  { eventFn = kbKeyUp(340) },
  {
    snapshot = function()
      local in1 = input1()
      check(t.uiMod.getFocused() == in1.path,
        "Shift+Tab moved focus back to input 1")
      check(cursorOf(in1.path) == 2, "input 1 cursor preserved (2)")
    end,
  },
})

print("== editing around the cursor + submit + paste ==")
boot({
  { eventFn = touchAt(input1, 4) },
  { eventFn = kbChar("Z") },
  { eventFn = kbChar("a") },
  { eventFn = kbChar("x") },
  { eventFn = kbChar("l") },
  { eventFn = kbChar("!") },
  { eventFn = kbKey(263) }, -- cursor 4
  { eventFn = kbKey(261) }, -- Delete removes the char AT the cursor ('!')
  {
    snapshot = function()
      local in1 = input1()
      check(in1.value == "Zaxl", "Delete removed the char at the cursor ('Zaxl')")
      check(cursorOf(in1.path) == 4, "cursor unchanged by Delete")
    end,
  },
  -- Enter submits
  { eventFn = kbKey(257) },
  {
    snapshot = function()
      local sub = findText(t.uiMod.getTree(), "submits:")
      check(sub ~= nil and sub.text == "submits: 1 last: Zaxl",
        "Enter fired onSubmit (submits: 1 last: Zaxl)")
    end,
  },
  -- paste inserts at the cursor
  { eventFn = kbPaste(" World") },
  {
    snapshot = function()
      local in1 = input1()
      check(in1.value == "Zaxl World", "paste inserted the clipboard text")
      check(cursorOf(in1.path) == 10, "cursor after the pasted text")
    end,
  },
  -- click-to-position: tap 3 chars in → cursor lands at index 3
  { eventFn = touchAt(input1, 4 + 6 * 3) },
  {
    snapshot = function()
      local in1 = input1()
      check(cursorOf(in1.path) == 3, "click placed the cursor at the tapped char (3)")
    end,
  },
  { eventFn = kbChar("?") },
  {
    snapshot = function()
      local in1 = input1()
      check(in1.value == "Zax?l World", "char inserted at the tapped position")
      check(cursorOf(in1.path) == 4, "cursor after the inserted char")
    end,
  },
  -- key release routes onKey(key, true) without re-editing; the fixture's
  -- press-only handler keeps the last PRESSED key (Enter 257)
  { eventFn = kbKeyUp(263) },
  {
    snapshot = function()
      local in1 = input1()
      check(in1.value == "Zax?l World", "key release did not edit the value")
      local lastkey = findText(t.uiMod.getTree(), "lastkey:")
      check(lastkey.text == "lastkey: 257",
        "onKey release event ignored by the fixture's press-only handler")
    end,
  },
})

print("== blur + cursor blink + key repeat ==")
boot({
  { eventFn = touchAt(input1, 4) },
  { eventFn = kbChar("a") },
  {
    snapshot = function()
      local in1 = input1()
      check(in1.value == "a", "input 1 has 'a'")
      check(t.uiMod.getFocused() == in1.path, "input 1 focused")
    end,
  },
  -- click a non-focusable spot → blur
  { eventFn = touchOutside(150) },
  {
    snapshot = function()
      local in1 = input1()
      check(t.uiMod.getFocused() == nil, "clicking outside blurred the input")
      check(stub.buf[in1.y][in1.x] == C_BORDER,
        "focus ring replaced by the default border after blur")
      -- the cursor is gone: the pixel where the bar was is no longer
      -- cursorColor (input background or glyph shows instead)
      local cx = in1.x + 4 + 6 -- cursor 1 → one char in
      check(stub.buf[in1.y + 6][cx] ~= C_FOCUS,
        "cursor bar no longer painted after blur")
    end,
  },
  -- refocus, then tick the blink timer twice → visibility toggles
  { eventFn = touchAt(input1, 4) },
  {
    snapshot = function()
      local in1 = input1()
      check(t.uiMod.getFocused() == in1.path, "refocused input 1")
      check(in1.cursorVisible == true, "cursor visible right after focus (blink on)")
    end,
  },
  { eventFn = timerTick() },
  {
    snapshot = function()
      local in1 = input1()
      check(in1.cursorVisible == false, "timer tick hid the cursor (blink off)")
    end,
  },
  { eventFn = timerTick() },
  {
    snapshot = function()
      local in1 = input1()
      check(in1.cursorVisible == true, "second timer tick showed the cursor again")
    end,
  },
  -- auto-repeat: a repeat Backspace (isRepeat=true) still edits. The refocus
  -- click placed the cursor at 0 while 'a' was already in the field, so move
  -- to the end and type before holding Backspace.
  { eventFn = kbKey(269) },
  { eventFn = kbChar("b") },
  { eventFn = kbKey(259, true) },
  {
    snapshot = function()
      local in1 = input1()
      check(in1.value == "a", "repeat Backspace deleted a char (auto-repeat works)")
      check(cursorOf(in1.path) == 1, "cursor moved with the repeat deletion")
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
