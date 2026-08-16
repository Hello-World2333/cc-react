---@diagnostic disable
local util = require('lib/util')
local UDP = require('lib/udp')
local simpleParallel = require('lib/simpleParallel')
local DHCP = {}

-- BOOTP operation codes
DHCP.BOOTREQUEST = 1
DHCP.BOOTREPLY = 2

-- Hardware type / length (Ethernet)
DHCP.HTYPE_ETHERNET = 1
DHCP.HLEN_ETHERNET = 6

-- Ports
DHCP.SERVER_PORT = 67
DHCP.CLIENT_PORT = 68

-- Message types
DHCP.DISCOVER = 1
DHCP.OFFER = 2
DHCP.REQUEST = 3
DHCP.DECLINE = 4
DHCP.ACK = 5
DHCP.NAK = 6
DHCP.RELEASE = 7
DHCP.INFORM = 8

-- Options
DHCP.OPT_SUBNET_MASK = 1
DHCP.OPT_ROUTER = 3
DHCP.OPT_DNS = 6
DHCP.OPT_HOSTNAME = 12
DHCP.OPT_REQUESTED_IP = 50
DHCP.OPT_LEASE_TIME = 51
DHCP.OPT_MESSAGE_TYPE = 53
DHCP.OPT_SERVER_ID = 54
DHCP.OPT_PARAM_REQUEST_LIST = 55
DHCP.OPT_RENEWAL_TIME = 58
DHCP.OPT_REBINDING_TIME = 59
DHCP.OPT_CLIENT_ID = 61
DHCP.OPT_END = 255

local OPT_PAD = 0
local OPT_SUBNET_MASK = DHCP.OPT_SUBNET_MASK
local OPT_ROUTER = DHCP.OPT_ROUTER
local OPT_DNS = DHCP.OPT_DNS
local OPT_HOSTNAME = DHCP.OPT_HOSTNAME
local OPT_REQUESTED_IP = DHCP.OPT_REQUESTED_IP
local OPT_LEASE_TIME = DHCP.OPT_LEASE_TIME
local OPT_MESSAGE_TYPE = DHCP.OPT_MESSAGE_TYPE
local OPT_SERVER_ID = DHCP.OPT_SERVER_ID
local OPT_RENEWAL_TIME = DHCP.OPT_RENEWAL_TIME
local OPT_REBINDING_TIME = DHCP.OPT_REBINDING_TIME
local OPT_CLIENT_ID = DHCP.OPT_CLIENT_ID
local OPT_END = DHCP.OPT_END

local BOOTREQUEST = DHCP.BOOTREQUEST
local BOOTREPLY = DHCP.BOOTREPLY
local HTYPE_ETHERNET = DHCP.HTYPE_ETHERNET
local HLEN_ETHERNET = DHCP.HLEN_ETHERNET

local DHCPDISCOVER = DHCP.DISCOVER
local DHCPOFFER = DHCP.OFFER
local DHCPREQUEST = DHCP.REQUEST
local DHCPDECLINE = DHCP.DECLINE
local DHCPACK = DHCP.ACK
local DHCPNAK = DHCP.NAK
local DHCPRELEASE = DHCP.RELEASE
local DHCPINFORM = DHCP.INFORM

local MAGIC_COOKIE = { 0x63, 0x82, 0x53, 0x63 }

