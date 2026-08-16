--[[
  Headless test for multi-file import support (scripts/fixtures/multi).

  Boots dist/fixture-multi.lua — a small app split across files with
  import/export — and asserts the import mechanisms added with multi-file
  support:

    1. components defined in OTHER files render (named + default exports)
    2. hooks (useState) work inside imported component files
    3. two files exporting the SAME component name are renamed consistently
       by the bundler (JSX tag and render function stay in sync)
    4. a .ts helper module (constants + a pure function) is inlined and usable
    5. an imported hex-color constant reaches the runtime as a STRING and is
       parsed by __color (compile-time folding only sees same-file literals)

  Usage: lua5.1 scripts/test_multiimport.lua [path-to-module.lua]
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

t.MAIN = arg and arg[1] or "dist/fixture-multi.lua"

print("== multi-file import: boot + cross-file rendering ==")
boot({
  {
    snapshot = function()
      local tree = t.uiMod.getTree()
      check(tree ~= nil, "boot: root tree exists")

      local counter = findText(tree, "counter:")
      check(counter ~= nil and counter.text == "counter: 0",
        "imported component renders, hooks initialized (counter: 0)")

      check(findText(tree, "one") ~= nil,
        "Widget (file A) rendered via named import")
      check(findText(tree, "extra:two") ~= nil,
        "Widget (file B) rendered despite name collision (renamed by bundler)")

      local def = findText(tree, "default export works")
      check(def ~= nil, "default-export component rendered")
      check(def.style.color == "#7ec8ff",
        "imported color constant kept as the theme value in the tree")

      local helper = findText(tree, "#fixture label 7")
      check(helper ~= nil and helper.text == "#fixture label 7",
        ".ts helper module inlined (constant + pure function)")
    end,
  },
  -- hooks inside the imported Counter component: click its "up" button
  { eventFn = clickButton("up") },
  {
    snapshot = function()
      local counter = findText(t.uiMod.getTree(), "counter:")
      check(counter ~= nil and counter.text == "counter: 1",
        "useState inside an imported component file works (counter: 1 after click)")
    end,
  },
})

print("== multi-file import: runtime hex-string color ==")
-- DefaultThing's color comes from an imported constant ('#7ec8ff'), which
-- reaches the runtime as a STRING; __color must fold it to the same signed
-- int32 the compiler emits for a same-file literal (0xFF7EC8FF → -8468225).
local found
for i = 1, #stub.calls do
  local c = stub.calls[i]
  -- recorded as { "drawText", x, y, text, fg, bg, size, pad }
  if c[1] == "drawText" and c[4] == "default export works" and c[5] == -8468225 then
    found = true
    break
  end
end
check(found, "imported color constant parsed at runtime (drawText fg = 0xFF7EC8FF)")

print("")
if t.failures == 0 then
  print("ALL TESTS PASSED")
  realExit(0)
else
  print(t.failures .. " TEST(S) FAILED")
  realExit(1)
end
