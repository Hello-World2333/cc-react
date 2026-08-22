# 移动数据（基站切换）接入

## 概述

在 `docs/lib` 现有网络栈基础上扩展，支持设备在多个基站之间自动无缝切换，
模拟简化版的蜂窝移动数据接入模型。

## 场景模型

```
  基站A ──┐
  基站B ──┼── 同一子网（同一DHCP池）── Internet
  基站C ──┘
     │ (channel: 1, 共享频率)
     ▼
   [设备]  ← 信号最强的基站负责服务
```

- 多台电脑充当**基站（Base Station / eNodeB）**
- 所有基站在**同一 channel** 广播，设备通过信号强度选择最优基站
- 所有基站共享**同一子网**（同一 DHCP 池），设备 IP 在任意基站都有效
- 设备**只有一个无线 Modem**，通过逻辑层区分不同基站

## 核心概念

### 1. Beacon（信标）

基站定期广播 beacon 帧，携带：
- **基站 ID**（senderID，唯一标识）
- **基站名称**（可选，用于 UI 显示）
- **负载信息**（当前服务的设备数，可选）

Beacon 使用链路层自定义 ethertype（`0x88B5`，IEEE 局部实验用），
区别于 IP（`0x0800`）和 ARP（`0x0806`）。

### 2. 信号强度

利用 CC modem_message 事件的 `distance` 字段衡量信号强弱：
- distance 越小 → 信号越强
- 设备维护每个已知基站的最新 distance

### 3. 注册（Association）

设备选择最优基站后，向其发送**注册请求**：
- 基站收到后成为该设备的**服务基站（Serving BS）**
- 基站记录该设备，只有它负责向该设备转发下行数据

### 4. 切换（Handover）

当更强的基站出现时：
1. 设备向新基站发送注册请求
2. 新基站确认后，设备切换完成
3. 旧基站收到通知（或超时）后停止服务该设备

由于 IP 不变（共享子网），**TCP 连接不中断**。

## 帧格式

### Beacon 帧（链路层）

```
[dst_mac: 6B][src_mac: 6B][etype: 2B = 0x88B5]
[payload]:
  [1B] 帧类型 = 0x01 (BEACON)
  [1B] 版本
  [4B] 基站ID
  [2B] 基站名称长度
  [NB] 基站名称 (UTF-8)
  [2B] 当前负载 (服务设备数)
```

### 注册请求（设备 → 基站）

```
[dst_mac: 6B][src_mac: 6B][etype: 2B = 0x88B5]
[payload]:
  [1B] 帧类型 = 0x10 (ASSOC_REQ)
  [4B] 设备ID
  [2B] 设备名称长度
  [NB] 设备名称 (UTF-8)
```

### 注册响应（基站 → 设备）

```
[dst_mac: 6B][src_mac: 6B][etype: 2B = 0x88B5]
[payload]:
  [1B] 帧类型 = 0x11 (ASSOC_RESP)
  [1B] 状态码 (0=接受, 1=拒绝)
  [4B] 基站ID
  [4B] 分配/确认的IP (或0表示使用DHCP)
```

### 注销（设备 → 旧基站）

```
[dst_mac: 6B][src_mac: 6B][etype: 2B = 0x88B5]
[payload]:
  [1B] 帧类型 = 0x12 (DISASSOC)
  [4B] 设备ID
```

## 架构分层

```
┌─────────────────────────────────┐
│         HTTP / TCP / UDP        │  ← 上层协议（不感知切换）
├─────────────────────────────────┤
│              IP                 │  ← 不感知切换（IP不变）
├─────────────────────────────────┤
│         Mobile Layer            │  ← 新增：基站管理 + 切换
│  (beacon扫描 / 注册 / 切换)     │
├─────────────────────────────────┤
│            Link                 │  ← 现有：modem收发
└─────────────────────────────────┘
```

**Mobile Layer** 位于 Link 和 IP 之间，对上层透明：
- IP 层看到的始终是一个逻辑接口（IP 不变）
- Mobile Layer 处理所有基站相关的发现、注册、切换

## 接口设计

### MobileClient（设备侧）

