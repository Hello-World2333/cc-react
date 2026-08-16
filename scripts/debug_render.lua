--[[
  Throwaway debug script: render each showcase tab to a PPM image so the
  layout can be inspected visually. Usage:
      lua5.1 scripts/debug_render.lua
  Output: dist/render-<tab>.ppm
]]

local t = require("scripts.cc_stub")
local clickButton = t.clickButton

local function dump(name)
  return function()
    local f = io.open("dist/render-" .. name .. ".ppm", "w")
    f:write("P3\n" .. t.VW .. " " .. t.VH .. "\n255\n")
    for y = 0, t.VH - 1 do
      for x = 0, t.VW - 1 do
        local c = t.stub.buf[y][x]
        local r = math.floor(c / 0x10000) % 256
        local g = math.floor(c / 0x100) % 256
        local b = c % 256
        f:write(r .. " " .. g .. " " .. b .. " ")
      end
      f:write("\n")
    end
    f:close()
    print("dumped dist/render-" .. name .. ".ppm")
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
  steps[#steps + 1] = { snapshot = dump(name) }
  local ok, err = pcall(t.boot, steps)
  if not ok then print("boot failed: " .. tostring(err)) end
end
