---@diagnostic disable
local util = require('lib/util')
local IP = require('lib/ip')
local simpleParallel = require('lib/simpleParallel')
local ICMP = {}

---@class ICMPReply
---@field [1] number dst_ip
---@field [2] number received at (os.clock)

---@class ICMPModule
---@field identifier number
---@field sequence number
---@field replies table<number, ICMPReply>  -- sequence -> { dst_ip, time }
---@field ping fun(self: ICMPModule, dst_ip: number, timeout: number | nil): boolean, number | nil

local ICMP_ECHO_REPLY = 0
local ICMP_ECHO_REQUEST = 8

---@param icmp_type number
---@param code number
---@param identifier number
---@param sequence number
---@param data number[]
---@return number[]
function ICMP.packPacket(icmp_type, code, identifier, sequence, data)
    local packet = {}
    local id_bytes = util.packInt(identifier, 2)
    local seq_bytes = util.packInt(sequence, 2)

    packet[1] = icmp_type
    packet[2] = code
    packet[3] = 0x00 -- checksum placeholder
    packet[4] = 0x00
    packet[5] = id_bytes[1]
    packet[6] = id_bytes[2]
    packet[7] = seq_bytes[1]
    packet[8] = seq_bytes[2]

    for i = 1, #data do
        packet[i + 8] = data[i]
    end

    local checksum_bytes = util.packInt(IP.checksum(packet), 2)
    packet[3] = checksum_bytes[1]
    packet[4] = checksum_bytes[2]

    return packet
end

---@param packet number[]
---@return number, number, number, number, number[]
function ICMP.unpackPacket(packet)
    local icmp_type = packet[1]
    local code = packet[2]
    local identifier = util.unpackInt({packet[5], packet[6]})
    local sequence = util.unpackInt({packet[7], packet[8]})
    local data = {}
    for i = 9, #packet do
        data[#data + 1] = packet[i]
    end
    return icmp_type, code, identifier, sequence, data
end

---@param ip IPInterface
---@return ICMPModule
function ICMP.new(ip)
    ---@type ICMPModule
    local icmp = {}
    icmp.identifier = os.getComputerID() % 0x10000
    icmp.sequence = 0
    icmp.replies = {} -- sequence -> {dst_ip, time}

    function icmp:ping(dst_ip, timeout)
        timeout = timeout or 5
        icmp.sequence = icmp.sequence + 1
        local seq = icmp.sequence
        ip:send(dst_ip, 0x0001, ICMP.packPacket(ICMP_ECHO_REQUEST, 0, icmp.identifier, seq, util.stringToBytes('ping')))
        local startTime = os.clock()
        while true do
            if icmp.replies[seq] and icmp.replies[seq][1] == dst_ip then
                local latency = (icmp.replies[seq][2] - startTime) * 1000
                icmp.replies[seq] = nil
                return true, latency
            end
            if os.clock() - startTime > timeout then
                return false, nil
            end
            sleep(0)
        end
    end

    simpleParallel.add(function()
        while true do
            local src_ip, protocol, data = ip:recv()
            if protocol == 0x0001 then
                local icmp_type, code, identifier, sequence, payload = ICMP.unpackPacket(data)
                if icmp_type == ICMP_ECHO_REQUEST then
                    ip:send(src_ip, 0x0001, ICMP.packPacket(ICMP_ECHO_REPLY, 0, identifier, sequence, payload))
                elseif icmp_type == ICMP_ECHO_REPLY then
                    if identifier == icmp.identifier then
                        icmp.replies[sequence] = {src_ip, os.clock()}
                    end
                end
            end
        end
    end)

    return icmp
end

return ICMP
