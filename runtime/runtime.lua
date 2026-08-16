--[[
  cc-react framework runtime (embedded into every compiled UI *module*).

  The compiled .tsx program produces a *style tree* (nodes built by the
  __box / __text / __panel / __button factories). This runtime:
    1. hooks state slots      (useState / useEffect compiled onto __useState / __useEffect)
    2. flexbox layout engine  (measure + place, text sized via gpu.getTextLength)
    3. dirty-rect renderer    (compare old/new layout trees, repaint only changes)
    4. event routing          (tm_monitor_touch / tm_monitor_mouse_* hit-testing)

  Entry model — the compiled output is a MODULE, not a standalone program:
    - at load time the top-level render(<App/>) only *mounts* the root
      component (__mount); no GPU work happens on require
    - the module returns a table whose `start(side)` is a blocking *task
      function* for simpleParallel (parallel.waitForAll): it initializes the
      GPU (blocking refreshSize), renders the first frame, then loops on
      os.pullEvent + dirty-rect repaint. The main program composes it with the
      network stack tasks, e.g.:

          local simpleParallel = require("lib.simpleParallel")
          local ui = require("ui")
          simpleParallel.add(function() ui.start("left") end)
          -- future: simpleParallel.add(networkTask)
          simpleParallel.start()

      CC's parallel scheduler first resumes every task with an empty event, so
      the initial frame renders before the first real event; afterwards every
      event is broadcast to all unfiltered consumers, so the UI loop sees the
      events it needs while the other tasks run concurrently.

  Coordinate convention: the framebuffer is 1-based (1..widthPx / 1..heightPx),
  matching tm_monitor_touch / tm_monitor_mouse_click pixel coordinates. The GPU
  adapter below translates to whatever base the real GPU expects (DRAW_OFFSET).
]]

local peripheral = peripheral
local os = os
local math = math
local table = table
local type = type
local tostring = tostring
local tonumber = tonumber
local ipairs = ipairs
local pairs = pairs
local error = error
local pcall = pcall
local select = select

-- viewport (must be declared before the GPU adapter, which reads it to clamp)
local __viewportW, __viewportH = 0, 0

-- ============================================================
-- 0. GPU adapter
-- ============================================================

-- GPU is resolved inside start(side), NOT at module load: the module is
-- require'd by a main program, which passes the GPU side explicitly
-- (ui.start("left")); the module never touches the shell's `arg` global.
local gpu

-- Coordinate convention: the GPU API is 1-based (verified against the mod's
-- bytecode: filledRectangle/drawText subtract 1 internally and throw
-- "Out of boundary" when x < 1 or y < 1). Events (tm_monitor_*) are also
-- 1-based (monitorPos adds +1). The framebuffer is uniformly 1-based and
-- coordinates pass through the adapter unchanged.

local RESOLUTION = 64        -- gpu.setSize(64): each monitor block = 64x64 px
-- Default font is 5x8 px at size 1 (verified: ascii.bin header byte 0x08 is
-- Font.fontHeight; 256 chars × 8 rows × 4B = 8192B tail matches the file size).
local FONT_W = 5
local FONT_H = 8
local FULL_REPAINT_RATIO = 0.4
-- Extra margin added to every dirty rect: covers glyphs that draw a pixel or
-- two beyond their measured box (sub-pixel centering, font metric rounding).
local DIRTY_PAD = 2
-- Upper bound for measuring scroll content in the scroll axis (far beyond any
-- CC screen; "100%" children along the scroll axis are user error).
local SCROLL_MAX = 100000

local COLOR_BG   = 0xFF0E0E12
local COLOR_TEXT = 0xFFFFFFFF

-- Normalize ARGB colors to signed int32. Compile-time colors are emitted as
-- unsigned (e.g. 0xFF131318 = 4279440152); Lua→Java conversion behaves
-- differently across bridges (LuaJ intValue wraps, a plain (int) cast
-- saturates). The signed int32 value is correct under BOTH conversions.
-- (The probe showed plain unsigned values also render fine on this mod.)
-- Hex strings ("#rgb" / "#rrggbb" / "#aarrggbb") are accepted too: colors
-- imported from other files (e.g. a theme module) arrive as runtime strings
-- — compile-time folding only sees string literals in the same file.
local function __color(c)
  if type(c) == "number" then
    if c > 2147483647 then return c - 4294967296 end
    return c
  end
  if type(c) == "string" and c:sub(1, 1) == "#" then
    local h = c:sub(2)
    if #h == 3 then h = h:gsub(".", "%0%0") end
    if #h == 6 then return __color(0xFF000000 + tonumber(h, 16)) end
    if #h == 8 then return __color(tonumber(h, 16)) end
  end
  return c
end

local __gpu = {}
function __gpu.refreshSize() gpu.refreshSize() end
function __gpu.setSize(n) gpu.setSize(n) end
function __gpu.sync() gpu.sync() end
function __gpu.fill(c) gpu.fill(__color(c)) end
function __gpu.getSize()
  return gpu.getSize()
end

