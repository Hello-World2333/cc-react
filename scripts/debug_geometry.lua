--[[
  Throwaway debug script: audit each tab's tree geometry against the real
  device target (192x256 px = 3x4 monitors at resolution 64). Reports any
  text that would extend past x=192, any box running off the bottom, and any
  sibling overlaps among top-level content rows. Usage:
      lua5.1 scripts/debug_geometry.lua
]]

local t = require("scripts.cc_stub")
local clickButton = t.clickButton
local findNodes = t.findNodes

local SCREEN_W = 192 -- 3 monitors wide at 64px
local SCREEN_H = 256

local function audit(name, steps)
  local problems = {}
  local ok, err = pcall(t.boot, steps)
  if not ok then
    print(name .. ": BOOT FAILED: " .. tostring(err))
    return
  end
  local tree = t.uiMod.getTree()
  local nodes = findNodes(tree, function() return true end)
  for _, n in ipairs(nodes) do
    -- content inside a scroll viewport is clipped on purpose (vertical rows,
    -- the over-long demo row) — skip it
    local inScroll = false
    local p = n.parent
    while p do
      if p.kind == "scroll" then inScroll = true break end
      p = p.parent
    end
    local tw = 0
    local str = ""
    if n.kind == "text" or n.kind == "button" then
      str = n.kind == "text" and (n.text or "") or (n.label or "")
      local fs = n.style.fontSize or 1
      tw = #str * (5 + (n.style.textPadding or 1)) * fs
    end
    if not inScroll and n.x + tw - 1 > SCREEN_W then
      problems[#problems + 1] = string.format(
        "text overflow: '%s' x=%d w=%d ends at %d (>192)", str, n.x, tw, n.x + tw - 1)
    end
    if not inScroll and n.y + n.h - 1 > SCREEN_H then
      problems[#problems + 1] = string.format(
        "off bottom: %s x=%d y=%d w=%d h=%d ends at %d", n.kind, n.x, n.y, n.w, n.h, n.y + n.h - 1)
    end
  end
  if #problems == 0 then
    print(name .. ": geometry OK (" .. #nodes .. " nodes, content within 192x256)")
  else
    print(name .. ": " .. #problems .. " problem(s):")
    for _, p in ipairs(problems) do print("  - " .. p) end
  end
end

local tabs = {
  { "home", nil },
  { "layout", "Layout" },
  { "counter", "Counter" },
  { "input", "Input" },
  { "scroll", "Scroll" },
  { "network", "Network" },
}
for _, spec in ipairs(tabs) do
  local name, btn = spec[1], spec[2]
  local steps = {}
  if btn then steps[#steps + 1] = { eventFn = clickButton(btn) } end
  steps[#steps + 1] = { snapshot = function() end }
  audit(name, steps)
end
