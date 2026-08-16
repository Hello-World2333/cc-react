---@diagnostic disable
local util = require('lib/util')
local IP = require('lib/ip')
local simpleParallel = require('lib/simpleParallel')
local OSPF = {}

local OSPF_PROTOCOL = IP.OSPF_PROTOCOL
local OSPF_TYPE_HELLO = 1
local OSPF_TYPE_LSU = 4
local OSPF_VERSION = 2
local BROADCAST_IP = 0xFFFFFFFF
local BROADCAST_MAC = 0xFFFFFFFFFFFF

local HELLO_INTERVAL = 10
local DEAD_INTERVAL = 40
local LSA_REFRESH = 30
local LSA_MAX_AGE = 3600
local LINK_COST = 1

---@class OSPFNeighbor
---@field ip number
---@field iface number interface index (1-based)
---@field last_heard number
---@field twoway boolean

---@class OSPFLink
---@field subnet number
---@field mask number
---@field cost number
---@field neighbor number router id, 0 = stub

---@class OSPFLSA
---@field router_id number
---@field sequence number
---@field age number
---@field links OSPFLink[]

---@class OSPFModule
---@field interfaces IPNetworkInterface[]
---@field router_id number
---@field area_id number
---@field neighbors table<number, OSPFNeighbor>
---@field lsdb table<number, OSPFLSA>
---@field sequence number
---@field routes Route[]
---@field buildOwnLSA fun(self: OSPFModule): OSPFLSA
---@field flood fun(self: OSPFModule, lsas: OSPFLSA[], exceptIface: number | nil): void
---@field floodOwnLSA fun(self: OSPFModule): void
---@field recomputeSPF fun(self: OSPFModule): void
---@field handleHello fun(self: OSPFModule, ifaceIndex: number, src_ip: number, packet: number[]): void
---@field handleLSU fun(self: OSPFModule, ifaceIndex: number, packet: number[]): void
---@field getRoute fun(self: OSPFModule, dst_ip: number): Route | nil
---@field getRoutes fun(self: OSPFModule): Route[]
---@field getNeighbors fun(self: OSPFModule): table<number, OSPFNeighbor>
---@field getLSDB fun(self: OSPFModule): table<number, OSPFLSA>

