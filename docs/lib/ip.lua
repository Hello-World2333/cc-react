---@diagnostic disable
local link = require('lib/link')
local util = require('lib/util')
local ARP = require('lib/arp')
local simpleParallel = require('lib/simpleParallel')
local IP = {}

IP.OSPF_PROTOCOL = 89
local BROADCAST_IP = 0xFFFFFFFF

---@class Route
---@field subnet number
---@field mask number
---@field next_hop number  0 = directly connected
---@field iface number interface index (1-based)
---@field cost number

---@class IPNetworkInterface
---@field iface LinkInterface
---@field ip number
---@field mask number
---@field gateway number | nil
---@field arp ARPModule | nil

---@class IPInterface
---@field send fun(self: IPInterface, dst_ip: number, protocol: number, data: number[]): void
---@field recv fun(self: IPInterface): number, number, number[] | nil
---@field getRoutes fun(self: IPInterface): Route[] | nil
---@field getNeighbors fun(self: IPInterface): table<number, OSPFNeighbor> | nil
---@field getLocalIp fun(self: IPInterface): number

---@class InterfaceConfig
---@field side string
---@field channel number
---@field ip number|string
---@field mask number|string
---@field gateway number|string

---@class IPConfig
---@field mode string -- "host" | "router"
---@field interfaces InterfaceConfig[]

---@param header number[]
---@return number
function IP.checksum(header)
    local sum = 0
    for i = 1, #header, 2 do
        local word = header[i] * 256 + (header[i + 1] or 0)
        sum = sum + word
    end
    while sum >= 0x10000 do
        sum = (sum % 0x10000) + math.floor(sum / 0x10000)
    end
    return 0xFFFF - sum
end

