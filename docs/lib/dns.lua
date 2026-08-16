---@diagnostic disable
local util = require('lib/util')
local UDP = require('lib/udp')
local TCP = require('lib/tcp')
local simpleParallel = require('lib/simpleParallel')
local DNS = {}

DNS.TYPE_A = 1
DNS.TYPE_NS = 2
DNS.TYPE_CNAME = 5
DNS.TYPE_SOA = 6
DNS.TYPE_PTR = 12
DNS.TYPE_MX = 15
DNS.TYPE_TXT = 16
DNS.TYPE_AAAA = 28
DNS.TYPE_ANY = 255

DNS.CLASS_IN = 1

DNS.RCODE_NOERROR = 0
DNS.RCODE_FORMERR = 1
DNS.RCODE_SERVFAIL = 2
DNS.RCODE_NXDOMAIN = 3
DNS.RCODE_NOTIMP = 4
DNS.RCODE_REFUSED = 5

local TYPE_NAMES = {
    [DNS.TYPE_A] = "A",
    [DNS.TYPE_NS] = "NS",
    [DNS.TYPE_CNAME] = "CNAME",
    [DNS.TYPE_SOA] = "SOA",
    [DNS.TYPE_PTR] = "PTR",
    [DNS.TYPE_MX] = "MX",
    [DNS.TYPE_TXT] = "TXT",
    [DNS.TYPE_AAAA] = "AAAA",
    [DNS.TYPE_ANY] = "ANY",
}

local NAME_TO_TYPE = {}
for k, v in pairs(TYPE_NAMES) do
    NAME_TO_TYPE[string.upper(v)] = k
end

local FLAG_QR = 0x8000
local FLAG_AA = 0x0400
local FLAG_TC = 0x0200
local FLAG_RD = 0x0100
local FLAG_RA = 0x0080

local MAX_UDP_SIZE = 512

