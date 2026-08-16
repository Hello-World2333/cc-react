--[[
  Headless test for Chinese text rendering (scripts/fixtures/chinese).

  Boots dist/fixture-chinese.lua with the opt-in custom font configured
  (ui.setChineseFont, called from preStart before start()). Asserts:

    1. font init inside start(): setFont("unicode_page_e0") + clearChars()
       + ASCII 0x20-0x7E registration (95 glyphs)
    2. UTF-8 -> slot encoding: Chinese text nodes draw as single-byte slot
       strings (你好世界 = 4 bytes, not 12) and measure with the 16px
       glyph advance (你好世界 @ fontSize 2 = 4 * 34 = 136px)
    3. lazy CJK registration: glyphs are addNewChar'd on first use
    4. missing chars fall back to the □ slot (0xFF) — the 龙 text
    5. Button with a Chinese label; clicking updates the text node
    6. Input: Chinese placeholder, pasting Chinese, char-aware Backspace /
       arrows (no half-UTF-8-char corruption)

  Usage: lua5.1 scripts/test_chinese.lua [path-to-module.lua]
]]

-- Capture the real os.exit BEFORE the stub replaces _G.os (cc_stub.lua
-- installs a stub os for the program under test).
local realExit = os.exit

local t = require("scripts.cc_stub")
local check = t.check
local boot = t.boot
local stub = t.stub
local findText = t.findText

t.MAIN = arg and arg[1] or "dist/fixture-chinese.lua"
local FONT_PATH = "scripts/fixtures/chinese/hanchan16.fnt"

-- count addNewChar calls whose char byte falls in a range
local function countAddNewChar(lo, hi)
  local n = 0
  for _, c in ipairs(stub.calls) do
    if c[1] == "addNewChar" then
      local b = c[2]:byte(1)
      if b >= lo and b <= hi then n = n + 1 end
    end
  end
  return n
end

-- the last drawText call whose text matches `text` (byte-exact)
local function findDrawText(text)
  for i = #stub.calls, 1, -1 do
    local c = stub.calls[i]
    if c[1] == "drawText" and c[4] == text then return c end
  end
  return nil
end

local function textNodes()
  return t.findNodes(t.uiMod.getTree(), function(n) return n.kind == "text" end)
end
local function bigText() return textNodes()[1] end
local function inputNode() return t.findNodes(t.uiMod.getTree(), function(n) return n.kind == "input" end)[1] end
local function cursorOf(path)
  local st = t.uiMod.getInputState(path)
  return st and st.cursor
end

-- event helpers
local function clickButton()
  return function()
    local b = t.findButton(t.uiMod.getTree(), "确认")
    if not b then error("button '确认' not found") end
    return { "tm_monitor_touch", "mon_0", b.x + math.floor(b.w / 2), b.y + math.floor(b.h / 2), false }
  end
end
local function clickInput()
  return function()
    local n = inputNode()
    return { "tm_monitor_touch", "mon_0", n.x + 4, n.y + 12, false }
  end
end
local function kbPaste(text)
  return function() return { "tm_keyboard_paste", "kb_0", text } end
end
local function kbKey(key)
  return function() return { "tm_keyboard_key", "kb_0", key } end
end

local function useFont(mod) mod.setChineseFont(FONT_PATH) end