-- Intersect a draw box with the viewport AND an optional clip rect (the
-- visible part of a scroll container). Returns 1-based inclusive edges
-- x1, y1, x2, y2, or nil when nothing survives.
local function __clipBox(x, y, w, h, clip)
  local x1, y1 = x, y
  local x2, y2 = x + w - 1, y + h - 1
  if x1 < 1 then x1 = 1 end
  if y1 < 1 then y1 = 1 end
  if x2 > __viewportW then x2 = __viewportW end
  if y2 > __viewportH then y2 = __viewportH end
  if clip then
    local cx2 = clip.x + clip.w - 1
    local cy2 = clip.y + clip.h - 1
    if x1 < clip.x then x1 = clip.x end
    if y1 < clip.y then y1 = clip.y end
    if x2 > cx2 then x2 = cx2 end
    if y2 > cy2 then y2 = cy2 end
  end
  if x1 > x2 or y1 > y2 then return nil end
  return x1, y1, x2, y2
end

-- Clamp a 1-based box to the viewport (and an optional scroll clip). The GPU
-- throws "Out of boundary" when x or y is < 1, and (unlike filledRectangle)
-- drawText throws when the text would extend past the right/bottom edge — so
-- anything off-screen is skipped.
function __gpu.filledRectangle(x, y, w, h, c, clip)
  if w <= 0 or h <= 0 then return end
  local x1, y1, x2, y2 = __clipBox(x, y, w, h, clip)
  if x1 == nil then return end
  gpu.filledRectangle(x1, y1, x2 - x1 + 1, y2 - y1 + 1, __color(c))
end
function __gpu.rectangle(x, y, w, h, c, clip)
  if w <= 0 or h <= 0 then return end
  local x1, y1, x2, y2 = __clipBox(x, y, w, h, clip)
  if x1 == nil then return end
  gpu.rectangle(x1, y1, x2 - x1 + 1, y2 - y1 + 1, __color(c))