---@param src_ip number
---@param dst_ip number
---@param protocol number
---@param data number[]
---@return number[]
function IP.packPacket(src_ip, dst_ip, protocol, data)
    local header = {}
    local src_bytes = util.packInt(src_ip, 4)
    local dst_bytes = util.packInt(dst_ip, 4)
    local total_len_bytes = util.packInt(20 + #data, 2)

    header[1] = 0x45 -- version 4, IHL 5
    header[2] = 0x00 -- TOS
    header[3] = total_len_bytes[1]
    header[4] = total_len_bytes[2]
    header[5] = 0x00 -- identification
    header[6] = 0x00
    header[7] = 0x00 -- flags + fragment offset
    header[8] = 0x00
    header[9] = 64 -- TTL
    header[10] = protocol
    header[11] = 0x00 -- checksum placeholder
    header[12] = 0x00
    for i = 1, 4 do
        header[i + 12] = src_bytes[i]
        header[i + 16] = dst_bytes[i]
    end

    local checksum_bytes = util.packInt(IP.checksum(header), 2)
    header[11] = checksum_bytes[1]
    header[12] = checksum_bytes[2]

    local packet = {}
    for i = 1, 20 do
        packet[i] = header[i]
    end
    for i = 1, #data do
        packet[i + 20] = data[i]
    end
    return packet
end

---@param packet number[]
---@return number, number, number, number[]
function IP.unpackPacket(packet)
    local src_bytes = {packet[13], packet[14], packet[15], packet[16]}
    local dst_bytes = {packet[17], packet[18], packet[19], packet[20]}
    local src_ip = util.unpackInt(src_bytes)
    local dst_ip = util.unpackInt(dst_bytes)
    local protocol = packet[10]
    local data = {}
    for i = 21, #packet do
        data[#data + 1] = packet[i]
    end
    return src_ip, dst_ip, protocol, data
end

---@param packet number[] full IP packet, modified in place
function IP.decrementTTL(packet)
    packet[9] = packet[9] - 1
    local header = {}
    for i = 1, 20 do
        header[i] = packet[i]
    end
    header[11] = 0x00
    header[12] = 0x00
    local checksum_bytes = util.packInt(IP.checksum(header), 2)
    packet[11] = checksum_bytes[1]
    packet[12] = checksum_bytes[2]
end

---@param config IPConfig
---@return IPInterface
function IP.new(config)
    config = config or {}
    local mode = config.mode or "host"
    local interfacesCfg = config.interfaces or {}

    if mode == "host" then
        if #interfacesCfg ~= 1 then
            error("host mode requires exactly one interface")
        end
    elseif mode ~= "router" then
        error("unknown mode: " .. tostring(mode))
    end

    ---@type IPNetworkInterface[]
    local interfaces = {}
    for i, icfg in ipairs(interfacesCfg) do
        interfaces[i] = {
            iface = link.open(icfg.side, icfg.channel),
            ip = util.toIp(icfg.ip),
            mask = util.toIp(icfg.mask),
            gateway = icfg.gateway and util.toIp(icfg.gateway) or nil,
        }
    end
    for i, ifc in ipairs(interfaces) do
        ifc.arp = ARP.new({ ip = ifc.ip }, ifc.iface)
    end

    ---@type OSPFModule | nil
    local ospf = nil
    if mode == "router" then
        local OSPF = require('lib/ospf')
        ospf = OSPF.new(interfaces)
    end

    local function isLocal(dst_ip)
        for _, ifc in ipairs(interfaces) do
            if ifc.ip == dst_ip then
                return true
            end
        end
        return false
    end

    ---@type IPInterface
    local ipInterface = {}

    function ipInterface:send(dst_ip, protocol, data)        if mode == "host" then
            local ifc = interfaces[1]
            local next_hop = dst_ip
            if util.bitAnd(dst_ip, ifc.mask) ~= util.bitAnd(ifc.ip, ifc.mask) then
                next_hop = ifc.gateway
            end
            if not next_hop then
                return
            end
            local mac = ifc.arp:lookup(next_hop)
            if mac then
                ifc.iface:send(mac, 0x0800, IP.packPacket(ifc.ip, dst_ip, protocol, data))
            end
        else
            local route = ospf.getRoute(dst_ip)
            if not route then
                return
            end
            local ifc = interfaces[route.iface]
            local next_hop = (route.next_hop ~= 0) and route.next_hop or dst_ip
            local mac = ifc.arp:lookup(next_hop)
            if mac then
                ifc.iface:send(mac, 0x0800, IP.packPacket(ifc.ip, dst_ip, protocol, data))
            end
        end
    end

    function ipInterface:recv()
        while true do
            local event, src_ip, protocol, data = os.pullEvent("ip_packet")
            if event == "ip_packet" then
                return src_ip, protocol, data
            end
        end
    end

    for i, ifc in ipairs(interfaces) do
        simpleParallel.add(function()
            local ifaceIndex = i
            while true do
                local dst_mac, src_mac, etype, data = ifc.iface.recv()
                if etype == 0x0800 then -- IPv4
                    local src_ip, dst_ip, protocol, payload = IP.unpackPacket(data)
                    if protocol == IP.OSPF_PROTOCOL then
                        -- handled by OSPF's own readers
                    elseif dst_ip ~= BROADCAST_IP and isLocal(dst_ip) then
                        os.queueEvent("ip_packet", src_ip, protocol, payload)
                    elseif mode == "router" and dst_ip ~= BROADCAST_IP then
                        local route = ospf.getRoute(dst_ip)
                        if route and data[9] > 1 then
                            -- avoid sending a directly-connected packet back out its ingress interface
                            if not (route.next_hop == 0 and route.iface == ifaceIndex) then
                                IP.decrementTTL(data)
                                local eifc = interfaces[route.iface]
                                local next_hop = (route.next_hop ~= 0) and route.next_hop or dst_ip
                                local mac = eifc.arp:lookup(next_hop)
                                if mac then
                                    eifc.iface:send(mac, 0x0800, data)
                                end
                            end
                        end
                    end
                end
            end
        end)
    end

    function ipInterface.getRoutes()
        if ospf then
            return ospf.getRoutes()
        end
        return nil
    end

    function ipInterface.getNeighbors()
        if ospf then
            return ospf.getNeighbors()
        end
        return nil
    end

    function ipInterface:getLocalIp()
        return interfaces[1].ip
    end

    return ipInterface
end

return IP
