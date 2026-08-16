---@diagnostic disable
local util = require('lib/util')
local TCP = require('lib/tcp')
local simpleParallel = require('lib/simpleParallel')

local HTTP = {}

local CRLF = "\r\n"

local STATUS_REASONS = {
    [100] = "Continue", [101] = "Switching Protocols",
    [200] = "OK", [201] = "Created", [202] = "Accepted", [204] = "No Content",
    [206] = "Partial Content",
    [301] = "Moved Permanently", [302] = "Found", [303] = "See Other",
    [304] = "Not Modified", [307] = "Temporary Redirect", [308] = "Permanent Redirect",
    [400] = "Bad Request", [401] = "Unauthorized", [403] = "Forbidden",
    [404] = "Not Found", [405] = "Method Not Allowed", [408] = "Request Timeout",
    [409] = "Conflict", [413] = "Payload Too Large", [415] = "Unsupported Media Type",
    [418] = "I'm a teapot", [429] = "Too Many Requests",
    [500] = "Internal Server Error", [501] = "Not Implemented",
    [502] = "Bad Gateway", [503] = "Service Unavailable", [504] = "Gateway Timeout",
}

-- ============================== JSON ==============================

local JSON_ESCAPES = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function jsonEncodeString(s)
    return '"' .. (s:gsub('[%z\1-\31\\"]', function(c)
        return JSON_ESCAPES[c] or string.format('\\u%04x', string.byte(c))
    end)) .. '"'
end

