---@diagnostic disable
local link = require('lib/link')
local util = require('lib/util')
local ARP = require('lib/arp')
local simpleParallel = require('lib/simpleParallel')
local IP = {}

IP.OSPF_PROTOCOL = 89
local BROADCAST_IP = 0xFFFFFFFF
local BROADCAST_MAC = 0xFFFFFFFFFFFF

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

-- ============================================================
-- IPv4 reserved / special address handling
-- (RFC 6890, RFC 5735, RFC 1812, RFC 1122, RFC 3927, RFC 1112)
-- ============================================================

---127.0.0.0/8 loopback
---@param ip number
---@return boolean
function IP.isLoopback(ip)
    return util.bitAnd(ip, 0xFF000000) == 0x7F000000
end

---224.0.0.0/4 multicast
---@param ip number
---@return boolean
function IP.isMulticast(ip)
    return util.bitAnd(ip, 0xF0000000) == 0xE0000000
end

---169.254.0.0/16 link-local
---@param ip number
---@return boolean
function IP.isLinkLocal(ip)
    return util.bitAnd(ip, 0xFFFF0000) == 0xA9FE0000
end

---0.0.0.0/8 "this network"
---@param ip number
---@return boolean
function IP.isZeroNet(ip)
    return util.bitAnd(ip, 0xFF000000) == 0
end

---240.0.0.0/4 class E (reserved for future use)
---@param ip number
---@return boolean
function IP.isClassE(ip)
    return util.bitAnd(ip, 0xF0000000) == 0xF0000000
end

---True when addr is the subnet-directed broadcast of (ip, mask)
---(network address with all host bits set).
---@param addr number
---@param ip number
---@param mask number
---@return boolean
function IP.isSubnetBroadcast(addr, ip, mask)
    if util.bitAnd(addr, mask) ~= util.bitAnd(ip, mask) then
        return false
    end
    local host_bits = util.bitNot(mask)
    return util.bitAnd(addr, host_bits) == host_bits
end

---IPv4 multicast MAC 01:00:5E:xx:xx:xx (RFC 1112, low 23 bits of the address)
---@param ip number multicast address
---@return number 48-bit MAC
function IP.multicastMac(ip)
    return 0x01005E000000 + (ip % 0x800000)
end

---Basic IPv4 header validation: version/IHL, total length, header checksum.
---@param packet number[] full IP packet
---@return boolean
function IP.validatePacket(packet)
    if #packet < 20 then
        return false
    end
    if packet[1] ~= 0x45 then -- version 4, IHL 5 (no options)
        return false
    end
    local total_len = packet[3] * 256 + packet[4]
    if total_len ~= #packet then
        return false
    end
    local header = {}
    for i = 1, 20 do
        header[i] = packet[i]
    end
    return IP.checksum(header) == 0
end

---An address that is never valid as a packet source (RFC 1122 §3.2.1.3).
---0.0.0.0/8 is intentionally excluded here: it is only legal for BOOTP/DHCP
---(RFC 2131 §4.1) and is handled separately in the receive path.
---@param ip number
---@return boolean
function IP.isInvalidSource(ip)
    return IP.isLoopback(ip)
        or IP.isMulticast(ip)
        or IP.isClassE(ip)
        or ip == BROADCAST_IP
end

---A source address a router must never forward (RFC 1812 §5.3.7, RFC 3927 §2.7).
---@param ip number
---@return boolean
function IP.isUnroutableSource(ip)
    return IP.isInvalidSource(ip)
        or IP.isZeroNet(ip)
        or IP.isLinkLocal(ip)
end

---A destination address that is never routed/forwarded
---(RFC 1812 §5.3.3–5.3.6, RFC 3927 §2.7). Subnet-directed broadcasts
---are checked separately against the route's subnet/mask.
---@param ip number
---@return boolean
function IP.isUnroutableDestination(ip)
    return IP.isLoopback(ip)
        or IP.isMulticast(ip)
        or IP.isLinkLocal(ip)
        or IP.isZeroNet(ip)
        or IP.isClassE(ip)
        or ip == BROADCAST_IP
end

