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
          ui.setHttpClient(client) -- optional (fetch): docs/lib HTTP client
          simpleParallel.add(function() ui.start("left") end) -- UI + fetch worker
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
-- Font height becomes 16 when the Chinese custom font is active
-- (__fontInit sets it; see the "Chinese font support" section below).
local __fontH = 8
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
  local fs = size or 1
  local tp = pad or 1 -- the mod's default padding (1px between characters)
  local tw = gpu.getTextLength(t, fs, tp)
  local th = __fontH * fs -- glyph height = fontHeight(8) x size; padding does not affect height
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
    -- The clip is inside the viewport (callers clamp via __clipIntersect), so
    -- scrolled content may start at a negative x — the sub-range always draws
    -- from clip.x onward and never reaches the screen edge.
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
  -- No clip: skip entirely if the text would extend past the screen edge
  -- (drawText throws "Out of boundary" instead of clipping).
  if x < 1 or y < 1 then return end
  if x + tw - 1 > __viewportW or y + th - 1 > __viewportH then return end
  gpu.drawText(x, y, t, fg2, bg2, fs, tp)
end
function __gpu.getTextLength(t, size, pad)
  return gpu.getTextLength(t, size, pad)
end

-- ============================================================
-- Chinese font support (opt-in via ui.setChineseFont(file.fnt))
-- ============================================================
-- Tom's GPU default font (ascii) is READ-ONLY ("Selected font is not
-- modifiable" — verified on a real device). The modifiable font is the
-- "unicode_page_e0" sprite font (official example: cc_term_font.lua): we
-- switch to it, clear it, and register our own glyphs — ASCII 0x20-0x7E
-- plus CJK characters loaded lazily from a binary font file on the
-- computer's disk (format v1: "CCF1" magic + count(u32 BE) + 37-byte
-- fixed-stride entries: cp(u32 BE) + width(u8) + 16×u16 BE glyph rows,
-- bit0 = leftmost pixel; generated by make_font_bin.py).
--
-- Every string is UTF-8-encoded to a "slot string" (one byte per glyph)
-- before it reaches drawText/getTextLength: ASCII passes through, each CJK
-- char becomes its registered slot byte (0x80-0xFE), missing chars become
-- the □ slot (0xFF). When the font is NOT configured everything is a
-- passthrough and the runtime behaves exactly as before.
local __fontMode = false
local __chineseFontFile = nil
local __fontFile
local __fontCount = 0
local FONT_ENTRY = 37
local __slots = {}       -- char (UTF-8) -> slot byte string
local __nextSlot = 0x80  -- CJK slots 0x80..0xFE; 0xFF reserved for □
local MISS_SLOT = 0xFF
local MISS_ROWS = {0xFFFF, 0x8001, 0x8001, 0x8001, 0x8001, 0x8001, 0x8001, 0x8001,
                   0x8001, 0x8001, 0x8001, 0x8001, 0x8001, 0x8001, 0x8001, 0xFFFF}

local function __be32(s, i)
  local b1, b2, b3, b4 = s:byte(i, i + 3)
  return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end
local function __be16(s, i)
  local b1, b2 = s:byte(i, i + 1)
  return b1 * 256 + b2
end

local function __fontOpen(name)
  if not fs or not fs.open then return false end
  __fontFile = fs.open(name, "rb")
  if not __fontFile then return false end
  local hdr = __fontFile.read(12)
  if not hdr or #hdr < 12 or hdr:sub(1, 4) ~= "CCF1" then
    __fontFile.close()
    __fontFile = nil
    return false
  end
  __fontCount = __be32(hdr, 5)
  return true
end

-- Read entry idx (0-based); returns cp, width, rows
local function __fontReadEntry(idx)
  __fontFile.seek("set", 12 + idx * FONT_ENTRY)
  local e = __fontFile.read(FONT_ENTRY)
  if not e or #e < FONT_ENTRY then return nil end
  local cp = __be32(e, 1)
  local w = e:byte(5)
  local rows = {}
  for r = 1, 16 do rows[r] = __be16(e, 6 + (r - 1) * 2) end
  return cp, w, rows
end

-- Binary search a codepoint; returns width, rows or nil
local function __fontFind(cp)
  local lo, hi = 0, __fontCount - 1
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local mcp, w, rows = __fontReadEntry(mid)
    if mcp == cp then return w, rows end
    if mcp < cp then lo = mid + 1 else hi = mid - 1 end
  end
  return nil
end

-- UTF-8 helpers (CC has no utf8 library; pure arithmetic, Lua 5.1/5.2 safe)
local function __utf8char(s, i)
  local b1 = s:byte(i)
  if b1 == nil then return nil end
  if b1 < 0x80 then return s:sub(i, i), i + 1 end
  if b1 < 0xE0 then return s:sub(i, i + 1), i + 2 end
  if b1 < 0xF0 then return s:sub(i, i + 2), i + 3 end
  return s:sub(i, i), i + 1
end
local function __utf8codepoint(s, i)
  i = i or 1
  local b1 = s:byte(i)
  if b1 == nil then return nil end
  if b1 < 0x80 then return b1, i + 1 end
  local b2 = s:byte(i + 1)
  if b1 < 0xE0 then return (b1 - 0xC0) * 64 + (b2 or 0) - 0x80, i + 2 end
  local b3 = s:byte(i + 2)
  if b1 < 0xF0 then return (b1 - 0xE0) * 4096 + ((b2 or 0) - 0x80) * 64 + (b3 or 0) - 0x80, i + 3 end
  return b1, i + 1
end

-- Byte index of the first byte of the char that contains `pos` (or the last
-- char boundary <= pos). Used to make Input editing char-aware.
local function __charStart(s, pos)
  local i, last = 1, 0
  while i <= pos and i <= #s do
    last = i
    local b1 = s:byte(i)
    if b1 < 0x80 then i = i + 1
    elseif b1 < 0xE0 then i = i + 2
    elseif b1 < 0xF0 then i = i + 3
    else i = i + 1 end
  end
  return last
end

-- Lazy-register a CJK glyph: look it up in the font file, allocate a slot,
-- addNewChar it. Returns the slot byte string or nil (missing / slot-full).
local function __ensureGlyph(ch)
  if __slots[ch] then return __slots[ch] end
  if __nextSlot >= MISS_SLOT then return nil end -- 0xFF reserved for □
  local cp = __utf8codepoint(ch)
  local w, rows = __fontFind(cp)
  if not w then return nil end
  local slot = string.char(__nextSlot)
  __nextSlot = __nextSlot + 1
  local ok, err = pcall(function() gpu.addNewChar(slot, w, table.unpack(rows)) end)
  if not ok then return nil end
  __slots[ch] = slot
  return slot