end
function __gpu.drawText(x, y, t, fg, bg, size, pad, clip)
  -- Skip entirely if the text would extend past the screen edge (drawText
  -- throws "Out of boundary" instead of clipping).
  if x < 1 or y < 1 then return end
  local fs = size or 1
  local tp = pad or 1 -- the mod's default padding (1px between characters)
  local tw = gpu.getTextLength(t, fs, tp)
  local th = FONT_H * fs -- glyph height = fontHeight(8) x size; padding does not affect height
  if x + tw - 1 > __viewportW or y + th - 1 > __viewportH then return end
  -- drawText requires explicit Numbers for fg/bg (nil → "Bad argument #5:
  -- (expected Number)"). -1 is the mod's "no background" sentinel; colors
  -- must be signed int32 because the mod converts them via a saturating
  -- (int) cast (MathHelper.floor does d2i).
  local fg2 = fg ~= nil and __color(fg) or COLOR_TEXT
  local bg2 = bg ~= nil and __color(bg) or -1
  if clip then
    -- A glyph row cannot be clipped part-way (drawText paints whole glyphs):
    -- the row must fit vertically inside the clip. Horizontally we split the
    -- string into the visible char span (per-char advance via getTextLength).
    if y < clip.y or y + th - 1 > clip.y + clip.h - 1 then return end
    if x >= clip.x and x + tw - 1 <= clip.x + clip.w - 1 then
      gpu.drawText(x, y, t, fg2, bg2, fs, tp)
      return
    end
    local a, b = nil, nil
    local cum = 0
    for i = 1, #t do
      local cw = gpu.getTextLength(t:sub(i, i), fs, tp)
      local startX = x + cum
      local endX = startX + cw - 1
      if a == nil and startX >= clip.x then a = i end
      if a then
        if endX > clip.x + clip.w - 1 then b = i - 1 break end
        b = i
      end
      cum = cum + cw
    end
    if a == nil or (b ~= nil and b < a) then return end
    if b == nil then b = #t end
    local off = a > 1 and gpu.getTextLength(t:sub(1, a - 1), fs, tp) or 0
    gpu.drawText(x + off, y, t:sub(a, b), fg2, bg2, fs, tp)
    return
  end
  gpu.drawText(x, y, t, fg2, bg2, fs, tp)
end
function __gpu.getTextLength(t, size, pad)
  return gpu.getTextLength(t, size, pad)
end

-- Startup sequence (refreshSize is BLOCKING — it returns after the mod has
-- re-detected the connected screens):
--   1. refreshSize()  — re-detect screens so the program adapts to layout
--                       changes since the last run (must run on EVERY boot)
--   2. setSize(64)    — apply the resolution multiplier
--   3. getSize()      — read the final pixel viewport
-- No polling: dynamic re-detection while running is out of scope for the MVP.
-- Runs inside start(side): the side comes from the main program, defaulting
-- to "left" so `simpleParallel.add(ui.start)` works for the common layout.
local function __gpuReady(side)
  local s = side or "left"
  gpu = peripheral.wrap(s)
  if not gpu then
    error("cc-react: no GPU peripheral found on side '" .. tostring(s)
      .. "' (pass the side to ui.start(side))", 0)
  end
  __gpu.refreshSize()
  __gpu.setSize(RESOLUTION)
  local w, h = __gpu.getSize()
  if w == nil or w <= 0 or h == nil or h <= 0 then
    error("cc-react: no monitors detected (getSize returned " .. tostring(w) .. "x" .. tostring(h)
      .. ") — check the GPU is next to Tom's Peripherals Monitor blocks", 0)
  end
  return w, h
end

-- ============================================================
-- 1. Style helpers
-- ============================================================

local function __box4(v)
  if v == nil then return 0, 0, 0, 0 end
  if type(v) == "number" then return v, v, v, v end
  if type(v) == "table" then
    return v.top or 0, v.right or 0, v.bottom or 0, v.left or 0
  end
  error("cc-react: margin/padding must be a number or {top,right,bottom,left}", 0)
end

-- Flatten margin/padding into per-side numbers so style tables only hold
-- scalars (cheap, deterministic dirty comparison).
local function __normalizeStyle(style)
  local s = {}
  if style then
    for k, v in pairs(style) do s[k] = v end
  end
  local margin = s.margin
  local padding = s.padding
  s.margin = nil
  s.padding = nil
  s.marginT, s.marginR, s.marginB, s.marginL = __box4(margin)
  s.paddingT, s.paddingR, s.paddingB, s.paddingL = __box4(padding)
  -- per-side overrides (marginTop / marginBottom / ...)
  if s.marginTop ~= nil then s.marginT = s.marginTop end
  if s.marginRight ~= nil then s.marginR = s.marginRight end
  if s.marginBottom ~= nil then s.marginB = s.marginBottom end
  if s.marginLeft ~= nil then s.marginL = s.marginLeft end
  if s.paddingTop ~= nil then s.paddingT = s.paddingTop end
  if s.paddingRight ~= nil then s.paddingR = s.paddingRight end
  if s.paddingBottom ~= nil then s.paddingB = s.paddingBottom end
  if s.paddingLeft ~= nil then s.paddingL = s.paddingLeft end
  return s
end

-- ============================================================
-- 2. Node factories
-- ============================================================

local function __makeNode(kind, props, defaults)
  local style = {}
  if defaults then
    for k, v in pairs(defaults) do style[k] = v end
  end
  if props.style then
    for k, v in pairs(props.style) do style[k] = v end
  end
  style = __normalizeStyle(style)
  local node = {
    __isNode = true,
    kind = kind,
    style = style,
    text = props.text,
    label = props.label,
    onClick = props.onClick,
    onMouseDown = props.onMouseDown,
    onMouseUp = props.onMouseUp,
    children = props.children or {},
    parent = nil,
    path = nil,
    pressed = false,
    x = 0, y = 0, w = 0, h = 0,
    -- scroll viewport: content size + current offset (set during layout)
    scrollX = 0, scrollY = 0, contentW = 0, contentH = 0,
  }
  return node
end

local function __box(props)
  return __makeNode("box", props)
end

local function __panel(props)
  return __makeNode("panel", props, { backgroundColor = COLOR_BG })
end

local function __text(props)
  return __makeNode("text", props, { color = COLOR_TEXT })
end

local function __button(props)
  return __makeNode("button", props, {
    backgroundColor = 0xFF2A2A35,
    borderColor = 0xFF4A4A5A,
    pressedColor = 0xFF3A3A48,
    color = COLOR_TEXT,
    padding = 6,
    fontSize = 1,
  })
end

-- Scrollable viewport: children are laid out at their FULL content size and
-- clipped to this box; scrollX/scrollY (internal state keyed by node path)
-- pan the content. Scrolled by tm_monitor_mouse_scroll (wheel) and by touch
-- drag (tm_monitor_mouse_click + _drag). Style: height/width fix the viewport
-- (auto = fill the parent's inner box), scrollStep = px per wheel notch
-- (default 8 = one 5x8 text row), flexDirection = scroll axis (column default).
local function __scroll(props)
  return __makeNode("scroll", props, {})
end

-- Normalize JSX children into a flat array of nodes.
-- - nil / false / true are dropped
-- - nested arrays are flattened
-- - plain strings/numbers become unstyled text nodes
local function __children(list)
  local out = {}
  local function add(v)
      if v == nil or v == false or v == true then return end
    local t = type(v)
    if t == "table" then
      if v.__isNode then
        table.insert(out, v)
      else
        for _, c in ipairs(v) do add(c) end
      end
    elseif t == "string" or t == "number" then
      table.insert(out, __text({ text = tostring(v) }))
    end
  end
  -- Compiled children tables can contain nil holes (e.g. a ternary that
  -- produced nil); ipairs stops at the first hole, so walk by the largest
  -- integer key instead.
  local n = 0
  for k in pairs(list) do
    if type(k) == "number" and k > n then n = k end
  end
  for i = 1, n do add(list[i]) end
  return out
end

-- JS Array.prototype.map compiled onto this (compact: nil results dropped).
local function __map(list, fn)
  local out = {}
  if list then
    for i = 1, #list do
      local r = fn(list[i], i - 1)
      if r ~= nil then table.insert(out, r) end
    end
  end
  return out
end

-- JS array literal with spread, e.g. [...a, b] — flattens table args.
local function __arr(...)
  local out = {}
  local n = select("#", ...)
  for i = 1, n do
    local v = select(i, ...)
    if type(v) == "table" and not v.__isNode then
      for j = 1, #v do table.insert(out, v[j]) end
    else
      table.insert(out, v)
    end
  end
  return out
end

-- ============================================================
-- 3. Hooks (state slots)
-- ============================================================

local __state = {}        -- __state[pathKey] = { slots = {...}, effects = {...} }
local __lastComp = {}     -- __lastComp[pathKey] = component fnId
local __pathStack = {}    -- DFS component instance indices
local __instanceCount = 0
local __currentPath = ""
local __hookIdx = 0
local __pendingEffects = {}
local __renderQueued = false
local __pressedPath = nil
local __rootFn = nil
local __lastTree = nil
local __scrollState = {}  -- __scrollState[path] = { x, y, maxX, maxY } (scroll viewport offsets)

local function __scheduleRender()
  __renderQueued = true
end

local function __sameDeps(a, b)
  if a == nil and b == nil then return true end
  if a == nil or b == nil then return false end
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

local function __useState(initial)
  __hookIdx = __hookIdx + 1
  local idx = __hookIdx
  local path = __currentPath
  local st = __state[path]
  if st.slots[idx] == nil then st.slots[idx] = initial end
  return st.slots[idx], function(value)
    local s = __state[path]
    if s then
      local cur = s.slots[idx]
      if type(value) == "function" then value = value(cur) end
      if cur ~= value then
              s.slots[idx] = value
        __scheduleRender()
      else
            end
    end
  end
end

local function __useEffect(fn, deps)
  __hookIdx = __hookIdx + 1
  local idx = __hookIdx
  local st = __state[__currentPath]
  local prev = st.effects[idx]
  local changed = prev == nil or not __sameDeps(prev.deps, deps)
  st.effects[idx] = { deps = deps, fn = fn }
  if changed then table.insert(__pendingEffects, fn) end
end

-- Run a component function under its instance path. Paths are the DFS order
-- index of component *instances* (deterministic across renders while the tree
-- structure is static). A different fnId at the same path resets the slots
-- (the MVP's answer to "component identity").
local function __component(fnId, fn, props)
  __instanceCount = __instanceCount + 1
  table.insert(__pathStack, __instanceCount)
  local key = table.concat(__pathStack, ".")
  if __lastComp[key] ~= fnId then
    __state[key] = { slots = {}, effects = {} }
    __lastComp[key] = fnId
  end
  local prevPath, prevHook = __currentPath, __hookIdx
  __currentPath = key
  __hookIdx = 0
  local ok, res = pcall(fn, props)
  __currentPath, __hookIdx = prevPath, prevHook
  table.remove(__pathStack)
  if not ok then error(res, 0) end
  return res
end

-- ============================================================
-- 4. Flexbox layout (measure + place)
-- ============================================================

local function __resolveSize(v, content, max)
  if v == nil then return content end
  local t = type(v)
  if t == "number" then return v end
  if t == "string" and v == "100%" then return max end
  error("cc-react: unsupported width/height value: " .. tostring(v), 0)
end

-- Intrinsic content size (before padding). maxW/maxH bound "100%" children.
local function __measure(node, maxW, maxH)
  local s = node.style
  local cw, ch
  local kind = node.kind
  if kind == "text" or kind == "button" then
    local fs = s.fontSize or 1
    local tp = s.textPadding or 1 -- mod default: 1px spacing between chars
    local str = kind == "text" and (node.text or "") or (node.label or "")
    cw = __gpu.getTextLength(str, fs, tp)
    ch = FONT_H * fs
  elseif kind == "scroll" then
    -- The scroll node is a viewport: auto-sizes to the parent's inner box
    -- (explicit width/height still win). Its CONTENT is measured unbounded in
    -- the scroll axis during __layoutScroll.
    cw = __resolveSize(s.width, maxW, maxW)
    ch = __resolveSize(s.height, maxH, maxH)
  else
    local dir = s.flexDirection or "column"
    local gap = s.gap or 0
    local innerW = math.max(0, maxW - s.paddingL - s.paddingR)
    local innerH = math.max(0, maxH - s.paddingT - s.paddingB)
    cw, ch = 0, 0
    local n = 0
    for i, c in ipairs(node.children) do
      local mw, mh = __measure(c, innerW, innerH)
      local mt, mr, mb, ml = c.style.marginT, c.style.marginR, c.style.marginB, c.style.marginL
      local cwi = __resolveSize(c.style.width, mw, math.max(0, innerW - ml - mr)) + ml + mr
      local chi = __resolveSize(c.style.height, mh, math.max(0, innerH - mt - mb)) + mt + mb
      if dir == "column" then
        if cwi > cw then cw = cwi end
        ch = ch + chi + gap
      else
        if chi > ch then ch = chi end
        cw = cw + cwi + gap
      end
      n = i
    end
    if n > 0 then
      if dir == "column" then ch = ch - gap else cw = cw - gap end
    end
  end
  -- the returned size is the full box size (content + own padding), so
  -- auto-sized containers/leaves honor their padding
  return cw + s.paddingL + s.paddingR, ch + s.paddingT + s.paddingB
end

-- Forward declaration: __layoutScroll (defined first) calls __layout and
-- __layout dispatches into __layoutScroll — a circular reference, so the
-- local must be declared before both.
local __layout

-- Lay out the CONTENT of a scroll node. Children are measured and placed in
-- content space (unbounded along the scroll axis), then translated by the
-- scroll offset into screen coordinates — content scrolled out of the
-- viewport lands outside node's box, where drawing clips it away. Also
-- computes the content size and clamps the stored scroll offset.
local function __layoutScroll(node)
  local s = node.style
  local st = __scrollState[node.path]
  if st == nil then st = { x = 0, y = 0, maxX = 0, maxY = 0 } __scrollState[node.path] = st end
  local dir = s.flexDirection or "column"
  local innerX = node.x + s.paddingL
  local innerY = node.y + s.paddingT
  local innerW = math.max(0, node.w - s.paddingL - s.paddingR)
  local innerH = math.max(0, node.h - s.paddingT - s.paddingB)
  local align = s.alignItems or "flex-start"
  local gap = s.gap or 0
  local n = #node.children

  -- pass 1: measure children in content space; track the content extent
  local items = {}
  local cursor = 0
  local contentW, contentH = 0, 0
  for i = 1, n do
    local c = node.children[i]
    local mw, mh
    if dir == "column" then mw, mh = __measure(c, innerW, SCROLL_MAX)
    else mw, mh = __measure(c, SCROLL_MAX, innerH) end
    local mt, mr, mb, ml = c.style.marginT, c.style.marginR, c.style.marginB, c.style.marginL
    local cw = __resolveSize(c.style.width, mw, math.max(0, innerW - ml - mr)) + ml + mr
    local ch = __resolveSize(c.style.height, mh, math.max(0, innerH - mt - mb)) + mt + mb
    if align == "stretch" then
      if dir == "row" and c.style.height == nil then ch = innerH end
      if dir == "column" and c.style.width == nil then cw = innerW end
    end
    items[i] = { node = c, w = cw, h = ch }
    if dir == "column" then
      if cw > contentW then contentW = cw end
      if cursor + ch > contentH then contentH = cursor + ch end
      cursor = cursor + ch + gap
    else
      if ch > contentH then contentH = ch end
      if cursor + cw > contentW then contentW = cursor + cw end
      cursor = cursor + cw + gap
    end
  end

  -- clamp the scroll offset against the current content size
  local maxX = math.max(0, contentW - innerW)
  local maxY = math.max(0, contentH - innerH)
  local sx, sy = st.x or 0, st.y or 0
  if sx < 0 then sx = 0 elseif sx > maxX then sx = maxX end
  if sy < 0 then sy = 0 elseif sy > maxY then sy = maxY end
  st.x, st.y, st.maxX, st.maxY = sx, sy, maxX, maxY
  node.scrollX, node.scrollY = sx, sy
  node.contentW, node.contentH = contentW, contentH

  -- pass 2: place children at screen coords = content coords - scroll offset
  local cur = 0
  for i = 1, n do
    local it = items[i]
    local c = it.node
    local mt, mr, mb, ml = c.style.marginT, c.style.marginR, c.style.marginB, c.style.marginL
    local cx, cy
    if dir == "column" then
      if align == "flex-start" or align == "stretch" then
        cx = 0
      elseif align == "center" then
        cx = (innerW - it.w) / 2
      else -- flex-end
        cx = innerW - it.w
      end
      cy = cur
      cur = cur + it.h + gap
    else
      if align == "flex-start" or align == "stretch" then
        cy = 0
      elseif align == "center" then
        cy = (innerH - it.h) / 2
      else -- flex-end
        cy = innerH - it.h
      end
      cx = cur
      cur = cur + it.w + gap
    end
    __layout(c, innerX + cx + ml - sx, innerY + cy + mt - sy, it.w - ml - mr, it.h - mt - mb)
  end
end

__layout = function(node, x, y, w, h)
  local s = node.style
  node.x = math.floor(x + 0.5)
  node.y = math.floor(y + 0.5)
  node.w = math.floor(w + 0.5)
  node.h = math.floor(h + 0.5)

  if node.kind == "scroll" then
    __layoutScroll(node)
    return
  end

  local innerX = node.x + s.paddingL
  local innerY = node.y + s.paddingT
  local innerW = math.max(0, node.w - s.paddingL - s.paddingR)
  local innerH = math.max(0, node.h - s.paddingT - s.paddingB)
  local dir = s.flexDirection or "column"
  local justify = s.justifyContent or "flex-start"
  local align = s.alignItems or "flex-start"
  local gap = s.gap or 0

  local items = {}
  local totalMain = 0
  for i, c in ipairs(node.children) do
    local mw, mh = __measure(c, innerW, innerH)
    local mt, mr, mb, ml = c.style.marginT, c.style.marginR, c.style.marginB, c.style.marginL
    local cw = __resolveSize(c.style.width, mw, math.max(0, innerW - ml - mr)) + ml + mr
    local ch = __resolveSize(c.style.height, mh, math.max(0, innerH - mt - mb)) + mt + mb
    if align == "stretch" then
      if dir == "row" and c.style.height == nil then ch = innerH end
      if dir == "column" and c.style.width == nil then cw = innerW end
    end
    items[i] = { node = c, w = cw, h = ch }
    totalMain = totalMain + (dir == "column" and ch or cw) + gap
  end
  local n = #items
  if n > 0 then totalMain = totalMain - gap end

  local mainStart = dir == "column" and innerY or innerX
  local mainSize = dir == "column" and innerH or innerW
  local free = mainSize - totalMain
  local cursor = mainStart
  local extraGap = 0

  if justify == "center" then
    cursor = mainStart + math.max(0, free) / 2
  elseif justify == "flex-end" then
    cursor = mainStart + math.max(0, free)
  elseif justify == "space-between" then
    if n > 1 and free > 0 then extraGap = free / (n - 1) end
  elseif justify == "space-around" then
    if n > 0 and free > 0 then extraGap = free / n end
    cursor = mainStart + extraGap / 2
  end

  for i = 1, n do
    local it = items[i]
    local c = it.node
    local mt, mr, mb, ml = c.style.marginT, c.style.marginR, c.style.marginB, c.style.marginL
    local cx, cy
    if dir == "column" then
      if align == "flex-start" or align == "stretch" then
        cx = innerX
      elseif align == "center" then
        cx = innerX + (innerW - it.w) / 2
      else -- flex-end
        cx = innerX + innerW - it.w
      end
      __layout(c, cx + ml, cursor + mt, it.w - ml - mr, it.h - mt - mb)
      cursor = cursor + it.h + gap
      if i < n then cursor = cursor + extraGap end
    else
      if align == "flex-start" or align == "stretch" then
        cy = innerY
      elseif align == "center" then
        cy = innerY + (innerH - it.h) / 2
      else -- flex-end
        cy = innerY + innerH - it.h
      end
      __layout(c, cursor + ml, cy + mt, it.w - ml - mr, it.h - mt - mb)
      cursor = cursor + it.w + gap
      if i < n then cursor = cursor + extraGap end
    end
  end
end

-- ============================================================
-- 5. Dirty-rect comparison & rendering
-- ============================================================

local function __assignPaths(node, path, parent)
  node.path = path
  node.parent = parent
  node.pressed = node.path == __pressedPath
  if node.kind == "scroll" then
    local st = __scrollState[path]
    if st == nil then st = { x = 0, y = 0, maxX = 0, maxY = 0 } __scrollState[path] = st end
    node.scrollX, node.scrollY = st.x, st.y
  end
  local children = node.children
  for i = 1, #children do
    __assignPaths(children[i], path .. "." .. i, node)
  end
end

local function __sameStyle(a, b)
  for k, v in pairs(a) do
    if b[k] ~= v then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

-- Two nodes are "the same" when their visuals and boxes match. Boxes are
-- compared so that pure layout shifts (a sibling growing above a node) mark
-- the moved node dirty too.
local function __sameNode(a, b)
  if a.kind ~= b.kind then return false end
  if not __sameStyle(a.style, b.style) then return false end
  if a.text ~= b.text then return false end
  if a.label ~= b.label then return false end
  if a.pressed ~= b.pressed then return false end
  if a.x ~= b.x or a.y ~= b.y or a.w ~= b.w or a.h ~= b.h then return false end
  return true
end

local function __addRect(rects, x, y, w, h)
  if w <= 0 or h <= 0 then return end
  -- pad each dirty rect so glyphs drawing a few px beyond the measured box
  -- are always repainted (__mergeRects clamps to the viewport afterwards)
  table.insert(rects, { x - DIRTY_PAD, y - DIRTY_PAD, w + DIRTY_PAD * 2, h + DIRTY_PAD * 2 })
end

local function __compareTrees(a, b, rects)
  if not __sameNode(a, b) then
    __addRect(rects, a.x, a.y, a.w, a.h)
    __addRect(rects, b.x, b.y, b.w, b.h)
    return
  end
  local na, nb = #a.children, #b.children
  local n = na > nb and na or nb
  for i = 1, n do
    local ac, bc = a.children[i], b.children[i]
    if ac and bc then
      __compareTrees(ac, bc, rects)
    elseif ac then
      __addRect(rects, ac.x, ac.y, ac.w, ac.h)
    elseif bc then
      __addRect(rects, bc.x, bc.y, bc.w, bc.h)
    end
  end
end

local function __intersect(a, b)
  return a[1] < b[1] + b[3] and b[1] < a[1] + a[3]
     and a[2] < b[2] + b[4] and b[2] < a[2] + a[4]
end

-- Greedy union of overlapping rects, clamped to the viewport.
local function __mergeRects(rects, vw, vh)
  local merged = {}
  local area = 0
  for _, r in ipairs(rects) do
    local x1 = r[1] < 1 and 1 or r[1]
    local y1 = r[2] < 1 and 1 or r[2]
    local x2 = r[1] + r[3] - 1
    local y2 = r[2] + r[4] - 1
    if x2 > vw then x2 = vw end
    if y2 > vh then y2 = vh end
    local w = x2 - x1 + 1
    local h = y2 - y1 + 1
    if w > 0 and h > 0 then
      local r2 = { x1, y1, w, h }
      local joined = false
      for _, m in ipairs(merged) do
        if __intersect(m, r2) then
          local nx1 = m[1] < x1 and m[1] or x1
          local ny1 = m[2] < y1 and m[2] or y1
          local nx2 = (m[1] + m[3] - 1) > x2 and (m[1] + m[3] - 1) or x2
          local ny2 = (m[2] + m[4] - 1) > y2 and (m[2] + m[4] - 1) or y2
          m[1], m[2], m[3], m[4] = nx1, ny1, nx2 - nx1 + 1, ny2 - ny1 + 1
          joined = true
          break
        end
      end
      if not joined then table.insert(merged, r2) end
      area = area + w * h
    end
  end
  return merged, area
end

local function __rootBg()
  local t = __lastTree
  return (t and t.style and t.style.backgroundColor) or COLOR_BG
end

-- Intersect an existing clip rect with another rect (the scroll viewport).
-- Returns a new clip table, or nil when empty (nothing visible).
local function __clipIntersect(clip, x, y, w, h)
  local x1, y1, x2, y2 = x, y, x + w - 1, y + h - 1
  if clip then
    local cx2 = clip.x + clip.w - 1
    local cy2 = clip.y + clip.h - 1
    if x1 < clip.x then x1 = clip.x end
    if y1 < clip.y then y1 = clip.y end
    if x2 > cx2 then x2 = cx2 end
    if y2 > cy2 then y2 = cy2 end
  end
  if x1 > x2 or y1 > y2 then return nil end
  return { x = x1, y = y1, w = x2 - x1 + 1, h = y2 - y1 + 1 }
end

-- Draw one node and its whole subtree (used for full repaints and for nodes
-- intersecting a dirty rect — overdraw of unchanged content is idempotent).
-- `clip` (nil = whole viewport) bounds the draw: scroll containers narrow it
-- to their viewport box, so scrolled-out content never paints outside.
local function __drawNode(node, clip)
  local s = node.style
  local w, h = node.w, node.h
  if w <= 0 or h <= 0 then return end
  local fill = s.backgroundColor
  if node.kind == "button" and node.pressed and s.pressedColor then
    fill = s.pressedColor
  end
  if fill then __gpu.filledRectangle(node.x, node.y, w, h, fill, clip) end
  if s.borderColor then
    __gpu.rectangle(node.x, node.y, w, h, s.borderColor, clip)
  end
  if node.kind == "text" then
    if node.text and #node.text > 0 then
      __gpu.drawText(
        node.x + s.paddingL, node.y + s.paddingT, node.text,
        s.color or COLOR_TEXT, s.textBackgroundColor, s.fontSize or 1, s.textPadding or 1, clip)
    end
  elseif node.kind == "button" then
    local fs = s.fontSize or 1
    local tp = s.textPadding or 1
    local label = node.label or ""
    local tw = __gpu.getTextLength(label, fs, tp)
    local th = FONT_H * fs
    local tx = math.floor(node.x + (w - tw) / 2 + 0.5)
    local ty = math.floor(node.y + (h - th) / 2 + 0.5)
    __gpu.drawText(tx, ty, label, s.color or COLOR_TEXT, fill, fs, tp, clip)
  end
  local children = node.children
  if node.kind == "scroll" then
    -- children are clipped to the scroll viewport (intersected with the
    -- parent clip, so nested scrolls compose)
    local vx = node.x + s.paddingL
    local vy = node.y + s.paddingT
    local vw2 = math.max(0, node.w - s.paddingL - s.paddingR)
    local vh2 = math.max(0, node.h - s.paddingT - s.paddingB)
    local cclip = __clipIntersect(clip, vx, vy, vw2, vh2)
    for i = 1, #children do __drawNode(children[i], cclip) end
  else
    for i = 1, #children do __drawNode(children[i], clip) end
  end
end

local function __intersectsAnyRect(node, rects)
  local x, y, w, h = node.x, node.y, node.w, node.h
  if w <= 0 or h <= 0 then return false end
  for _, r in ipairs(rects) do
    if x < r[1] + r[3] and r[1] < x + w and y < r[2] + r[4] and r[2] < y + h then
      return true
    end
  end
  return false
end

local function __drawFull(tree)
  __gpu.fill(__rootBg())
  __drawNode(tree, nil)
end

local function __drawDirty(tree, rects)
  local bg = __rootBg()
  for _, r in ipairs(rects) do
    __gpu.filledRectangle(r[1], r[2], r[3], r[4], bg)
  end
  local function walk(node)
    local children = node.children
    for i = 1, #children do
      local c = children[i]
      if __intersectsAnyRect(c, rects) then
        __drawNode(c, nil) -- whole subtree; children are covered
      else
        walk(c)
      end
    end
  end
  walk(tree)
end

local function __render()
  __renderQueued = false
  __pendingEffects = {}
  __instanceCount = 0
  __pathStack = {}
  local ok, tree = pcall(__component, "__root", __rootFn, {})
  if not ok then error("cc-react: render failed: " .. tostring(tree), 0) end
  if type(tree) ~= "table" then
    error("cc-react: the root component must return an element, got " .. tostring(tree), 0)
  end
  __assignPaths(tree, "1", nil)
  __layout(tree, 1, 1, __viewportW, __viewportH)

  local rects = {}
  if __lastTree == nil then
    __addRect(rects, 1, 1, __viewportW, __viewportH)
  else
    __compareTrees(__lastTree, tree, rects)
  end
  __lastTree = tree

  local merged, area = __mergeRects(rects, __viewportW, __viewportH)
  if area > __viewportW * __viewportH * FULL_REPAINT_RATIO then
    __drawFull(tree)
  else
    __drawDirty(tree, merged)
  end
  __gpu.sync()

  local effects = __pendingEffects
  __pendingEffects = {}
  for i = 1, #effects do
    local ok2, err = pcall(effects[i])
    if not ok2 then print("cc-react: effect error: " .. tostring(err)) end
  end
end

-- ============================================================
-- 6. Event routing (hit test)
-- ============================================================

local function __hitTest(x, y)
  local best = nil
  local function walk(node)
    if x >= node.x and x < node.x + node.w
       and y >= node.y and y < node.y + node.h then
      best = node
      local children = node.children
      for i = 1, #children do walk(children[i]) end
    end
  end
  walk(__lastTree)
  return best
end

local function __findHandler(node, key)
  while node do
    if node[key] then return node end
    node = node.parent
  end
  return nil
end

-- Closest scroll container an event hit belongs to (the hit itself included).
local function __findScrollAncestor(node)
  while node do
    if node.kind == "scroll" then return node end
    node = node.parent
  end
  return nil
end

-- How far a pointer may move before a press counts as a drag instead of a tap
-- (suppresses the click that would otherwise fire on mouse_up).
local DRAG_TAP_SLOP = 4
local __scrollDrag = nil -- { path, x, y, moved, total } — active touch drag on a scroll

local function __scrollBy(sc, dx, dy)
  local st = __scrollState[sc.path]
  if st == nil then return end
  local nx, ny = st.x, st.y
  if dx ~= 0 then
    nx = st.x + dx
    if nx < 0 then nx = 0 elseif nx > st.maxX then nx = st.maxX end
  end
  if dy ~= 0 then
    ny = st.y + dy
    if ny < 0 then ny = 0 elseif ny > st.maxY then ny = st.maxY end
  end
  if nx ~= st.x or ny ~= st.y then
    st.x, st.y = nx, ny
    __scheduleRender()
  end
end

-- CC peripheral events carry the attachment name as the first payload arg.
local function __eventArgs(e)
  if type(e[2]) == "string" then return 3 end
  return 2
end

local function __handleEvent(e)
  local name = e[1]
  if name == "tm_monitor_touch" then
    local i = __eventArgs(e)
    local x, y = e[i], e[i + 1]
    if type(x) == "number" and type(y) == "number" then
      local h = __findHandler(__hitTest(x, y), "onClick")
      if h and h.onClick then
          h.onClick()
    end
    end
  elseif name == "tm_monitor_mouse_click" then
    local i = __eventArgs(e)
    local x, y, btn = e[i], e[i + 1], e[i + 2]
    if type(x) == "number" and type(y) == "number" and (btn == nil or btn == 1) then
      local hit = __hitTest(x, y)
      local h = __findHandler(hit, "onClick")
      if h then
        __pressedPath = h.path
        __scheduleRender() -- repaint the pressed visual
      end
      -- a press over a scroll container starts a potential touch drag
      local sc = __findScrollAncestor(hit)
      if sc then
        __scrollDrag = { path = sc.path, x = x, y = y, moved = false }
      end
    end
  elseif name == "tm_monitor_mouse_drag" then
    local i = __eventArgs(e)
    local x, y, btn = e[i], e[i + 1], e[i + 2]
    if __scrollDrag and type(x) == "number" and type(y) == "number"
       and (btn == nil or btn == 1) then
      local sc = __scrollState[__scrollDrag.path]
      if sc then
        local dx = x - __scrollDrag.x
        local dy = y - __scrollDrag.y
        if dx ~= 0 or dy ~= 0 then
          -- accumulate total travel: several small moves still count as a drag
          __scrollDrag.total = (__scrollDrag.total or 0) + math.abs(dx) + math.abs(dy)
          if __scrollDrag.total > DRAG_TAP_SLOP then __scrollDrag.moved = true end
          -- content follows the finger: scrollBy(-delta)
          __scrollBy({ path = __scrollDrag.path }, -dx, -dy)
          __scrollDrag.x, __scrollDrag.y = x, y
        end
      end
    end
  elseif name == "tm_monitor_mouse_up" then
    local i = __eventArgs(e)
    local x, y, btn = e[i], e[i + 1], e[i + 2]
    if type(x) == "number" and type(y) == "number"
       and (btn == nil or btn == 1) then
      -- a drag that actually moved cancels the tap's click
      local wasDrag = __scrollDrag ~= nil and __scrollDrag.moved
      __scrollDrag = nil
      if __pressedPath then
        if not wasDrag then
          local h = __findHandler(__hitTest(x, y), "onClick")
          if h and h.path == __pressedPath and h.onClick then
            h.onClick()
          end
        end
        __pressedPath = nil
        __scheduleRender()
      end
    end
  elseif name == "tm_monitor_mouse_scroll" then
    local i = __eventArgs(e)
    local x, y, dir = e[i], e[i + 1], e[i + 2]
    if type(x) == "number" and type(y) == "number"
       and type(dir) == "number" and dir ~= 0 then
      local sc = __findScrollAncestor(__hitTest(x, y))
      if sc then
        -- Real-device convention (verified in source): Minecraft wheel delta
        -- < 0 (wheel down) maps to dir = +1, wheel up to dir = -1 — so a
        -- positive dir scrolls the content down (scrollY increases).
        local step = sc.style.scrollStep or 8
        __scrollBy(sc, 0, dir * step)
      end
    end
  end
  -- keyboard (tm_keyboard_*) is a follow-up milestone (Input + focus)
end

local function __drain()
  local guard = 0
  while __renderQueued and guard < 16 do
    guard = guard + 1
    local ok, err = pcall(__render)
    if not ok then
      print("cc-react: render error: " .. tostring(err))
      return
    end
  end
end

-- ============================================================
-- 7. Module entry (mount + task)
-- ============================================================

-- Register the root component. Compiled from the top-level render(<App/>);
-- only records the function — no GPU work happens at module load.
local function __mount(rootFn)
  __rootFn = rootFn
end

-- The UI task body. This is the function a main program hands to
-- simpleParallel (parallel.waitForAll), so the UI loop runs concurrently
-- with the rest of the program (future network stack tasks). CC broadcasts
-- every event to all consumers, so this loop sees all events and filters
-- its own (tm_monitor_*). Initialization is done here, not at load time.
local function __start(side)
  if __rootFn == nil then
    error("cc-react: no component mounted — the module needs render(<App/>) at top level", 0)
  end
  local w, h = __gpuReady(side)
  __viewportW, __viewportH = w, h
  __render()
  __drain()
  while true do
    local e = { os.pullEvent() }
    local ok, err = pcall(__handleEvent, e)
    if not ok then print("cc-react: event error: " .. tostring(err)) end
    __drain()
  end
end

-- Module interface + debug/test hooks. The compiled module returns this
-- table (see the `return ccreact` epilogue appended by the compiler); the
-- headless test harness drives it through start() and inspects the tree.
ccreact = {
  -- entry points
  start = function(side) return __start(side) end,
  mount = function(rootFn) __mount(rootFn) end,
  -- debug / test hooks
  getTree = function() return __lastTree end,
  getViewport = function() return __viewportW, __viewportH end,
  isPressed = function() return __pressedPath end,
  hitTest = function(x, y) return __hitTest(x, y) end,
}
