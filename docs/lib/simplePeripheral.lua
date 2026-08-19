---@diagnostic disable
--[[-
simplePeripheral — 用 schema 描述设备所需接口, 通过 side 绑定实际外设位置并严格校验。
仅在 CC: Tweaked 环境中运行(依赖 peripheral / redstone / colours 全局 API)。

用法:

    local simplePeripheral = require("lib.simplePeripheral")

    -- 1) 定义 schema: 设备需要哪些接口
    local schema = simplePeripheral.defineSchema("controller", {
        { name = "modem",   kind = "peripheral", type = "modem" },                        -- 需要类型完全一致的外设
        { name = "power",   kind = "redstone", direction = "input",  signal = "binary" },   -- 数字输入(抽象布尔)
        { name = "dial",    kind = "redstone", direction = "input",  signal = "analogue" }, -- 模拟输入 0-15
        { name = "enabled", kind = "redstone", direction = "output", signal = "binary" },   -- 数字输出(抽象布尔)
        { name = "bus",     kind = "redstone", direction = "output", signal = "bundled" },  -- 整根 bundled 电缆(原始接口控制)
    })

    -- 2) attach: 绑定各接口到实际外设地址或红石 side, 校验失败会报错退出
    local device = schema:attach {
        modem   = "top",
        power   = "left",
        dial    = "left",                                   -- 同侧复用: 方向同为 input, 允许
        enabled = { side = "front", color = colours.red },  -- binary 接口绑成 bundled 的红色通道(上层仍只看到 boolean)
        bus     = "right",                                  -- bundled 接口只绑 side, 整根电缆由上层控制
        relay_in  = { relay = "redstone_relay_0", side = "front" },  -- relay 的 front 面作为 binary 输入
        relay_bus = { relay = "redstone_relay_0", side = "right" },  -- relay 的 right 面作为 bundled 输出
    }

    -- 3) 使用
    local modem = device:getPeripheral("modem")
    local powered = device:getInput("power")        -- boolean
    local level   = device:getInput("dial")         -- 0-15 的 number
    device:setOutput("enabled", true)               -- 写 front 红色通道(读改写, 不影响其他通道)
    device:setBundledOutput("bus", 0xFFFF)          -- 整根电缆全开(覆盖全部 16 个通道)
    local mask = device:getBundledInput("bus")      -- 整根电缆输入掩码
    device:testBundledInput("bus", colours.green)   -- 绿色通道是否开

设计要点 / 限制:
  * 接口分两类: 外设接口(kind = "peripheral", 类型必须与 peripheral.getType 完全一致)和
    红石接口(kind = "redstone", 方向 + 信号类型)。
  * 红石信号三种:
      - binary: 抽象布尔, attach 时可绑成真实红石("side")或 bundled 的某个颜色通道
        ({ side = ..., color = ... }); 输出走通道时读改写, 不影响同侧其他通道。
      - analogue: 模拟强度 0-15, 只能绑普通 side(模拟量无法走 bundled 通道)。
      - bundled: 整根电缆的完整控制权, 只绑 side; 用 getBundledInput/testBundledInput/
        getBundledOutput/setBundledOutput 操作 16 位掩码, 不接受 color 参数。
  * 同侧冲突按域检查: 普通红石域(binary/analogue 直接绑 side)必须全 input 或恰好一个 output;
    bundled 域(该侧的 bundled 接口 + binary 通道接口)规则:
      - 出现 bundled 输出(整根电缆)则独占该侧 bundled 域, 不能与其他 bundled 接口共存;
      - 有 bundled 输入(读整根电缆)时不允许任何通道输出, 否则会读到自己写入的通道;
      - 只有 binary 通道接口时按颜色通道检查(每色至多一个 output, 同色不允许 input+output, 不同颜色独立)。
    两个域互相独立, 且外设接口可与红石接口共享 side。
  * 外设接口绑定可以是六个 side(top/bottom/left/right/front/back), 也可以是有线 modem 上的任意外设名(如 "monitor_0"、"modem_1")。
  * **relay 绑定**: kind="redstone" 的接口还可绑定到 redstone_relay 外设的某个面,
    格式为 { relay = "redstone_relay_0", side = "front" }, binary 时可附加 color 走 bundled 通道。
    relay 绑定的红石读写自动通过 relay 外设的 API 路由, 对上层完全透明。
]]