end

-- Encode a UTF-8 string into a slot string. Second return: offsets[k] = raw
-- byte index of the k-th encoded char (nil when the font is inactive).
local function __encFull(s)
  if not __fontMode then return s end
  local out, offs = {}, {}
  local i, k = 1, 0
  while i <= #s do
    local ch, ni = __utf8char(s, i)
    if not ch then break end
    k = k + 1
    offs[k] = i
    if ch:byte(1) < 0x80 then
      out[k] = ch
    else
      local slot = __ensureGlyph(ch)
      out[k] = slot or string.char(MISS_SLOT)
    end
    i = ni
  end
  return table.concat(out), offs
end

local function __enc(s)
  return __encFull(s)
end

-- Map a raw byte cursor index into the encoded string's index (clamps a
-- mid-char cursor to the char's end, i.e. the next boundary).
local function __encCursor(val, cur)
  if not __fontMode then return cur end
  local ecur = 0
  local i = 1
  while i <= cur and i <= #val do
    local ch, ni = __utf8char(val, i)
    if not ch then break end
    ecur = ecur + 1
    i = ni
  end
  return ecur
end

-- Initialize the custom font. Opens the font FILE first (no GPU side effects
-- on failure), then switches the GPU to the modifiable font and registers
-- ASCII + the □ fallback. CJK is registered lazily by __ensureGlyph.
local function __fontInit(name)
  if not __fontOpen(name) then
    print("cc-react: cannot open chinese font file '" .. tostring(name) .. "' — Chinese support disabled")
    return false
  end
  pcall(function() gpu.setFont("unicode_page_e0") end)
  pcall(function() gpu.clearChars() end)
  local okAscii = 0
  for i = 0x20, 0x7E do
    local w, rows = __fontFind(i)
    if w then
      local ok = pcall(function() gpu.addNewChar(string.char(i), w, table.unpack(rows)) end)
      if ok then okAscii = okAscii + 1 end
    end
  end
  pcall(function() gpu.addNewChar(string.char(MISS_SLOT), 16, table.unpack(MISS_ROWS)) end)
  __fontH = 16
  __fontMode = true
  return true
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
    value = props.value,
    placeholder = props.placeholder,
    onChange = props.onChange,
    onSubmit = props.onSubmit,
    onKey = props.onKey,
    onClick = props.onClick,
    onMouseDown = props.onMouseDown,
    onMouseUp = props.onMouseUp,
    disabled = props.disabled,
    children = props.children or {},
    parent = nil,
    path = nil,
    pressed = false,
    focused = false,
    cursor = 0,
    cursorVisible = false,
    inputOffset = 0, -- horizontal text scroll (set by __layoutInputOffset)
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