---@param name string
---@return number[]
function DNS.encodeName(name)
    local bytes = {}
    name = string.lower(name)
    if name == "" or name == "." then
        bytes[1] = 0
        return bytes
    end
    for label in string.gmatch(name, "[^.]+") do
        if #label > 63 then
            return nil
        end
        bytes[#bytes + 1] = #label
        for i = 1, #label do
            bytes[#bytes + 1] = string.byte(label, i)
        end
    end
    bytes[#bytes + 1] = 0
    return bytes
end

---@param msg number[]
---@param offset number
---@return string, number | nil
function DNS.decodeName(msg, offset)
    local labels = {}
    local pos = offset
    local endPos = nil
    local jumps = 0
    while true do
        if pos > #msg then
            return nil, nil
        end
        local len = msg[pos]
        if len == 0 then
            pos = pos + 1
            if endPos == nil then
                endPos = pos
            end
            break
        elseif len >= 0xC0 then
            local ptr = (len - 0xC0) * 256 + msg[pos + 1]
            if endPos == nil then
                endPos = pos + 2
            end
            pos = ptr + 1
            jumps = jumps + 1
            if jumps > 20 then
                return nil, nil
            end
        else
            pos = pos + 1
            if pos + len - 1 > #msg then
                return nil, nil
            end
            local label = ""
            for i = 0, len - 1 do
                label = label .. string.char(msg[pos + i])
            end
            labels[#labels + 1] = label
            pos = pos + len
        end
    end
    return table.concat(labels, "."), endPos
end

---@class DNSDbRecord
---@field ttl number
---@field value any

---@class DNSRecord
---@field name string
---@field type string | number
---@field value any
---@field ttl number | nil

---@class DNSQuestion
---@field name string
---@field type number
---@field class number

---@class DNSResourceRecord
---@field name string
---@field type number
---@field class number
---@field ttl number
---@field value any

---@class DNSAnswer
---@field type string | number
---@field value any
---@field ttl number

---@class DNSResponse
---@field id number
---@field flags number
---@field rcode number
---@field tc boolean
---@field answers DNSResourceRecord[]

---@class DNSConfig
---@field port number | nil
---@field records DNSRecord[] | nil

---@class DNSClientConfig
---@field server string | number | nil
---@field port number | nil
---@field timeout number | nil

local function newWriter()
    ---@class DNSWriter
    ---@field bytes number[]
    ---@field nameOffsets table<string, number>
    ---@field pos fun(self: DNSWriter): number
    ---@field byte fun(self: DNSWriter, b: number): void
    ---@field u16 fun(self: DNSWriter, v: number): void
    ---@field u32 fun(self: DNSWriter, v: number): void
    ---@field raw fun(self: DNSWriter, t: number[]): void
    ---@field name fun(self: DNSWriter, name: string): void
    ---@type DNSWriter
    local w = {}
    w.bytes = {}
    w.nameOffsets = {}
    function w:pos()
        return #self.bytes
    end
    function w:byte(b)
        self.bytes[#self.bytes + 1] = b
    end
    function w:u16(v)
        local b = util.packInt(v, 2)
        self.bytes[#self.bytes + 1] = b[1]
        self.bytes[#self.bytes + 1] = b[2]
    end
    function w:u32(v)
        local b = util.packInt(v, 4)
        for i = 1, 4 do
            self.bytes[#self.bytes + 1] = b[i]
        end
    end
    function w:raw(t)
        for i = 1, #t do
            self.bytes[#self.bytes + 1] = t[i]
        end
    end
    function w:name(name)
        name = string.lower(name)
        if name == "" or name == "." then
            self.bytes[#self.bytes + 1] = 0
            return
        end
        local labels = {}
        for label in string.gmatch(name, "[^.]+") do
            labels[#labels + 1] = label
        end
        local n = #labels
        for i = 1, n do
            local suffix = table.concat(labels, ".", i)
            local off = self.nameOffsets[suffix]
            if off then
                self.bytes[#self.bytes + 1] = 0xC0 + math.floor(off / 256)
                self.bytes[#self.bytes + 1] = off % 256
                return
            end
            self.nameOffsets[suffix] = self:pos()
            local label = labels[i]
            self.bytes[#self.bytes + 1] = #label
            for j = 1, #label do
                self.bytes[#self.bytes + 1] = string.byte(label, j)
            end
        end
        self.bytes[#self.bytes + 1] = 0
    end
    return w
end

---@param addr string
---@return number[] | nil
local function ipv4ToBytes(addr)
    local bytes = {}
    for b in string.gmatch(addr, "%d+") do
        local v = tonumber(b)
        if v == nil or v < 0 or v > 255 then
            return nil
        end
        bytes[#bytes + 1] = v
    end
    if #bytes ~= 4 then
        return nil
    end
    return bytes
end

---@param addr string
---@return number[] | nil
local function ipv6ToBytes(addr)
    local dbl = string.find(addr, "::", 1, true)
    local head = addr
    local tail = ""
    if dbl then
        head = string.sub(addr, 1, dbl - 1)
        tail = string.sub(addr, dbl + 2)
    end
    local function parseGroups(s)
        local groups = {}
        if s == "" then
            return groups
        end
        for g in string.gmatch(s, "[^:]+") do
            local v = tonumber(g, 16)
            if v == nil then
                return nil
            end
            groups[#groups + 1] = v
        end
        return groups
    end
    local headGroups = parseGroups(head)
    local tailGroups = parseGroups(tail)
    if not headGroups or not tailGroups then
        return nil
    end
    if dbl then
        local zeros = 8 - #headGroups - #tailGroups
        if zeros < 0 then
            return nil
        end
        local groups = {}
        for i = 1, #headGroups do
            groups[#groups + 1] = headGroups[i]
        end
        for i = 1, zeros do
            groups[#groups + 1] = 0
        end
        for i = 1, #tailGroups do
            groups[#groups + 1] = tailGroups[i]
        end
        headGroups = groups
    end
    if #headGroups ~= 8 then
        return nil
    end
    local bytes = {}
    for i = 1, 8 do
        bytes[#bytes + 1] = math.floor(headGroups[i] / 256)
        bytes[#bytes + 1] = headGroups[i] % 256
    end
    return bytes
end

---@param w DNSWriter
---@param rtype number
---@param value any
---@return number | nil
local function writeRData(w, rtype, value)
    local startPos = w:pos()
    if rtype == DNS.TYPE_A then
        local b = ipv4ToBytes(value)
        if not b then
            return nil
        end
        w:raw(b)
    elseif rtype == DNS.TYPE_AAAA then
        local b = ipv6ToBytes(value)
        if not b then
            return nil
        end
        w:raw(b)
    elseif rtype == DNS.TYPE_CNAME or rtype == DNS.TYPE_NS or rtype == DNS.TYPE_PTR then
        w:name(value)
    elseif rtype == DNS.TYPE_MX then
        local pref = value.preference or value[1] or 10
        local exch = value.exchange or value[2]
        if not exch then
            return nil
        end
        w:u16(pref)
        w:name(exch)
    elseif rtype == DNS.TYPE_TXT then
        local txts = type(value) == "table" and value or { value }
        for _, s in ipairs(txts) do
            local b = util.stringToBytes(s)
            if #b > 255 then
                b = { table.unpack(b, 1, 255) }
            end
            w:byte(#b)
            w:raw(b)
        end
    elseif rtype == DNS.TYPE_SOA then
        w:name(value.mname or value[1])
        w:name(value.rname or value[2])
        w:u32(value.serial or value[3] or 0)
        w:u32(value.refresh or value[4] or 0)
        w:u32(value.retry or value[5] or 0)
        w:u32(value.expire or value[6] or 0)
        w:u32(value.minimum or value[7] or 0)
    else
        return nil
    end
    return w:pos() - startPos
end

---@param w DNSWriter
---@param name string
---@param rtype number
---@param class number
---@param ttl number
---@param value any
local function writeRR(w, name, rtype, class, ttl, value)
    w:name(name)
    w:u16(rtype)
    w:u16(class)
    w:u32(ttl)
    local rdlenPos = w:pos()
    w:u16(0)
    local len = writeRData(w, rtype, value)
    if not len then
        return
    end
    local b = util.packInt(len, 2)
    w.bytes[rdlenPos + 1] = b[1]
    w.bytes[rdlenPos + 2] = b[2]
end

---@alias DNSDatabase table<string, table<number, DNSDbRecord[]>>

---@param db DNSDatabase
---@param name string
---@param rtype number | string
---@param value any
---@param ttl number | nil
---@return boolean
local function addToDb(db, name, rtype, value, ttl)
    name = string.lower(name)
    if type(rtype) == "string" then
        rtype = NAME_TO_TYPE[string.upper(rtype)]
    end
    if not rtype or rtype == DNS.TYPE_ANY then
        return false
    end
    if rtype == DNS.TYPE_A and not ipv4ToBytes(value) then
        return false
    end
    if rtype == DNS.TYPE_AAAA and not ipv6ToBytes(value) then
        return false
    end
    if db[name] == nil then
        db[name] = {}
    end
    if db[name][rtype] == nil then
        db[name][rtype] = {}
    end
    db[name][rtype][#db[name][rtype] + 1] = { ttl = ttl or 300, value = value }
    return true
end

---@param records DNSRecord[]
---@return DNSDatabase
local function loadRecords(records)
    local db = {}
    for _, rec in ipairs(records) do
        addToDb(db, rec.name, rec.type, rec.value, rec.ttl)
    end
    return db
end

---@param db DNSDatabase
---@param name string
---@param rtype number
---@return DNSDbRecord[]
local function getByType(db, name, rtype)
    local byName = db[name]
    if not byName then
        return {}
    end
    return byName[rtype] or {}
end

---@param db DNSDatabase
---@param qname string
---@param qtype number
---@return DNSResourceRecord[], boolean
local function resolveName(db, qname, qtype)
    local answers = {}

    if qtype == DNS.TYPE_ANY then
        local byName = db[qname]
        if byName then
            for rtype, recs in pairs(byName) do
                for _, r in ipairs(recs) do
                    answers[#answers + 1] = { name = qname, type = rtype, class = DNS.CLASS_IN, ttl = r.ttl, value = r.value }
                end
            end
        end
        return answers, byName ~= nil
    end

    if qtype == DNS.TYPE_A or qtype == DNS.TYPE_AAAA then
        local name = qname
        local seen = {}
        for _ = 1, 10 do
            if seen[name] then
                break
            end
            seen[name] = true
            local cnames = getByType(db, name, DNS.TYPE_CNAME)
            if #cnames > 0 then
                for _, r in ipairs(cnames) do
                    answers[#answers + 1] = { name = name, type = DNS.TYPE_CNAME, class = DNS.CLASS_IN, ttl = r.ttl, value = r.value }
                end
                name = string.lower(cnames[1].value)
            else
                local recs = getByType(db, name, qtype)
                for _, r in ipairs(recs) do
                    answers[#answers + 1] = { name = name, type = qtype, class = DNS.CLASS_IN, ttl = r.ttl, value = r.value }
                end
                break
            end
        end
        return answers, db[qname] ~= nil
    end

    local recs = getByType(db, qname, qtype)
    for _, r in ipairs(recs) do
        answers[#answers + 1] = { name = qname, type = qtype, class = DNS.CLASS_IN, ttl = r.ttl, value = r.value }
    end
    return answers, db[qname] ~= nil
end

---@param data string
---@param db DNSDatabase
---@return string | nil
function DNS.buildResponse(data, db)
    local msg = util.stringToBytes(data)
    if #msg < 12 then
        return nil
    end

    local id = util.unpackInt({ msg[1], msg[2] })
    local flags = util.unpackInt({ msg[3], msg[4] })
    local qdcount = util.unpackInt({ msg[5], msg[6] })

    local qr = util.bitAnd(flags, FLAG_QR) ~= 0
    local opcode = math.floor(util.bitAnd(flags, 0x7800) / 0x0800)
    local rd = util.bitAnd(flags, FLAG_RD) ~= 0

    if qr then
        return nil
    end

    local questions = {}
    local rcode = DNS.RCODE_NOERROR

    if qdcount == 0 then
        rcode = DNS.RCODE_FORMERR
    elseif opcode ~= 0 then
        rcode = DNS.RCODE_NOTIMP
    end

    local pos = 13
    for _ = 1, qdcount do
        local name, endPos = DNS.decodeName(msg, pos)
        if not name or not endPos or endPos + 3 > #msg then
            return nil
        end
        pos = endPos
        local qtype = util.unpackInt({ msg[pos], msg[pos + 1] })
        local qclass = util.unpackInt({ msg[pos + 2], msg[pos + 3] })
        pos = pos + 4
        questions[#questions + 1] = { name = string.lower(name), type = qtype, class = qclass }
    end

    local allAnswers = {}
    for _, q in ipairs(questions) do
        local answers, exists = resolveName(db, q.name, q.type)
        for _, a in ipairs(answers) do
            allAnswers[#allAnswers + 1] = a
        end
        if rcode == DNS.RCODE_NOERROR and not exists then
            rcode = DNS.RCODE_NXDOMAIN
        end
    end

    local w = newWriter()
    w:u16(id)
    local respFlags = FLAG_QR + FLAG_AA + FLAG_RA + rcode
    if rd then
        respFlags = respFlags + FLAG_RD
    end
    w:u16(respFlags)
    w:u16(#questions)
    w:u16(#allAnswers)
    w:u16(0)
    w:u16(0)

    for _, q in ipairs(questions) do
        w:name(q.name)
        w:u16(q.type)
        w:u16(q.class)
    end

    for _, a in ipairs(allAnswers) do
        writeRR(w, a.name, a.type, a.class, a.ttl, a.value)
    end

    if #w.bytes > MAX_UDP_SIZE then
        w.bytes[3] = w.bytes[3] + 0x02
        while #w.bytes > MAX_UDP_SIZE do
            table.remove(w.bytes)
        end
    end

    return util.bytesToString(w.bytes)
end

---@class DNSModule
---@field db DNSDatabase
---@field udp UDPModule
---@field sock UDPSocket
---@field addRecord fun(self: DNSModule, name: string, type: string | number, value: any, ttl: number | nil): boolean
---@field removeRecord fun(self: DNSModule, name: string, type: string | number | nil, value: any): void
---@field resolve fun(self: DNSModule, name: string, type: string | number | nil): DNSAnswer[]

---@param ip IPInterface
---@param config DNSConfig | nil
---@return DNSModule
function DNS.new(ip, config)
    config = config or {}
    local udp = UDP.new(ip)
    local port = config.port or 53
    local db = loadRecords(config.records or {})

    local sock = udp:socket()
    sock:setsockname("*", port)

    simpleParallel.add(function()
        while true do
            local data, addr, rport = sock:receivefrom()
            if data then
                local response = DNS.buildResponse(data, db)
                if response then
                    sock:sendto(response, addr, rport)
                end
            end
        end
    end)

    ---@type DNSModule
    local dns = {}
    dns.db = db
    dns.udp = udp
    dns.sock = sock

    function dns:addRecord(name, type, value, ttl)
        return addToDb(self.db, name, type, value, ttl)
    end

    function dns:removeRecord(name, rtype, value)
        name = string.lower(name)
        if rtype and rtype ~= "" then
            if type(rtype) == "string" then
                rtype = NAME_TO_TYPE[string.upper(rtype)]
            end
        end
        local byName = self.db[name]
        if not byName then
            return
        end
        if not rtype then
            self.db[name] = nil
            return
        end
        if not value then
            byName[rtype] = nil
            return
        end
        local recs = byName[rtype]
        if not recs then
            return
        end
        for i = #recs, 1, -1 do
            if recs[i].value == value then
                table.remove(recs, i)
            end
        end
        if #recs == 0 then
            byName[rtype] = nil
        end
        if next(byName) == nil then
            self.db[name] = nil
        end
    end

    function dns:resolve(name, qtype)
        name = string.lower(name)
        if qtype and qtype ~= "" then
            if type(qtype) == "string" then
                qtype = NAME_TO_TYPE[string.upper(qtype)]
            end
            qtype = qtype or DNS.TYPE_A
        else
            qtype = DNS.TYPE_A
        end
        local answers = resolveName(self.db, name, qtype)
        local out = {}
        for _, a in ipairs(answers) do
            out[#out + 1] = { type = TYPE_NAMES[a.type] or a.type, value = a.value, ttl = a.ttl }
        end
        return out
    end

    return dns
end

---@param msg number[]
---@param i number
---@return number
local function u16at(msg, i)
    return msg[i] * 256 + msg[i + 1]
end

---@param msg number[]
---@param i number
---@return number
local function u32at(msg, i)
    return msg[i] * 16777216 + msg[i + 1] * 65536 + msg[i + 2] * 256 + msg[i + 3]
end

---@param bytes number[]
---@return string
local function bytesToIpv6(bytes)
    local groups = {}
    local g = 1
    for i = 1, 16, 2 do
        groups[g] = bytes[i] * 256 + bytes[i + 1]
        g = g + 1
    end
    local bestStart, bestLen = 0, 0
    local i = 1
    while i <= 8 do
        if groups[i] == 0 then
            local j = i
            while j <= 8 and groups[j] == 0 do
                j = j + 1
            end
            if j - i > bestLen then
                bestStart, bestLen = i, j - i
            end
            i = j
        else
            i = i + 1
        end
    end
    if bestLen >= 8 then
        return "::"
    end
    local parts = {}
    if bestLen >= 2 then
        for i = 1, bestStart - 1 do
            parts[#parts + 1] = string.format("%x", groups[i])
        end
        parts[#parts + 1] = ""
        for i = bestStart + bestLen, 8 do
            parts[#parts + 1] = string.format("%x", groups[i])
        end
    else
        for i = 1, 8 do
            parts[#parts + 1] = string.format("%x", groups[i])
        end
    end
    return table.concat(parts, ":")
end

---@param msg number[]
---@param pos number
---@param rdlen number
---@param rtype number
---@return any
local function decodeRData(msg, pos, rdlen, rtype)
    if rtype == DNS.TYPE_A then
        if rdlen ~= 4 then
            return nil
        end
        return msg[pos] .. "." .. msg[pos + 1] .. "." .. msg[pos + 2] .. "." .. msg[pos + 3]
    elseif rtype == DNS.TYPE_AAAA then
        if rdlen ~= 16 then
            return nil
        end
        local bytes = {}
        for i = 0, 15 do
            bytes[#bytes + 1] = msg[pos + i]
        end
        return bytesToIpv6(bytes)
    elseif rtype == DNS.TYPE_CNAME or rtype == DNS.TYPE_NS or rtype == DNS.TYPE_PTR then
        return DNS.decodeName(msg, pos)
    elseif rtype == DNS.TYPE_MX then
        local pref = u16at(msg, pos)
        local exch = DNS.decodeName(msg, pos + 2)
        return { preference = pref, exchange = exch }
    elseif rtype == DNS.TYPE_TXT then
        local txts = {}
        local p = pos
        local endPos = pos + rdlen
        while p < endPos do
            local len = msg[p]
            p = p + 1
            local s = ""
            for i = 0, len - 1 do
                s = s .. string.char(msg[p + i])
            end
            p = p + len
            txts[#txts + 1] = s
        end
        return txts
    elseif rtype == DNS.TYPE_SOA then
        local mname, p1 = DNS.decodeName(msg, pos)
        local rname, p2 = DNS.decodeName(msg, p1)
        if not mname or not rname then
            return nil
        end
        return {
            mname = mname,
            rname = rname,
            serial = u32at(msg, p2),
            refresh = u32at(msg, p2 + 4),
            retry = u32at(msg, p2 + 8),
            expire = u32at(msg, p2 + 12),
            minimum = u32at(msg, p2 + 16),
        }
    end
    return nil
end

---@param data string
---@return DNSResponse | nil
function DNS.parseResponse(data)
    local msg = util.stringToBytes(data)
    if #msg < 12 then
        return nil
    end
    local id = u16at(msg, 1)
    local flags = u16at(msg, 3)
    local qdcount = u16at(msg, 5)
    local ancount = u16at(msg, 7)
    local rcode = flags % 16
    local tc = util.bitAnd(flags, FLAG_TC) ~= 0

    local pos = 13
    for _ = 1, qdcount do
        local name, p = DNS.decodeName(msg, pos)
        if not name then
            return nil
        end
        pos = p + 4
    end

    local function parseRR()
        local name, p = DNS.decodeName(msg, pos)
        if not name then
            return nil
        end
        if p + 9 > #msg then
            return nil
        end
        pos = p
        local rtype = u16at(msg, pos)
        local rclass = u16at(msg, pos + 2)
        local ttl = u32at(msg, pos + 4)
        local rdlen = u16at(msg, pos + 8)
        pos = pos + 10
        if pos + rdlen - 1 > #msg then
            return nil
        end
        local rdataStart = pos
        pos = pos + rdlen
        local value = decodeRData(msg, rdataStart, rdlen, rtype)
        return { name = string.lower(name), type = rtype, class = rclass, ttl = ttl, value = value }
    end

    local answers = {}
    for _ = 1, ancount do
        local rr = parseRR()
        if rr then
            answers[#answers + 1] = rr
        end
    end

    return { id = id, flags = flags, rcode = rcode, tc = tc, answers = answers }
end

---@param name string
---@param qtype number
---@param id number
---@return string
function DNS.buildQuery(name, qtype, id)
    local w = newWriter()
    w:u16(id)
    w:u16(FLAG_RD)
    w:u16(1)
    w:u16(0)
    w:u16(0)
    w:u16(0)
    w:name(name)
    w:u16(qtype)
    w:u16(DNS.CLASS_IN)
    return util.bytesToString(w.bytes)
end

---@class DNSClient
---@field udp UDPModule
---@field query fun(self: DNSClient, name: string, type: string | number | nil, server: string | number | nil): DNSResourceRecord[] | nil, string | nil
---@field resolve fun(self: DNSClient, name: string, server: string | number | nil): string[] | nil, string | nil

---@param ip IPInterface
---@param config DNSClientConfig | nil
---@return DNSClient
function DNS.newClient(ip, config)
    config = config or {}
    local udp = UDP.new(ip)
    local tcpModule = TCP.new(ip)
    local server = config.server and util.toIp(config.server) or nil
    local port = config.port or 53
    local timeout = config.timeout or 5

    local sock = udp:socket()
    sock:setsockname("*", 0)

    local pending = {}
    local nextId = 1

    ---@return number
    local function newId()
        local id = nextId
        nextId = nextId + 1
        if nextId > 65535 then
            nextId = 1
        end
        return id
    end

    simpleParallel.add(function()
        while true do
            local data = sock:receivefrom()
            if data then
                local resp = DNS.parseResponse(data)
                if resp and pending[resp.id] then
                    pending[resp.id].resp = resp
                end
            end
        end
    end)

    ---@param name string
    ---@param qtype number
    ---@param srv number
    ---@return DNSResponse | nil, string | nil
    local function queryUdp(name, qtype, srv)
        local id = newId()
        local query = DNS.buildQuery(name, qtype, id)
        local p = { resp = nil }
        pending[id] = p
        sock:sendto(query, srv, port)
        local startTime = os.clock()
        while p.resp == nil do
            if os.clock() - startTime > timeout then
                pending[id] = nil
                return nil, "timeout"
            end
            sleep(0)
        end
        pending[id] = nil
        return p.resp
    end

    ---@param name string
    ---@param qtype number
    ---@param srv number
    ---@return DNSResponse | nil, string | nil
    local function queryTcp(name, qtype, srv)
        local id = newId()
        local query = DNS.buildQuery(name, qtype, id)
        local tcpSock = tcpModule:socket()
        tcpSock:settimeout(timeout)
        local ok, err = tcpSock:connect(srv, port)
        if not ok then
            tcpSock:close()
            return nil, err or "connect failed"
        end
        local qbytes = util.stringToBytes(query)
        local payload = string.char(math.floor(#qbytes / 256), #qbytes % 256) .. query
        local sent = tcpSock:send(payload)
        if not sent then
            tcpSock:close()
            return nil, "send failed"
        end
        local lenBytes = tcpSock:receive(2)
        if not lenBytes or #lenBytes < 2 then
            tcpSock:close()
            return nil, "receive failed"
        end
        local len = lenBytes:byte(1) * 256 + lenBytes:byte(2)
        local body = tcpSock:receive(len)
        tcpSock:close()
        if not body or #body < len then
            return nil, "receive failed"
        end
        return DNS.parseResponse(body)
    end

    ---@type DNSClient
    local client = {}
    client.udp = udp
    function client:query(name, qtype, srv)
        if type(qtype) == "string" then
            qtype = NAME_TO_TYPE[string.upper(qtype)]
        end
        qtype = qtype or DNS.TYPE_A
        srv = srv or server
        if not srv then
            return nil, "no server"
        end
        srv = util.toIp(srv)
        local resp, err = queryUdp(name, qtype, srv)
        if not resp then
            return nil, err
        end
        if resp.tc then
            resp, err = queryTcp(name, qtype, srv)
            if not resp then
                return nil, err
            end
        end
        if resp.rcode ~= DNS.RCODE_NOERROR then
            return nil, "rcode " .. resp.rcode
        end
        return resp.answers
    end

    function client:resolve(name, srv)
        local answers, err = self:query(name, DNS.TYPE_A, srv)
        if not answers then
            return nil, err
        end
        local out = {}
        for _, a in ipairs(answers) do
            if a.type == DNS.TYPE_A then
                out[#out + 1] = a.value
            end
        end
        if #out == 0 then
            return nil, "no A record"
        end
        return out
    end

    return client
end

return DNS