---@diagnostic disable: undefined-global

-- ===== 类型定义(EmmyLua) =====

--- 红石接口可用方向。
---@alias RedstoneDirection "input"|"output"

--- 红石信号类型: "binary"=数字(抽象布尔), "analogue"=模拟强度(0-15), "bundled"=整根 bundled 电缆(16 位掩码)。
---@alias RedstoneSignal "binary"|"analogue"|"bundled"

--- 计算机的六个 side。
---@alias Side "top"|"bottom"|"left"|"right"|"front"|"back"

--- colours 表中的颜色位掩码(如 colours.red = 16384), 每个都是 2 的幂; 也可用于组合(如 colours.combine)。
---@alias ColourMask integer

--- CC: Tweaked 的 wrapped 外设对象(`peripheral.wrap` 的返回值)。
--- 具体可用方法取决于外设类型(如 modem 有 transmit/receive)。
--- 若 IDE 同时加载了社区类型定义(如 github.com/applejag/cc-tweaked-emmylua),
--- 同名类会自动合并, 获得完整的各外设方法提示。
---@class Peripheral
---@field getName fun(self: Peripheral): string 外设的名字(通常是 side, 如 "top")
---@field getType fun(self: Peripheral): string 外设类型(如 "modem")

--- 外设接口定义: 需要某处存在类型与 `type` 完全一致的外设。
--- 绑定可以是 side(top/bottom/left/right/front/back), 也可以是有线 modem 上的外设名(如 "monitor_0")。
---@class PeripheralInterfaceSpec
---@field name string 接口名(schema 内唯一)
---@field kind "peripheral"
---@field type string 要求的外设类型, attach 时用 peripheral.getType(addr) 与之完全一致

--- 红石接口定义: 用 方向 + 信号类型 描述, 实际位置在 attach 时绑定。
--- 注意: bundled 接口不再有 color 字段(color 概念只出现在 binary 接口的 attach 绑定里)。
---@class RedstoneInterfaceSpec
---@field name string 接口名(schema 内唯一)
---@field kind "redstone"
---@field direction RedstoneDirection 信号方向
---@field signal RedstoneSignal 信号类型

--- 任一接口定义。
---@alias InterfaceSpec PeripheralInterfaceSpec|RedstoneInterfaceSpec

--- binary 接口绑定为 bundled 通道时的绑定: 除了 side 还要指定颜色通道。
---@class ChannelBinding
---@field side Side bundled 电缆所在侧
---@field color ColourMask 颜色通道, 必须是 colours 表中的单一颜色(如 colours.red)

--- redstone_relay 绑定: 指定 relay 外设名 + 其上面; binary 时还可指定颜色通道。
---@class RelayBinding
---@field relay string redstone_relay 外设名(如 "redstone_relay_0")
---@field side Side relay 上的面
---@field color? ColourMask binary 信号走 bundled 通道时指定颜色(analogue/bundled 不需要)

--- 任一接口的绑定: 外设接口为任意非空字符串(side 或 wired modem 上的外设名); 红石普通 side 绑定为 Side 字符串;
--- binary 接口还可以是 { side = ..., color = ... } 或 relay 绑定。
---@alias InterfaceBinding Side|string|ChannelBinding|RelayBinding

--- attach 时传入的绑定表: 接口名 -> 绑定。
---@alias Bindings { [string]: InterfaceBinding }

--- 设备接口 schema。
---@class SimplePeripheralSchema
---@field name string 设备名
---@field interfaces InterfaceSpec[] 接口定义列表
---@field _byName { [string]: InterfaceSpec } 接口名索引(内部使用)
---@field validate fun(self: SimplePeripheralSchema, bindings: Bindings): string[]? 校验绑定是否满足 schema
---@field attach fun(self: SimplePeripheralSchema, bindings: Bindings): SimplePeripheralDevice 绑定各接口到实际外设, 校验失败报错

