# 部署

编译产物是**模块**而非独立程序：它导出 `start(side)` 任务函数，由主程序通过
[simpleParallel](https://tweaked.cc/module/parallel.html)（`parallel.waitForAll` 封装）调度，
从而与网络任务（`docs/lib/` 网络栈）并发运行。

## 文件拷贝

把下列文件通过 SFTP 拷进游戏存档的电脑目录（`saves/<存档>/computers/<id>/`）：

```
ui.lua      ← dist/ui.lua           编译产物
main.lua    ← demo/main.lua         主程序（或自己写）
lib/        ← simpleParallel.lua + 网络栈（docs/lib；simpleParallel 来自网络栈 lib）
```

## 运行

在游戏内运行：

```bash
lua main.lua left
```

`left` 是 GPU 外设所在的 side（默认 `left`）。

## 主程序模板

主程序负责构建网络客户端（IP 栈配置），实例传给 UI 模块；`ui.start()` 内部已组合 fetch 的
worker 循环（`networkLoop`），**只需添加一个任务**：

```lua
local simpleParallel = require("lib.simpleParallel")
local ui = require("ui")

-- 网络（里程碑 3）：主程序用 docs/lib 构建 HTTP client（IP 栈 + 可选 DNS），
-- 传给 ui.setHttpClient()。client 必须在 simpleParallel.start() 之前构建
-- （栈自身的 ARP/DNS 收包任务在构造时注册）。没有网卡时构建失败，应用里的
-- fetch 会把错误显示在屏幕上。
local IP = require("lib.ip")
local HTTP = require("lib.http")
local ipIface = IP.new({
  mode = "host",
  interfaces = {
    { side = "back", channel = 1, ip = "192.168.1.10", mask = "255.255.255.0", gateway = "192.168.1.1" },
  },
})
ui.setHttpClient(HTTP.newClient(ipIface, { dnsServer = "8.8.8.8", timeout = 10 }))

-- 中文渲染（可选）：指向电脑磁盘上的二进制字库文件（format v1，见「中文渲染」）。
-- 在 simpleParallel.start() 之前调用；不调用则保持默认 5x8 ASCII 字体。
-- ui.setChineseFont("hanchan16-common.fnt")

simpleParallel.add(function() ui.start("left") end)   -- UI + fetch worker
simpleParallel.start()
```

## 显示器要求

UI 任务在 `os.pullEvent` 处让出调度器，因此 UI 渲染不阻塞其他任务；CC 会把每个事件
广播给所有消费者（无争抢），`simpleParallel.start()` 首次会以空事件启动每个任务，
所以首帧在第一个事件到来前就已渲染。屏幕至少需要 **3 块横向拼接的显示器**
（192px 宽；示例的完整界面在 3×4 = 192×256 上最佳，基础界面（含输入框）在 3×3 上即可）。

## 任务调度说明

- `simpleParallel` 封装了 `parallel.waitForAll`，支持非阻塞调度
- UI 任务在 `os.pullEvent` 处让出调度器，因此与网络栈任务并发、互不阻塞
- CC 的 `parallel.waitForAll` 首轮以空事件 resume 每个任务（首帧在首个事件前渲染）
- 网络栈（`docs/lib`）的 IP/ARP/DNS 任务必须在 `simpleParallel.start()` 前构造（主程序构建 client 时即完成）

## 移动数据（基站切换）

`docs/lib/mobile.lua` 支持多基站覆盖下的设备自动切换。部署时需要区分**基站**和**设备**两种角色。

### 基站主程序

基站电脑充当接入点，定期广播 beacon，接收设备注册请求：

```lua
local simpleParallel = require("lib.simpleParallel")
local Mobile = require("lib.mobile")
local IP = require("lib.ip")
local HTTP = require("lib.http")

-- 基站：在 channel 1 上广播 beacon，同时作为路由器连接上游网络
local bs = Mobile.newBaseStation({
    side = "back",
    channel = 1,
    bsName = "Tower-01",
})

bs.onAssoc = function(device)
    print("设备加入: " .. device.name .. " (ID: " .. device.id .. ")")
end
bs.onDissoc = function(device)
    print("设备离开: " .. device.name)
end

-- 基站同时是路由器：上游有线 + 下行无线移动网络
local ipIface = IP.new({
    mode = "router",
    interfaces = {
        { side = "top", channel = 2, ip = "10.0.0.1", mask = "255.255.255.0" },
        { side = "back", channel = 1, ip = "192.168.1.1", mask = "255.255.255.0" },
    },
})

simpleParallel.start()
```

### 设备主程序

设备自动扫描基站，选择信号最强的注册，切换时 IP 不变：

```lua
local simpleParallel = require("lib.simpleParallel")
local Mobile = require("lib.mobile")
local IP = require("lib.ip")
local HTTP = require("lib.http")
local ui = require("ui")

-- 移动客户端
local mobile = Mobile.newClient({
    side = "back",
    channel = 1,
    scanInterval = 5,       -- 每 5 秒扫描一次
    switchThreshold = 0.5,  -- 信号差超过 0.5 才切换
    deviceName = "cc-phone",
})

mobile.onAssoc = function(bs)
    print("已连接: " .. bs.name .. " (距离: " .. bs.distance .. ")")
end
mobile.onSwitch = function(oldBs, newBs)
    print("切换: " .. oldBs.name .. " -> " .. newBs.name)
end
mobile.onDissoc = function()
    print("已断开所有基站")
end

-- IP 层：通过 mobile:getInterface() 获取接口配置
local ipCfg = mobile:getInterface({ ip = "dynamic", mask = "255.255.255.0" })
local ipIface = IP.new({
    mode = "host",
    interfaces = { ipCfg },
})
ui.setHttpClient(HTTP.newClient(ipIface, { dnsServer = "8.8.8.8" }))

simpleParallel.add(function() ui.start("left") end)
simpleParallel.start()
```
