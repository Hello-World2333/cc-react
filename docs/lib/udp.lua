---@diagnostic disable
local util = require('lib/util')
local simpleParallel = require('lib/simpleParallel')
local UDP = {}

UDP.PROTOCOL = 17

local UDP_HEADER_SIZE = 8

---@class UDPEntry
---@field data string
---@field ip number
---@field port number

---@class UDPModule
---@field ip IPInterface
---@field sockets table<number, UDPSocket>
---@field nextEphemeralPort number
---@field socket fun(self: UDPModule): UDPSocket

---@class UDPSocket
---@field ip IPInterface
---@field sockname { ip: string, port: number } | nil
---@field peer { ip: number, port: number } | nil
---@field timeout number | nil
---@field recvQueue UDPEntry[]
---@field closed boolean
---@field options table<string, any>
---@field settimeout fun(self: UDPSocket, t: number | nil): void
---@field gettimeout fun(self: UDPSocket): number | nil
---@field setoption fun(self: UDPSocket, opt: string, value: any): void
---@field getoption fun(self: UDPSocket, opt: string): any
---@field setsockname fun(self: UDPSocket, host: string, port: number): number | nil, string | nil
---@field getsockname fun(self: UDPSocket): string | nil, string | nil
---@field setpeername fun(self: UDPSocket, host: string, port: number): number | nil, string | nil
---@field getpeername fun(self: UDPSocket): string | nil, string | nil
---@field sendto fun(self: UDPSocket, datagram: string, host: string | number, port: number): number | nil, string | nil
---@field send fun(self: UDPSocket, datagram: string): number | nil, string | nil
---@field receivefrom fun(self: UDPSocket): string | nil, string | nil, number | nil
---@field receive fun(self: UDPSocket): string | nil, string | nil, number | nil
---@field close fun(self: UDPSocket): void

---@param src_port number
---@param dst_port number
---@param data number[]
---@return number[]
function UDP.packPacket(src_port, dst_port, data)
    local packet = {}
    local src_bytes = util.packInt(src_port, 2)
    local dst_bytes = util.packInt(dst_port, 2)
    local len_bytes = util.packInt(UDP_HEADER_SIZE + #data, 2)

    packet[1] = src_bytes[1]
    packet[2] = src_bytes[2]
    packet[3] = dst_bytes[1]
    packet[4] = dst_bytes[2]
    packet[5] = len_bytes[1]
    packet[6] = len_bytes[2]
    packet[7] = 0x00 -- checksum (0 = none)
    packet[8] = 0x00
    for i = 1, #data do
        packet[i + UDP_HEADER_SIZE] = data[i]
    end
    return packet
end

---@param packet number[]
---@return number, number, number[]
function UDP.unpackPacket(packet)
    local src_port = util.unpackInt({ packet[1], packet[2] })
    local dst_port = util.unpackInt({ packet[3], packet[4] })
    local data = {}
    for i = UDP_HEADER_SIZE + 1, #packet do
        data[#data + 1] = packet[i]
    end
    return src_port, dst_port, data
end

---@param ip IPInterface
---@return UDPModule
function UDP.new(ip)
    ---@type UDPModule
    local udp = {}
    udp.ip = ip
    udp.sockets = {}
    udp.nextEphemeralPort = 40000

    local function ephemeralPort()
        local p = udp.nextEphemeralPort
        udp.nextEphemeralPort = udp.nextEphemeralPort + 1
        if udp.nextEphemeralPort > 65535 then
            udp.nextEphemeralPort = 40000
        end
        while udp.sockets[p] do
            p = udp.nextEphemeralPort
            udp.nextEphemeralPort = udp.nextEphemeralPort + 1
            if udp.nextEphemeralPort > 65535 then
                udp.nextEphemeralPort = 40000
            end
        end
        return p
    end

    simpleParallel.add(function()
        while true do
            local src_ip, protocol, data = ip:recv()
            if protocol == UDP.PROTOCOL then
                local src_port, dst_port, payload = UDP.unpackPacket(data)
                local sock = udp.sockets[dst_port]
                if sock then
                    sock.recvQueue[#sock.recvQueue + 1] = {
                        data = util.bytesToString(payload),
                        ip = src_ip,
                        port = src_port,
                    }
                end
            end
        end
    end)

    function udp:socket()
        ---@type UDPSocket
        local sock = {}
        sock.ip = ip
        sock.sockname = nil
        sock.peer = nil
        sock.timeout = nil
        sock.recvQueue = {}
        sock.closed = false
        sock.options = {}

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
            if self.sockname and udp.sockets[self.sockname.port] == self then
                udp.sockets[self.sockname.port] = nil
            end
            port = port or 0
            if port == 0 then
                port = ephemeralPort()
            end
            self.sockname = { ip = host, port = port }
            udp.sockets[port] = self
            return 1
        end

        function sock:getsockname()
            if not self.sockname then
                return nil, "not bound"
            end
            return util.intToIp(util.toIp(self.sockname.ip)), self.sockname.port
        end

        function sock:setpeername(host, port)
            if self.closed then
                return nil, "closed"
            end
            self.peer = { ip = util.toIp(host), port = port }
            return 1
        end

        function sock:getpeername()
            if not self.peer then
                return nil, "not connected"
            end
            return util.intToIp(self.peer.ip), self.peer.port
        end

        function sock:sendto(datagram, host, port)
            if self.closed then
                return nil, "closed"
            end
            if not self.sockname then
                self:setsockname("*", 0)
            end
            ip:send(util.toIp(host), UDP.PROTOCOL,
                UDP.packPacket(self.sockname.port, port, util.stringToBytes(datagram)))
            return 1
        end

        function sock:send(datagram)
            if not self.peer then
                return nil, "not connected"
            end
            return self:sendto(datagram, self.peer.ip, self.peer.port)
        end

        function sock:receivefrom()
            if self.closed then
                return nil, "closed"
            end
            if not self.sockname then
                self:setsockname("*", 0)
            end
            local startTime = os.clock()
            while true do
                local entry = table.remove(self.recvQueue, 1)
                if entry then
                    return entry.data, util.intToIp(entry.ip), entry.port
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

        function sock:receive()
            if not self.peer then
                return nil, "not connected"
            end
            while true do
                local data, addr, port = self:receivefrom()
                if data == nil then
                    return nil, addr
                end
                if util.toIp(addr) == self.peer.ip and port == self.peer.port then
                    return data, addr, port
                end
            end
        end

        function sock:close()
            if self.closed then
                return
            end
            self.closed = true
            if self.sockname and udp.sockets[self.sockname.port] == self then
                udp.sockets[self.sockname.port] = nil
            end
        end

        return sock
    end

    return udp
end

return UDP