--- 绑定完成后的设备对象。
---@class SimplePeripheralDevice
---@field name string 设备名
---@field schema SimplePeripheralSchema 来源 schema
---@field sides { [string]: Side|string } 各接口绑定的 side 或外设地址(peripheral 接口可为 wired modem 上的外设名)
---@field colors { [string]: ColourMask } 绑定为 bundled 通道的 binary 接口的颜色(仅此类接口有)
---@field wrapped { [string]: Peripheral } 外设接口的 wrapped 外设(仅 kind == "peripheral" 的接口)
---@field relays { [string]: Peripheral } relay 绑定的 wrapped redstone_relay 外设
---@field relaySides { [string]: Side } relay 绑定的 relay 上的面

---@class simplePeripheral
local simplePeripheral = {}

-- ===== 内部工具 =====

local SimplePeripheralSchema = {}
SimplePeripheralSchema.__index = SimplePeripheralSchema

local SimplePeripheralDevice = {}
SimplePeripheralDevice.__index = SimplePeripheralDevice

local SIDES = {
    top = true, bottom = true, left = true, right = true, front = true, back = true,
}

--- 带前缀和调用方定位的报错(level 2 指向调用本库函数的那一行)。
---@param fmt string
---@param ... any
local function fail(fmt, ...)
    error(("simplePeripheral: " .. fmt):format(...), 2)
end

--- 判断 value 是否为 colours 表中的单一颜色位掩码。
---@param value any
---@return boolean
local function isSingleColour(value)
    if type(value) ~= "number" then
        return false
    end
    for _, mask in pairs(colours) do
        if mask == value then
            return true
        end
    end
    return false
end

--- 判断 value 是否为 relay 绑定格式({ relay = ..., side = ... })。
---@param value any
---@return boolean
local function isRelayBinding(value)
    return type(value) == "table"
        and type(value.relay) == "string" and value.relay ~= ""
        and type(value.side) == "string" and SIDES[value.side]
end

--- 在 bundled 电缆的单个颜色通道上写布尔(读改写, 不影响同侧其他通道)。
--- 支持通过 relay 操作。
---@param device SimplePeripheralDevice 设备对象
---@param name string 接口名
---@param bit ColourMask 颜色位掩码(2 的幂)
---@param on boolean
local function setBundledChannel(device, name, bit, on)
    local side = device.sides[name]
    local relay = device.relays[name]
    local rs = relay or redstone
    local cur = relay and relay.getBundledOutput(side) or redstone.getBundledOutput(side)
    local others
    if cur % (bit * 2) >= bit then
        others = cur - bit
    else
        others = cur
    end
    rs.setBundledOutput(side, others + (on and bit or 0))
end

--- 校验一个接口定义(schema 定义期), 不合法直接报错。
---@param iface InterfaceSpec
---@param index integer 定义在列表中的序号
---@param seenNames { [string]: boolean } 已见过的接口名
local function checkInterface(iface, index, seenNames)
    if type(iface) ~= "table" then
        fail("interface definition #%d is not a table", index)
    end
    local name = iface.name
    if type(name) ~= "string" or name == "" then
        fail("interface definition #%d is missing a non-empty 'name' field", index)
    end
    if seenNames[name] then
        fail("duplicate interface name '%s'", name)
    end
    seenNames[name] = true

    if iface.kind == "peripheral" then
        if type(iface.type) ~= "string" or iface.type == "" then
            fail("peripheral interface '%s' requires a 'type' field (e.g. \"modem\")", name)
        end
    elseif iface.kind == "redstone" then
        if iface.direction ~= "input" and iface.direction ~= "output" then
            fail("redstone interface '%s' direction must be \"input\" or \"output\", got %s", name, tostring(iface.direction))
        end
        if iface.signal ~= "binary" and iface.signal ~= "analogue" and iface.signal ~= "bundled" then
            fail("redstone interface '%s' signal must be \"binary\", \"analogue\", or \"bundled\", got %s", name, tostring(iface.signal))
        end
    else
        fail("interface '%s' kind must be \"peripheral\" or \"redstone\", got %s", name, tostring(iface.kind))
    end
end

-- ===== schema 定义与绑定 =====