-- Text input (keyboard milestone): a focusable leaf that draws its value (or
-- the placeholder while empty) plus a blinking cursor when focused. Editing
-- is built in — characters insert at the cursor, backspace/delete/arrows/
-- home/end move it, enter fires onSubmit — and every edit reports the new
-- value via onChange (the app owns the value, React controlled style).
-- Tab / Shift+Tab move focus between inputs; clicking an input focuses it
-- and places the cursor at the clicked character. The focus ring uses
-- focusBorderColor while the node has focus.
local function __input(props)
  return __makeNode("input", props, {
    backgroundColor = 0xFF17171E,
    borderColor = 0xFF4A4A5A,
    focusBorderColor = 0xFF7EC8FF,
    color = COLOR_TEXT,
    placeholderColor = 0xFF6A6A78,
    cursorColor = 0xFF7EC8FF,
    padding = 4,
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

-- Toggle switch: a clickable on/off leaf. Renders a track with a sliding knob
-- (ON = accent color, OFF = gray). Props: value (boolean), onChange (callback).
-- Fixed default size: 16×9 px; override via style width/height.
local function __switch(props)
  local node = __makeNode("switch", props, {
    backgroundColor = 0xFF3A3A48,   -- track off background
    color = 0xFF7EC8FF,             -- accent: track on + knob on
    borderColor = 0xFF4A4A5A,
    pressedColor = 0xFF3A3A48,
    padding = 0,
  })
  -- Wire up onClick to toggle: reads current value from the node (always
  -- fresh after re-render) and calls onChange with the negated boolean.
  node.onClick = function()
    if not node.disabled and node.onChange then
      node.onChange(not node.value)
    end
  end
  return node
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

-- Focus model (keyboard milestone): __focusedPath is the path of the node
-- that owns keyboard input; __focusList is the ordered set of focusable
-- nodes in the CURRENT tree (rebuilt every render — Tab cycles it in tree
-- order); __inputState holds per-input editing state (cursor index + blink
-- timer); __modsDown tracks held modifier keys (Tom's keyboard sends key
-- down/release as separate events, so Shift+Tab is detectable).
local __focusedPath = nil
local __focusList = {}
local __inputState = {}   -- __inputState[path] = { cursor = n, blink = bool, timer = id }
local __modsDown = {}     -- __modsDown[key] = true while a key is held
local __focusSeen = false -- the focused path is present in the current tree
local BLINK_INTERVAL = 0.5

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
-- 3b. Focus model & keyboard editing (Input)
-- ============================================================

-- Tom's Peripherals keyboard emits GLFW key codes (not CC's PC scancodes;
-- verified in the mod's KeyboardWidget: the keyPressed() key parameter is
-- passed through verbatim) with tm_keyboard_key(peripheral, key, isRepeat)
-- on press/repeat and tm_keyboard_key_up(peripheral, key) on release.
local KEY_ENTER = 257
local KEY_TAB = 258
local KEY_BACKSPACE = 259
local KEY_DELETE = 261
local KEY_RIGHT = 262
local KEY_LEFT = 263
local KEY_HOME = 268
local KEY_END = 269
local KEY_LSHIFT = 340
local KEY_RSHIFT = 344

-- The input cursor is drawn as a 2px-wide bar; the horizontal text scroll
-- (__layoutInputOffset) always keeps that bar inside the content box.
local CURSOR_W = 2

-- Focusable nodes: only Input in the MVP (extend with Buttons later).
local function __isFocusable(node)
  return node.kind == "input" and not node.disabled
end

local function __inputStateFor(path)
  local st = __inputState[path]
  if st == nil then
    st = { cursor = 0, blink = true, timer = nil, offsetX = 0 }
    __inputState[path] = st
  end
  return st
end

-- Horizontal text scroll inside an input (real-input long-text behavior):
-- the text is clipped to the content box and the view follows the cursor.
-- The offset is persisted per input (__inputState[path].offsetX) and only
-- adjusted when the cursor would leave the view — typing at the end scrolls
-- the text left, moving home/left reveals the start, backspace at the end
-- keeps the text end pinned to the cursor. Ran from __layout (box width is
-- known there); node.inputOffset is what __drawNode consumes.
local function __layoutInputOffset(node)
  local s = node.style
  local contentW = math.max(0, node.w - s.paddingL - s.paddingR)
  local fs = s.fontSize or 1
  local tp = s.textPadding or 1
  local val = node.value or ""
  local eval = __enc(val)
  local textW = __gpu.getTextLength(eval, fs, tp)
  local maxOff = math.max(0, textW + CURSOR_W - contentW)
  local st = __inputStateFor(node.path)
  local off = st.offsetX or 0
  if off < 0 then off = 0 elseif off > maxOff then off = maxOff end
  local ecur = __encCursor(val, node.cursor)
  local cursorX = __gpu.getTextLength(eval:sub(1, ecur), fs, tp)
  if cursorX < off then
    off = cursorX -- cursor left of the view: reveal it at the left edge
  elseif cursorX + CURSOR_W > off + contentW then
    off = cursorX + CURSOR_W - contentW -- right of the view: pin to the right edge
  end
  if off < 0 then off = 0 elseif off > maxOff then off = maxOff end
  st.offsetX = off
  node.inputOffset = off
end

-- The node that currently owns keyboard input, looked up by path in the last
-- rendered tree (paths are stable while the tree structure is static).
local function __focusedNode()
  if __focusedPath == nil then return nil end
  local function find(n)
    if n.path == __focusedPath then return n end
    for i = 1, #n.children do
      local r = find(n.children[i])
      if r then return r end
    end
    return nil
  end
  return find(__lastTree)
end

local function __cancelBlink(path)
  local st = __inputState[path]
  if st and st.timer then
    if os.cancelTimer then pcall(os.cancelTimer, st.timer) end
    st.timer = nil
  end
end

-- Restart the cursor blink cycle (blink ON + a fresh timer). Called whenever
-- the focused input or its editing state changes; schedules a repaint so the
-- cursor appears instantly.
local function __restartBlink(path)
  local st = __inputStateFor(path)
  st.blink = true
  __cancelBlink(path)
  if os.startTimer then
    local ok, id = pcall(os.startTimer, BLINK_INTERVAL)
    if ok and id then st.timer = id end
  end
  __scheduleRender()
end

-- Drop focus (blur). No-op when nothing is focused.
local function __blur()
  if __focusedPath == nil then return end
  __cancelBlink(__focusedPath)
  __focusedPath = nil
  __scheduleRender()
end

local function __focusNode(node)
  if node == nil or node.path == __focusedPath then return end
  if __focusedPath then __cancelBlink(__focusedPath) end
  __focusedPath = node.path
  __restartBlink(node.path)
end

-- Move focus to the next/prev focusable node in tree order (Tab / Shift+Tab);
-- wraps around. With no current focus, direction picks the first/last.
local function __focusNext(dir)
  local n = #__focusList
  if n == 0 then return end
  local idx = nil
  for i = 1, n do
    if __focusList[i].path == __focusedPath then idx = i break end
  end
  if idx == nil then idx = dir > 0 and 0 or (n + 1) end
  idx = idx + dir
  if idx < 1 then idx = n elseif idx > n then idx = 1 end
  __focusNode(__focusList[idx])
end

-- Focus an input from a pointer press, placing the cursor at the character
-- the press landed on (nearest char boundary of the value text, accounting
-- for the horizontal scroll offset).
local function __focusInputAt(node, x)
  if node.disabled then return end
  local path = node.path
  if __focusedPath ~= path then
    if __focusedPath then __cancelBlink(__focusedPath) end
    __focusedPath = path
  end
  local st = __inputStateFor(path)
  local val = node.value or ""
  local fs = node.style.fontSize or 1
  local tp = node.style.textPadding or 1
  local base = node.x + node.style.paddingL - (node.inputOffset or 0)
  local cur = #val
  local eval, offs = __encFull(val)
  if offs then
    -- font mode: iterate the encoded string (one byte = one glyph) and map
    -- the glyph index back to a raw byte cursor
    for k = 1, #eval do
      local cw = __gpu.getTextLength(eval:sub(k, k), fs, tp)
      if x < base + cw / 2 then cur = (offs[k] - 1) break end
      base = base + cw
    end
  else
    for i = 1, #val do
      local cw = __gpu.getTextLength(val:sub(i, i), fs, tp)
      if x < base + cw / 2 then cur = i - 1 break end
      base = base + cw
    end
  end
  st.cursor = cur
  __restartBlink(path)
end

-- Insert text (a typed char or pasted content) at the cursor; reports the
-- new full value via onChange.
local function __inputInsert(node, str)
  local val = node.value or ""
  local st = __inputStateFor(node.path)
  local cur = st.cursor
  if cur < 0 then cur = 0 elseif cur > #val then cur = #val end
  local nv = val:sub(1, cur) .. str .. val:sub(cur + 1)
  st.cursor = cur + #str
  if node.onChange then node.onChange(nv) end
  __restartBlink(node.path)
end

local function __inputBackspace(node)
  local val = node.value or ""
  local st = __inputStateFor(node.path)
  local cur = st.cursor
  if cur > 0 then
    -- remove the whole UTF-8 char ending at the cursor (char-aware):
    -- __charStart(cur) = start of the char that occupies position cur
    local start = __charStart(val, cur)
    local nv = val:sub(1, start - 1) .. val:sub(cur + 1)
    st.cursor = start - 1
    if node.onChange then node.onChange(nv) end
  end
  __restartBlink(node.path)
end

local function __inputDelete(node)
  local val = node.value or ""
  local st = __inputStateFor(node.path)
  local cur = st.cursor
  if cur < #val then
    -- remove the whole UTF-8 char starting at the cursor (char-aware)
    local start = __charStart(val, cur + 1)
    local b1 = val:byte(start)
    local ni
    if b1 < 0x80 then ni = start + 1
    elseif b1 < 0xE0 then ni = start + 2
    elseif b1 < 0xF0 then ni = start + 3
    else ni = start + 1 end
    local nv = val:sub(1, cur) .. val:sub(ni)
    if node.onChange then node.onChange(nv) end
  end
  __restartBlink(node.path)
end

-- move = -1 / +1 steps, or "start" / "end"; clamps to the value length.
-- Step movement is char-aware: left jumps to the char start before the
-- cursor, right to the char end at the cursor.
local function __inputMoveCursor(node, delta, mode)
  local val = node.value or ""
  local st = __inputStateFor(node.path)
  local cur = st.cursor
  if mode == "start" then cur = 0
  elseif mode == "end" then cur = #val
  elseif delta < 0 then
    if cur > 0 then cur = __charStart(val, cur) - 1 end
  else
    if cur < #val then
      local start = __charStart(val, cur + 1)
      local b1 = val:byte(start)
      local ni
      if b1 < 0x80 then ni = start + 1
      elseif b1 < 0xE0 then ni = start + 2
      elseif b1 < 0xF0 then ni = start + 3
      else ni = start + 1 end
      cur = ni
    end
  end
  if cur < 0 then cur = 0 elseif cur > #val then cur = #val end
  if cur ~= st.cursor then
    st.cursor = cur
    __restartBlink(node.path)
  end
end

-- Built-in key-down handling for the focused input. Repeats (isRepeat=true)
-- are handled too, so holding Backspace/arrows auto-repeats like a terminal.
local function __handleKeyDown(node, key)
  if key == KEY_BACKSPACE then
    __inputBackspace(node)
  elseif key == KEY_DELETE then
    __inputDelete(node)
  elseif key == KEY_LEFT then
    __inputMoveCursor(node, -1)
  elseif key == KEY_RIGHT then
    __inputMoveCursor(node, 1)
  elseif key == KEY_HOME then
    __inputMoveCursor(node, 0, "start")
  elseif key == KEY_END then
    __inputMoveCursor(node, 0, "end")
  elseif key == KEY_ENTER then
    if node.onSubmit then node.onSubmit() end
    __restartBlink(node.path)
  elseif key == KEY_TAB then
    local shift = __modsDown[KEY_LSHIFT] or __modsDown[KEY_RSHIFT]
    __focusNext(shift and -1 or 1)
  end
end

-- ============================================================
-- 3c. Async (futures) + network (milestone 3)
-- ============================================================
-- `async function` bodies compile to an event-driven state machine: code
-- runs synchronously until an `await`, then registers a continuation with
-- the awaited future; the rest of the body runs inside the continuation when
-- the future resolves. No native Lua coroutines are involved (a coroutine
-- that calls sleep() would exit), so every await point is a plain closure.
--
-- Futures are the async operations themselves (`fetch(...)` returns one).
-- The UI never blocks on them: the network worker task (the module's
-- networkLoop(), added by the main program alongside ui.start()) runs the
-- blocking docs/lib HTTP client and reports back through a queued event,
-- which the UI event loop turns into a future resolution.

local __futSeq = 0

local function __newFuture()
  __futSeq = __futSeq + 1
  return {
    __future = true,
    id = __futSeq,
    resolved = false,
    value = nil,
    conts = {}, -- waiting continuations: function(value)
  }
end

-- Resolve a future with a value: every registered continuation runs now (the
-- caller is the UI event loop, so state setters called here schedule a
-- repaint through the normal dirty-rect path). Already-resolved futures are
-- no-ops, so the FIRST resolution wins.
local function __resolveFuture(f, value)
  if f == nil or f.resolved then return end
  f.resolved = true
  f.value = value
  local conts = f.conts
  f.conts = nil
  for i = 1, #conts do
    local ok, err = pcall(conts[i], value)
    if not ok then print("cc-react: async continuation error: " .. tostring(err)) end
  end
end

-- `await X` compiles to __await(X, continuation). A future resolves the
-- continuation with its value (now, or later via __resolveFuture); any other
-- value passes through immediately (JS-style await on non-promises).
local function __await(f, cont)
  if type(f) == "table" and f.__future then
    if f.resolved then
      cont(f.value)
    else
      f.conts[#f.conts + 1] = cont
    end
  else
    cont(f)
  end
end

-- ---- network bridge ------------------------------------------------------
-- fetch() queues a job for the network worker task and returns a future the
-- UI awaits. The worker (networkLoop) runs the blocking HTTP client — the
-- stack in docs/lib — inside its own coroutine (start() composes it via
-- parallel.waitForAll), so requests never freeze the UI. The MAIN PROGRAM
-- builds the client (it owns the IP stack / network config) and hands the
-- instance to the module before start():
--
--   local IP = require("lib.ip")
--   local HTTP = require("lib.http")
--   local ipIface = IP.new({ mode = "host", interfaces = {
--     { side = "back", channel = 1, ip = "192.168.1.10",
--       mask = "255.255.255.0", gateway = "192.168.1.1" } } })
--   local client = HTTP.newClient(ipIface, { timeout = 10, dnsServer = "8.8.8.8" })
--   ui.setHttpClient(client)
--   simpleParallel.add(function() ui.start("left") end)
--   simpleParallel.start()
--
-- A fetch resolves with a docs/lib HTTP response ({ ok, status, statusText,
-- headers, body, text(), json() }); failures resolve with
-- { ok = false, error = <message> } so async code can branch on resp.ok
-- without try/catch (await try/catch is not compiled yet).

local __netJobs = {}      -- pending fetch jobs: { id, url, options }
local __netPending = {}   -- job id -> future
local __netSeq = 0
local __netClient = nil   -- docs/lib HTTP client (set by the main program)
local __netBackend = nil  -- test hook: replaces the real HTTP client
local __netDeferred = {}  -- id -> job whose backend asked to defer
-- id -> response table. CC: Tweaked's os.queueEvent CANNOT carry function
-- values (verified on a real device: they arrive as nil), and docs/lib
-- responses carry methods (json/text are closures) — so the response NEVER
-- crosses an event. The worker stores it here and the completion event
-- carries only the primitive job id; the UI reads the table back directly.
local __netResults = {}

local function __fetch(url, options)
  __netSeq = __netSeq + 1
  local id = __netSeq
  local f = __newFuture()
  __netPending[id] = f
  __netJobs[#__netJobs + 1] = { id = id, url = url, options = options or {} }
  if os.queueEvent then os.queueEvent("ccreact_net_job") end
  return f
end

-- Hand the HTTP client to the worker. The client must be built by the main
-- program BEFORE simpleParallel.start() (docs/lib stack tasks — ARP/DNS
-- receive loops — register at construction time). Passing nil clears it.
local function __setHttpClient(client)
  __netClient = client
end

-- Perform one fetch job. Runs inside the network worker task, so the
-- blocking HTTP client may yield on sockets (fine — simpleParallel manages
-- this coroutine). Returns resp, err; a backend returning `false` defers the
-- job (the test harness resolves it later via resolveNetworkJob).
-- NOTE: this is deliberately NOT pcall'd by the caller — the docs/lib HTTP
-- client yields inside socket receive, and yielding across a pcall C-boundary
-- kills the coroutine (docs/lib http.lua warns about exactly this).
local function __netFetchOne(job)
  if __netBackend then
    local resp, err = __netBackend(job.url, job.options)
    if resp == false then
      __netDeferred[job.id] = job
      return false
    end
    return resp, err
  end
  if __netClient == nil then
    return nil, "http client not set: call ui.setHttpClient(client) from the main program"
  end
  return __netClient:fetch(job.url, job.options)
end

-- Finish a fetch job: normalize errors to a failed response, store the
-- response in __netResults (the response NEVER crosses an event — CC event
-- args cannot carry function values, and responses carry methods), then wake
-- the UI with an event carrying only the primitive job id.
local function __netFinish(id, resp, err)
  if err ~= nil then resp = { ok = false, error = err } end
  if resp == nil then resp = { ok = false, error = "empty response" } end
  __netResults[id] = resp
  if os.queueEvent then os.queueEvent("ccreact_net_done", id) end
end

-- The network worker task body. It drains the job queue on every wake-up,
-- then waits for any event (an event can be missed while a blocking fetch is
-- in flight — the drain loop catches up when it returns).
local function __networkLoop()
  while true do
    while #__netJobs > 0 do
      local job = table.remove(__netJobs, 1)
      local resp, err = __netFetchOne(job) -- may yield; never wrapped in pcall
      if resp ~= false then
        __netFinish(job.id, resp, err)
      end
    end
    os.pullEvent()
  end
end

-- Resolve a deferred job (test harness: feed a network response by hand).
local function __netResolveDeferred(id, resp, err)
  if __netDeferred[id] == nil then return end
  __netDeferred[id] = nil
  __netFinish(id, resp, err)
end

-- Deferred jobs in id order (test harness: find the job to resolve).
local function __netPendingJobs()
  local out = {}
  for id = 1, __netSeq do
    local job = __netDeferred[id]
    if job then out[#out + 1] = { id = id, url = job.url, options = job.options } end
  end
  return out
end

-- ---- setTimeout / setInterval -------------------------------------------
-- JavaScript-compatible timer API backed by CC: Tweaked's os.startTimer().
--
-- setTimeout(fn, ms)  → one-shot timer, returns id
-- setInterval(fn, ms) → repeating timer, returns id
-- clearTimeout(id)    → cancel a pending setTimeout
-- clearInterval(id)   → cancel a pending setInterval
--
-- CC timers are event-driven: os.startTimer(seconds) returns a numeric id,
-- and a "timer" event fires when it expires. We maintain a mapping table so
-- the UI event loop can route timer events to user callbacks.
local __timers = {}   -- our_id -> { callback, repeating, ms, ccId }
local __timerSeq = 0

-- Shared implementation: the codegen emits __timerNew(cb, ms, false) for
-- setTimeout and __timerNew(cb, ms, true) for setInterval, keeping the
-- number of top-level locals at 200.
local function __timerNew(callback, ms, repeating)
  local delay = (ms or 0) / 1000
  __timerSeq = __timerSeq + 1
  local id = __timerSeq
  local ok, ccId = pcall(os.startTimer, delay)
  if ok and ccId then
    __timers[id] = { callback = callback, repeating = repeating, ms = ms, ccId = ccId }
  end
  return id
end

local function __clearTimer(id)
  local t = __timers[id]
  if t then
    if t.ccId and os.cancelTimer then pcall(os.cancelTimer, t.ccId) end
    __timers[id] = nil
  end
end

-- ---- useRequest ----------------------------------------------------------
-- Three-state data-fetch hook: { data, loading, error, refetch }. fetcher()
-- must return a future (typically () => fetch(url)). Fetches on mount and
-- whenever deps change; a stale response (a newer request started since) is
-- ignored, so refetching or dep changes can't be clobbered by an older
-- in-flight request. `data` is the resolved response (check .ok).
local function __useRequest(fetcher, deps)
  __hookIdx = __hookIdx + 1
  local dataIdx = __hookIdx
  __hookIdx = __hookIdx + 1
  local loadingIdx = __hookIdx
  __hookIdx = __hookIdx + 1
  local errorIdx = __hookIdx
  __hookIdx = __hookIdx + 1
  local tokenIdx = __hookIdx
  __hookIdx = __hookIdx + 1
  local effectIdx = __hookIdx

  local path = __currentPath
  local st = __state[path]
  if st.slots[loadingIdx] == nil then st.slots[loadingIdx] = false end
  if st.slots[tokenIdx] == nil then st.slots[tokenIdx] = 0 end

  local function startRequest()
    local myTok = st.slots[tokenIdx] + 1
    st.slots[tokenIdx] = myTok
    st.slots[loadingIdx] = true
    __scheduleRender()
    local f = fetcher()
    __await(f, function(resp)
      if st.slots[tokenIdx] ~= myTok then return end -- stale response: a newer request won
      st.slots[loadingIdx] = false
      if resp ~= nil and resp.ok then
        st.slots[dataIdx] = resp
        st.slots[errorIdx] = nil
      else
        st.slots[dataIdx] = nil
        st.slots[errorIdx] = (resp ~= nil and resp.error) or "request failed"
      end
      __scheduleRender()
    end)
  end

  -- effect: fetch on mount and whenever deps change (fires after the draw,
  -- exactly like __useEffect)
  local prev = st.effects[effectIdx]
  local changed = prev == nil or not __sameDeps(prev.deps, deps)
  st.effects[effectIdx] = { deps = deps, fn = nil }
  if changed then
    table.insert(__pendingEffects, startRequest)
  end

  return {
    data = st.slots[dataIdx],
    loading = st.slots[loadingIdx],
    error = st.slots[errorIdx],
    refetch = startRequest,
  }
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
  if kind == "text" or kind == "button" or kind == "input" then
    local fs = s.fontSize or 1
    local tp = s.textPadding or 1 -- mod default: 1px spacing between chars
    local str
    if kind == "input" then
      str = node.value or ""
      if #str == 0 then str = node.placeholder or "" end
      if #str == 0 then str = " " end -- keep an empty input a char cell wide
    else
      str = kind == "text" and (node.text or "") or (node.label or "")
    end
    cw = __gpu.getTextLength(__enc(str), fs, tp)
    ch = __fontH * fs
  elseif kind == "scroll" then
    -- The scroll node is a viewport: auto-sizes to the parent's inner box
    -- (explicit width/height still win). Its CONTENT is measured unbounded in
    -- the scroll axis during __layoutScroll.
    cw = __resolveSize(s.width, maxW, maxW)
    ch = __resolveSize(s.height, maxH, maxH)
  elseif kind == "switch" then
    -- Toggle switch: fixed 16×9 default size, overridable via style.
    cw = __resolveSize(s.width, 16, maxW)
    ch = __resolveSize(s.height, 9, maxH)
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

  if node.kind == "input" then
    -- box width is known now: compute the horizontal text scroll (the text
    -- view follows the cursor; see __layoutInputOffset)
    __layoutInputOffset(node)
  elseif node.kind == "scroll" then
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
  node.focused = node.path == __focusedPath
  if node.focused then __focusSeen = true end
  -- cursor position for the focused input (clamped to the current value);
  -- cursorVisible drives the blink repaint
  local inState = __inputState[path]
  local cur = inState and inState.cursor or 0
  local vlen = (type(node.value) == "string") and #node.value or 0
  if cur < 0 then cur = 0 elseif cur > vlen then cur = vlen end
  if inState and inState.cursor ~= cur then inState.cursor = cur end
  node.cursor = cur
  node.cursorVisible = node.focused and inState ~= nil and inState.blink
  if __isFocusable(node) then table.insert(__focusList, node) end
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
  if a.value ~= b.value then return false end
  if a.placeholder ~= b.placeholder then return false end
  if a.pressed ~= b.pressed then return false end
  if a.focused ~= b.focused then return false end
  if a.disabled ~= b.disabled then return false end
  if a.cursor ~= b.cursor then return false end
  if a.cursorVisible ~= b.cursorVisible then return false end
  if a.x ~= b.x or a.y ~= b.y or a.w ~= b.w or a.h ~= b.h then return false end
  return true
end

local function __addRect(rects, x, y, w, h)
  if w <= 0 or h <= 0 then return end
  -- pad each dirty rect so glyphs drawing a few px beyond the measured box
  -- are always repainted (__mergeRects clamps to the viewport afterwards)
  table.insert(rects, { x - DIRTY_PAD, y - DIRTY_PAD, w + DIRTY_PAD * 2, h + DIRTY_PAD * 2 })
end

-- Full drawn extent of a node for dirty-rect purposes. text/button draw
-- their glyphs WITHOUT clipping to the box (a fixed-width button with a long
-- label paints beyond its edges), so the dirty rect must cover that whole
-- span — otherwise a label change leaves stale pixels beyond the box. Input
-- text is clipped to its content box (__layoutInputOffset scrolls it), so
-- the box alone is its full drawn extent.
local function __visualRect(node)
  local x, y, w, h = node.x, node.y, node.w, node.h
  local left, right, top, bottom = x, x + w, y, y + h
  local kind = node.kind
  if kind == "text" or kind == "button" then
    local s = node.style
    local fs = s.fontSize or 1
    local tp = s.textPadding or 1
    local str = kind == "text" and (node.text or "") or (node.label or "")
    local tw = __gpu.getTextLength(__enc(str), fs, tp)
    local th = __fontH * fs
    local tx, ty
    if kind == "button" then
      tx = math.floor(x + (w - tw) / 2 + 0.5)
      ty = math.floor(y + (h - th) / 2 + 0.5)
    else
      tx = x + (s.paddingL or 0)
      ty = y + (s.paddingT or 0)
    end
    if tx < left then left = tx end
    if tx + tw > right then right = tx + tw end
    if ty < top then top = ty end
    if ty + th > bottom then bottom = ty + th end
  end
  return left, top, right - left, bottom - top
end

local function __compareTrees(a, b, rects)
  if not __sameNode(a, b) then
    local ax, ay, aw, ah = __visualRect(a)
    local bx, by, bw, bh = __visualRect(b)
    __addRect(rects, ax, ay, aw, ah)
    __addRect(rects, bx, by, bw, bh)
    return
  end
  local na, nb = #a.children, #b.children
  local n = na > nb and na or nb
  for i = 1, n do
    local ac, bc = a.children[i], b.children[i]
    if ac and bc then
      __compareTrees(ac, bc, rects)
    elseif ac then
      local ax, ay, aw, ah = __visualRect(ac)
      __addRect(rects, ax, ay, aw, ah)
    elseif bc then
      local bx, by, bw, bh = __visualRect(bc)
      __addRect(rects, bx, by, bw, bh)
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

-- Intersect an existing clip rect with another rect (the scroll viewport or
-- an input's content box), then clamp to the viewport — every clip consumed
-- by __gpu.drawText/__gpu.filledRectangle is guaranteed inside the screen,
-- so clipped drawing never hits the GPU's "Out of boundary" throw. Returns a
-- new clip table, or nil when empty (nothing visible).
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
  if x1 < 1 then x1 = 1 end
  if y1 < 1 then y1 = 1 end
  if x2 > __viewportW then x2 = __viewportW end
  if y2 > __viewportH then y2 = __viewportH end
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
  local disabled = node.disabled == true
  local fill = s.backgroundColor
  if node.kind == "button" then
    if disabled then
      fill = 0xFF1A1A22
    elseif node.pressed and s.pressedColor then
      fill = s.pressedColor
    end
  elseif node.kind == "input" and disabled then
    fill = 0xFF1A1A22
  end
  if fill then __gpu.filledRectangle(node.x, node.y, w, h, fill, clip) end
  if s.borderColor then
    local bc = s.borderColor
    if disabled then
      bc = 0xFF333340
    elseif node.kind == "input" and node.focused and s.focusBorderColor then
      bc = s.focusBorderColor -- focus ring
    end
    __gpu.rectangle(node.x, node.y, w, h, bc, clip)
  end
  if node.kind == "text" then
    if node.text and #node.text > 0 then
      __gpu.drawText(
        node.x + s.paddingL, node.y + s.paddingT, __enc(node.text),
        s.color or COLOR_TEXT, s.textBackgroundColor, s.fontSize or 1, s.textPadding or 1, clip)
    end
  elseif node.kind == "button" then
    local fs = s.fontSize or 1
    local tp = s.textPadding or 1
    local label = __enc(node.label or "")
    local tw = __gpu.getTextLength(label, fs, tp)
    local th = __fontH * fs
    local tx = math.floor(node.x + (w - tw) / 2 + 0.5)
    local ty = math.floor(node.y + (h - th) / 2 + 0.5)
    local textColor = disabled and 0xFF5A5A68 or (s.color or COLOR_TEXT)
    __gpu.drawText(tx, ty, label, textColor, fill, fs, tp, clip)
  elseif node.kind == "input" then
    local fs = s.fontSize or 1
    local tp = s.textPadding or 1
    local val = node.value or ""
    -- the text view is clipped to the content box and scrolled horizontally
    -- so the cursor stays visible (__layoutInputOffset set node.inputOffset)
    local contentW = math.max(0, node.w - s.paddingL - s.paddingR)
    local contentH = math.max(0, node.h - s.paddingT - s.paddingB)
    local iclip = __clipIntersect(clip, node.x + s.paddingL, node.y + s.paddingT, contentW, contentH)
    local off = node.inputOffset or 0
    local show, color = val, s.color or COLOR_TEXT
    if disabled then
      color = 0xFF5A5A68
    end
    if #show == 0 then
      show = node.placeholder or ""
      if disabled then
        color = 0xFF5A5A68
      else
        color = s.placeholderColor or (s.color or COLOR_TEXT)
      end
      off = 0 -- the placeholder is pinned to the left edge
    end
    local eshow = __enc(show)
    if #eshow > 0 then
      __gpu.drawText(node.x + s.paddingL - off, node.y + s.paddingT, eshow, color, s.textBackgroundColor, fs, tp, iclip)
    end
    -- blinking insertion-point cursor (2px bar, full glyph height) — hidden when disabled
    if node.focused and node.cursorVisible and not disabled then
      local eval = __enc(val)
      local ecur = __encCursor(val, node.cursor)
      local cw = __gpu.getTextLength(eval:sub(1, ecur), fs, tp)
      local cx = node.x + s.paddingL + cw - off
      __gpu.filledRectangle(cx, node.y + s.paddingT, 2, __fontH * fs, s.cursorColor or COLOR_TEXT, iclip)
    end
  elseif node.kind == "switch" then
    -- Toggle switch: track (full node) + sliding knob.
    -- ON  = accent fill + knob on right;  OFF = dark fill + knob on left.
    local isOn = node.value == true
    local trackColor
    if disabled then
      trackColor = 0xFF1A1A22
    elseif isOn then
      trackColor = s.color or 0xFF7EC8FF  -- accent (on)
    else
      trackColor = fill or 0xFF3A3A48      -- off
    end
    -- Draw track background
    __gpu.filledRectangle(node.x, node.y, w, h, trackColor, clip)
    if s.borderColor then
      local bc = disabled and 0xFF333340 or s.borderColor
      __gpu.rectangle(node.x, node.y, w, h, bc, clip)
    end
    -- Knob: 7×7 centered vertically, horizontal position depends on on/off.
    -- Padding of 1px around the knob inside the track.
    local knobSize = 7
    local knobY = node.y + math.floor((h - knobSize) / 2)
    local knobX
    if isOn then
      knobX = node.x + w - knobSize - 1  -- right side
    else
      knobX = node.x + 1                  -- left side
    end
    local knobColor
    if disabled then
      knobColor = 0xFF5A5A68
    elseif isOn then
      knobColor = 0xFFFFFFFF  -- white knob on accent track
    else
      knobColor = 0xFFAAAAAA  -- gray knob on dark track
    end
    __gpu.filledRectangle(knobX, knobY, knobSize, knobSize, knobColor, clip)
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
  __focusList = {}
  __focusSeen = false
  local ok, tree = pcall(__component, "__root", __rootFn, {})
  if not ok then error("cc-react: render failed: " .. tostring(tree), 0) end
  if type(tree) ~= "table" then
    error("cc-react: the root component must return an element, got " .. tostring(tree), 0)
  end
  __assignPaths(tree, "1", nil)
  -- if the focused node vanished (conditional render removed it), drop the
  -- focus state — don't schedule, we are mid-render already
  if __focusedPath and not __focusSeen then
    __cancelBlink(__focusedPath)
    __focusedPath = nil
  end
  __layout(tree, 1, 1, __viewportW, __viewportH)

  local rects = {}
  if __lastTree == nil then
    __addRect(rects, 1, 1, __viewportW, __viewportH)
  else
    __compareTrees(__lastTree, tree, rects)
  end
  __lastTree = tree

  local merged, area = __mergeRects(rects, __viewportW, __viewportH)
  if area > __viewportW * __viewportH * 0.4 then
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
      local hit = __hitTest(x, y)
      -- focus management: tapping an input focuses it (cursor at the tap
      -- position), any other tap blurs; disabled nodes are never focusable
      if hit and __isFocusable(hit) then
        __focusInputAt(hit, x)
      else
        __blur()
      end
      local h = __findHandler(hit, "onClick")
      if h and h.onClick and not h.disabled then
        h.onClick()
      end
    end
  elseif name == "tm_monitor_mouse_click" then
    local i = __eventArgs(e)
    local x, y, btn = e[i], e[i + 1], e[i + 2]
    if type(x) == "number" and type(y) == "number" and (btn == nil or btn == 1) then
      local hit = __hitTest(x, y)
      if hit and __isFocusable(hit) then
        __focusInputAt(hit, x)
      else
        __blur()
      end
      local h = __findHandler(hit, "onClick")
      if h and not h.disabled then
        __pressedPath = h.path
        __scheduleRender() -- repaint the pressed visual
      end
      -- a press over a scroll container starts a potential touch drag
      local sc = __findScrollAncestor(hit)
      if sc and not sc.disabled then
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
          if h and h.path == __pressedPath and h.onClick and not h.disabled then
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
      if sc and not sc.disabled then
        -- Real-device convention (verified in source): Minecraft wheel delta
        -- < 0 (wheel down) maps to dir = +1, wheel up to dir = -1 — so a
        -- positive dir scrolls the content down (scrollY increases).
        local step = sc.style.scrollStep or 8
        __scrollBy(sc, 0, dir * step)
      end
    end
  elseif name == "tm_keyboard_key" then
    -- (peripheral, key, isRepeat): fires on press AND on auto-repeat
    local i = __eventArgs(e)
    local key, isRepeat = e[i], e[i + 1]
    if type(key) == "number" then
      __modsDown[key] = true
      local node = __focusedNode()
      if node then
        __handleKeyDown(node, key)
        if node.onKey then node.onKey(key, false) end
      end
    end
  elseif name == "tm_keyboard_key_up" then
    -- (peripheral, key): fires once on release
    local i = __eventArgs(e)
    local key = e[i]
    if type(key) == "number" then
      __modsDown[key] = nil
      local node = __focusedNode()
      if node and node.onKey then node.onKey(key, true) end
    end
  elseif name == "tm_keyboard_char" then
    -- (peripheral, char): printable characters only (space included)
    local i = __eventArgs(e)
    local ch = e[i]
    if type(ch) == "string" and #ch > 0 then
      local node = __focusedNode()
      if node then __inputInsert(node, ch) end
    end
  elseif name == "tm_keyboard_paste" then
    -- (peripheral, content): the player's clipboard (Ctrl+V is intercepted
    -- client-side, so this is the only way pasted text reaches the program)
    local i = __eventArgs(e)
    local content = e[i]
    if type(content) == "string" and #content > 0 then
      local node = __focusedNode()
      if node then __inputInsert(node, content) end
    end
  elseif name == "ccreact_net_done" then
    -- (id) — a fetch worker finished a job. The response lives in
    -- __netResults (CC events can't carry function values, and responses
    -- carry methods); only the primitive id crosses the event.
    local id = e[2]
    local f = __netPending[id]
    if f then
      __netPending[id] = nil
      local resp = __netResults[id]
      __netResults[id] = nil
      __resolveFuture(f, resp)
    end
  elseif name == "timer" then
    local ccId = e[2]
    -- cursor blink tick for the focused input
    local st = __focusedPath and __inputState[__focusedPath]
    if st and st.timer == ccId then
      st.blink = not st.blink
      __scheduleRender()
      if os.startTimer then
        local ok, id2 = pcall(os.startTimer, BLINK_INTERVAL)
        if ok and id2 then st.timer = id2 end
      end
    end
    -- user timers (setTimeout / setInterval)
    local ourId, t = nil, nil
    for tid, tt in pairs(__timers) do
      if tt.ccId == ccId then ourId, t = tid, tt; break end
    end
    if t then
      if t.repeating then
        -- restart the interval timer
        local ok, newCcId = pcall(os.startTimer, t.ms / 1000)
        if ok and newCcId then
          t.ccId = newCcId
        else
          __timers[ourId] = nil
        end
      else
        __timers[ourId] = nil
      end
      local ok, err = pcall(t.callback)
      if not ok then print("cc-react: timer callback error: " .. tostring(err)) end
    end
  end
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

-- The UI event loop: pulls every event, routes the ones it understands
-- (tm_monitor_*, tm_keyboard_*, timers, network completions), then drains any
-- queued re-renders. CC broadcasts every event to all consumers, so this
-- loop filters its own and never steals from other tasks.
local function __uiLoop()
  while true do
    local e = { os.pullEvent() }
    local ok, err = pcall(__handleEvent, e)
    if not ok then print("cc-react: event error: " .. tostring(err)) end
    __drain()
  end
end

-- The UI task body. This is the function a main program hands to
-- simpleParallel (parallel.waitForAll), so the UI loop runs concurrently
-- with the rest of the program (network stack tasks). Initialization is done
-- here, not at load time.
--
-- start() ALSO composes the network worker loop (networkLoop) internally via
-- parallel.waitForAll — the fetch worker needs its own coroutine (blocking
-- HTTP yields on sockets), and nested waitForAll is exactly that scheduler.
-- The main program still adds only ONE task:
--
--   simpleParallel.add(function() ui.start("left") end)
--   simpleParallel.start()
local function __start(side)
  if __rootFn == nil then
    error("cc-react: no component mounted — the module needs render(<App/>) at top level", 0)
  end
  local w, h = __gpuReady(side)
  __viewportW, __viewportH = w, h
  if __chineseFontFile then
    if not __fontInit(__chineseFontFile) then
      print("cc-react: chinese font init failed — continuing without Chinese support")
    end
  end
  __render()
  __drain()
  if parallel and parallel.waitForAll then
    parallel.waitForAll(
      function() __uiLoop() end,
      function() __networkLoop() end)
  else
    -- no parallel scheduler available: run the UI alone (fetch jobs stay
    -- queued — the worker needs a scheduler to run)
    __uiLoop()
  end
end

-- Module interface + debug/test hooks. The compiled module returns this
-- table (see the `return ccreact` epilogue appended by the compiler); the
-- headless test harness drives it through start() and inspects the tree.
ccreact = {
  -- entry points
  start = function(side) return __start(side) end,
  mount = function(rootFn) __mount(rootFn) end,
  -- network (milestone 3): the main program builds the docs/lib HTTP client
  -- (it owns the IP stack config) and hands the instance to the module;
  -- start() already runs the networkLoop worker internally. networkLoop() is
  -- kept for advanced composition (e.g. running the worker under a different
  -- scheduler) — do NOT add it as a separate task alongside start().
  setHttpClient = function(client) __setHttpClient(client) end,
  -- Chinese font (opt-in): point at a binary font file on the computer's
  -- disk (format v1, generated by make_font_bin.py). Call BEFORE start().
  -- Without it the runtime keeps the default 5x8 ASCII font.
  setChineseFont = function(name) __chineseFontFile = name end,
  networkLoop = function() return __networkLoop() end,
  -- debug / test hooks
  setNetworkBackend = function(fn) __netBackend = fn end,
  getNetworkJobs = function() return __netPendingJobs() end,
  resolveNetworkJob = function(id, resp, err) __netResolveDeferred(id, resp, err) end,
  getTree = function() return __lastTree end,
  getViewport = function() return __viewportW, __viewportH end,
  isPressed = function() return __pressedPath end,
  hitTest = function(x, y) return __hitTest(x, y) end,
  getFocused = function() return __focusedPath end,
  getInputState = function(path) return __inputState[path] end,
}
