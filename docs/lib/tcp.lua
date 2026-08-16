---@diagnostic disable
local util = require('lib/util')
local IP = require('lib/ip')
local simpleParallel = require('lib/simpleParallel')
local TCP = {}

TCP.PROTOCOL = 6

local FIN = 0x01
local SYN = 0x02
local RST = 0x04
local PSH = 0x08
local ACK = 0x10

local MSS = 512
local RECV_WINDOW = 65535
local RTO_INIT = 3
local RTO_MAX = 60
local TIME_WAIT_DURATION = 4

---@class TCPAddress
---@field ip number
---@field port number

---@class TCPSegment
---@field seq number
---@field len number
---@field data number[]
---@field flags number
---@field ack number
---@field time number
---@field retries number

---@class TCPSocket
---@field ip IPInterface
---@field localAddr TCPAddress | nil
---@field peer TCPAddress | nil
---@field state string  -- "CLOSED" | "LISTEN" | "SYN_SENT" | "SYN_RECEIVED" | "ESTABLISHED" | "FIN_WAIT_1" | "FIN_WAIT_2" | "CLOSE_WAIT" | "CLOSING" | "LAST_ACK" | "TIME_WAIT"
---@field timeout number | nil
---@field options table<string, any>
---@field iss number
---@field irs number
---@field snd_nxt number
---@field snd_una number
---@field snd_wnd number
---@field rcv_nxt number
---@field inFlight number
---@field sendQueue TCPSegment[]
---@field unacked TCPSegment[]
---@field recvBuffer string
---@field ooo table<number, string>
---@field finReceived boolean
---@field timerRunning boolean
---@field timerStart number
---@field rto number
---@field pending TCPSocket[]
---@field backlog number
---@field timeWaitUntil number
---@field closed boolean
---@field settimeout fun(self: TCPSocket, t: number | nil): void
---@field gettimeout fun(self: TCPSocket): number | nil
---@field setoption fun(self: TCPSocket, opt: string, value: any): void
---@field getoption fun(self: TCPSocket, opt: string): any
---@field setsockname fun(self: TCPSocket, host: string | nil, port: number | nil): number | nil, string | nil
---@field getsockname fun(self: TCPSocket): string | nil, string | nil
---@field getpeername fun(self: TCPSocket): string | nil, string | nil
---@field bind fun(self: TCPSocket, host: string | nil, port: number | nil, backlog: number | nil): number | nil, string | nil
---@field listen fun(self: TCPSocket, backlog: number | nil): number | nil, string | nil
---@field connect fun(self: TCPSocket, host: string | number, port: number | nil): number | nil, string | nil
---@field accept fun(self: TCPSocket): TCPSocket | nil, string | nil
---@field send fun(self: TCPSocket, data: string | number, i: number | nil, j: number | nil): number | nil, string | nil
---@field receive fun(self: TCPSocket, pattern: string | number | nil, prefix: string | nil): string | nil, string | nil
---@field shutdown fun(self: TCPSocket, mode: string | nil): number | nil, string | nil
---@field close fun(self: TCPSocket): void

---@class TCPModule
---@field ip IPInterface
---@field sockets TCPSocket[]
---@field connections table<string, TCPSocket>
---@field listeners table<number, TCPSocket>
---@field nextEphemeralPort number
---@field socket fun(self: TCPModule): TCPSocket

local function generateISN()
    return math.floor(os.clock() * 1000000) % 0x7FFFFFFF
end