--- 定义一个设备接口 schema。
--- 接口定义形态:
---   { name = "...", kind = "peripheral", type = "modem" }                 -- 需要类型完全一致的外设(side 或 wired modem 上的外设名)
---   { name = "...", kind = "redstone", direction = "input|output", signal = "binary|analogue|bundled" }
---   -- binary: 抽象布尔, attach 时可绑普通 side 或 bundled 通道 { side, color }
---   -- analogue: 模拟强度(0-15), 只能绑普通 side
---   -- bundled: 整根电缆, 只绑 side, 由上层用 setBundledOutput/getBundledInput 等控制
---@param name string 设备名(仅用于报错信息)
---@param interfaces InterfaceSpec[] 接口定义列表(至少一个)
---@return SimplePeripheralSchema
function simplePeripheral.defineSchema(name, interfaces)
    if type(name) ~= "string" or name == "" then
        fail("defineSchema requires a non-empty device name")
    end
    if type(interfaces) ~= "table" or #interfaces == 0 then
        fail("defineSchema requires at least one interface definition")
    end
    local seenNames = {}
    for index, iface in ipairs(interfaces) do
        checkInterface(iface, index, seenNames)
    end

    local schema = {
        name = name,
        interfaces = interfaces,
        _byName = {},
    }
    for _, iface in ipairs(interfaces) do
        schema._byName[iface.name] = iface
    end
    return setmetatable(schema, SimplePeripheralSchema)
end