```lua
local Mobile = require('lib/mobile')

local client = Mobile.newClient({
    side = "back",           -- 无线Modem所在side
    channel = 1,             -- 共享channel
    scanInterval = 5,        -- 扫描间隔（秒）
    switchThreshold = 0.5,   -- 信号差阈值：新基站需比当前强0.5以上才切换
    deviceName = "cc-phone", -- 设备名称
})

-- 注册事件回调
client.onSwitch = function(old_bs, new_bs)
    print("切换: " .. old_bs.id .. " -> " .. new_bs.id)
end

client.onAssoc = function(bs)
    print("已连接: " .. bs.name .. " (距离: " .. bs.distance .. ")")
end

client.onDissoc = function()
    print("已断开")
end

-- 获取当前服务基站
local serving = client:getServingBS()
-- 获取所有已知基站
local stations = client:getStations()
```

### BaseStation（基站侧）

```lua
local Mobile = require('lib/mobile')

local bs = Mobile.newBaseStation({
    side = "back",
    channel = 1,
    bsId = nil,              -- nil = 使用os.getComputerID()
    bsName = "Tower-01",
    beaconInterval = 2,      -- beacon广播间隔（秒）
})

-- 获取当前服务的设备列表
local devices = bs:getDevices()

-- 注册事件回调
client.onAssoc = function(device)
    print("设备加入: " .. device.id)
end

client.onDissoc = function(device)
    print("设备离开: " .. device.id)
end
```

## 切换算法

```
周期性扫描 (每 scanInterval 秒):
  1. 收集所有 beacon 中的基站信息 {id, distance, name}
  2. 按 distance 升序排列（信号越强越靠前）
  3. 取最优基站 best
  4. 如果 best != 当前服务基站:
     a. 计算信号差 = current.distance - best.distance
     b. 如果 信号差 > switchThreshold:
        - 向 best 发送注册请求
        - 收到响应后，向旧基站发送注销
        - 更新当前服务基站
```

## 对现有代码的影响

### ip.lua
- **不需要修改**：IP层不感知切换，始终通过同一个逻辑接口收发

### link.lua
- **不需要修改**：底层modem收发不变，Mobile Layer在它之上工作

### 新增 mobile.lua
- 实现 beacon 广播/扫描
- 实现注册/注销协议
- 实现切换逻辑
- 对上层提供一个"虚拟接口"，包装底层的 link 接口

### main.lua（部署）
- 主程序需要根据设备角色（基站/设备）初始化不同的模块
- 基站模式：`Mobile.newBaseStation(...)` + IP栈
- 设备模式：`Mobile.newClient(...)` + IP栈（通过 Mobile 提供的虚拟接口）

## 示例配置

### 基站配置

```lua
local simpleParallel = require("lib.simpleParallel")
local Mobile = require("lib.mobile")
local IP = require("lib.ip")

-- 基站
local bs = Mobile.newBaseStation({
    side = "back",
    channel = 1,
    bsName = "Tower-01",
})

-- 基站同时是路由器，连接上游网络
local ipIface = IP.new({
    mode = "router",
    interfaces = {
        { side = "top", channel = 2, ip = "10.0.0.1", mask = "255.255.255.0" },
        bs:getInterface(),  -- 移动网络接口（连接到channel 1）
    },
})

simpleParallel.start()
```

### 设备配置

```lua
local simpleParallel = require("lib/simpleParallel")
local Mobile = require("lib/mobile")
local IP = require("lib.ip")
local HTTP = require("lib.http")

-- 移动客户端
local mobile = Mobile.newClient({
    side = "back",
    channel = 1,
    scanInterval = 5,
    deviceName = "cc-phone",
})

-- IP层通过Mobile提供的接口
local ipIface = IP.new({
    mode = "host",
    interfaces = {
        mobile:getInterface({ ip = "dynamic", mask = "255.255.255.0" }),
    },
})

ui.setHttpClient(HTTP.newClient(ipIface, { dnsServer = "8.8.8.8" }))

simpleParallel.start()
```

## v1 限制

- 同一channel上的所有modem消息是广播的，基站需要过滤自己的beacon
- 信号强度仅依赖 `distance` 字段，精度有限
- 不支持鉴权/加密（简化模型）
- 切换过程中（注册请求→响应）的短暂期间可能丢包，上层需容忍
- 基站不主动推送切换通知，设备靠超时检测旧基站不可达