---@param src_ip number
---@param dst_ip number
---@param src_port number
---@param dst_port number
---@param seq number
---@param ack number
---@param flags number
---@param window number
---@param data number[]
---@return number[]
function TCP.packSegment(src_ip, dst_ip, src_port, dst_port, seq, ack, flags, window, data)
    data = data or {}
    local packet = {}
    local sp = util.packInt(src_port, 2)
    local dp = util.packInt(dst_port, 2)
    local sq = util.packInt(seq, 4)
    local ak = util.packInt(ack, 4)
    local w = util.packInt(window, 2)

    packet[1] = sp[1]
    packet[2] = sp[2]
    packet[3] = dp[1]
    packet[4] = dp[2]
    packet[5] = sq[1]
    packet[6] = sq[2]
    packet[7] = sq[3]
    packet[8] = sq[4]
    packet[9] = ak[1]
    packet[10] = ak[2]
    packet[11] = ak[3]
    packet[12] = ak[4]
    packet[13] = 5 * 16 -- data offset (5 * 4 = 20 bytes, no options)
    packet[14] = flags
    packet[15] = w[1]
    packet[16] = w[2]
    packet[17] = 0x00 -- checksum placeholder
    packet[18] = 0x00
    packet[19] = 0x00 -- urgent pointer
    packet[20] = 0x00
    for i = 1, #data do
        packet[20 + i] = data[i]
    end

    local pseudo = {}
    local srcb = util.packInt(src_ip, 4)
    local dstb = util.packInt(dst_ip, 4)
    for i = 1, 4 do
        pseudo[i] = srcb[i]
        pseudo[4 + i] = dstb[i]
    end
    pseudo[9] = 0x00
    pseudo[10] = TCP.PROTOCOL
    local lenb = util.packInt(#packet, 2)
    pseudo[11] = lenb[1]
    pseudo[12] = lenb[2]

    local all = {}
    for i = 1, #pseudo do
        all[#all + 1] = pseudo[i]
    end
    for i = 1, #packet do
        all[#all + 1] = packet[i]
    end
    if #all % 2 == 1 then
        all[#all + 1] = 0x00
    end

    local checksum = IP.checksum(all)
    local cb = util.packInt(checksum, 2)
    packet[17] = cb[1]
    packet[18] = cb[2]

    return packet
end

---@param packet number[]
---@return number, number, number, number, number, number, number[]
function TCP.unpackSegment(packet)
    local src_port = util.unpackInt({ packet[1], packet[2] })
    local dst_port = util.unpackInt({ packet[3], packet[4] })
    local seq = util.unpackInt({ packet[5], packet[6], packet[7], packet[8] })
    local ack = util.unpackInt({ packet[9], packet[10], packet[11], packet[12] })
    local data_offset = math.floor(packet[13] / 16)
    local flags = packet[14]
    local window = util.unpackInt({ packet[15], packet[16] })
    local data = {}
    for i = data_offset * 4 + 1, #packet do
        data[#data + 1] = packet[i]
    end
    return src_port, dst_port, seq, ack, flags, window, data
end

---@param ip IPInterface
---@return TCPModule
function TCP.new(ip)
    ---@type TCPModule
    local tcp = {}
    tcp.ip = ip
    tcp.sockets = {}
    tcp.connections = {}
    tcp.listeners = {}
    tcp.nextEphemeralPort = 40000

    ---@param localPort number
    ---@param remoteIp number
    ---@param remotePort number
    ---@return string
    local function connectionKey(localPort, remoteIp, remotePort)
        return math.floor(localPort) .. ":" .. math.floor(remoteIp) .. ":" .. math.floor(remotePort)
    end

    ---@return number
    local function ephemeralPort()
        local p = tcp.nextEphemeralPort
        tcp.nextEphemeralPort = tcp.nextEphemeralPort + 1
        if tcp.nextEphemeralPort > 65535 then
            tcp.nextEphemeralPort = 40000
        end
        return p
    end

    local function newSocket()
        ---@type TCPSocket
        local sock = {}
        sock.ip = ip
        sock.localAddr = nil
        sock.peer = nil
        sock.state = "CLOSED"
        sock.timeout = nil
        sock.options = {}

        sock.iss = 0
        sock.irs = 0
        sock.snd_nxt = 0
        sock.snd_una = 0
        sock.snd_wnd = 65535
        sock.rcv_nxt = 0
        sock.inFlight = 0

        sock.sendQueue = {}
        sock.unacked = {}
        sock.recvBuffer = ""
        sock.ooo = {}
        sock.finReceived = false

        sock.timerRunning = false
        sock.timerStart = 0
        sock.rto = RTO_INIT

        sock.pending = {}
        sock.backlog = 5
        sock.timeWaitUntil = 0
        sock.closed = false

        function sock:advertiseWindow()
            return math.max(0, RECV_WINDOW - #self.recvBuffer)
        end

        function sock:sendSegment(flags, data, seq, ack)
            local src_ip = self.ip:getLocalIp()
            local dst_ip = self.peer.ip
            local seg = TCP.packSegment(src_ip, dst_ip, self.localAddr.port, self.peer.port,
                seq, ack, flags, self:advertiseWindow(), data or {})
            self.ip:send(dst_ip, TCP.PROTOCOL, seg)
        end

        function sock:sendAck()
            self:sendSegment(ACK, {}, self.snd_nxt, self.rcv_nxt)
        end

        function sock:startTimer()
            self.timerRunning = true
            self.timerStart = os.clock()
            self.rto = RTO_INIT
        end

        function sock:resetTimer()
            self.timerRunning = true
            self.timerStart = os.clock()
            self.rto = RTO_INIT
        end

        function sock:clearTimer()
            self.timerRunning = false
        end

        function sock:retransmit()
            if #self.unacked == 0 then
                self.timerRunning = false
                return
            end
            local seg = self.unacked[1]
            seg.retries = seg.retries + 1
            local ack = (util.bitAnd(seg.flags, SYN) ~= 0) and seg.ack or self.rcv_nxt
            self:sendSegment(seg.flags, seg.data, seg.seq, ack)
            seg.time = os.clock()
            self.rto = math.min(self.rto * 2, RTO_MAX)
            self.timerStart = os.clock()
        end

        function sock:removeAcked(ack)
            while #self.unacked > 0 do
                local seg = self.unacked[1]
                if seg.seq + seg.len <= ack then
                    table.remove(self.unacked, 1)
                    self.snd_una = seg.seq + seg.len
                    self.inFlight = self.inFlight - seg.len
                else
                    break
                end
            end
        end

        function sock:processAck(ack)
            if ack > self.snd_una then
                self:removeAcked(ack)
                if #self.unacked > 0 then
                    self:resetTimer()
                else
                    self:clearTimer()
                end
            end
            self:flush()
        end

        function sock:flush()
            while #self.sendQueue > 0 and self.inFlight < self.snd_wnd do
                local seg = table.remove(self.sendQueue, 1)
                self:sendSegment(PSH + ACK, seg.data, seg.seq, self.rcv_nxt)
                seg.time = os.clock()
                seg.retries = 0
                self.unacked[#self.unacked + 1] = seg
                self.inFlight = self.inFlight + seg.len
                if not self.timerRunning then
                    self:startTimer()
                end
            end
        end

        function sock:processData(seq, payload)
            local n = #payload
            if seq == self.rcv_nxt then
                self.recvBuffer = self.recvBuffer .. util.bytesToString(payload)
                self.rcv_nxt = self.rcv_nxt + n
                while self.ooo[self.rcv_nxt] do
                    local d = self.ooo[self.rcv_nxt]
                    self.ooo[self.rcv_nxt] = nil
                    self.recvBuffer = self.recvBuffer .. d
                    self.rcv_nxt = self.rcv_nxt + #d
                end
                self:sendAck()
            elseif seq > self.rcv_nxt then
                self.ooo[seq] = util.bytesToString(payload)
                self:sendAck()
            else
                self:sendAck()
            end
        end

        function sock:startTimeWait()
            self:clearTimer()
            self.timeWaitUntil = os.clock() + TIME_WAIT_DURATION
        end

        function sock:cleanup()
            if self.closed then
                return
            end
            self.closed = true
            self.state = "CLOSED"
            self:clearTimer()
            if self.localAddr and self.peer then
                local key = connectionKey(self.localAddr.port, self.peer.ip, self.peer.port)
                if tcp.connections[key] == self then
                    tcp.connections[key] = nil
                end
            end
            for i = #tcp.sockets, 1, -1 do
                if tcp.sockets[i] == self then
                    table.remove(tcp.sockets, i)
                    break
                end
            end
        end

        function sock:reset()
            self:clearTimer()
            self:cleanup()
        end

        function sock:handleSegment(seq, ack, flags, window, payload)
            local hasSyn = util.bitAnd(flags, SYN) ~= 0
            local hasAck = util.bitAnd(flags, ACK) ~= 0
            local hasFin = util.bitAnd(flags, FIN) ~= 0
            local hasRst = util.bitAnd(flags, RST) ~= 0

            if hasRst then
                self:reset()
                return
            end

            local state = self.state

            if state == "SYN_SENT" then
                if hasSyn then
                    self.irs = seq
                    self.rcv_nxt = seq + 1
                    self.snd_wnd = window
                    if hasAck then
                        self:removeAcked(ack)
                        if ack > self.snd_nxt then
                            self.snd_nxt = ack
                        end
                        self:sendAck()
                        self:clearTimer()
                        self.state = "ESTABLISHED"
                        self:flush()
                    else
                        self:sendAck()
                        self.state = "SYN_RECEIVED"
                    end
                end
                return
            end

            if state == "SYN_RECEIVED" then
                if hasAck then
                    self:removeAcked(ack)
                    if ack > self.snd_nxt then
                        self.snd_nxt = ack
                    end
                    self:clearTimer()
                    self.state = "ESTABLISHED"
                    self:flush()
                end
                return
            end

            if state == "ESTABLISHED" or state == "CLOSE_WAIT" then
                self.snd_wnd = window
                if hasAck then
                    self:processAck(ack)
                end
                if #payload > 0 then
                    self:processData(seq, payload)
                end
                if hasFin then
                    if not self.finReceived then
                        self.rcv_nxt = self.rcv_nxt + 1
                        self.finReceived = true
                    end
                    self:sendAck()
                    self.state = "CLOSE_WAIT"
                end
                return
            end

            if state == "FIN_WAIT_1" then
                self.snd_wnd = window
                if hasAck then
                    self:processAck(ack)
                end
                if #payload > 0 then
                    self:processData(seq, payload)
                end
                if hasFin then
                    if not self.finReceived then
                        self.rcv_nxt = self.rcv_nxt + 1
                        self.finReceived = true
                    end
                    self:sendAck()
                    if hasAck then
                        self.state = "TIME_WAIT"
                        self:startTimeWait()
                    else
                        self.state = "CLOSING"
                    end
                elseif hasAck then
                    self.state = "FIN_WAIT_2"
                end
                return
            end

            if state == "FIN_WAIT_2" then
                self.snd_wnd = window
                if hasAck then
                    self:processAck(ack)
                end
                if #payload > 0 then
                    self:processData(seq, payload)
                end
                if hasFin then
                    if not self.finReceived then
                        self.rcv_nxt = self.rcv_nxt + 1
                        self.finReceived = true
                    end
                    self:sendAck()
                    self.state = "TIME_WAIT"
                    self:startTimeWait()
                end
                return
            end

            if state == "CLOSING" then
                if hasAck then
                    self:clearTimer()
                    self.state = "TIME_WAIT"
                    self:startTimeWait()
                end
                return
            end

            if state == "LAST_ACK" then
                if hasAck then
                    self:clearTimer()
                    self:cleanup()
                end
                return
            end
        end

        function sock:tryRead(pattern)
            if pattern == "*a" then
                if self.finReceived or self.closed then
                    local all = self.recvBuffer
                    self.recvBuffer = ""
                    return all
                end
                return nil
            elseif pattern == "*l" then
                local i = string.find(self.recvBuffer, "\n", 1, true)
                if i then
                    local line = string.sub(self.recvBuffer, 1, i - 1)
                    self.recvBuffer = string.sub(self.recvBuffer, i + 1)
                    if line:sub(-1) == "\r" then
                        line = line:sub(1, -2)
                    end
                    return line
                end
                return nil
            elseif type(pattern) == "number" then
                if #self.recvBuffer >= pattern then
                    local data = string.sub(self.recvBuffer, 1, pattern)
                    self.recvBuffer = string.sub(self.recvBuffer, pattern + 1)
                    return data
                end
                return nil
            else
                return nil, "invalid pattern"
            end
        end

        function sock:settimeout(t)
            self.timeout = t
        end

        function sock:gettimeout()
            return self.timeout
        end

        function sock:setoption(opt, value)
            self.options[opt] = value
        end

        function sock:getoption(opt)
            return self.options[opt]
        end

        function sock:setsockname(host, port)
            if self.closed then
                return nil, "closed"
            end
            local h = host or "*"
            local lip = (h == "*") and self.ip:getLocalIp() or util.toIp(h)
            port = port or 0
            if port == 0 then
                port = ephemeralPort()
            end
            self.localAddr = { ip = lip, port = port }
            return 1
        end

        function sock:getsockname()
            if not self.localAddr then
                return nil, "not bound"
            end
            return util.intToIp(self.localAddr.ip), self.localAddr.port
        end

        function sock:getpeername()
            if not self.peer then
                return nil, "not connected"
            end
            return util.intToIp(self.peer.ip), self.peer.port
        end

        function sock:bind(host, port, backlog)
            local ok, err = self:setsockname(host, port)
            if not ok then
                return nil, err
            end
            return self:listen(backlog)
        end

        function sock:listen(backlog)
            if self.state ~= "CLOSED" then
                return nil, "already bound"
            end
            if not self.localAddr then
                return nil, "not bound"
            end
            self.backlog = backlog or self.backlog
            self.state = "LISTEN"
            tcp.listeners[self.localAddr.port] = self
            tcp.sockets[#tcp.sockets + 1] = self
            return 1
        end

        function sock:connect(host, port)
            if self.state ~= "CLOSED" then
                return nil, "already connected"
            end
            local dst_ip = util.toIp(host)
            port = port or 0
            if not self.localAddr then
                self:setsockname("*", 0)
            end
            self.peer = { ip = dst_ip, port = port }
            self.iss = generateISN()
            self.snd_nxt = self.iss
            self.snd_una = self.iss
            self.state = "SYN_SENT"
            self:sendSegment(SYN, {}, self.iss, 0)
            self.snd_nxt = self.snd_nxt + 1
            self.unacked = { { seq = self.iss, len = 1, data = {}, flags = SYN, ack = 0, time = os.clock(), retries = 0 } }
            self.inFlight = 1
            self:startTimer()
            tcp.connections[connectionKey(self.localAddr.port, dst_ip, port)] = self
            tcp.sockets[#tcp.sockets + 1] = self

            local startTime = os.clock()
            while self.state == "SYN_SENT" do
                if self.timeout == 0 then
                    return nil, "timeout"
                end
                if self.timeout and os.clock() - startTime > self.timeout then
                    return nil, "timeout"
                end
                sleep(0)
            end
            if self.state == "ESTABLISHED" then
                return 1
            end
            return nil, "closed"
        end

        function sock:acceptSyn(src_ip, src_port, seq, window)
            if #self.pending >= self.backlog then
                return
            end
            local child = newSocket()
            child.localAddr = { ip = self.localAddr.ip, port = self.localAddr.port }
            child.peer = { ip = src_ip, port = src_port }
            child.iss = generateISN()
            child.snd_nxt = child.iss
            child.snd_una = child.iss
            child.irs = seq
            child.rcv_nxt = seq + 1
            child.snd_wnd = window
            child.state = "SYN_RECEIVED"
            child:sendSegment(SYN + ACK, {}, child.iss, child.rcv_nxt)
            child.snd_nxt = child.snd_nxt + 1
            child.unacked = { { seq = child.iss, len = 1, data = {}, flags = SYN + ACK, ack = child.rcv_nxt, time = os.clock(), retries = 0 } }
            child.inFlight = 1
            child:startTimer()
            tcp.connections[connectionKey(child.localAddr.port, src_ip, src_port)] = child
            tcp.sockets[#tcp.sockets + 1] = child
            self.pending[#self.pending + 1] = child
        end

        function sock:accept()
            if self.state ~= "LISTEN" then
                return nil, "not listening"
            end
            local startTime = os.clock()
            while true do
                for i = 1, #self.pending do
                    local child = self.pending[i]
                    if child.state == "ESTABLISHED" then
                        table.remove(self.pending, i)
                        return child
                    end
                    if child.closed then
                        table.remove(self.pending, i)
                        break
                    end
                end
                if self.timeout == 0 then
                    return nil, "timeout"
                end
                if self.timeout and os.clock() - startTime > self.timeout then
                    return nil, "timeout"
                end
                sleep(0)
            end
        end

        function sock:send(data, i, j)
            local state = self.state
            if state ~= "ESTABLISHED" and state ~= "CLOSE_WAIT" then
                return nil, "closed"
            end
            if type(data) == "number" then
                data = string.char(data)
            end
            local str = data
            if i then
                str = string.sub(str, i, j)
            end
            local bytes = util.stringToBytes(str)
            local pos = 1
            while pos <= #bytes do
                local len = math.min(MSS, #bytes - pos + 1)
                local chunk = {}
                for k = 1, len do
                    chunk[k] = bytes[pos + k - 1]
                end
                self.sendQueue[#self.sendQueue + 1] = { seq = self.snd_nxt, len = len, data = chunk, flags = PSH + ACK }
                self.snd_nxt = self.snd_nxt + len
                pos = pos + len
            end
            self:flush()
            return #str
        end

        function sock:receive(pattern, prefix)
            local state = self.state
            if state ~= "ESTABLISHED" and state ~= "CLOSE_WAIT" and state ~= "FIN_WAIT_1"
                and state ~= "FIN_WAIT_2" and state ~= "CLOSING" then
                return nil, "closed"
            end
            pattern = pattern or "*l"
            prefix = prefix or ""
            local startTime = os.clock()
            while true do
                local data, err = self:tryRead(pattern)
                if data ~= nil then
                    return prefix .. data
                end
                if err then
                    return nil, err
                end
                if self.closed then
                    if self.recvBuffer ~= "" then
                        local rest = self.recvBuffer
                        self.recvBuffer = ""
                        return nil, "closed", prefix .. rest
                    end
                    return nil, "closed"
                end
                if self.timeout == 0 then
                    return nil, "timeout"
                end
                if self.timeout and os.clock() - startTime > self.timeout then
                    return nil, "timeout"
                end
                sleep(0)
            end
        end

        function sock:sendFin()
            self:sendSegment(FIN, {}, self.snd_nxt, self.rcv_nxt)
            self.unacked[#self.unacked + 1] = { seq = self.snd_nxt, len = 1, data = {}, flags = FIN, ack = self.rcv_nxt, time = os.clock(), retries = 0 }
            self.snd_nxt = self.snd_nxt + 1
            self.inFlight = self.inFlight + 1
            if not self.timerRunning then
                self:startTimer()
            else
                self:resetTimer()
            end
        end

        function sock:shutdown(mode)
            if self.closed then
                return nil, "closed"
            end
            mode = mode or "both"
            if mode == "send" or mode == "both" then
                local state = self.state
                if state == "ESTABLISHED" then
                    self:sendFin()
                    self.state = "FIN_WAIT_1"
                elseif state == "CLOSE_WAIT" then
                    self:sendFin()
                    self.state = "LAST_ACK"
                end
            end
            if mode == "receive" or mode == "both" then
                self.finReceived = true
            end
            return 1
        end

        function sock:close()
            if self.closed then
                return
            end
            local state = self.state
            if state == "LISTEN" then
                if self.localAddr then
                    tcp.listeners[self.localAddr.port] = nil
                end
                self:cleanup()
                return
            end
            if state == "SYN_SENT" or state == "SYN_RECEIVED" then
                self:cleanup()
                return
            end
            if state == "ESTABLISHED" or state == "SYN_RECEIVED" then
                self:sendFin()
                self.state = "FIN_WAIT_1"
                return
            end
            if state == "CLOSE_WAIT" then
                self:sendFin()
                self.state = "LAST_ACK"
                return
            end
            self:cleanup()
        end

        return sock
    end

    simpleParallel.add(function()
        while true do
            local src_ip, protocol, data = ip:recv()
            if protocol == TCP.PROTOCOL then
                local src_port, dst_port, seq, ack, flags, window, payload = TCP.unpackSegment(data)
                local hasSyn = util.bitAnd(flags, SYN) ~= 0
                local listener = tcp.listeners[dst_port]
                if listener and hasSyn then
                    listener:acceptSyn(src_ip, src_port, seq, window)
                else
                    local sock = tcp.connections[connectionKey(dst_port, src_ip, src_port)]
                    if sock then
                        sock:handleSegment(seq, ack, flags, window, payload)
                    end
                end
            end
        end
    end)

    simpleParallel.add(function()
        while true do
            local now = os.clock()
            for i = #tcp.sockets, 1, -1 do
                local sock = tcp.sockets[i]
                if sock.state == "TIME_WAIT" then
                    if now >= sock.timeWaitUntil then
                        sock:cleanup()
                    end
                elseif sock.timerRunning and now - sock.timerStart >= sock.rto then
                    sock:retransmit()
                end
            end
            sleep(0.1)
        end
    end)

    ---@return TCPSocket
    function tcp:socket()
        return newSocket()
    end

    return tcp
end

return TCP