---True when the IP payload is a UDP datagram addressed to a BOOTP/DHCP port
---(67/68). This is the one case where a 0.0.0.0 source is legal.
---@param protocol number
---@param payload number[] IP payload
---@return boolean
local function isBootp(protocol, payload)
    if protocol ~= 17 then -- UDP
        return false
    end
    if #payload < 4 then
        return false
    end
    local dst_port = payload[3] * 256 + payload[4]
    return dst_port == 67 or dst_port == 68
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

    ---True when dst_ip is addressed to this node: one of our own interface
    ---addresses, the limited broadcast, or a directed broadcast of one of
    ---our directly-connected subnets.
    ---@param dst_ip number
    ---@return boolean
    local function isForUs(dst_ip)
        if dst_ip == BROADCAST_IP then
            return true
        end
        for _, ifc in ipairs(interfaces) do
            if dst_ip == ifc.ip then
                return true
            end
            if IP.isSubnetBroadcast(dst_ip, ifc.ip, ifc.mask) then
                return true
            end
        end
        return false
    end

    ---Send a packet out of a specific interface, picking the right link-layer
    ---destination: broadcast MAC for broadcasts, multicast MAC for multicast,
    ---ARP-resolved MAC otherwise.
    ---@param eifc IPNetworkInterface
    ---@param dst_ip number
    ---@param protocol number
    ---@param data number[]
    ---@param next_hop number | nil next hop for unicast (nil = drop)
    local function sendOnInterface(eifc, dst_ip, protocol, data, next_hop)
        if dst_ip == BROADCAST_IP or IP.isSubnetBroadcast(dst_ip, eifc.ip, eifc.mask) then
            eifc.iface:send(BROADCAST_MAC, 0x0800, IP.packPacket(eifc.ip, dst_ip, protocol, data))
            return
        end
        if IP.isMulticast(dst_ip) then
            eifc.iface:send(IP.multicastMac(dst_ip), 0x0800, IP.packPacket(eifc.ip, dst_ip, protocol, data))
            return
        end
        if not next_hop then
            return
        end
        local mac = eifc.arp:lookup(next_hop)
        if mac then
            eifc.iface:send(mac, 0x0800, IP.packPacket(eifc.ip, dst_ip, protocol, data))
        end
    end

    ---@type IPInterface
    local ipInterface = {}

    function ipInterface:send(dst_ip, protocol, data)
        if mode == "host" then
            local ifc = interfaces[1]
            -- own address and loopback never leave the machine
            if dst_ip == ifc.ip or IP.isLoopback(dst_ip) then
                os.queueEvent("ip_packet", dst_ip, protocol, data)
                return
            end
            -- broadcasts go out as link-layer broadcast (checked before the
            -- class-E test: 255.255.255.255 falls inside 240.0.0.0/4 numerically)
            if dst_ip == BROADCAST_IP or IP.isSubnetBroadcast(dst_ip, ifc.ip, ifc.mask) then
                ifc.iface:send(BROADCAST_MAC, 0x0800, IP.packPacket(ifc.ip, dst_ip, protocol, data))
                return
            end
            -- multicast maps to 01:00:5E:xx:xx:xx
            if IP.isMulticast(dst_ip) then
                ifc.iface:send(IP.multicastMac(dst_ip), 0x0800, IP.packPacket(ifc.ip, dst_ip, protocol, data))
                return
            end
            -- invalid destinations
            if IP.isZeroNet(dst_ip) or IP.isClassE(dst_ip) then
                return
            end
            local on_link = util.bitAnd(dst_ip, ifc.mask) == util.bitAnd(ifc.ip, ifc.mask)
            -- link-local is only meaningful on the link, never via a gateway
            if IP.isLinkLocal(dst_ip) and not on_link then
                return
            end
            local next_hop = on_link and dst_ip or ifc.gateway
            sendOnInterface(ifc, dst_ip, protocol, data, next_hop)
        else
            -- limited broadcast originates on every interface
            if dst_ip == BROADCAST_IP then
                for _, eifc in ipairs(interfaces) do
                    sendOnInterface(eifc, dst_ip, protocol, data, nil)
                end
                return
            end
            -- loopback is delivered locally
            if IP.isLoopback(dst_ip) then
                os.queueEvent("ip_packet", dst_ip, protocol, data)
                return
            end
            -- never originate traffic to these destinations
            -- (multicast is not supported in router mode: no multicast routing
            -- table, and the receive path drops multicast anyway)
            if IP.isZeroNet(dst_ip) or IP.isClassE(dst_ip) or IP.isLinkLocal(dst_ip) or IP.isMulticast(dst_ip) then
                return
            end
            -- directed broadcast of a directly-connected subnet
            for _, eifc in ipairs(interfaces) do
                if IP.isSubnetBroadcast(dst_ip, eifc.ip, eifc.mask) then
                    sendOnInterface(eifc, dst_ip, protocol, data, nil)
                    return
                end
            end
            local route = ospf.getRoute(dst_ip)
            if not route then
                return
            end
            local eifc = interfaces[route.iface]
            local next_hop = (route.next_hop ~= 0) and route.next_hop or dst_ip
            sendOnInterface(eifc, dst_ip, protocol, data, next_hop)
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
                if etype == 0x0800 and IP.validatePacket(data) then -- IPv4
                    local src_ip, dst_ip, protocol, payload = IP.unpackPacket(data)
                    if protocol == IP.OSPF_PROTOCOL then
                        -- handled by OSPF's own readers
                    else
                        -- source-address (martian) filtering
                        local bad_src = IP.isInvalidSource(src_ip)
                        if not bad_src and IP.isZeroNet(src_ip) and not isBootp(protocol, payload) then
                            bad_src = true -- 0.0.0.0/8 only legal for BOOTP/DHCP
                        end
                        if not bad_src then
                            for _, ifc2 in ipairs(interfaces) do
                                if src_ip == ifc2.ip then
                                    bad_src = true -- spoofed own address
                                    break
                                end
                            end
                        end
                        -- RFC 1812 §5.3.7: a source on a directly-connected subnet
                        -- must arrive via that subnet's interface
                        if not bad_src then
                            for j, jifc in ipairs(interfaces) do
                                if j ~= ifaceIndex
                                    and util.bitAnd(src_ip, jifc.mask) == util.bitAnd(jifc.ip, jifc.mask) then
                                    bad_src = true
                                    break
                                end
                            end
                        end

                        if not bad_src then
                            if isForUs(dst_ip) then
                                -- local delivery, including broadcasts
                                os.queueEvent("ip_packet", src_ip, protocol, payload)
                            elseif mode == "router" then
                                local route = ospf.getRoute(dst_ip)
                                if route and data[9] > 1 -- TTL check (RFC 1812 §5.3.1)
                                    and not IP.isUnroutableDestination(dst_ip)
                                    and not IP.isSubnetBroadcast(dst_ip, route.subnet, route.mask)
                                    and not IP.isUnroutableSource(src_ip) then
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