---@param v any
---@return string
local jsonEncode
jsonEncode = function(v)
    local t = type(v)
    if v == nil then
        return "null"
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            return "null"
        end
        return tostring(v)
    elseif t == "string" then
        return jsonEncodeString(v)
    elseif t == "table" then
        local isArray = true
        local n = 0
        for k in pairs(v) do
            if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
                isArray = false
                break
            end
            n = n + 1
        end
        if isArray then
            for i = 1, n do
                if v[i] == nil then
                    isArray = false
                    break
                end
            end
        end
        local out = {}
        if isArray then
            for i = 1, n do
                out[i] = jsonEncode(v[i])
            end
            return "[" .. table.concat(out, ",") .. "]"
        else
            for k, val in pairs(v) do
                if type(k) == "string" then
                    out[#out + 1] = jsonEncodeString(k) .. ":" .. jsonEncode(val)
                end
            end
            return "{" .. table.concat(out, ",") .. "}"
        end
    end
    return "null"
end

---@param str string
---@return any
local function jsonDecode(str)
    local pos = 1
    local len = #str

    local function fail(msg)
        error("JSON decode error: " .. msg .. " (at byte " .. pos .. ")", 2)
    end

    local function skipWs()
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == " " or c == "\t" or c == "\n" or c == "\r" then
                pos = pos + 1
            else
                break
            end
        end
    end

    local function parseString()
        pos = pos + 1
        local out = {}
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(out)
            elseif c == "\\" then
                pos = pos + 1
                local e = str:sub(pos, pos)
                pos = pos + 1
                if e == '"' then out[#out + 1] = '"'
                elseif e == "\\" then out[#out + 1] = "\\"
                elseif e == "/" then out[#out + 1] = "/"
                elseif e == "b" then out[#out + 1] = "\b"
                elseif e == "f" then out[#out + 1] = "\f"
                elseif e == "n" then out[#out + 1] = "\n"
                elseif e == "r" then out[#out + 1] = "\r"
                elseif e == "t" then out[#out + 1] = "\t"
                elseif e == "u" then
                    local hex = str:sub(pos, pos + 3)
                    pos = pos + 4
                    out[#out + 1] = string.char(tonumber(hex, 16))
                else
                    fail("bad escape '\\" .. e .. "'")
                end
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end
        fail("unterminated string")
    end

    local function parseNumber()
        local start = pos
        while pos <= len and str:sub(pos, pos):find("[%d%+%-%.eE]") do
            pos = pos + 1
        end
        local v = tonumber(str:sub(start, pos - 1))
        if v == nil then
            fail("bad number")
        end
        return v
    end

    local parseValue

    local function parseObject()
        pos = pos + 1
        local obj = {}
        skipWs()
        if str:sub(pos, pos) == "}" then
            pos = pos + 1
            return obj
        end
        while true do
            skipWs()
            if str:sub(pos, pos) ~= '"' then
                fail("expected object key")
            end
            local key = parseString()
            skipWs()
            if str:sub(pos, pos) ~= ":" then
                fail("expected ':'")
            end
            pos = pos + 1
            obj[key] = parseValue()
            skipWs()
            local c = str:sub(pos, pos)
            if c == "," then
                pos = pos + 1
            elseif c == "}" then
                pos = pos + 1
                return obj
            else
                fail("expected ',' or '}'")
            end
        end
    end

    local function parseArray()
        pos = pos + 1
        local arr = {}
        skipWs()
        if str:sub(pos, pos) == "]" then
            pos = pos + 1
            return arr
        end
        while true do
            arr[#arr + 1] = parseValue()
            skipWs()
            local c = str:sub(pos, pos)
            if c == "," then
                pos = pos + 1
            elseif c == "]" then
                pos = pos + 1
                return arr
            else
                fail("expected ',' or ']'")
            end
        end
    end

    parseValue = function()
        skipWs()
        local c = str:sub(pos, pos)
        if c == '"' then
            return parseString()
        elseif c == "{" then
            return parseObject()
        elseif c == "[" then
            return parseArray()
        elseif c == "t" then
            pos = pos + 4
            return true
        elseif c == "f" then
            pos = pos + 5
            return false
        elseif c == "n" then
            pos = pos + 4
            return nil
        else
            return parseNumber()
        end
    end

    return parseValue()
end

HTTP.jsonEncode = jsonEncode
HTTP.jsonDecode = jsonDecode

-- ============================== URL ==============================

---@param s string
---@return string
local function urlDecode(s)
    s = s:gsub("+", " ")
    s = s:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
    return s
end

---@param s string
---@return string
local function urlEncode(s)
    return (s:gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

---@param s string
---@param m number 取模基数（地址数量），要求 m >= 1 且 gcd(m, 1009) == 1
---@return number 0 <= 返回值 < m
local function hashString(s, m)
    -- 多项式滚动哈希，直接对 m 取模：h = (h * 1009 + byte) % m。
    -- 乘子 1009 是素数，与任何现实的地址数量（< 1009）互素，因此路径中
    -- 任意位置单个字节的变化都会贡献 delta * 1009^k (mod m)，是字节值的
    -- 一一映射——只差一个字节的路径也会均匀散开。相比之下，先算 32 位哈希
    -- 再对 m 取模容易塌缩（例如 djb2 的乘子 33 能被 3 整除；65599^2 mod 2^32
    -- 也能被 3 整除，导致单字节差异的路径全部落到同一后端）。
    -- 所有中间值 < 1009*m + 255，double 下完全精确。
    local h = 0
    for i = 1, #s do
        h = (h * 1009 + s:byte(i)) % m
    end
    return h
end

---@class ParsedURL
---@field scheme string
---@field host string
---@field port number
---@field path string

---@param url string
---@return ParsedURL
local function parseUrl(url)
    local scheme, rest = url:match("^(%a[%w+%.-]*)://(.*)$")
    if not scheme then
        scheme = "http"
        rest = url
    end
    local host, port, path
    local slash = rest:find("/")
    local authority
    if slash then
        authority = rest:sub(1, slash - 1)
        path = rest:sub(slash)
    else
        authority = rest
        path = "/"
    end
    local hostPort = authority:match("^%[(.*)%]$")
    if hostPort then
        host = hostPort
    else
        host, port = authority:match("^(.-):(%d+)$")
        if not host then
            host = authority
        end
    end
    port = tonumber(port)
    if not port then
        port = (scheme == "https") and 443 or 80
    end
    return { scheme = scheme:lower(), host = host, port = port, path = path }
end

---@param target string
---@return string path
---@return table<string, string> query
local function splitQuery(target)
    local path, queryStr = target, ""
    local q = target:find("?", 1, true)
    if q then
        path = target:sub(1, q - 1)
        queryStr = target:sub(q + 1)
    end
    local query = {}
    if queryStr ~= "" then
        for k, v in queryStr:gmatch("([^&]*)=([^&]*)") do
            query[urlDecode(k)] = urlDecode(v)
        end
    end
    return path, query
end

-- ============================== stream parsing ==============================

---@param sock TCPSocket
---@return string | nil
local function readLine(sock)
    local line = sock:receive("*l")
    if line == nil then
        return nil
    end
    return line
end

---@param sock TCPSocket
---@return string
local function readChunked(sock)
    local out = {}
    while true do
        local line = readLine(sock)
        if line == nil then
            break
        end
        local size = tonumber(line:match("^%x+"))
        if not size or size == 0 then
            while true do
                local l = readLine(sock)
                if l == nil or l == "" then
                    break
                end
            end
            break
        end
        local data = sock:receive(size)
        if data then
            out[#out + 1] = data
        end
        sock:receive(2)
    end
    return table.concat(out)
end

---@param fields table<string, string>
---@param sock TCPSocket
---@return string
local function readBody(fields, sock)
    local te = fields["transfer-encoding"]
    if te and te:lower():find("chunked", 1, true) then
        return readChunked(sock)
    end
    local cl = tonumber(fields["content-length"])
    if cl and cl > 0 then
        return sock:receive(cl) or ""
    end
    if cl then
        return ""
    end
    return sock:receive("*a") or ""
end

---@param sock TCPSocket
---@return string | nil method
---@return string | nil target
---@return string | nil version
---@return table<string, string> | nil fields
---@return string | nil body
local function readRequest(sock)
    local lines = {}
    while true do
        local line = readLine(sock)
        if line == nil then
            return nil
        end
        if line == "" then
            break
        end
        lines[#lines + 1] = line
    end
    if #lines == 0 then
        return nil
    end
    local method, target, version = lines[1]:match("^(%S+) (%S+) HTTP/(%S+)$")
    if not method then
        return nil
    end
    local fields = {}
    for i = 2, #lines do
        local name, value = lines[i]:match("^([^:]+):%s*(.*)$")
        if name then
            fields[string.lower(name)] = value
        end
    end
    local body = readBody(fields, sock)
    return method, target, version, fields, body
end

---@param sock TCPSocket
---@return string | nil version
---@return number | nil status
---@return string | nil reason
---@return table<string, string> | nil fields
---@return string | nil body
local function readResponse(sock)
    local line = readLine(sock)
    if line == nil then
        return nil
    end
    local version, status, reason = line:match("^HTTP/(%S+) (%d+) ?(.*)$")
    if not version then
        return nil
    end
    local fields = {}
    while true do
        local l = readLine(sock)
        if l == nil or l == "" then
            break
        end
        local name, value = l:match("^([^:]+):%s*(.*)$")
        if name then
            fields[string.lower(name)] = value
        end
    end
    local body = readBody(fields, sock)
    return version, tonumber(status), reason, fields, body
end

-- ============================== response (client) ==============================

---@class HTTPResponse
---@field version string | nil
---@field status number | nil
---@field statusText string | nil
---@field headers table<string, string> | nil
---@field body string | nil
---@field ok boolean
---@field text fun(self: HTTPResponse): string | nil
---@field json fun(self: HTTPResponse): any, string | nil

---@param version string | nil
---@param status number | nil
---@param reason string | nil
---@param fields table<string, string> | nil
---@param body string | nil
---@return HTTPResponse
local function newResponse(version, status, reason, fields, body)
    ---@type HTTPResponse
    local resp = {}
    resp.version = version
    resp.status = status
    resp.statusText = reason
    resp.headers = fields
    resp.body = body
    resp.ok = status ~= nil and status >= 200 and status < 300

    function resp:text()
        return body
    end

    function resp:json()
        local ok, v = pcall(jsonDecode, body)
        if ok then
            return v
        end
        return nil, v
    end

    return resp
end

-- ============================== client ==============================

---@class HTTPClientConfig
---@field timeout number | nil
---@field dns DNSClient | nil
---@field dnsServer string | number | nil
---@field resolve (fun(host: string): string | nil, string | nil) | nil
---@field dnsSelect "hash" | "random" | nil  多个 DNS 地址时的选择策略：nil=总是取第一个地址；"hash"=按请求目标哈希取一个；"random"=随机取一个

---@class HTTPClient
---@field tcp TCPModule
---@field fetch fun(self: HTTPClient, url: string, options: HTTPFetchOptions | nil): HTTPResponse | nil, string | nil

---@class HTTPFetchOptions
---@field method string | nil
---@field headers table<string, string> | nil
---@field body string | table | nil

---@param ip IPInterface
---@param config HTTPClientConfig | nil
---@return HTTPClient
function HTTP.newClient(ip, config)
    config = config or {}
    local tcp = TCP.new(ip)
    local timeout = config.timeout or 10

    if not config.dns and config.dnsServer then
        local ok, DNS = pcall(require, 'lib/dns')
        if ok then
            config.dns = DNS.newClient(ip, { server = config.dnsServer, timeout = timeout })
        end
    end

    ---@param host string
    ---@param selectMode string | nil
    ---@param hashKey string | nil
    ---@return string | nil, string | nil
    local function resolveHost(host, selectMode, hashKey)
        if host:match("^%d+%.%d+%.%d+%.%d+$") then
            return host
        end
        if config.resolve then
            return config.resolve(host)
        end
        if config.dns then
            local addrs, err = config.dns:resolve(host)
            if addrs and #addrs > 0 then
                -- 从多个 A 记录中选一个地址（单地址时任何模式都返回 addrs[1]）：
                --   "hash"   : 按请求目标（path + query）的哈希固定选择，同一
                --              请求始终落到同一后端，便于对方服务器负载均衡/会话亲和
                --   "random" : 随机选择
                --   nil/其他 : 总是取第一个地址（旧行为）
                -- 均不做故障切换：连接失败不会回退到其他地址。
                if #addrs == 1 then
                    return addrs[1]
                end
                if selectMode == "hash" and hashKey then
                    return addrs[hashString(hashKey, #addrs) + 1]
                elseif selectMode == "random" then
                    return addrs[math.random(#addrs)]
                end
                return addrs[1]
            end
            if err then
                return nil, err
            end
        end
        return nil, "cannot resolve host: " .. tostring(host)
    end

    ---@type HTTPClient
    local client = {}
    client.tcp = tcp
    function client:fetch(url, options)
        options = options or {}
        local u = parseUrl(url)
        if u.scheme ~= "http" then
            return nil, "unsupported scheme: " .. u.scheme
        end

        local method = (options.method or "GET"):upper()

        -- 多个 DNS 地址时的选择策略：
        --   nil      : 总是取第一个地址（默认）
        --   "hash"   : 按请求目标（path + query）的哈希固定选择
        --   "random" : 随机选择
        local ipAddr, rerr = resolveHost(u.host, config.dnsSelect, config.dnsSelect == "hash" and u.path or nil)
        if not ipAddr then
            return nil, rerr or "resolve failed"
        end

        local headers = {}
        for k, v in pairs(options.headers or {}) do
            headers[string.lower(k)] = v
        end

        local body = options.body
        if body == nil then
            body = ""
        elseif type(body) ~= "string" then
            body = jsonEncode(body)
            if headers["content-type"] == nil then
                headers["content-type"] = "application/json"
            end
        end

        if headers["host"] == nil then
            headers["host"] = u.host
        end
        if headers["connection"] == nil then
            headers["connection"] = "close"
        end
        if headers["content-length"] == nil then
            headers["content-length"] = tostring(#body)
        end

        local sock = tcp:socket()
        sock:settimeout(timeout)
        local ok, cerr = sock:connect(ipAddr, u.port)
        if not ok then
            sock:close()
            return nil, cerr or "connect failed"
        end

        local parts = { method, " ", u.path, " HTTP/1.1", CRLF }
        for k, v in pairs(headers) do
            parts[#parts + 1] = k .. ": " .. v .. CRLF
        end
        parts[#parts + 1] = CRLF
        parts[#parts + 1] = body

        local sent = sock:send(table.concat(parts))
        if not sent then
            sock:close()
            return nil, "send failed"
        end

        local version, status, reason, fields, respBody = readResponse(sock)
        sock:close()
        if not version then
            return nil, "invalid response"
        end
        return newResponse(version, status, reason, fields, respBody)
    end

    return client
end

-- ============================== server ==============================

---@class HTTPRequest
---@field method string
---@field url string
---@field path string
---@field query table<string, string>
---@field headers table<string, string>
---@field body string
---@field version string | nil
---@field params table<string, string>
---@field conn TCPSocket
---@field json fun(self: HTTPRequest): any, string | nil

---@class HTTPResponseWriter
---@field conn TCPSocket
---@field version string
---@field status number
---@field reason string
---@field headers table<string, string>
---@field sent boolean
---@field keepAlive boolean
---@field setStatus fun(self: HTTPResponseWriter, code: number, reason: string | nil): HTTPResponseWriter
---@field setHeader fun(self: HTTPResponseWriter, name: string, value: string): HTTPResponseWriter
---@field getHeader fun(self: HTTPResponseWriter, name: string): string | nil
---@field send fun(self: HTTPResponseWriter, body: string | table | nil): HTTPResponseWriter
---@field json fun(self: HTTPResponseWriter, data: any): HTTPResponseWriter
---@field finish fun(self: HTTPResponseWriter): HTTPResponseWriter

---@param method string
---@param target string
---@param version string | nil
---@param fields table<string, string>
---@param body string
---@param conn TCPSocket
---@return HTTPRequest
local function buildRequest(method, target, version, fields, body, conn)
    local path, query = splitQuery(target)
    ---@type HTTPRequest
    local req = {
        method = method,
        url = target,
        path = path,
        query = query,
        headers = fields,
        body = body,
        version = version,
        params = {},
        conn = conn,
    }

    function req:json()
        local ok, v = pcall(jsonDecode, self.body)
        if ok then
            return v
        end
        return nil, v
    end

    return req
end

---@param conn TCPSocket
---@param version string | nil
---@return HTTPResponseWriter
local function newResponseWriter(conn, version)
    ---@type HTTPResponseWriter
    local res = {}
    res.conn = conn
    res.version = version or "1.1"
    res.status = 200
    res.reason = "OK"
    res.headers = {
        ["content-type"] = "text/plain; charset=utf-8",
        ["connection"] = "close",
        ["server"] = "cc-http/1.1",
    }
    res.sent = false
    res.keepAlive = false

    function res:setStatus(code, reason)
        self.status = code
        self.reason = reason or STATUS_REASONS[code] or "Unknown"
        return self
    end

    function res:setHeader(name, value)
        self.headers[string.lower(name)] = value
        return self
    end

    function res:getHeader(name)
        return self.headers[string.lower(name)]
    end

    function res:send(body)
        if self.sent then
            return self
        end
        self.sent = true
        if body == nil then
            body = ""
        elseif type(body) ~= "string" then
            body = jsonEncode(body)
            if self.headers["content-type"] == nil then
                self.headers["content-type"] = "application/json"
            end
        end
        self.headers["content-length"] = tostring(#body)
        if not self.keepAlive then
            self.headers["connection"] = "close"
        end

        local parts = { "HTTP/", self.version, " ", tostring(self.status), " ", self.reason, CRLF }
        for k, v in pairs(self.headers) do
            parts[#parts + 1] = k .. ": " .. v .. CRLF
        end
        parts[#parts + 1] = CRLF
        parts[#parts + 1] = body

        self.conn:send(table.concat(parts))
        if not self.keepAlive then
            self.conn:close()
        end
        return self
    end

    function res:json(data)
        self:setHeader("content-type", "application/json")
        return self:send(jsonEncode(data))
    end

    function res:finish()
        return self:send("")
    end

    return res
end

---@param p string | nil
---@return string[]
local function splitPath(p)
    local segs = {}
    if p == nil or p == "" or p == "/" then
        return segs
    end
    p = p:gsub("^/", ""):gsub("/$", "")
    for seg in p:gmatch("[^/]+") do
        segs[#segs + 1] = seg
    end
    return segs
end

---@param pattern string
---@param path string
---@return boolean
---@return table<string, string> | nil
local function matchPath(pattern, path)
    if pattern == path then
        return true, {}
    end
    local pSegs = splitPath(pattern)
    local rSegs = splitPath(path)
    local params = {}
    local ri = 1
    for i = 1, #pSegs do
        local ps = pSegs[i]
        if ps == "*" then
            return true, params
        elseif ps:sub(1, 1) == ":" then
            if ri > #rSegs then
                return false, nil
            end
            params[ps:sub(2)] = urlDecode(rSegs[ri])
            ri = ri + 1
        else
            if rSegs[ri] ~= ps then
                return false, nil
            end
            ri = ri + 1
        end
    end
    return ri == #rSegs + 1, params
end

---@class HTTPRoute
---@field method string | nil
---@field pattern string
---@field handler fun(req: HTTPRequest, res: HTTPResponseWriter)

---@class HTTPServer
---@field tcp TCPModule
---@field port number
---@field routes HTTPRoute[]
---@field middlewares fun(req: HTTPRequest, res: HTTPResponseWriter)[]
---@field sock TCPSocket
---@field get fun(self: HTTPServer, path: string, handler: fun(req: HTTPRequest, res: HTTPResponseWriter)): HTTPServer
---@field post fun(self: HTTPServer, path: string, handler: fun(req: HTTPRequest, res: HTTPResponseWriter)): HTTPServer
---@field put fun(self: HTTPServer, path: string, handler: fun(req: HTTPRequest, res: HTTPResponseWriter)): HTTPServer
---@field delete fun(self: HTTPServer, path: string, handler: fun(req: HTTPRequest, res: HTTPResponseWriter)): HTTPServer
---@field route fun(self: HTTPServer, method: string, path: string, handler: fun(req: HTTPRequest, res: HTTPResponseWriter)): HTTPServer
---@field use fun(self: HTTPServer, handler: fun(req: HTTPRequest, res: HTTPResponseWriter)): HTTPServer

---@class HTTPServerConfig
---@field port number | nil
---@field backlog number | nil
---@field timeout number | nil
---@field workers number | nil
---@field onError (fun(err: any): void) | nil

---@param ip IPInterface
---@param config HTTPServerConfig | nil
---@return HTTPServer
function HTTP.new(ip, config)
    config = config or {}
    local tcp = TCP.new(ip)
    local port = config.port or 80
    local backlog = config.backlog or 16
    local timeout = config.timeout or 10
    local workers = config.workers or 8

    ---@type HTTPServer
    local server = {}
    server.tcp = tcp
    server.port = port
    server.routes = {}
    server.middlewares = {}

    ---@param req HTTPRequest
    ---@param res HTTPResponseWriter
    ---@return boolean
    local function dispatch(req, res)
        for _, r in ipairs(server.routes) do
            local okPath, params = matchPath(r.pattern, req.path)
            if okPath and (not r.method or r.method == req.method) then
                req.params = params or {}
                r.handler(req, res)
                return true
            end
        end
        for _, mw in ipairs(server.middlewares) do
            mw(req, res)
            return true
        end
        return false
    end

    ---@param conn TCPSocket
    local function handleConnection(conn)
        local keepAlive
        while true do
            local method, target, version, fields, body = readRequest(conn)
            if not method then
                return
            end
            keepAlive = false
            local connHeader = fields["connection"]
            if connHeader and connHeader:lower():find("keep%-alive", 1, true) then
                keepAlive = true
            end

            local req = buildRequest(method, target, version, fields, body, conn)
            local res = newResponseWriter(conn, version)
            res.keepAlive = keepAlive
            if keepAlive then
                res:setHeader("connection", "keep-alive")
            end

            -- Wrap only the (non-yielding) user handler in pcall: wrapping the
            -- whole request loop would make conn:receive()/sleep() yield across
            -- the pcall C boundary (Lua 5.1) and kill the handler coroutine.
            local okDispatch, handled = pcall(dispatch, req, res)
            if not okDispatch then
                if config.onError then
                    config.onError(handled)
                else
                    print("HTTP error: " .. tostring(handled))
                end
                res:setStatus(500):send("Internal Server Error")
            elseif not handled then
                res:setStatus(404):send("Not Found")
            elseif not res.sent then
                res:send("")
            end

            if not keepAlive then
                return
            end
        end
    end

    local sock = tcp:socket()
    local ok, err = sock:bind("*", port, backlog)
    if not ok then
        error(err)
    end
    server.sock = sock

    -- Shared queue of accepted-but-unhandled connections, plus a fixed pool of
    -- worker coroutines. sleep()/os.pullEvent() only work in coroutines managed
    -- by simpleParallel (parallel.waitForAll), so every blocking read happens
    -- inside a worker. We must NOT spawn handler coroutines with
    -- coroutine.create + coroutine.resume: sleep() would kill them.
    local pending = {}

    simpleParallel.add(function()
        while true do
            local conn = sock:accept()
            if conn then
                conn:settimeout(timeout)
                pending[#pending + 1] = conn
                os.queueEvent("http_conn")
            end
        end
    end)

    for _ = 1, workers do
        simpleParallel.add(function()
            while true do
                -- Drain first: a connection may sit in `pending` while every
                -- worker was busy, so we must not wait for a wake-up event
                -- before checking the queue.
                while #pending > 0 do
                    local conn = table.remove(pending, 1)
                    if not conn.closed then
                        handleConnection(conn)
                    end
                    conn:close()
                end
                os.pullEvent("http_conn")
            end
        end)
    end

    function server:route(method, path, handler)
        self.routes[#self.routes + 1] = { method = method:upper(), pattern = path, handler = handler }
        return self
    end

    function server:get(path, handler)
        return self:route("GET", path, handler)
    end

    function server:post(path, handler)
        return self:route("POST", path, handler)
    end

    function server:put(path, handler)
        return self:route("PUT", path, handler)
    end

    function server:delete(path, handler)
        return self:route("DELETE", path, handler)
    end

    function server:use(handler)
        self.middlewares[#self.middlewares + 1] = handler
        return self
    end

    return server
end

HTTP.newServer = HTTP.new

HTTP.CRLF = CRLF
HTTP.parseUrl = parseUrl
HTTP.urlEncode = urlEncode
HTTP.urlDecode = urlDecode

return HTTP