--- 校验一份绑定是否满足 schema, 返回错误信息列表; 全部通过时返回 nil。
--- 校验内容:
---   * 每个接口都有绑定, 且不存在多余的未知接口名
---   * 外设接口: 绑定为任意非空字符串(side 或 wired modem 上的外设名), 该处必须存在外设, 且类型与 schema 完全一致
---   * binary 接口可绑为 bundled 通道 { side = ..., color = ... }, color 必须是 colours 单一颜色
---   * analogue/bundled 接口只能绑普通 side(bundled 不再有 color, 由上层用原始接口控制)
---   * 同侧冲突按域检查(规则见文件头"设计要点")
---@param self SimplePeripheralSchema
---@param bindings Bindings 接口名 -> side 或 { side = ..., color = ... }(仅 binary 接口)
---@return string[]? 错误信息列表, 全部通过时为 nil
function SimplePeripheralSchema:validate(bindings)
    if type(peripheral) ~= "table" then
        return { "current environment has no peripheral API (this library only supports CC: Tweaked)" }
    end
    local errors = {}
    if type(bindings) ~= "table" then
        return { "bindings must be a table (interface name -> side or { side = ..., color = ... })" }
    end

    -- 1) 未知接口名
    for boundName in pairs(bindings) do
        if not self._byName[boundName] then
            table.insert(errors, ("unknown interface name '%s' (not in schema)"):format(tostring(boundName)))
        end
    end

    -- 2) 逐接口检查
    for _, iface in ipairs(self.interfaces) do
        local binding = bindings[iface.name]
        if binding == nil then
            table.insert(errors, ("interface '%s' is missing a binding"):format(iface.name))
        elseif iface.kind == "peripheral" then
            -- 外设接口: 绑定必须是非空字符串(可以是 side 或 wired modem 上的外设名), 且外设存在、类型完全一致
            if type(binding) ~= "string" or binding == "" then
                table.insert(errors, ("interface '%s' binding '%s' is not a valid peripheral address (must be a non-empty string, e.g. \"top\" or \"monitor_0\")"):format(iface.name, tostring(binding)))
            else
                if not peripheral.isPresent(binding) then
                    table.insert(errors, ("peripheral interface '%s': no peripheral at '%s'"):format(iface.name, binding))
                else
                    local actual = peripheral.getType(binding)
                    if actual ~= iface.type then
                        table.insert(errors, ("peripheral interface '%s' requires type '%s', but '%s' has %s"):format(iface.name, iface.type, binding, tostring(actual)))
                    end
                end
            end
        elseif iface.kind == "redstone" and iface.signal == "binary" and type(binding) == "table" and not isRelayBinding(binding) then
            -- binary 接口绑定为 bundled 通道: { side = ..., color = ... }
            if type(binding.side) ~= "string" or not SIDES[binding.side] then
                table.insert(errors, ("interface '%s' side '%s' is invalid (must be top/bottom/left/right/front/back)"):format(iface.name, tostring(binding.side)))
            end
            if not isSingleColour(binding.color) then
                table.insert(errors, ("interface '%s' color must be a single colour from the colours table (e.g. colours.red), got %s"):format(iface.name, tostring(binding.color)))
            end
        elseif iface.kind == "redstone" and iface.signal == "binary" and isRelayBinding(binding) then
            -- binary 接口绑定到 relay: { relay = "...", side = "..." } 或 { relay = "...", side = "...", color = ... }
            if not peripheral.isPresent(binding.relay) then
                table.insert(errors, ("relay binding '%s': peripheral '%s' not present"):format(iface.name, binding.relay))
            elseif peripheral.getType(binding.relay) ~= "redstone_relay" then
                table.insert(errors, ("relay binding '%s': peripheral '%s' is type '%s', expected 'redstone_relay'"):format(iface.name, binding.relay, tostring(peripheral.getType(binding.relay))))
            end
            if binding.color ~= nil and not isSingleColour(binding.color) then
                table.insert(errors, ("relay binding '%s' color must be a single colour from the colours table, got %s"):format(iface.name, tostring(binding.color)))
            end
        elseif iface.kind == "redstone" and type(binding) == "table" and not isRelayBinding(binding) then
            -- analogue / bundled 不接受通道绑定
            if iface.signal == "analogue" then
                table.insert(errors, ("analogue interface '%s' can only bind to a plain side (analogue cannot use bundled channels)"):format(iface.name))
            else
                table.insert(errors, ("bundled interface '%s' binding should just be a side string (color is controlled via setBundledOutput/getBundledInput)"):format(iface.name))
            end
        elseif iface.kind == "redstone" and isRelayBinding(binding) then
            -- analogue/bundled 接口绑定到 relay
            if not peripheral.isPresent(binding.relay) then
                table.insert(errors, ("relay binding '%s': peripheral '%s' not present"):format(iface.name, binding.relay))
            elseif peripheral.getType(binding.relay) ~= "redstone_relay" then
                table.insert(errors, ("relay binding '%s': peripheral '%s' is type '%s', expected 'redstone_relay'"):format(iface.name, binding.relay, tostring(peripheral.getType(binding.relay))))
            end
            if iface.signal == "bundled" then
                -- bundled 信号的 relay 绑定只绑 side, 不需要 color
                if binding.color ~= nil then
                    table.insert(errors, ("bundled relay binding '%s' does not need a color (color is controlled via setBundledOutput/getBundledInput)"):format(iface.name))
                end
            end
        else
            -- 普通 side 绑定(binary/analogue 真实红石, 或 bundled 接口)
            if type(binding) ~= "string" or not SIDES[binding] then
                table.insert(errors, ("interface '%s' binding '%s' is not a valid side (must be top/bottom/left/right/front/back)"):format(iface.name, tostring(binding)))
            end
        end
    end

    -- 3) 同侧冲突检查(只统计绑定合法的接口)
    local perSide = {}
    for _, iface in ipairs(self.interfaces) do
        local binding = bindings[iface.name]
        local side, domain, color
        if iface.kind == "peripheral" then
            -- 外设接口也参与同侧统计(用于"一个 side 最多一个外设"检查)
            if type(binding) == "string" and SIDES[binding] then
                side, domain = binding, "peripheral"
            end
        elseif iface.kind == "redstone" and iface.signal == "binary" and type(binding) == "table" and not isRelayBinding(binding) then
            -- binary 通道接口 -> bundled 域(仅本地 bundled 通道, relay 绑定不参与同侧冲突)
            side, domain, color = binding.side, "bundled", binding.color
        elseif iface.kind == "redstone" and type(binding) == "string" then
            -- 普通侧绑定: bundled 接口进 bundled 域, binary/analogue 进普通域
            side = binding
            domain = iface.signal == "bundled" and "bundled" or "plain"
        end
        if side ~= nil and SIDES[side] then
            perSide[side] = perSide[side] or {}
            table.insert(perSide[side], { iface = iface, domain = domain, color = color })
        end
    end
    for side, entries in pairs(perSide) do
        local peripheralCount = 0
        local plainInput, plainOutput = 0, 0
        local bundledEntries = {}
        for _, entry in ipairs(entries) do
            local iface = entry.iface
            if iface.kind == "peripheral" then
                peripheralCount = peripheralCount + 1
            elseif entry.domain == "bundled" then
                table.insert(bundledEntries, entry)
            else
                if iface.direction == "input" then
                    plainInput = plainInput + 1
                else
                    plainOutput = plainOutput + 1
                end
            end
        end

        if peripheralCount > 1 then
            table.insert(errors, ("side '%s' is shared by %d peripheral interfaces (each side can have at most one peripheral)"):format(side, peripheralCount))
        end
        -- 普通红石域: 全 input 或恰好一个 output
        if plainInput > 0 and plainOutput > 0 then
            table.insert(errors, ("side '%s' plain redstone channel direction conflict: input+output mixed causes feedback (must be all input or exactly one output)"):format(side))
        elseif plainOutput > 1 then
            table.insert(errors, ("side '%s' has %d plain redstone output interfaces (at most one output per side)"):format(side, plainOutput))
        end

        -- bundled 域分析
        local bw, br, cw, cr = 0, 0, 0, 0 -- bundled 输出/输入, 通道输出/输入
        local channelOutputs = {} -- color -> 输出数
        local channelInputs = {}  -- color -> 输入数
        for _, entry in ipairs(bundledEntries) do
            local iface = entry.iface
            local isOutput = iface.direction == "output"
            if iface.signal == "bundled" then
                if isOutput then bw = bw + 1 else br = br + 1 end
            elseif entry.color ~= nil then
                -- binary 通道接口(形状非法导致 color 缺失的已在步骤 2 报错, 跳过)
                if isOutput then
                    cw = cw + 1
                    channelOutputs[entry.color] = (channelOutputs[entry.color] or 0) + 1
                else
                    cr = cr + 1
                    channelInputs[entry.color] = (channelInputs[entry.color] or 0) + 1
                end
            end
        end
        if bw > 1 then
            table.insert(errors, ("side '%s' has %d bundled output interfaces (bundled output takes the entire cable, at most one per side)"):format(side, bw))
        elseif bw == 1 then
            if br + cw + cr > 0 then
                table.insert(errors, ("side '%s' bundled output takes the entire cable and cannot coexist with other bundled interfaces (including binary channels) on the same side"):format(side))
            end
        elseif br > 0 then
            if cw > 0 then
                table.insert(errors, ("side '%s' has bundled input (reads entire cable) and channel output, would read back own output; bundled domain on this side must be input-only"):format(side))
            end
        else
            -- 纯 binary 通道接口: 按颜色通道检查
            for color, count in pairs(channelOutputs) do
                if count > 1 then
                    table.insert(errors, ("side '%s' colour channel %s has %d output interfaces (at most one output per colour channel)"):format(side, tostring(color), count))
                end
                if channelInputs[color] then
                    table.insert(errors, ("side '%s' colour channel %s direction conflict: input+output mixed causes feedback (must be all input or exactly one output)"):format(side, tostring(color)))
                end
            end
        end
    end

    if #errors == 0 then
        return nil
    end
    return errors