print("== chinese fixture: font init + slot-encoded rendering ==")
boot({
  {
    snapshot = function()
      -- 1. font init
      local sawSetFont, sawClear = false, false
      for _, c in ipairs(stub.calls) do
        if c[1] == "setFont" and c[2] == "unicode_page_e0" then sawSetFont = true end
        if c[1] == "clearChars" then sawClear = true end
      end
      check(sawSetFont, "start() switched to the modifiable font (unicode_page_e0)")
      check(sawClear, "start() cleared the font before registering")
      check(countAddNewChar(0x20, 0x7E) == 95, "ASCII 0x20-0x7E registered (95 glyphs)")
      check(stub.chars[0xFF] ~= nil, "□ fallback registered at slot 0xFF")

      -- 2. UTF-8 -> slot encoding + 16px metrics
      local b = bigText()
      check(b ~= nil and b.text == "你好世界", "tree keeps the raw UTF-8 text")
      check(b.w == 136, "你好世界 measured at 4*34px (fontSize 2, 16px glyphs) — got " .. tostring(b.w))

      local dt = findDrawText(string.char(0x80, 0x81, 0x82, 0x83))
      check(dt ~= nil, "你好世界 drawn as 4 slot bytes (0x80-0x83)")

      -- 3. lazy CJK registration happened (slots 0x80+ beyond the □)
      local cjk = 0
      for b2, _ in pairs(stub.chars) do
        if b2 >= 0x80 and b2 < 0xFF then cjk = cjk + 1 end
      end
      check(cjk == 15, "CJK glyphs registered lazily from the font file (" .. cjk .. " slots)")

      -- 4. missing char -> □ (0xFF)
      local loong = findDrawText(string.char(0xFF))
      check(loong ~= nil, "missing char 龙 drawn as the □ slot byte (0xFF)")

      -- 5. Chinese button label drawn encoded
      local btn = t.findButton(t.uiMod.getTree(), "确认")
      check(btn ~= nil, "button label 确认 present")
    end,
  },
}, nil, useFont)

print("== chinese fixture: button click updates text ==")
boot({
  { eventFn = clickButton() },
  {
    snapshot = function()
      local b = bigText()
      check(b.text == "测试中文", "clicking 确认 updated the text to 测试中文")
      local dt = findDrawText(string.char(0x8F, 0x90, 0x91, 0x92))
      check(dt ~= nil, "测试中文 drawn as 4 slot bytes")
      local cjk = 0
      for b2, _ in pairs(stub.chars) do
        if b2 >= 0x80 and b2 < 0xFF then cjk = cjk + 1 end
      end
      check(cjk == 19, "new glyphs 测/试/中/文 registered lazily (" .. cjk .. " slots total)")
    end,
  },
}, nil, useFont)

print("== chinese fixture: input placeholder + paste + char-aware editing ==")
boot({
  {
    snapshot = function()
      local inp = inputNode()
      check(inp.placeholder == "请输入", "input placeholder is Chinese")
      check(inp.w == 220, "input laid out at 220px")
      -- placeholder glyphs: 请输入 = 3 slot bytes (请/输/入 not yet used -> 0x93+)
      local found = false
      for _, c in ipairs(stub.calls) do
        if c[1] == "drawText" and type(c[4]) == "string" and #c[4] == 3 and c[4]:byte(1) >= 0x80 then found = true end
      end
      check(found, "placeholder 请输入 drawn as 3 slot bytes")
    end,
  },
  { eventFn = clickInput() },
  {
    snapshot = function()
      local inp = inputNode()
      check(t.uiMod.getFocused() == inp.path, "click focused the input")
      check(cursorOf(inp.path) == 0, "cursor at 0 on focus")
    end,
  },
  { eventFn = kbPaste("你好") },
  {
    snapshot = function()
      local inp = inputNode()
      check(inp.value == "你好", "paste inserted the Chinese value")
      check(cursorOf(inp.path) == 6, "cursor advanced by 6 raw bytes")
      check(findDrawText(string.char(0x80, 0x81)) ~= nil,
        "value 你好 drawn as 2 slot bytes (0x80 0x81)")
    end,
  },
  -- char-aware Backspace: removes the whole 好 (3 bytes), not one byte
  { eventFn = kbKey(259) },
  {
    snapshot = function()
      local inp = inputNode()
      check(inp.value == "你", "Backspace removed the whole char 好 — got '" .. tostring(inp.value) .. "'")
      check(cursorOf(inp.path) == 3, "cursor back to 3 raw bytes")
    end,
  },
  -- Home / Left / Right char-aware movement
  { eventFn = kbKey(268) },
  {
    snapshot = function()
      check(cursorOf(inputNode().path) == 0, "Home moved to the start")
    end,
  },
  { eventFn = kbKey(262) },
  {
    snapshot = function()
      check(cursorOf(inputNode().path) == 3, "Right moved past the whole char 你 (3 bytes)")
    end,
  },
  { eventFn = kbKey(263) },
  {
    snapshot = function()
      check(cursorOf(inputNode().path) == 0, "Left moved back to the start")
    end,
  },
}, nil, useFont)

print("done: chinese fixture tests")
realExit(t.failures == 0 and 0 or 1)
