# 网络接入（里程碑 3）

## 概述

`async function` / `async () =>` 编译为**事件驱动状态机**：体部同步执行到第一个 `await`，
之后的所有代码成为续体闭包，等 `await` 的 future 解析后再运行（完全不用原生 Lua 协程）。

`fetch(url, options)` 返回一个 future，请求在**后台 worker**（`ui.start()` 内部组合的
`networkLoop` 循环，独立协程）里执行，UI 事件循环不被阻塞。

## 基本用法

```tsx
const [status, setStatus] = useState('press fetch');

async function fetchHello() {
  setStatus('fetching...');
  const resp = await fetch('http://192.168.1.50:8080/hello');
  if (resp.ok) {
    const msg = resp.json();
    setStatus('hello: ' + msg.msg);
  } else {
    setStatus('error: ' + resp.error);
  }
}

<Button label="Fetch" onClick={fetchHello} />
<Text>{status}</Text>
```

失败（连接失败 / DNS / 未配置）解析为 `{ ok = false, error }` 响应，
直接按 `resp.ok` 分支即可（v1 未编译 await 的 try/catch）。

## useRequest Hook

`useRequest` 封装三态（loading / data / error）：挂载与 `deps` 变化时自动请求，`refetch()` 立即
重发；过期响应（新请求已发起后旧请求才返回）会被丢弃：

```tsx
const req = useRequest(() => fetch('http://192.168.1.50:8080/quote'));
// req.loading / req.data / req.error / req.refetch()
<Text>{req.loading ? 'loading…' : req.error ? req.error : req.data.body}</Text>
```

## 部署配置

部署时主程序要构建网络客户端（见 [deployment.md](deployment.md)）：
`ui.setHttpClient(client)`（docs/lib 的 HTTP client 实例，由主程序构建）；
worker 已内置于 `ui.start()`。

`fetch` 的响应是 docs/lib 的 HTTP 响应（`ok / status / statusText / headers / body`，`text()` / `json()`）；
JSON body 用 `resp.json()`。

## 技术实现

### async 降级（编译器）

`async function` / `async () =>` 编译为普通 Lua 函数：体部同步执行到第一个 `await`，
随后把「await 之后的所有代码」注册为续体闭包（`__await(未来对象, function(值) ... end)`），
函数立即返回自己的 future（`__newFuture()`，结束时 `__resolveFuture(__self, 返回值)`）。
续体内部再遇 `await` 则递归再拆——**纯闭包链，全程不创建原生 Lua 协程**。

### fetch 运行时

`fetch(url, options)` 编译为 `__fetch`——登记一个作业并
`os.queueEvent("ccreact_net_job")` 唤醒网络 worker，返回 future。

worker 是 `__networkLoop` 循环，由 `ui.start()` 内部用 `parallel.waitForAll` 与 UI 循环组合。
worker 阻塞式调用 `docs/lib` 的 HTTP client，完成后**把响应存进运行时共享表（`__netResults[id]`），
事件只携带 job id**（`os.queueEvent("ccreact_net_done", id)`）。

### 网络客户端注入

**HTTP client 实例由主程序构建并传入**（框架不拼 IP 栈——网络配置属于部署环境）。
主程序在 `simpleParallel.start()` **之前**用 `docs/lib` 构建 client，
然后 `ui.setHttpClient(client)`。

未传入时 fetch 解析为 `{ ok = false, error = "http client not set: ..." }`。

## v1 限制

- 每条语句**一个** `await`；`await` 只支持在语句层（变量声明初始化、表达式语句、
  `return await E`），**出现在 if/else 分支内会编译报错**（把 await 提到分支上方即可）；
  循环/switch 本就不在 codegen 支持范围。多级**顺序** await 支持。
- `await` 的 try/catch 未编译：错误处理用 `resp.ok` / `resp.error` 分支。
- async 组件（含 JSX 的 async 函数）编译期报错——组件必须同步返回元素。
- `fetch` 需要主程序构建 docs/lib HTTP client 并传入（`ui.setHttpClient(client)`）；
  worker 已内置于 `ui.start()`（无需额外注册任务）。
- CC 的 `os.queueEvent` 事件参数**携带 function 会变 nil**（真机实测，表内嵌套的函数字段
  同样被丢弃）：fetch 的响应表不经过事件传输（运行时按 job id 存共享表，事件只带 id），
  因此响应上的 `json()` / `text()` 方法可用；自己给 `os.queueEvent` 传含函数的值会踩同样的坑。
- 网络栈（`docs/lib`）的 IP/ARP/DNS 任务必须在 `simpleParallel.start()` 前构造
  （主程序构建 client 时即完成）；`fetch` 只支持 `http://`（docs/lib 现状）。