end

--- 按绑定实例化设备: 校验失败会报错退出, 成功返回设备对象。
---@param self SimplePeripheralSchema
---@param bindings Bindings
---@return SimplePeripheralDevice
function SimplePeripheralSchema:attach(bindings)
    local errors = self:validate(bindings)
    if errors then
        fail("binding validation failed:\n  - %s", table.concat(errors, "\n  - "))
    end

    local device = {
        name = self.name,
        schema = self,
        sides = {},
        colors = {},
        wrapped = {},
        relays = {},
        relaySides = {},
    }
    for _, iface in ipairs(self.interfaces) do
        local binding = bindings[iface.name]
        if isRelayBinding(binding) then
            -- relay 绑定: 记录 relay 外设、relay 上的面、以及颜色(如有)
            device.sides[iface.name] = binding.side
            device.relays[iface.name] = peripheral.wrap(binding.relay)
            device.relaySides[iface.name] = binding.side
            if binding.color ~= nil then
                device.colors[iface.name] = binding.color
            end
        elseif iface.kind == "redstone" and iface.signal == "binary" and type(binding) == "table" then
            -- binary 通道接口(本地 bundled 电缆): { side = ..., color = ... }
            device.sides[iface.name] = binding.side
            device.colors[iface.name] = binding.color
        else
            device.sides[iface.name] = binding
            if iface.kind == "peripheral" then
                device.wrapped[iface.name] = peripheral.wrap(binding)
            end
        end
    end
    return setmetatable(device, SimplePeripheralDevice)