local function appendBytes(dst, src)
    for i = 1, #src do
        dst[#dst + 1] = src[i]
    end
end

---@param list (string|number)[]
---@return number[]
local function ipListBytes(list)    local b = {}
    for _, ip in ipairs(list) do
        appendBytes(b, util.packInt(util.toIp(ip), 4))
    end
    return b
end

---@class DHCPOption
---@field [1] number option type
---@field [2] number[] option data

---@param opts DHCPOption[] list of {type, data}
---@return number[]
local function packOptions(opts)
    local b = {}
    for _, o in ipairs(opts) do
        if o[1] ~= OPT_PAD and o[1] ~= OPT_END then
            b[#b + 1] = o[1]
            b[#b + 1] = #o[2]
            appendBytes(b, o[2])
        end
    end
    b[#b + 1] = OPT_END
    return b
end

---@param msg number[]
---@param start number
---@return DHCPOption[]
local function unpackOptions(msg, start)
    local opts = {}
    local i = start
    while i <= #msg do
        local t = msg[i]
        if t == OPT_END then
            break
        elseif t == OPT_PAD then
            i = i + 1
        elseif i + 1 > #msg then
            break
        else
            local len = msg[i + 1]
            local data = {}
            for k = 1, len do
                data[k] = msg[i + 1 + k]
            end
            opts[#opts + 1] = { t, data }
            i = i + 2 + len
        end
    end
    return opts
end

---@param opts DHCPOption[]
---@param t number
---@return number[] | nil
local function getOption(opts, t)
    for _, o in ipairs(opts) do
        if o[1] == t then
            return o[2]
        end
    end
    return nil
end

---@class DHCPMessage
---@field op number
---@field htype number
---@field hlen number
---@field hops number
---@field xid number
---@field secs number
---@field flags number
---@field ciaddr number
---@field yiaddr number
---@field siaddr number
---@field giaddr number
---@field chaddr number[]
---@field sname string
---@field file string
---@field options DHCPOption[]

---@param msg DHCPMessage
---@return number[]
function DHCP.packMessage(msg)
    local b = {}
    b[1] = msg.op or BOOTREQUEST
    b[2] = msg.htype or HTYPE_ETHERNET
    b[3] = msg.hlen or HLEN_ETHERNET
    b[4] = msg.hops or 0
    appendBytes(b, util.packInt(msg.xid or 0, 4))
    appendBytes(b, util.packInt(msg.secs or 0, 2))
    appendBytes(b, util.packInt(msg.flags or 0, 2))
    appendBytes(b, util.packInt(msg.ciaddr or 0, 4))
    appendBytes(b, util.packInt(msg.yiaddr or 0, 4))
    appendBytes(b, util.packInt(msg.siaddr or 0, 4))
    appendBytes(b, util.packInt(msg.giaddr or 0, 4))

    for i = 1, 16 do
        b[#b + 1] = (msg.chaddr and msg.chaddr[i]) or 0
    end

    local sname = msg.sname or ""
    for i = 1, 64 do
        b[#b + 1] = string.byte(sname, i) or 0
    end
    local file = msg.file or ""
    for i = 1, 128 do
        b[#b + 1] = string.byte(file, i) or 0
    end

    appendBytes(b, MAGIC_COOKIE)
    appendBytes(b, packOptions(msg.options or {}))

    return b
end

---@param msg number[]
---@return DHCPMessage | nil
function DHCP.unpackMessage(msg)
    if #msg < 240 then
        return nil
    end
    local chaddr = {}
    for i = 1, 16 do
        chaddr[i] = msg[28 + i]
    end
    return {
        op = msg[1],
        htype = msg[2],
        hlen = msg[3],
        hops = msg[4],
        xid = util.unpackInt({ msg[5], msg[6], msg[7], msg[8] }),
        secs = util.unpackInt({ msg[9], msg[10] }),
        flags = util.unpackInt({ msg[11], msg[12] }),
        ciaddr = util.unpackInt({ msg[13], msg[14], msg[15], msg[16] }),
        yiaddr = util.unpackInt({ msg[17], msg[18], msg[19], msg[20] }),
        siaddr = util.unpackInt({ msg[21], msg[22], msg[23], msg[24] }),
        giaddr = util.unpackInt({ msg[25], msg[26], msg[27], msg[28] }),
        chaddr = chaddr,
        options = unpackOptions(msg, 241),
    }
end

---@param msg DHCPMessage
---@return string
local function clientId(msg)
    local cid = getOption(msg.options, OPT_CLIENT_ID)
    if cid then
        return util.bytesToString(cid)
    end
    local parts = {}
    for i = 1, (msg.hlen or HLEN_ETHERNET) do
        parts[#parts + 1] = string.format("%02x", msg.chaddr[i])
    end
    return table.concat(parts, ":")
end

---@class DHCPLeaseInfo
---@field clientId string
---@field ip string
---@field expires number

---@class DHCPLease
---@field ip string
---@field mask string | nil
---@field routers string[]
---@field dns string[]
---@field serverId string | nil
---@field leaseTime number | nil
---@field renewalTime number | nil
---@field rebindingTime number | nil
---@field acquired number

---@class DHCPRange
---@field start string | number | nil
---@field ['end'] string | number | nil
---@field [1] string | number | nil
---@field [2] string | number | nil

---@class DHCPServer
---@field mask number
---@field routers (string | number)[]
---@field dns (string | number)[]
---@field leaseTime number
---@field renewalTime number
---@field rebindingTime number
---@field serverId number
---@field rangeStart number
---@field rangeEnd number
---@field leases table<string, { ip: number, expires: number }>
---@field byIp table<number, string>
---@field declined table<number, boolean>
---@field reserved table<string, number>
---@field reservedByIp table<number, string>
---@field inRange fun(self: DHCPServer, addr: number): boolean
---@field isFree fun(self: DHCPServer, addr: number): boolean
---@field allocate fun(self: DHCPServer, wanted: number | nil, cid: string): number | nil
---@field commit fun(self: DHCPServer, msg: DHCPMessage, wanted: number | nil): number | nil
---@field getLeases fun(self: DHCPServer): DHCPLeaseInfo[]
---@field release fun(self: DHCPServer, ip: string | number): void
---@field setReserved fun(self: DHCPServer, clientId: string, ip: string | number): void

---@class DHCPServerConfig
---@field range DHCPRange | nil -- { start = ip, ['end'] = ip } or { ip, ip }
---@field subnetMask string | number | nil
---@field routers (string | number)[] | nil
---@field dns (string | number)[] | nil
---@field leaseTime number | nil
---@field renewalTime number | nil
---@field rebindingTime number | nil
---@field serverId string | number | nil

---@param ip IPInterface
---@param config DHCPServerConfig
---@return DHCPServer
function DHCP.newServer(ip, config)
    config = config or {}
    local udp = UDP.new(ip)
    local sock = udp:socket()
    sock:setsockname("*", DHCP.SERVER_PORT)

    local range = config.range or {}
    local rangeStart = util.toIp(range.start or range[1] or "192.168.1.100")
    local rangeEnd = util.toIp(range["end"] or range[2] or rangeStart)

    ---@type DHCPServer
    local server = {}
    server.mask = util.toIp(config.subnetMask or "255.255.255.0")
    server.routers = config.routers or {}
    server.dns = config.dns or {}
    server.leaseTime = config.leaseTime or 86400
    server.renewalTime = config.renewalTime or math.floor(server.leaseTime / 2)
    server.rebindingTime = config.rebindingTime or math.floor(server.leaseTime * 7 / 8)
    server.serverId = util.toIp(config.serverId or ip:getLocalIp())
    server.rangeStart = rangeStart
    server.rangeEnd = rangeEnd
    server.leases = {} -- clientId -> { ip, expires }
    server.byIp = {}   -- ip -> clientId
    server.declined = {}
    server.reserved = {}    -- clientId -> ip
    server.reservedByIp = {} -- ip -> clientId

    function server:inRange(addr)
        return addr >= self.rangeStart and addr <= self.rangeEnd
    end

    function server:isFree(addr)
        if not self:inRange(addr) then
            return false
        end
        if self.declined[addr] then
            return false
        end
        local cid = self.byIp[addr]
        if not cid then
            return true
        end
        local lease = self.leases[cid]
        if lease and lease.expires > os.clock() then
            return false
        end
        self.byIp[addr] = nil
        self.leases[cid] = nil
        return true
    end

    function server:allocate(wanted, cid)
        if wanted and self:isFree(wanted) and self.reservedByIp[wanted] == nil then
            return wanted
        end
        for addr = self.rangeStart, self.rangeEnd do
            if self:isFree(addr) and (self.reservedByIp[addr] == nil or self.reservedByIp[addr] == cid) then
                return addr
            end
        end
        return nil
    end

    function server:commit(msg, wanted)
        local cid = clientId(msg)
        local addr = wanted
        local reservedIp = self.reserved[cid]
        if reservedIp then
            if self:isFree(reservedIp) then
                addr = reservedIp
            else
                return nil
            end
        end
        if addr and self.reservedByIp[addr] and self.reservedByIp[addr] ~= cid then
            return nil
        end
        if not addr then
            local existing = self.leases[cid]
            if existing and self:inRange(existing.ip) and self:isFree(existing.ip) then
                addr = existing.ip
            else
                addr = self:allocate(nil, cid)
            end
        end
        if not addr then
            return nil
        end
        if not self:inRange(addr) then
            return nil
        end
        local owner = self.byIp[addr]
        if owner and owner ~= cid then
            local olease = self.leases[owner]
            if olease and olease.expires > os.clock() then
                return nil
            end
        end
        self.leases[cid] = { ip = addr, expires = os.clock() + self.leaseTime }
        self.byIp[addr] = cid
        return addr
    end

    function server:releaseIp(addr)
        local cid = self.byIp[addr]
        if cid then
            self.byIp[addr] = nil
            self.leases[cid] = nil
        end
    end

    function server:declineIp(addr)
        self.declined[addr] = true
        self:releaseIp(addr)
    end

    ---@param yiaddr number
    ---@return DHCPOption[]
    local function leaseOptions(yiaddr)
        local opts = {
            { OPT_SUBNET_MASK, util.packInt(server.mask, 4) },
            { OPT_LEASE_TIME, util.packInt(server.leaseTime, 4) },
            { OPT_RENEWAL_TIME, util.packInt(server.renewalTime, 4) },
            { OPT_REBINDING_TIME, util.packInt(server.rebindingTime, 4) },
        }
        if #server.routers > 0 then
            opts[#opts + 1] = { OPT_ROUTER, ipListBytes(server.routers) }
        end
        if #server.dns > 0 then
            opts[#opts + 1] = { OPT_DNS, ipListBytes(server.dns) }
        end
        return opts
    end

    ---@param msg DHCPMessage
    ---@param messageType number
    ---@param yiaddr number
    ---@param addr string
    ---@param rport number
    local function sendReply(msg, messageType, yiaddr, addr, rport)
        local opts = {
            { OPT_MESSAGE_TYPE, { messageType } },
            { OPT_SERVER_ID, util.packInt(server.serverId, 4) },
        }
        if (messageType == DHCPOFFER or messageType == DHCPACK) and yiaddr and yiaddr ~= 0 then
            local lo = leaseOptions()
            for _, o in ipairs(lo) do
                opts[#opts + 1] = o
            end
        end
        local reply = {
            op = BOOTREPLY,
            xid = msg.xid,
            flags = msg.flags,
            ciaddr = 0,
            yiaddr = yiaddr or 0,
            siaddr = server.serverId,
            giaddr = 0,
            chaddr = msg.chaddr,
            options = opts,
        }
        sock:sendto(util.bytesToString(DHCP.packMessage(reply)), addr, rport)
    end

    ---@param msg DHCPMessage
    ---@param addr string
    ---@param rport number
    local function handleRequest(msg, addr, rport)
        local m = getOption(msg.options, OPT_MESSAGE_TYPE)
        if not m then
            return
        end
        local mtype = m[1]

        if mtype == DHCPDISCOVER then
            local req = getOption(msg.options, OPT_REQUESTED_IP)
            local wanted = req and util.unpackInt(req) or nil
            local offered = server:allocate(wanted, clientId(msg))
            if offered then
                sendReply(msg, DHCPOFFER, offered, addr, rport)
            end
        elseif mtype == DHCPREQUEST then
            local sid = getOption(msg.options, OPT_SERVER_ID)
            if sid and util.unpackInt(sid) ~= server.serverId then
                return
            end
            local req = getOption(msg.options, OPT_REQUESTED_IP)
            local wanted = req and util.unpackInt(req) or (msg.ciaddr ~= 0 and msg.ciaddr or nil)
            local assigned = server:commit(msg, wanted)
            if assigned then
                sendReply(msg, DHCPACK, assigned, addr, rport)
            else
                sendReply(msg, DHCPNAK, 0, addr, rport)
            end
        elseif mtype == DHCPRELEASE then
            if msg.ciaddr ~= 0 then
                server:releaseIp(msg.ciaddr)
            end
        elseif mtype == DHCPDECLINE then
            local req = getOption(msg.options, OPT_REQUESTED_IP)
            if req then
                server:declineIp(util.unpackInt(req))
            end
        elseif mtype == DHCPINFORM then
            sendReply(msg, DHCPACK, 0, addr, rport)
        end
    end

    simpleParallel.add(function()
        while true do
            local data, addr, rport = sock:receivefrom()
            if data then
                local msg = DHCP.unpackMessage(util.stringToBytes(data))
                if msg and msg.op == BOOTREQUEST then
                    handleRequest(msg, addr, rport)
                end
            end
        end
    end)

    simpleParallel.add(function()
        while true do
            sleep(60)
            local now = os.clock()
            for cid, lease in pairs(server.leases) do
                if lease.expires <= now then
                    if server.byIp[lease.ip] == cid then
                        server.byIp[lease.ip] = nil
                    end
                    server.leases[cid] = nil
                end
            end
        end
    end)

    function server:getLeases()
        local out = {}
        for cid, lease in pairs(self.leases) do
            out[#out + 1] = {
                clientId = cid,
                ip = util.intToIp(lease.ip),
                expires = lease.expires,
            }
        end
        return out
    end

    function server:release(addr)
        self:releaseIp(util.toIp(addr))
    end

    function server:setReserved(cid, addr)
        addr = util.toIp(addr)
        local old = self.reserved[cid]
        if old then
            self.reservedByIp[old] = nil
        end
        self.reserved[cid] = addr
        self.reservedByIp[addr] = cid
    end

    return server
end

---@class DHCPClient
---@field lease DHCPLease | nil
---@field timeout number
---@field retryDelay number
---@field serverIp number | nil
---@field hostname string | nil
---@field requestedIp number | nil
---@field xid number
---@field chaddr number[]
---@field request fun(self: DHCPClient, timeout: number | nil): DHCPLease | nil, string | nil
---@field renew fun(self: DHCPClient, timeout: number | nil): boolean, string | nil
---@field release fun(self: DHCPClient): void
---@field start fun(self: DHCPClient): void
---@field getLease fun(self: DHCPClient): DHCPLease | nil

---@class DHCPClientConfig
---@field server string | number
---@field hostname string | nil
---@field requestedIp string | number | nil
---@field timeout number | nil
---@field retryDelay number | nil

---@param ip IPInterface
---@param config DHCPClientConfig
---@return DHCPClient
function DHCP.newClient(ip, config)
    config = config or {}
    local udp = UDP.new(ip)
    local sock = udp:socket()
    sock:setsockname("*", DHCP.CLIENT_PORT)
    sock:settimeout(0)

    ---@type DHCPClient
    local client = {}
    client.lease = nil
    client.timeout = config.timeout or 5
    client.retryDelay = config.retryDelay or 30
    client.serverIp = config.server and util.toIp(config.server) or nil
    client.hostname = config.hostname
    client.requestedIp = config.requestedIp and util.toIp(config.requestedIp) or nil
    client.xid = 0

    local mac = util.packInt(os.getComputerID(), 6)
    client.chaddr = {}
    for i = 1, 16 do
        client.chaddr[i] = mac[i] or 0
    end

    ---@return number
    local function nextXid()
        client.xid = client.xid + 1
        if client.xid >= 0x7FFFFFFF then
            client.xid = 1
        end
        return client.xid
    end

    ---@param messageType number
    ---@param ciaddr number | nil
    ---@param opts DHCPOption[] | nil
    ---@return string
    local function buildMsg(messageType, ciaddr, opts)
        opts = opts or {}
        local full = { { OPT_MESSAGE_TYPE, { messageType } } }
        if client.hostname then
            full[#full + 1] = { OPT_HOSTNAME, util.stringToBytes(client.hostname) }
        end
        for _, o in ipairs(opts) do
            full[#full + 1] = o
        end
        return DHCP.packMessage({
            op = BOOTREQUEST,
            xid = client.xid,
            flags = 0,
            ciaddr = ciaddr or 0,
            chaddr = client.chaddr,
            options = full,
        })
    end

    ---@param packed string
    local function sendToServer(packed)
        local host = client.serverIp and util.intToIp(client.serverIp) or "255.255.255.255"
        sock:sendto(packed, host, DHCP.SERVER_PORT)
    end

    ---@param messageType number
    ---@param timeout number | nil
    ---@return DHCPMessage | nil
    local function waitReply(messageType, timeout)
        local start = os.clock()
        while true do
            local data = sock:receivefrom()
            if data then
                local msg = DHCP.unpackMessage(util.stringToBytes(data))
                if msg and msg.op == BOOTREPLY and msg.xid == client.xid then
                    local m = getOption(msg.options, OPT_MESSAGE_TYPE)
                    if m then
                        if m[1] == messageType then
                            return msg
                        elseif m[1] == DHCPNAK then
                            return nil
                        end
                    end
                end
            end
            if os.clock() - start > (timeout or client.timeout) then
                return nil
            end
            sleep(0)
        end
    end

    ---@param msg DHCPMessage
    ---@return DHCPLease
    local function buildLease(msg)
        local mask = getOption(msg.options, OPT_SUBNET_MASK)
        local routers = getOption(msg.options, OPT_ROUTER)
        local dns = getOption(msg.options, OPT_DNS)
        local leaseTime = getOption(msg.options, OPT_LEASE_TIME)
        local serverId = getOption(msg.options, OPT_SERVER_ID)
        local renewalTime = getOption(msg.options, OPT_RENEWAL_TIME)
        local rebindingTime = getOption(msg.options, OPT_REBINDING_TIME)

        local function ipList(bytes)
            local out = {}
            for i = 1, #bytes, 4 do
                out[#out + 1] = util.intToIp(util.unpackInt({ bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3] }))
            end
            return out
        end

        local lease = {
            ip = util.intToIp(msg.yiaddr),
            mask = mask and util.intToIp(util.unpackInt(mask)) or nil,
            routers = routers and ipList(routers) or {},
            dns = dns and ipList(dns) or {},
            serverId = serverId and util.intToIp(util.unpackInt(serverId)) or nil,
            leaseTime = leaseTime and util.unpackInt(leaseTime) or nil,
            renewalTime = renewalTime and util.unpackInt(renewalTime) or nil,
            rebindingTime = rebindingTime and util.unpackInt(rebindingTime) or nil,
            acquired = os.clock(),
        }
        return lease
    end

    function client:request(timeout)
        if not self.serverIp then
            return nil, "no server configured"
        end
        nextXid()

        local discoverOpts = {}
        if self.requestedIp then
            discoverOpts[#discoverOpts + 1] = { OPT_REQUESTED_IP, util.packInt(self.requestedIp, 4) }
        end
        sendToServer(util.bytesToString(buildMsg(DHCPDISCOVER, 0, discoverOpts)))
        local offer = waitReply(DHCPOFFER, timeout)
        if not offer then
            return nil, "no offer"
        end

        local serverId = getOption(offer.options, OPT_SERVER_ID)
        local requestOpts = {}
        if serverId then
            requestOpts[#requestOpts + 1] = { OPT_SERVER_ID, serverId }
        end
        requestOpts[#requestOpts + 1] = { OPT_REQUESTED_IP, util.packInt(offer.yiaddr, 4) }

        sendToServer(util.bytesToString(buildMsg(DHCPREQUEST, 0, requestOpts)))
        local ack = waitReply(DHCPACK, timeout)
        if not ack then
            return nil, "no ack"
        end

        self.lease = buildLease(ack)
        return self.lease
    end

    function client:renew(timeout)
        if not self.lease then
            return false, "no lease"
        end
        if not self.serverIp then
            return false, "no server configured"
        end
        nextXid()
        sendToServer(util.bytesToString(buildMsg(DHCPREQUEST, util.toIp(self.lease.ip), {})))
        local ack = waitReply(DHCPACK, timeout)
        if not ack then
            self.lease = nil
            return false, "renew failed"
        end
        self.lease = buildLease(ack)
        return true
    end

    function client:release()
        if not self.lease then
            return
        end
        nextXid()
        sendToServer(util.bytesToString(buildMsg(DHCPRELEASE, util.toIp(self.lease.ip), {})))
        self.lease = nil
    end

    function client:getLease()
        return self.lease
    end

    function client:start()
        simpleParallel.add(function()
            while true do
                if self.lease then
                    local wait = self.lease.renewalTime or math.floor((self.lease.leaseTime or 3600) / 2)
                    sleep(wait)
                    self:renew(self.timeout)
                else
                    local lease, err = self:request(self.timeout)
                    if not lease then
                        sleep(self.retryDelay)
                    end
                end
            end
        end)
    end

    return client
end

return DHCP
