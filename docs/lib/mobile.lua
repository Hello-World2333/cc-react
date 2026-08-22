---@diagnostic disable
--- mobile.lua — 移动数据层（基站切换）
---
--- 位于 Link 和 IP 之间，对上层透明。
--- 设备通过 beacon 扫描发现基站，选择信号最强的注册，切换时 IP 不变。
---
--- 依赖：link.lua, util.lua, simpleParallel.lua
--- 无外部协议依赖：IP/TCP/UDP/HTTP 均不感知本层的存在。
---
--- 与 IP 层共享同一 Modem：通过 ethertype 区分帧。
--- Mobile 层只处理 0x88B5，IP 层只处理 0x0800/0x0806。
--- link.lua 在 open() 时注册的 mac_frame 转发任务不影响 Mobile/IP 的收包。
--- CC 的 os.pullEvent 将事件广播给所有消费者，因此 Mobile 和 IP 的 recv 循环
--- 可以并行运行，互不干扰。

local link = require('lib/link')
local util = require('lib/util')
local simpleParallel = require('lib/simpleParallel')
local Mobile = {}

-- ============================================================
-- 常量
-- ============================================================

Mobile.ETHERTYPE = 0x88B5 -- 自定义 ethertype（IEEE 局部实验用，Mobile Management）

-- 帧类型
Mobile.FRAME_BEACON     = 0x01
Mobile.FRAME_ASSOC_REQ  = 0x10
Mobile.FRAME_ASSOC_RESP = 0x11
Mobile.FRAME_DISASSOC   = 0x12

-- 协议版本
Mobile.VERSION = 1

-- 广播 MAC（与 link.lua 一致）
local BROADCAST_MAC = 0xFFFFFFFFFFFF

-- ============================================================
-- 底层收发：直接操作 modem，获取 distance 信息
-- ============================================================
-- link.lua 的 iface.recv() 不返回 distance（只返回 dst/src/etype/data），
-- 而 Mobile 层需要 distance 做信号强度判断。因此 Mobile 层绕过 link 的
-- recv 函数，直接调用 modem API。发送仍复用 link.packFrame + modem.transmit。

--- 创建一个 Mobile 专用的底层收发接口。
--- @param side string modem 所在 side
--- @param channel number 使用的 channel
--- @return table mobileIface { send, recvRaw }
local function openMobileIface(side, channel)
    local modem = peripheral.wrap(side)
    modem.open(channel)

    local iface = {}

    --- 发送帧（复用 link.packFrame 格式）。
    --- @param dst_mac number
    --- @param etype number
    --- @param data number[]
    function iface:send(dst_mac, etype, data)
        local frame = link.packFrame(dst_mac, os.getComputerID(), etype, data)
        modem.transmit(channel, channel, frame)
    end

    --- 接收帧，返回 dst_mac, src_mac, etype, data, distance。
    --- 直接从 modem_message 事件中提取 distance。
    --- @return number|nil dst_mac
    --- @return number|nil src_mac
    --- @return number|nil etype
    --- @return number[] data
    --- @return number distance 信号距离（默认 0）
    function iface:recvRaw()
        while true do
            local event, modemSide, senderChannel, replyChannel, message, distance =
                os.pullEvent("modem_message")
            if modemSide == side and senderChannel == channel then
                local dst_mac, src_mac, etype, data = link.unpackFrame(message)
                return dst_mac, src_mac, etype, data, distance or 0
            end
        end
    end

    return iface
end

-- ============================================================
-- 帧打包/解包
-- ============================================================