end

-- ===== 设备访问 =====

--- 获取接口对应的红石 API 源和 side: relay 绑定返回 relay wrapped 对象, 否则返回全局 redstone。
---@param device SimplePeripheralDevice
---@param name string 接口名
---@return table rs redstone API 源(global redstone 或 relay wrapped 对象)
---@return Side side 操作的面
local function getRedstoneSource(device, name)
    local relay = device.relays[name]
    if relay then
        return relay, device.relaySides[name]
    end
    return redstone, device.sides[name]
end

--- 返回某接口绑定的 side 或外设地址(peripheral 接口可返回 wired modem 上的外设名)。
---@param self SimplePeripheralDevice
---@param name string 接口名
---@return Side|string
function SimplePeripheralDevice:getSide(name)
    local side = self.sides[name]
    if side == nil then
        fail("unknown interface name '%s'", tostring(name))
    end
    return side
end

--- 返回外设接口的 wrapped 外设(仅 kind == "peripheral" 的接口)。
---@param self SimplePeripheralDevice
---@param name string 接口名
---@return Peripheral
function SimplePeripheralDevice:getPeripheral(name)
    local iface = self.schema._byName[name]
    if iface == nil then
        fail("unknown interface name '%s'", tostring(name))
    end
    if iface.kind ~= "peripheral" then
        fail("interface '%s' is not a peripheral interface, use getInput/setOutput or bundled raw APIs instead", name)
    end
    return self.wrapped[name]
end

--- 读取输入型 binary/analogue 接口的信号: binary 返回 boolean(真实红石或 bundled 通道),
--- analogue 返回 0-15 的 number。bundled 接口请用 getBundledInput/testBundledInput。
---@param self SimplePeripheralDevice
---@param name string 接口名
---@return boolean|number
function SimplePeripheralDevice:getInput(name)
    local iface = self.schema._byName[name]
    if iface == nil then
        fail("unknown interface name '%s'", tostring(name))
    end
    if iface.kind ~= "redstone" then
        fail("interface '%s' is not a redstone interface, use getPeripheral instead", name)
    end
    if iface.signal == "bundled" then
        fail("bundled interface '%s', use getBundledInput/testBundledInput to control the entire cable", name)
    end
    if iface.direction ~= "input" then
        fail("interface '%s' is an output interface, cannot call getInput", name)
    end
    local side = self.sides[name]
    local rs = self.relays[name] or redstone
    if iface.signal == "binary" then
        local color = self.colors[name]
        if color then
            return rs.testBundledInput(side, color)
        end
        return rs.getInput(side)
    end
    return rs.getAnalogueInput(side)
end

