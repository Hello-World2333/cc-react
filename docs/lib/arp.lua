---@diagnostic disable
---@class ARPModule
---@field lookup fun(self: ARPModule, ip: number, timeout: number | nil): number | nil  -- IP -> MAC
---@field update fun(self: ARPModule, ip: number, mac: number): void
---@field getCache fun(self: ARPModule, ip: number): number | nil
---@field cache table<number, ARPEntry>  -- IP -> { MAC, time }
---@field cacheTTL number

---@class ARPEntry
---@field [1] number MAC
---@field [2] number time (os.clock)

---@class HostConfig
---@field ip number | string

local link = require('lib/link')
local util = require('lib/util')
local simpleParallel = require('lib/simpleParallel')
local ARP = {}

---@param op number
---@param sender_mac number
---@param sender_ip number
---@param target_mac number
---@param target_ip number
---@return number[]
function ARP.packFrame(op, sender_mac, sender_ip, target_mac, target_ip)
    local frame = {}
    local op_bytes = util.packInt(op, 2)
    local sender_mac_bytes = util.packInt(sender_mac, 6)
    local sender_ip_bytes = util.packInt(sender_ip, 4)
    local target_mac_bytes = util.packInt(target_mac, 6)
    local target_ip_bytes = util.packInt(target_ip, 4)

    for i = 1, 2 do
        frame[i] = op_bytes[i]
    end

    for i = 1, 6 do
        frame[i + 2] = sender_mac_bytes[i]
        frame[i + 12] = target_mac_bytes[i]
    end

    for i = 1, 4 do
        frame[i + 8] = sender_ip_bytes[i]
        frame[i + 18] = target_ip_bytes[i]
    end

    return frame
end

---@param frame number[]
---@return number, number, number, number, number 
function ARP.unpackFrame(frame)
    local op_bytes = {frame[1], frame[2]}
    local sender_mac_bytes = {frame[3], frame[4], frame[5], frame[6], frame[7], frame[8]}
    local sender_ip_bytes = {frame[9], frame[10], frame[11], frame[12]}
    local target_mac_bytes = {frame[13], frame[14], frame[15], frame[16], frame[17], frame[18]}
    local target_ip_bytes = {frame[19], frame[20], frame[21], frame[22]}

    local op = util.unpackInt(op_bytes)
    local sender_mac = util.unpackInt(sender_mac_bytes)
    local sender_ip = util.unpackInt(sender_ip_bytes)
    local target_mac = util.unpackInt(target_mac_bytes)
    local target_ip = util.unpackInt(target_ip_bytes)

    return op, sender_mac, sender_ip, target_mac, target_ip
end

---@param config HostConfig
---@param iface LinkInterface
---@return ARPModule
function ARP.new(config, iface)
    ---@type ARPModule
    local arp = {}
    arp.cache = {}
    arp.cacheTTL = 60
    function arp:update(ip, mac)
        arp.cache[ip] = {mac, os.clock()}
    end
    function arp:getCache(ip)
        if arp.cache[ip] then
            if os.clock() - arp.cache[ip][2] > arp.cacheTTL then
                arp.cache[ip] = nil
                return nil
            end
            return arp.cache[ip][1]
        else
            return nil
        end
    end
    function arp:lookup(ip, timeout)
        if (arp:getCache(ip)) then
            return arp:getCache(ip)
        end
        timeout = timeout or 5
        iface:send(0xFFFFFFFFFFFF, 0x0806, ARP.packFrame(1, os.getComputerID(), config.ip, 0, ip))
        local startTime = os.clock()
        while true do
            if arp:getCache(ip) then
                return arp:getCache(ip)
            end
            if os.clock() - startTime > timeout then
                return nil
            end
            sleep(0)
        end
    end
    simpleParallel.add(function()
        while true do
            local dst_mac, src_mac, etype, data = iface.recv()
            if etype == 0x0806 then -- ARP
                local op, sender_mac, sender_ip, target_mac, target_ip = ARP.unpackFrame(data)
                if (op == 1) then -- ARP Request
                    if target_ip == config.ip then
                        iface:send(sender_mac, 0x0806,
                            ARP.packFrame(2, os.getComputerID(), config.ip, sender_mac, sender_ip))
                    end
                end
                if (op == 2) then -- ARP Reply
                    arp:update(sender_ip, sender_mac)
                end
            end
        end
    end)
    return arp
end

return ARP