--- 将帧类型 + payload 打包为链路层 payload（ethertype 之后的部分）。
---@param frameType number
---@param payload number[]
---@return number[]
function Mobile.packFrame(frameType, payload)
    local b = { Mobile.VERSION, frameType }
    for i = 1, #payload do
        b[#b + 1] = payload[i]
    end
    return b
end

--- 解析链路层 payload，返回版本、帧类型、剩余数据。
---@param data number[]
---@return number|nil version
---@return number|nil frameType
---@return number[] payload
function Mobile.unpackFrame(data)
    if #data < 2 then
        return nil, nil, {}
    end
    local version = data[1]
    local frameType = data[2]
    local payload = {}
    for i = 3, #data do
        payload[#payload + 1] = data[i]
    end
    return version, frameType, payload
end

--- 打包字符串字段：[2B 长度][NB 内容]。
---@param str string
---@return number[]
local function packString(str)
    local bytes = util.stringToBytes(str)
    local lenBytes = util.packInt(#bytes, 2)
    local result = {}
    for i = 1, 2 do
        result[#result + 1] = lenBytes[i]
    end
    for i = 1, #bytes do
        result[#result + 1] = bytes[i]
    end
    return result
end

--- 解包字符串字段，返回字符串和消耗的字节数。
---@param data number[]
---@param offset number 起始位置（1-based）
---@return string str
---@return number consumed 消耗的字节数（含2B长度头）
local function unpackString(data, offset)
    if offset + 1 > #data then
        return "", 0
    end
    local len = data[offset] * 256 + (data[offset + 1] or 0)
    local start = offset + 2
    local chars = {}
    for i = 0, len - 1 do
        if start + i <= #data then
            chars[#chars + 1] = string.char(data[start + i])
        end
    end
    return table.concat(chars), 2 + len
end

-- ============================================================
-- Beacon 帧：[4B bsId][字符串 bsName][2B load]
-- （外层 Mobile.packFrame 会加上 [1B 版本][1B 类型]）
-- ============================================================

---@param bsId number
---@param bsName string
---@param load number 当前服务设备数
---@return number[]
function Mobile.packBeacon(bsId, bsName, load)
    local payload = {}
    for _, b in ipairs(util.packInt(bsId, 4)) do
        payload[#payload + 1] = b
    end
    for _, b in ipairs(packString(bsName)) do
        payload[#payload + 1] = b
    end
    for _, b in ipairs(util.packInt(load, 2)) do
        payload[#payload + 1] = b
    end
    return Mobile.packFrame(Mobile.FRAME_BEACON, payload)
end

---@param payload number[]
---@return number bsId
---@return string bsName
---@return number load
function Mobile.unpackBeacon(payload)
    local bsId = util.unpackInt({ payload[1], payload[2], payload[3], payload[4] })
    local bsName, consumed = unpackString(payload, 5)
    local loadOffset = 5 + consumed
    local load = 0
    if loadOffset + 1 <= #payload then
        load = payload[loadOffset] * 256 + (payload[loadOffset + 1] or 0)
    end
    return bsId, bsName, load
end

-- ============================================================
-- Association Request：[4B deviceId][字符串 deviceName]
-- ============================================================

---@param deviceId number
---@param deviceName string
---@return number[]
function Mobile.packAssocReq(deviceId, deviceName)
    local payload = {}
    for _, b in ipairs(util.packInt(deviceId, 4)) do
        payload[#payload + 1] = b
    end
    for _, b in ipairs(packString(deviceName)) do
        payload[#payload + 1] = b
    end
    return Mobile.packFrame(Mobile.FRAME_ASSOC_REQ, payload)
end

---@param payload number[]
---@return number deviceId
---@return string deviceName
function Mobile.unpackAssocReq(payload)
    local deviceId = util.unpackInt({ payload[1], payload[2], payload[3], payload[4] })
    local deviceName = unpackString(payload, 5)
    return deviceId, deviceName
end

-- ============================================================
-- Association Response：[1B status][4B bsId]
-- status: 0=接受, 1=拒绝
-- ============================================================

---@param status number
---@param bsId number
---@return number[]
function Mobile.packAssocResp(status, bsId)
    local payload = { status }
    for _, b in ipairs(util.packInt(bsId, 4)) do
        payload[#payload + 1] = b
    end
    return Mobile.packFrame(Mobile.FRAME_ASSOC_RESP, payload)
end

---@param payload number[]
---@return number status
---@return number bsId
function Mobile.unpackAssocResp(payload)
    local status = payload[1] or 1
    local bsId = util.unpackInt({ payload[2], payload[3], payload[4], payload[5] })
    return status, bsId
end

-- ============================================================
-- Disassociation：[4B deviceId]
-- ============================================================

---@param deviceId number
---@return number[]
function Mobile.packDisassoc(deviceId)
    local payload = {}
    for _, b in ipairs(util.packInt(deviceId, 4)) do
        payload[#payload + 1] = b
    end
    return Mobile.packFrame(Mobile.FRAME_DISASSOC, payload)
end

---@param payload number[]
---@return number deviceId
function Mobile.unpackDisassoc(payload)
    return util.unpackInt({ payload[1], payload[2], payload[3], payload[4] })
end

-- ============================================================
-- BaseStation（基站侧）
-- ============================================================

---@class BaseStationConfig
---@field side string 无线Modem所在side
---@field channel number 共享channel
---@field bsId number|nil nil=os.getComputerID()
---@field bsName string 基站名称
---@field beaconInterval number beacon广播间隔（秒）

---@class BaseStationDevice
---@field id number 设备电脑ID
---@field name string 设备名称
---@field lastSeen number os.clock() 上次收到注册/心跳的时间

---@class BaseStation
---@field id number
---@field name string
---@field devices table<number, BaseStationDevice>
---@field onAssoc (fun(device: BaseStationDevice): void)|nil
---@field onDissoc (fun(device: BaseStationDevice): void)|nil
---@field getDevices fun(self: BaseStation): BaseStationDevice[]
---@field getRawInterface fun(self: BaseStation): table
---@field getDeviceIds fun(self: BaseStation): number[]
---@field isDeviceRegistered fun(self: BaseStation, deviceId: number): boolean

---@param config BaseStationConfig
---@return BaseStation
function Mobile.newBaseStation(config)
    config = config or {}
    local side = config.side or "back"
    local channel = config.channel or 1
    local bsId = config.bsId or os.getComputerID()
    local bsName = config.bsName or ("BS-" .. tostring(bsId))
    local beaconInterval = config.beaconInterval or 2

    local iface = openMobileIface(side, channel)

    ---@type BaseStation
    local bs = {}
    bs.id = bsId
    bs.name = bsName
    bs.devices = {} -- deviceId -> BaseStationDevice

    ---@type (fun(device: BaseStationDevice): void)|nil
    bs.onAssoc = nil
    ---@type (fun(device: BaseStationDevice): void)|nil
    bs.onDissoc = nil

    --- 获取当前服务的设备列表。
    ---@return BaseStationDevice[]
    function bs:getDevices()
        local list = {}
        for _, d in pairs(self.devices) do
            list[#list + 1] = d
        end
        return list
    end

    --- 返回底层接口（用于 IP 层共享 Modem）。
    ---@return table
    function bs:getRawInterface()
        return iface
    end

    --- 获取设备 ID 列表。
    ---@return number[]
    function bs:getDeviceIds()
        local ids = {}
        for id in pairs(self.devices) do
            ids[#ids + 1] = id
        end
        return ids
    end

    --- 检查设备是否已注册。
    ---@param deviceId number
    ---@return boolean
    function bs:isDeviceRegistered(deviceId)
        return self.devices[deviceId] ~= nil
    end

    -- ---- 内部：帧处理 ----

    local function handleAssocReq(srcMac, payload)
        local deviceId, deviceName = Mobile.unpackAssocReq(payload)
        local device = bs.devices[deviceId]
        if not device then
            device = {
                id = deviceId,
                name = deviceName,
                lastSeen = os.clock(),
            }
            bs.devices[deviceId] = device
            if bs.onAssoc then
                bs.onAssoc(device)
            end
        else
            device.name = deviceName
            device.lastSeen = os.clock()
        end
        local resp = Mobile.packAssocResp(0, bsId)
        iface:send(srcMac, Mobile.ETHERTYPE, resp)
    end

    local function handleDisassoc(payload)
        local deviceId = Mobile.unpackDisassoc(payload)
        local device = bs.devices[deviceId]
        if device then
            bs.devices[deviceId] = nil
            if bs.onDissoc then
                bs.onDissoc(device)
            end
        end
    end

    -- ---- 任务 1：广播 beacon ----
    simpleParallel.add(function()
        while true do
            local load = 0
            for _ in pairs(bs.devices) do
                load = load + 1
            end
            local beacon = Mobile.packBeacon(bsId, bsName, load)
            iface:send(BROADCAST_MAC, Mobile.ETHERTYPE, beacon)
            sleep(beaconInterval)
        end
    end)

    -- ---- 任务 2：接收帧（过滤 Mobile.ETHERTYPE） ----
    simpleParallel.add(function()
        while true do
            local dstMac, srcMac, etype, data = iface:recvRaw()
            if etype == Mobile.ETHERTYPE then
                local version, frameType, payload = Mobile.unpackFrame(data)
                if version == Mobile.VERSION then
                    if frameType == Mobile.FRAME_ASSOC_REQ then
                        handleAssocReq(srcMac, payload)
                    elseif frameType == Mobile.FRAME_DISASSOC then
                        handleDisassoc(payload)
                    end
                end
            end
        end
    end)

    -- ---- 任务 3：设备超时清理（每 30 秒） ----
    simpleParallel.add(function()
        while true do
            sleep(30)
            local now = os.clock()
            for id, device in pairs(bs.devices) do
                if now - device.lastSeen > 60 then
                    bs.devices[id] = nil
                    if bs.onDissoc then
                        bs.onDissoc(device)
                    end
                end
            end
        end
    end)

    return bs
end

-- ============================================================
-- MobileClient（设备侧）
-- ============================================================

---@class MobileClientConfig
---@field side string 无线Modem所在side
---@field channel number 共享channel
---@field scanInterval number 扫描间隔（秒）
---@field switchThreshold number 信号差阈值：新基站需比当前强多少才切换
---@field deviceName string 设备名称
---@field bsWhitelist number[]|nil 白名单：只认这些基站ID（nil=接受所有）

---@class StationInfo
---@field id number 基站ID
---@field name string 基站名称
---@field distance number 信号距离（越小越强）
---@field load number 基站当前负载
---@field lastBeard number 上次收到beacon的时间

---@class MobileClient
---@field stations table<number, StationInfo> 已知基站
---@field serving StationInfo|nil 当前服务基站
---@field onAssoc (fun(bs: StationInfo): void)|nil
---@field onDissoc (fun(): void)|nil
---@field onSwitch (fun(oldBs: StationInfo, newBs: StationInfo): void)|nil
---@field getServingBS fun(self: MobileClient): StationInfo|nil
---@field getStations fun(self: MobileClient): StationInfo[]
---@field getInterface fun(self: MobileClient, config: table): table
---@field forceScan fun(self: MobileClient): void
---@field forceSwitch fun(self: MobileClient, bsId: number): void

---@param config MobileClientConfig
---@return MobileClient
function Mobile.newClient(config)
    config = config or {}
    local side = config.side or "back"
    local channel = config.channel or 1
    local scanInterval = config.scanInterval or 5
    local switchThreshold = config.switchThreshold or 0.5
    local deviceName = config.deviceName or ("device-" .. tostring(os.getComputerID()))
    local bsWhitelist = config.bsWhitelist

    local iface = openMobileIface(side, channel)
    local deviceId = os.getComputerID()

    ---@type MobileClient
    local client = {}
    client.stations = {} -- bsId -> StationInfo
    client.serving = nil

    ---@type (fun(bs: StationInfo): void)|nil
    client.onAssoc = nil
    ---@type (fun(): void)|nil
    client.onDissoc = nil
    ---@type (fun(oldBs: StationInfo, newBs: StationInfo): void)|nil
    client.onSwitch = nil

    --- 获取当前服务基站。
    ---@return StationInfo|nil
    function client:getServingBS()
        return self.serving
    end

    --- 获取所有已知基站。
    ---@return StationInfo[]
    function client:getStations()
        local list = {}
        for _, s in pairs(self.stations) do
            list[#list + 1] = s
        end
        return list
    end

    --- 主动触发一次扫描。
    function client:forceScan()
        os.queueEvent("mobile_force_scan")
    end

    --- 强制切换到指定基站。
    ---@param bsId number
    function client:forceSwitch(bsId)
        local bs = self.stations[bsId]
        if not bs then
            return
        end
        local old = self.serving
        -- 向新基站发送注册请求
        local req = Mobile.packAssocReq(deviceId, deviceName)
        iface:send(util.packInt(bsId, 6), Mobile.ETHERTYPE, req)
        sleep(0.1) -- 等待响应
        -- 向旧基站发送注销
        if old and old.id ~= bsId then
            local dis = Mobile.packDisassoc(deviceId)
            iface:send(util.packInt(old.id, 6), Mobile.ETHERTYPE, dis)
        end
        self.serving = bs
        if old and old.id ~= bsId and self.onSwitch then
            self.onSwitch(old, bs)
        elseif not old and self.onAssoc then
            self.onAssoc(bs)
        end
    end

    --- 获取 IP 层接口配置。
    --- 返回标准 InterfaceConfig 描述，IP 层通过 link.open 共享同一 Modem。
    --- CC 允许对同一 channel 多次 open（引用计数），因此 IP 层可以安全地
    --- 再调用 link.open(side, channel)。两个 LinkInterface 的 recv 循环
    --- 并行运行，通过 ethertype 过滤各自需要的帧。
    ---@param ipConfig table { ip: string|number, mask: string|number, gateway: string|number|nil }
    ---@return table interfaceConfig 传给 IP.new 的接口配置
    function client:getInterface(ipConfig)
        return {
            side = side,
            channel = channel,
            ip = ipConfig.ip,
            mask = ipConfig.mask,
            gateway = ipConfig.gateway,
        }
    end

    -- ---- 内部状态 ----

    ---@type StationInfo|nil
    local pendingAssoc = nil
    local assocTimeout = 2

    --- 处理收到的 beacon。
    ---@param distance number
    ---@param payload number[]
    local function handleBeacon(distance, payload)
        local bsId, bsName, bsLoad = Mobile.unpackBeacon(payload)

        -- 过滤自身发出的 beacon
        if bsId == deviceId then
            return
        end

        -- 白名单过滤
        if bsWhitelist then
            local allowed = false
            for _, id in ipairs(bsWhitelist) do
                if id == bsId then
                    allowed = true
                    break
                end
            end
            if not allowed then
                return
            end
        end

        client.stations[bsId] = {
            id = bsId,
            name = bsName,
            distance = distance,
            load = bsLoad,
            lastBeard = os.clock(),
        }
    end

    --- 处理收到的注册响应。
    ---@param payload number[]
    local function handleAssocResp(payload)
        local status, bsId = Mobile.unpackAssocResp(payload)
        if status == 0 then
            local bs = client.stations[bsId]
            if bs then
                local old = client.serving
                client.serving = bs
                pendingAssoc = nil
                if old and old.id ~= bsId then
                    if client.onSwitch then
                        client.onSwitch(old, bs)
                    end
                elseif not old then
                    if client.onAssoc then
                        client.onAssoc(bs)
                    end
                end
            end
        else
            pendingAssoc = nil
        end
    end

    --- 选择最优基站（距离最小）。
    ---@return StationInfo|nil
    local function selectBestStation()
        local best = nil
        for _, s in pairs(client.stations) do
            if not best or s.distance < best.distance then
                best = s
            end
        end
        return best
    end

    --- 向基站发送注册请求。
    ---@param bs StationInfo
    local function sendAssocReq(bs)
        local req = Mobile.packAssocReq(deviceId, deviceName)
        iface:send(util.packInt(bs.id, 6), Mobile.ETHERTYPE, req)
        pendingAssoc = bs
    end

    --- 向当前服务基站发送注销。
    local function sendDisassoc()
        if client.serving then
            local dis = Mobile.packDisassoc(deviceId)
            iface:send(util.packInt(client.serving.id, 6), Mobile.ETHERTYPE, dis)
        end
    end

    -- ---- 任务 1：接收帧（过滤 Mobile.ETHERTYPE） ----
    simpleParallel.add(function()
        while true do
            local dstMac, srcMac, etype, data, distance = iface:recvRaw()
            if etype == Mobile.ETHERTYPE then
                local version, frameType, payload = Mobile.unpackFrame(data)
                if version == Mobile.VERSION then
                    if frameType == Mobile.FRAME_BEACON then
                        handleBeacon(distance, payload)
                    elseif frameType == Mobile.FRAME_ASSOC_RESP then
                        handleAssocResp(payload)
                    end
                end
            end
        end
    end)

    -- ---- 任务 2：周期性扫描 + 切换判断 ----
    simpleParallel.add(function()
        while true do
            local timerId = os.startTimer(scanInterval)
            while true do
                local event, param1 = os.pullEvent()
                if event == "timer" and param1 == timerId then
                    break
                elseif event == "mobile_force_scan" then
                    break
                end
            end

            -- 清理超时基站（30 秒未收到 beacon）
            local now = os.clock()
            for id, s in pairs(client.stations) do
                if now - s.lastBeard > 30 then
                    client.stations[id] = nil
                end
            end

            -- 选择最优基站
            local best = selectBestStation()
            if not best then
                -- 没有可见基站，如果当前有服务基站则断开
                if client.serving then
                    sendDisassoc()
                    client.serving = nil
                    if client.onDissoc then
                        client.onDissoc()
                    end
                end
            elseif not client.serving then
                -- 有基站但未注册，发起注册
                sendAssocReq(best)
            elseif best.id ~= client.serving.id then
                -- 发现更强的基站，判断是否切换
                local diff = client.serving.distance - best.distance
                if diff > switchThreshold then
                    sendAssocReq(best)
                end
            else
                -- 已在最优基站，刷新信息
                client.serving.distance = best.distance
                client.serving.load = best.load
                client.serving.lastBeard = now
            end
        end
    end)

    -- ---- 任务 3：注册响应等待超时 ----
    simpleParallel.add(function()
        while true do
            sleep(assocTimeout)
            if pendingAssoc then
                pendingAssoc = nil
            end
        end
    end)

    return client
end

return Mobile
