---@diagnostic disable
---@class LinkModule
---@field packFrame fun(dst_mac: number, src_mac: number, etype: number, data: number[]): number[]
---@field unpackFrame fun(frame: number[]): number, number, number, number[]
---@field open fun(side: string, channel: number): LinkInterface

local util = require('lib/util')
local simpleParallel = require('lib/simpleParallel')
---@type LinkModule
local link = {}

---@param dst_mac number
---@param src_mac number
---@param etype number
---@param data number[]
---@return number[]
function link.packFrame(dst_mac, src_mac, etype, data)
    local frame = {}
    local dst_bytes = util.packInt(dst_mac, 6)
    local src_bytes = util.packInt(src_mac, 6)
    local etype_bytes = util.packInt(etype, 2)

    for i = 1, 6 do
        frame[i] = dst_bytes[i]
        frame[i + 6] = src_bytes[i]
    end

    for i = 1, 2 do
        frame[i + 12] = etype_bytes[i]
    end

    for i = 1, #data do
        frame[i + 14] = data[i]
    end

    return frame
end

---@param frame number[]
---@return number, number, number, number[]
function link.unpackFrame(frame)
    local dst_bytes = {}
    local src_bytes = {}
    local etype_bytes = {}
    local data = {}

    for i = 1, 6 do
        dst_bytes[i] = frame[i]
        src_bytes[i] = frame[i + 6]
    end

    for i = 1, 2 do
        etype_bytes[i] = frame[i + 12]
    end

    for i = 15, #frame do
        data[#data + 1] = frame[i]
    end

    local dst_mac = util.unpackInt(dst_bytes)
    local src_mac = util.unpackInt(src_bytes)
    local etype = util.unpackInt(etype_bytes)

    return dst_mac, src_mac, etype, data
end

---@class LinkInterface
---@field send fun(self: LinkInterface, dst_mac: number, etype: number, data: number[]): void
---@field recv fun(self: LinkInterface): number, number, number, number[] | nil

---@param side string
---@param channel number
---@return LinkInterface
function link.open(side, channel)
    local modem = peripheral.wrap(side)
    ---@type LinkInterface
    local iface = {}
    modem.open(channel)
    function iface:send(dst_mac, etype, data)
        local frame = link.packFrame(dst_mac, os.getComputerID(), etype, data)
        modem.transmit(channel, channel, frame)
    end
    function iface.recv()
        local event, modemSide, senderChannel, replyChannel, message, distance = os.pullEvent("modem_message")
        if modemSide == side and senderChannel == channel then
            return link.unpackFrame(message)
        end
    end
    simpleParallel.add(function()
        while true do
            local dst_mac, src_mac, etype, data = iface.recv()
            if dst_mac == os.getComputerID() or dst_mac == 0xFFFFFFFFFFFF then
                os.queueEvent("mac_frame", dst_mac, src_mac, etype, data)
            end
        end
    end)
    return iface
end

return link