--- 写入输出型 binary/analogue 接口的信号: binary 传 boolean(真实红石或 bundled 通道, 通道走读改写),
--- analogue 传 0-15 的 number(自动截断到该范围)。bundled 接口请用 setBundledOutput。
---@param self SimplePeripheralDevice
---@param name string 接口名
---@param value boolean|number 信号值
function SimplePeripheralDevice:setOutput(name, value)
    local iface = self.schema._byName[name]
    if iface == nil then
        fail("unknown interface name '%s'", tostring(name))
    end
    if iface.kind ~= "redstone" then
        fail("interface '%s' is not a redstone interface", name)
    end
    if iface.signal == "bundled" then
        fail("bundled interface '%s', use setBundledOutput to control the entire cable", name)
    end
    if iface.direction ~= "output" then
        fail("interface '%s' is an input interface, cannot call setOutput", name)
    end
    local side = self.sides[name]
    local rs = self.relays[name] or redstone
    if iface.signal == "binary" then
        local color = self.colors[name]
        if color then
            setBundledChannel(self, name, color, value and true or false)
        else
            rs.setOutput(side, value and true or false)
        end
    else -- analogue
        if type(value) ~= "number" then
            fail("analogue output interface '%s' requires a value of 0-15, got %s", name, tostring(value))
        end
        local v = math.floor(value)
        if v < 0 then v = 0 elseif v > 15 then v = 15 end
        rs.setAnalogueOutput(side, v)
    end
end

--- 校验 name 是否为指定方向的 bundled 接口; 失败时返回 nil 和错误信息。
---@param device SimplePeripheralDevice
---@param name string
---@param methodName string 调用方方法名(用于报错)
---@param requiredDirection RedstoneDirection 要求的方向
---@return RedstoneInterfaceSpec? iface 接口定义
---@return string? errorMsg 错误信息(iface 为 nil 时非 nil)
local function checkBundled(device, name, methodName, requiredDirection)
    local iface = device.schema._byName[name]
    if iface == nil then
        return nil, ("unknown interface name '%s'"):format(tostring(name))
    end
    if iface.kind ~= "redstone" then
        return nil, ("interface '%s' is not a redstone interface"):format(name)
    end
    if iface.signal ~= "bundled" then
        return nil, ("interface '%s' is not a bundled interface (use getInput/setOutput)"):format(name)
    end
    if iface.direction ~= requiredDirection then
        local dirWord = requiredDirection == "input" and "output" or "input"
        return nil, ("interface '%s' is an %s interface, cannot call %s"):format(name, dirWord, methodName)
    end
    return iface, nil
end

--- 读取 bundled 输入接口的整根电缆输入掩码(仅 bundled 输入接口)。
---@param self SimplePeripheralDevice
---@param name string 接口名
---@return ColourMask 16 位输入掩码
function SimplePeripheralDevice:getBundledInput(name)
    local iface, msg = checkBundled(self, name, "getBundledInput", "input")
    if iface == nil then
        fail("%s", msg)
    end
    local rs, side = getRedstoneSource(self, name)
    return rs.getBundledInput(side)
end

--- 判断 bundled 输入接口的某个(些)颜色通道是否全为开(仅 bundled 输入接口)。
---@param self SimplePeripheralDevice
---@param name string 接口名
---@param mask ColourMask 要测试的颜色位掩码(可用 colours.combine 组合多个颜色)
---@return boolean
function SimplePeripheralDevice:testBundledInput(name, mask)
    local iface, msg = checkBundled(self, name, "testBundledInput", "input")
    if iface == nil then
        fail("%s", msg)
    end
    local rs, side = getRedstoneSource(self, name)
    return rs.testBundledInput(side, mask)
end

--- 读取 bundled 输出接口当前写出的掩码(仅 bundled 输出接口)。
---@param self SimplePeripheralDevice
---@param name string 接口名
---@return ColourMask 当前输出掩码
function SimplePeripheralDevice:getBundledOutput(name)
    local iface, msg = checkBundled(self, name, "getBundledOutput", "output")
    if iface == nil then
        fail("%s", msg)
    end
    local rs, side = getRedstoneSource(self, name)
    return rs.getBundledOutput(side)
end

--- 写入 bundled 输出接口的整根电缆掩码, 覆盖全部 16 个通道(仅 bundled 输出接口)。
---@param self SimplePeripheralDevice
---@param name string 接口名
---@param mask? ColourMask 要写出的位掩码, 缺省或 0 表示全部关闭
function SimplePeripheralDevice:setBundledOutput(name, mask)
    local iface, msg = checkBundled(self, name, "setBundledOutput", "output")
    if iface == nil then
        fail("%s", msg)
    end
    local rs, side = getRedstoneSource(self, name)
    rs.setBundledOutput(side, mask or 0)
end

return simplePeripheral