local function appendInt(bytes, int, len)
    local b = util.packInt(int, len)
    for i = 1, #b do
        bytes[#bytes + 1] = b[i]
    end
end

local function bytesToInt(bytes, start, len)
    local t = {}
    for i = 1, len do
        t[i] = bytes[start + i - 1]
    end
    return util.unpackInt(t)
end

---@param router_id number
---@param area_id number
---@param mask number
---@param hello_interval number
---@param neighbors number[]
---@return number[]
local function packHello(router_id, area_id, mask, hello_interval, neighbors)
    local b = {}
    b[1] = OSPF_VERSION
    b[2] = OSPF_TYPE_HELLO
    appendInt(b, router_id, 4)
    appendInt(b, area_id, 4)
    appendInt(b, mask, 4)
    appendInt(b, hello_interval, 2)
    appendInt(b, #neighbors, 2)
    for _, n in ipairs(neighbors) do
        appendInt(b, n, 4)
    end
    return b
end

---@param p number[]
---@return number, number, number, number, number[]
local function unpackHello(p)
    local router_id = bytesToInt(p, 3, 4)
    local area_id = bytesToInt(p, 7, 4)
    local mask = bytesToInt(p, 11, 4)
    local hello_interval = bytesToInt(p, 15, 2)
    local count = bytesToInt(p, 17, 2)
    local neighbors = {}
    for i = 1, count do
        local off = 19 + (i - 1) * 4
        neighbors[#neighbors + 1] = bytesToInt(p, off, 4)
    end
    return router_id, area_id, mask, hello_interval, neighbors
end

---@param lsa OSPFLSA
---@return number[]
local function packLSA(lsa)
    local b = {}
    appendInt(b, lsa.router_id, 4)
    appendInt(b, lsa.sequence, 4)
    appendInt(b, lsa.age, 2)
    appendInt(b, #lsa.links, 2)
    for _, link in ipairs(lsa.links) do
        appendInt(b, link.subnet, 4)
        appendInt(b, link.mask, 4)
        appendInt(b, link.cost, 2)
        appendInt(b, link.neighbor, 4)
    end
    return b
end

---@param bytes number[]
---@param start number
---@return OSPFLSA, number
local function unpackLSA(bytes, start)
    local pos = start
    local router_id = bytesToInt(bytes, pos, 4)
    pos = pos + 4
    local sequence = bytesToInt(bytes, pos, 4)
    pos = pos + 4
    local age = bytesToInt(bytes, pos, 2)
    pos = pos + 2
    local count = bytesToInt(bytes, pos, 2)
    pos = pos + 2
    local links = {}
    for i = 1, count do
        links[i] = {
            subnet = bytesToInt(bytes, pos, 4),
            mask = bytesToInt(bytes, pos + 4, 4),
            cost = bytesToInt(bytes, pos + 8, 2),
            neighbor = bytesToInt(bytes, pos + 10, 4),
        }
        pos = pos + 14
    end
    return { router_id = router_id, sequence = sequence, age = age, links = links }, pos
end

---@param router_id number
---@param area_id number
---@param lsas OSPFLSA[]
---@return number[]
local function packLSU(router_id, area_id, lsas)
    local b = {}
    b[1] = OSPF_VERSION
    b[2] = OSPF_TYPE_LSU
    appendInt(b, router_id, 4)
    appendInt(b, area_id, 4)
    appendInt(b, #lsas, 2)
    for _, lsa in ipairs(lsas) do
        local lb = packLSA(lsa)
        for i = 1, #lb do
            b[#b + 1] = lb[i]
        end
    end
    return b
end

---@param p number[]
---@return number, number, OSPFLSA[]
local function unpackLSU(p)
    local router_id = bytesToInt(p, 3, 4)
    local area_id = bytesToInt(p, 7, 4)
    local count = bytesToInt(p, 11, 2)
    local lsas = {}
    local pos = 13
    for i = 1, count do
        local lsa
        lsa, pos = unpackLSA(p, pos)
        lsas[i] = lsa
    end
    return router_id, area_id, lsas
end

---@param interfaces IPNetworkInterface[] each { iface = LinkInterface, ip = number, mask = number }
---@return OSPFModule
function OSPF.new(interfaces)
    ---@type OSPFModule
    local ospf = {}
    ospf.interfaces = interfaces
    ospf.router_id = os.getComputerID()
    ospf.area_id = 0
    ospf.neighbors = {} -- router_id -> { ip, iface, last_heard, twoway }
    ospf.lsdb = {} -- router_id -> LSA
    ospf.sequence = 0
    ospf.routes = {}

    ---@param ifaceIndex number
    ---@param bytes number[]
    local function sendOn(ifaceIndex, bytes)
        local ifc = interfaces[ifaceIndex]
        ifc.iface:send(BROADCAST_MAC, 0x0800, IP.packPacket(ifc.ip, BROADCAST_IP, OSPF_PROTOCOL, bytes))
    end

    ---@param ifaceIndex number
    ---@return number[]
    local function neighborsOn(ifaceIndex)
        local list = {}
        for rid, n in pairs(ospf.neighbors) do
            if n.iface == ifaceIndex then
                list[#list + 1] = rid
            end
        end
        return list
    end

    ---@param ifaceIndex number
    local function sendHello(ifaceIndex)
        local ifc = interfaces[ifaceIndex]
        sendOn(ifaceIndex, packHello(ospf.router_id, ospf.area_id, ifc.mask, HELLO_INTERVAL, neighborsOn(ifaceIndex)))
    end

    ---@return OSPFLSA
    function ospf.buildOwnLSA()
        local links = {}
        for i, ifc in ipairs(interfaces) do
            local neighbor = 0
            for rid, n in pairs(ospf.neighbors) do
                if n.iface == i and n.twoway then
                    neighbor = rid
                end
            end
            links[#links + 1] = {
                subnet = util.bitAnd(ifc.ip, ifc.mask),
                mask = ifc.mask,
                cost = LINK_COST,
                neighbor = neighbor,
            }
        end
        return { router_id = ospf.router_id, sequence = ospf.sequence, age = 0, links = links }
    end

    ---@param lsas OSPFLSA[]
    ---@param exceptIface number | nil
    function ospf.flood(lsas, exceptIface)
        for i = 1, #interfaces do
            if i ~= exceptIface then
                sendOn(i, packLSU(ospf.router_id, ospf.area_id, lsas))
            end
        end
    end

    function ospf.floodOwnLSA()
        ospf.sequence = ospf.sequence + 1
        local lsa = ospf.buildOwnLSA()
        ospf.lsdb[ospf.router_id] = lsa
        ospf.flood({ lsa })
    end

    function ospf.recomputeSPF()
        -- adjacency graph: adj[a][b] = cost, only 2-way adjacencies
        local adj = {}
        for rid, lsa in pairs(ospf.lsdb) do
            for _, link in ipairs(lsa.links) do
                if link.neighbor ~= 0 then
                    local other = ospf.lsdb[link.neighbor]
                    if other then
                        local twoway = false
                        for _, ol in ipairs(other.links) do
                            if ol.neighbor == rid then
                                twoway = true
                                break
                            end
                        end
                        if twoway then
                            adj[rid] = adj[rid] or {}
                            adj[rid][link.neighbor] = link.cost
                        end
                    end
                end
            end
        end

        -- Dijkstra from self
        local dist = { [ospf.router_id] = 0 }
        local prev = {}
        local visited = {}
        while true do
            local u = nil
            for rid, d in pairs(dist) do
                if not visited[rid] and (u == nil or d < dist[u]) then
                    u = rid
                end
            end
            if u == nil then
                break
            end
            visited[u] = true
            for v, c in pairs(adj[u] or {}) do
                local nd = dist[u] + c
                if dist[v] == nil or nd < dist[v] then
                    dist[v] = nd
                    prev[v] = u
                end
            end
        end

        local function firstHop(rid)
            if rid == ospf.router_id then
                return nil
            end
            local cur = rid
            while prev[cur] ~= ospf.router_id do
                cur = prev[cur]
                if cur == nil then
                    return nil
                end
            end
            return cur
        end

        local routes = {}
        local routeMap = {}
        ---@param subnet number
        ---@param mask number
        ---@param next_hop number
        ---@param ifaceIndex number | nil
        ---@param cost number
        local function addRoute(subnet, mask, next_hop, ifaceIndex, cost)
            local key = tostring(subnet) .. ":" .. tostring(mask)
            local existing = routeMap[key]
            if existing then
                if existing.cost <= cost then
                    return
                end
                existing.next_hop = next_hop
                existing.iface = ifaceIndex
                existing.cost = cost
            else
                local r = { subnet = subnet, mask = mask, next_hop = next_hop, iface = ifaceIndex, cost = cost }
                routeMap[key] = r
                routes[#routes + 1] = r
            end
        end

        -- directly connected networks
        for i, ifc in ipairs(interfaces) do
            addRoute(util.bitAnd(ifc.ip, ifc.mask), ifc.mask, 0, i, LINK_COST)
        end

        -- networks reachable through other routers
        for rid, lsa in pairs(ospf.lsdb) do
            if rid ~= ospf.router_id then
                local fh = firstHop(rid)
                if fh then
                    local nbr = ospf.neighbors[fh]
                    local ifaceIdx = nbr and nbr.iface
                    local next_hop = nbr and nbr.ip or 0
                    for _, link in ipairs(lsa.links) do
                        addRoute(link.subnet, link.mask, next_hop, ifaceIdx, dist[rid] + link.cost)
                    end
                end
            end
        end

        ospf.routes = routes
    end

    ---@param ifaceIndex number
    ---@param src_ip number
    ---@param p number[]
    function ospf.handleHello(ifaceIndex, src_ip, p)
        local rid, area_id, mask, hello_interval, neighbors = unpackHello(p)
        if area_id ~= ospf.area_id then
            return
        end
        if rid == ospf.router_id then
            return
        end
        local twoway = false
        for _, nb in ipairs(neighbors) do
            if nb == ospf.router_id then
                twoway = true
            end
        end
        local n = ospf.neighbors[rid]
        local changed = false
        if not n then
            n = { ip = src_ip, iface = ifaceIndex, last_heard = os.clock(), twoway = twoway }
            ospf.neighbors[rid] = n
            changed = true
        else
            n.ip = src_ip
            n.iface = ifaceIndex
            n.last_heard = os.clock()
            if n.twoway ~= twoway then
                n.twoway = twoway
                changed = true
            end
        end
        if changed then
            ospf.recomputeSPF()
            ospf.floodOwnLSA()
        end
    end

    ---@param ifaceIndex number
    ---@param p number[]
    function ospf.handleLSU(ifaceIndex, p)
        local router_id, area_id, lsas = unpackLSU(p)
        if area_id ~= ospf.area_id then
            return
        end
        local changed = false
        for _, lsa in ipairs(lsas) do
            if lsa.router_id ~= ospf.router_id then
                local existing = ospf.lsdb[lsa.router_id]
                if not existing or lsa.sequence > existing.sequence then
                    ospf.lsdb[lsa.router_id] = lsa
                    changed = true
                    ospf.flood({ lsa }, ifaceIndex)
                end
            end
        end
        if changed then
            ospf.recomputeSPF()
        end
    end

    -- per-interface readers
    for i = 1, #interfaces do
        simpleParallel.add(function()
            local ifaceIndex = i
            while true do
                local dst_mac, src_mac, etype, data = interfaces[ifaceIndex].iface.recv()
                if etype == 0x0800 then
                    local src_ip, dst_ip, protocol, payload = IP.unpackPacket(data)
                    if protocol == OSPF_PROTOCOL and payload[1] == OSPF_VERSION then
                        local ptype = payload[2]
                        if ptype == OSPF_TYPE_HELLO then
                            ospf.handleHello(ifaceIndex, src_ip, payload)
                        elseif ptype == OSPF_TYPE_LSU then
                            ospf.handleLSU(ifaceIndex, payload)
                        end
                    end
                end
            end
        end)
    end

    -- hello + neighbor timeout
    simpleParallel.add(function()
        while true do
            local now = os.clock()
            local changed = false
            for rid, n in pairs(ospf.neighbors) do
                if now - n.last_heard > DEAD_INTERVAL then
                    ospf.neighbors[rid] = nil
                    changed = true
                end
            end
            if changed then
                ospf.recomputeSPF()
                ospf.floodOwnLSA()
            end
            for i = 1, #interfaces do
                sendHello(i)
            end
            sleep(HELLO_INTERVAL)
        end
    end)

    -- LSA refresh + aging
    simpleParallel.add(function()
        while true do
            sleep(LSA_REFRESH)
            ospf.floodOwnLSA()
            local changed = false
            for rid, lsa in pairs(ospf.lsdb) do
                if rid ~= ospf.router_id then
                    lsa.age = lsa.age + LSA_REFRESH
                    if lsa.age > LSA_MAX_AGE then
                        ospf.lsdb[rid] = nil
                        changed = true
                    end
                end
            end
            if changed then
                ospf.recomputeSPF()
            end
        end
    end)

    -- initial advertisement
    ospf.floodOwnLSA()
    for i = 1, #interfaces do
        sendHello(i)
    end
    ospf.recomputeSPF()

    ---@param dst_ip number
    ---@return Route | nil
    function ospf.getRoute(dst_ip)
        local best = nil
        for _, r in ipairs(ospf.routes) do
            if util.bitAnd(dst_ip, r.mask) == r.subnet then
                if best == nil or r.mask > best.mask then
                    best = r
                end
            end
        end
        return best
    end

    function ospf.getRoutes()
        return ospf.routes
    end

    function ospf.getNeighbors()
        return ospf.neighbors
    end

    function ospf.getLSDB()
        return ospf.lsdb
    end

    return ospf
end

return OSPF
