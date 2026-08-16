---@diagnostic disable
-- ============================================================================
-- lib/simpleTCP.lua —— 简易并发 TCP 服务器
-- ============================================================================
-- 基于 lib/tcp 的封装，允许用最简单的方式创建一个支持并发的 TCP 服务器。
-- 内部并发处理方式与 lib/http.lua 的服务器部分完全一致：
--
--   * 一个 acceptor 协程负责 sock:accept()，把新连接放入共享队列 pending，
--     然后 os.queueEvent() 唤醒 worker；
--   * 固定数量的 worker 协程（simpleParallel 协程池）先排空 pending 队列，
--     再 os.pullEvent() 等待新连接事件；
--   * 所有阻塞操作（accept / receive / sleep）都发生在 simpleParallel
--     管理的协程中，因此可以安全地 sleep() / os.pullEvent()。千万不要自己
--     coroutine.create + coroutine.resume，在原生协程里调用 sleep() 会直接
--     导致协程退出。
--
-- 用法示例：
--
--   local simpleTCP = require('lib/simpleTCP')
--
--   local server = simpleTCP.new(ip, {
--       port    = 8080,      -- 监听端口（默认 8080）
--       backlog = 16,        -- 未处理连接队列上限（默认 16）
--       timeout = 10,        -- 每个连接的收发超时，秒（默认 10）
--       workers = 8,         -- 并发处理连接的 worker 数量（默认 8）
--       onConnect = function(conn, server)
--           -- 每个连接在一个独立的 worker 协程里执行，可以阻塞读写：
--           local line = conn:receive("*l")
--           if line then
--               conn:send("echo: " .. line .. "\n")
--           end
--           conn:close()     -- 不手动关也可以，handler 返回后会自动关闭
--       end,
--   })
--
--   -- 也可以先创建服务器，之后再注册 handler：
--   -- local server = simpleTCP.new(ip, { port = 8080 })
--   -- server:onConnect(function(conn, server) ... end)
--   -- 或直接传函数：simpleTCP.new(ip, function(conn) ... end)
--
--   simpleParallel.start()   -- 在 startup.lua 中统一启动协程池
--
-- 注意：
--   * 必须在 simpleParallel.start() 之前创建服务器（与 http.lua 相同）。
--   * handler 中抛出的错误无法被本库捕获：捕获需要 pcall 包裹，而
--     receive()/sleep() 在 pcall 内 yield 会跨过 pcall 的 C 边界把协程搞死
--     （见 http.lua 中相关注释），因此错误会直接向上抛出终止整个程序。
--     请在 handler 内部自行处理异常。
--   * server:close() 只停止接受新连接，已注册的 worker 协程会继续存活：
--     它们属于全局协程池的一部分，退出会导致 parallel.waitForAll 结束。
-- ============================================================================

local TCP = require('lib/tcp')
local simpleParallel = require('lib/simpleParallel')

local SimpleTCP = {}

---@class SimpleTCPServer
---@field tcp TCPModule TCP 模块实例
---@field sock TCPSocket 监听 socket
---@field port number 监听端口
---@field timeout number
---@field closed boolean 是否已停止接受新连接
---@field activeConnections number 当前正在处理的连接数
---@field totalConnections number 累计接受的连接数
---@field onConnectHandler fun(conn: TCPSocket, server: SimpleTCPServer): any | nil
---@field onConnect fun(self: SimpleTCPServer, handler: fun(conn: TCPSocket, server: SimpleTCPServer): any): SimpleTCPServer
---@field close fun(self: SimpleTCPServer): void

---@class SimpleTCPConfig
---@field port number | nil
---@field backlog number | nil
---@field timeout number | nil
---@field workers number | nil
---@field onConnect fun(conn: TCPSocket, server: SimpleTCPServer): any | nil

-- 每个服务器使用独立的事件名，避免多个服务器互相唤醒对方空闲的 worker
local nextServerId = 0

---@param ip IPInterface
---@param config SimpleTCPConfig | fun(conn: TCPSocket, server: SimpleTCPServer): any 配置表，或直接传 onConnect 函数
---@return SimpleTCPServer
function SimpleTCP.new(ip, config)
    if type(config) == "function" then
        config = { onConnect = config }
    end
    config = config or {}

    local tcp = TCP.new(ip)
    local port = config.port or 8080
    local backlog = config.backlog or 16
    local timeout = config.timeout or 10
    local workers = config.workers or 8

    ---@type SimpleTCPServer
    local server = {}
    server.tcp = tcp
    server.port = port
    server.timeout = timeout
    server.closed = false
    server.activeConnections = 0
    server.totalConnections = 0
    server.onConnectHandler = config.onConnect

    function server:onConnect(handler)
        self.onConnectHandler = handler
        return self
    end

    local sock = tcp:socket()
    local ok, err = sock:bind("*", port, backlog)
    if not ok then
        error("simpleTCP: failed to listen on port " .. tostring(port) .. ": " .. tostring(err), 2)
    end
    -- 给监听 socket 一个轮询超时：accept() 空闲时会周期性返回 "timeout"，
    -- 使 acceptor 有机会重新检查 server.closed，从而及时响应 server:close()
    sock:settimeout(1)
    server.sock = sock

    -- 共享队列 + 固定 worker 协程池，与 http.lua 服务器部分相同的并发方式。
    -- 注意：os.pullEvent() 会把事件广播给所有消费者，多个 worker 不会争抢
    -- 事件；每个 worker 醒来后先排空 pending（table.remove 不 yield，因此
    -- 同一时刻只有一个 worker 能取到某个连接），取不到再回去等待。
    local pending = {}

    ---@param conn TCPSocket
    local function handleConnection(conn)
        local handler = server.onConnectHandler
        if handler then
            handler(conn, server)
        end
        -- handler 返回后若连接还开着，自动关闭（重复 close 是安全的）
        if not conn.closed then
            conn:close()
        end
        server.activeConnections = math.max(0, server.activeConnections - 1)
    end

    -- acceptor 协程：负责 accept 并放入队列
    nextServerId = nextServerId + 1
    local eventName = "simpleTCP_conn_" .. nextServerId

    simpleParallel.add(function()
        while not server.closed do
            local conn, aerr = sock:accept()
            if conn then
                if server.closed then
                    -- 关闭发生在 accept() 返回之前：丢弃该连接并停止
                    conn:close()
                    break
                end
                conn:settimeout(timeout)
                pending[#pending + 1] = conn
                server.totalConnections = server.totalConnections + 1
                server.activeConnections = server.activeConnections + 1
                os.queueEvent(eventName)
            elseif aerr ~= "timeout" then
                -- accept() 失败且不是轮询超时（如监听 socket 已关闭）：停止
                break
            end
        end
    end)

    -- worker 协程池：先排空队列，再等待新连接事件
    for _ = 1, workers do
        simpleParallel.add(function()
            while true do
                while #pending > 0 do
                    local conn = table.remove(pending, 1)
                    if conn.closed then
                        -- 连接已被对端重置/关闭，无需处理
                        server.activeConnections = math.max(0, server.activeConnections - 1)
                    else
                        handleConnection(conn)
                    end
                end
                os.pullEvent(eventName)
            end
        end)
    end

    function server:close()
        if self.closed then
            return
        end
        self.closed = true
        if self.sock then
            self.sock:close()
        end
    end

    return server
end

SimpleTCP.newServer = SimpleTCP.new

return SimpleTCP
