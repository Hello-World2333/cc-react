# cc-react

用 React 组件（`.tsx`）为 [CC: Tweaked](https://tweaked.cc/) 电脑编写 UI 的框架：
`.tsx` 经自研编译器降级为 Lua，显示输出走 [Tom's Peripherals](https://github.com/tom5454/Toms-Peripherals/wiki/) 的 GPU（像素 framebuffer）。

架构设计见 [docs/architecture.md](docs/architecture.md)，Tom's Peripherals GPU 的 API 契约（坐标/颜色/
字体度量/启动顺序等，经 1.3.1 字节码验证）见 [docs/toms-gpu-api.md](docs/toms-gpu-api.md)。
**当前状态：MVP 已实现**，满足 §14 两条验收标准：静态页面渲染 + 交互/脏矩形重绘闭环；
多文件 `import` 已支持（应用可拆多个 `.tsx`/`.ts` 文件，编译期打包进单个 Lua 模块）；
里程碑 1「键盘输入 + 焦点管理」已实现（`<Input>` 文本框 + 点击聚焦 / Tab 切换 + 光标闪烁）；
**里程碑 3「网络接入」已实现**：`async/await` 编译为事件驱动状态机 + `fetch`（复用 `docs/lib`
HTTP 客户端，后台任务执行）+ `useRequest`（loading/data/error 三态）。
编译产物为**模块**（`start(side)` 任务函数），由主程序经 simpleParallel 非阻塞调度
（与网络任务 `networkLoop()` 并发）。

## 目录

```
compiler/          JSX → Lua 编译器（esbuild 打包+擦类型 → @babel/parser AST → codegen）
runtime/           框架运行时（hooks 状态槽、flexbox 布局、脏矩形渲染、事件路由、焦点模型、GPU 适配）
framework/         全局 TS 类型声明（useState/useEffect/render 与 JSX 组件类型）
demo/App.tsx       演示入口（计数器 + 条件徽章 + 动态列表 + 键盘输入，import 多个组件文件）
demo/components/   演示组件（Header / CounterControls / Badge / HistoryList）
demo/main.lua      演示主程序（require 编译产物，经 simpleParallel 非阻塞调度 UI 任务）
scripts/           无头测试（stub GPU + CC 环境：验收标准 + 模块/并行契约 + 多文件 import + 滚动 + 键盘输入 + 网络用例）
dist/ui.lua        编译产物（模块：require 后由主程序组合调度，拷进电脑即可用）
```

## 快速开始

```bash
npm install        # esbuild + @babel/parser + typescript
npm run build      # demo/App.tsx -> dist/ui.lua（模块形态）
npm run test       # luac 语法检查 + 无头测试（stub GPU + 并行调度）
npm run test:all   # typecheck + build + test
```

## 部署

编译产物是**模块**而非独立程序：它导出 `start(side)` 任务函数，由主程序通过
[simpleParallel](https://tweaked.cc/module/parallel.html)（`parallel.waitForAll` 封装）调度，
从而与网络任务（`docs/lib/` 网络栈 + 模块的 `networkLoop()`）并发运行。把下列文件通过 SFTP 拷进
游戏存档的电脑目录（`saves/<存档>/computers/<id>/`）：

```
ui.lua      ← dist/ui.lua           编译产物
main.lua    ← demo/main.lua         主程序（或自己写）
lib/        ← simpleParallel.lua + 网络栈（docs/lib；simpleParallel 来自网络栈 lib）
```

然后在游戏内运行：

```
lua main.lua left
```

`left` 是 GPU 外设所在的 side（默认 `left`）。主程序里就是简单的任务组合：

```lua
local simpleParallel = require("lib.simpleParallel")
local ui = require("ui")

-- 网络（里程碑 3）：配置 IP 栈（必须在 simpleParallel.start() 之前——栈自身的
-- ARP/DNS 收包任务在构造时注册），然后 networkLoop() 作为 fetch 的 worker 任务。
-- 没有网卡时 configureNetwork 记录错误，应用里的 fetch 会把错误显示在屏幕上。
ui.configureNetwork({
  interfaces = {
    { side = "back", channel = 1, ip = "192.168.1.10", mask = "255.255.255.0", gateway = "192.168.1.1" },
  },
  dns = "8.8.8.8",   -- 可选：fetch URL 用域名时需要
  timeout = 10,      -- HTTP 超时（秒）
})

simpleParallel.add(function() ui.start("left") end)   -- UI 任务
simpleParallel.add(function() ui.networkLoop() end)   -- fetch worker（网络任务）
simpleParallel.start()
```

UI 任务在 `os.pullEvent` 处让出调度器，因此 UI 渲染不阻塞其他任务；CC 会把每个事件
广播给所有消费者（无争抢），`simpleParallel.start()` 首次会以空事件启动每个任务，
所以首帧在第一个事件到来前就已渲染。屏幕至少需要 **3 块横向拼接的显示器**
（192px 宽；示例的完整界面在 3×4 = 192×256 上最佳，基础界面（含输入框）在 3×3 上即可）。

## 写一个应用

作者模型不变：`.tsx` 里定义组件，`render(<App/>)` 挂载根组件；编译产物是模块，
GPU 初始化与事件循环都在 `start(side)` 里（由主程序经 simpleParallel 调用）。
应用可以按正常 React 习惯拆成多个文件：编译器在编译期把整个应用（`import`/`export`）
**打包**进同一个 Lua 模块，部署仍只拷一个 `ui.lua`。

```tsx
function App() {
  const [count, setCount] = useState(0);

  useEffect(() => {
    // 只在 count 变化后触发
  }, [count]);

  return (
    <Panel style={{ width: '100%', height: '100%', flexDirection: 'column',
                   alignItems: 'center', justifyContent: 'center',
                   backgroundColor: '#131318', padding: 10 }}>
      <Text style={{ fontSize: 3, color: '#ffffff' }}>cc-react</Text>
      <Text style={{ fontSize: 2, color: '#ffd866' }}>Count: {count}</Text>
      <Box style={{ flexDirection: 'row', gap: 8 }}>
        <Button label="+" style={{ width: 40, height: 40 }} onClick={() => setCount(count + 1)} />
      </Box>
    </Panel>
  );
}

render(<App />);
```

### 多文件（import / export）

组件、工具函数、常量可以放在各自的文件里，用普通 `import` / `export` 组织（与
`demo/` 的拆分方式一致）。编译器在 esbuild 层打包，Lua 产物仍是**单个模块**：

```tsx
// components/Header.tsx
export function Header({ title }: { title: string }) {
  return <Text style={{ fontSize: 3 }}>{title}</Text>;
}

// lib/format.ts —— 纯 .ts 工具模块（无 JSX）
export const ACCENT = '#7ec8ff';
export function pad(n: number): string { return String(n); }

// App.tsx（入口，含 render）
import { Header } from './components/Header';
import { pad } from './lib/format';

function App() {
  const [n, setN] = useState(0);
  return (
    <Panel style={{ backgroundColor: '#131318' }}>
      <Header title="cc-react" />
      <Button label="+" onClick={() => setN(n + 1)} />
      <Text style={{ color: ACCENT }}>{pad(n)}</Text>
    </Panel>
  );
}

render(<App />);
```

支持范围：命名/默认导出、跨文件 props（含事件回调）、跨文件 hooks、`.ts` 工具模块
（常量/纯函数）、`import { X as Y }` 别名。两个文件导出**同名组件**时打包器会自动改名，
两者互不干扰。颜色常量可从其他文件导入（`#rgb` / `#rrggbb` / `#aarrggbb` 在运行时解析）。

### 键盘输入（Input + 焦点管理）

`<Input>` 是**受控**组件：文本存在 app 的 `useState` 里，`onChange` 回传每次编辑后的新值；
内置编辑（光标插入/删除、方向键、粘贴）都走 `onChange`，Enter 触发 `onSubmit`：

```tsx
function Login() {
  const [name, setName] = useState('');

  return (
    <Panel style={{ backgroundColor: '#131318', padding: 10, flexDirection: 'column' }}>
      <Text style={{ color: '#8a8a95' }}>name:</Text>
      <Input
        value={name}
        onChange={setName}
        placeholder="type your name"
        style={{ width: 180, height: 24, marginTop: 4 }}
        onSubmit={() => print('hello ' + name)}
      />
    </Panel>
  );
}
```

点击输入框聚焦（光标定位到点击处，边框变为 `focusBorderColor`，光标闪烁）；
Tab / Shift+Tab 在输入框之间循环焦点；点击输入框以外的区域失焦。
`onKey(key, isUp)` 可拿到原始按键（**GLFW 键码**，Tom's 键盘透传 Minecraft 键码：
Enter 257 / Tab 258 / Backspace 259 / Delete 261 / Left 263 / Right 262 / Home 268 / End 269）。

### 网络（async/await + fetch + useRequest，里程碑 3）

`async function` / `async () =>` 编译为**事件驱动状态机**：体部同步执行到第一个 `await`，
之后的所有代码成为续体闭包，等 `await` 的 future 解析后再运行（完全不用原生 Lua 协程）。
`fetch(url, options)` 返回一个 future，请求在**后台任务**（主程序的 `ui.networkLoop()`）里执行，
UI 事件循环不被阻塞；失败（连接失败 / DNS / 未配置）解析为 `{ ok = false, error }` 响应，
直接按 `resp.ok` 分支即可（v1 未编译 await 的 try/catch）：

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

`useRequest` 封装三态（loading / data / error）：挂载与 `deps` 变化时自动请求，`refetch()` 立即
重发；过期响应（新请求已发起后旧请求才返回）会被丢弃：

```tsx
const req = useRequest(() => fetch('http://192.168.1.50:8080/quote'));
// req.loading / req.data / req.error / req.refetch()
<Text>{req.loading ? 'loading…' : req.error ? req.error : req.data.body}</Text>
```

部署时主程序要配置网络栈并注册 worker（见「部署」）：`ui.configureNetwork({...})` +
`simpleParallel.add(function() ui.networkLoop() end)`。`fetch` 的响应是 docs/lib 的 HTTP 响应
（`ok / status / statusText / headers / body`，`text()` / `json()`）；JSON body 用 `resp.json()`。

### 支持范围（MVP）

- 组件：`Box` / `Panel` / `Text` / `Button` / `Scroll`（滚动容器，也接受小写 `scroll` 等）/
  `Input`（文本框，里程碑 1）
- hooks：`useState`（含函数式更新）、`useEffect`（依赖数组比对）
- 布局：flexbox 子集 —— `flexDirection`（默认 column）、`justifyContent`、`alignItems`（含 stretch）、
  `gap`、`margin` / `padding`（数值或四边对象，支持 `marginTop` 等单边）、固定尺寸 / 内容尺寸 / `width: '100%'`
- 颜色：`#rgb` / `#rrggbb` / `#aarrggbb`，编译期转 ARGB
- 事件：`tm_monitor_touch`（普通屏点击）与 `tm_monitor_mouse_click/up`（Bitmap 屏，含按下视觉反馈）
- 键盘输入 + 焦点管理（里程碑 1）：`<Input>` 文本框 —— 受控 `value` + `onChange`（app 持有文本）、
  `placeholder` 占位、内置编辑（字符插入/删除、Backspace/Delete、方向键/Home/End、Enter 触发 `onSubmit`、
  `tm_keyboard_paste` 粘贴）、点击聚焦并把光标定位到点击处、Tab/Shift+Tab 在输入框间循环焦点、
  点击空白失焦、焦点边框 + 闪烁光标（`os.startTimer` 驱动）；长文本**裁剪到内容盒并随光标
  自动水平滚动**（真实输入框行为）；键盘事件走 Tom's Peripherals 的
  `tm_keyboard_key` / `tm_keyboard_key_up` / `tm_keyboard_char` / `tm_keyboard_paste`
- 滚动：`<Scroll>` 容器 —— 内容按完整尺寸布局、视口裁剪（不越界绘制），
  滚轮（`tm_monitor_mouse_scroll`，方向语义与真机一致：向下滚动 dir=+1）与触摸拖拽滚动；
  `scrollStep` 控制步长（默认 8px = 一个 5×8 行）；滚动偏移按路径持久化、两端自动钳制
- JSX 表达式：三元（真值分支）、`&&` / `||`、`.map()`（→ 运行时 `__map`）、数组展开（→ `__arr`）、模板/拼接文本
- 多文件 import：应用可拆成多个 `.tsx` / `.ts` 文件（`import` / `export`），编译期打包进单个 Lua 模块；
  同名组件自动改名、跨文件 hooks/props/常量均可用（见上文「多文件」）；编译产物是模块，
  `start(side)` 作为 simpleParallel 任务被主程序调度（见「部署」）
- 网络（里程碑 3）：`async function` / `async () =>` 编译为事件驱动状态机（`await` → 续体闭包链，
  无原生协程）；`fetch(url, options)` 返回 future（请求在 `networkLoop()` 后台任务执行；
  失败解析为 `{ ok = false, error }`）；`useRequest(fetcher, deps)` 三态 hook（loading/data/error +
  refetch，含过期响应丢弃）；`await` 非 future 值按 JS 语义透传；主程序用
  `ui.configureNetwork(...)` + `simpleParallel.add(ui.networkLoop)` 接线（见「网络」与「部署」）

## 故障排查：真机黑屏（已修复 2025-08）

早期版本在真机上表现为「程序正常运行但完全黑屏」，根因有三，均已修复并验证：

1. **坐标基假设错误**：Tom's Peripherals GPU 的 draw 系列（`filledRectangle` / `drawText` 等）是
   **1-based** 的（从 1.3.1 字节码确认：内部执行 `x-1`，`x<1` 时抛 "Out of boundary"）。
   框架内部与事件一致地使用 1-based 坐标，适配层不再做偏移。
2. **启动顺序**：`refreshSize()` 是**阻塞**的（返回时屏幕已识别）。启动固定按
   `refreshSize()` → `setSize(64)` → `getSize()` 执行，每次启动都重新识别屏幕，屏幕改动后
   重启才能适应；无屏幕时给出明确报错而非黑屏。
3. **Lua nil 空洞**：编译产物中条件渲染产生的 `nil` 会让 `ipairs` 提前停止，导致排在空洞之后的
   兄弟节点（如 Recorded 列表）丢失。`__children` 改为按最大整数键遍历。

另外注意：
- 默认字体为 **5×8**（ascii.bin 头字节 fontHeight=8）；字符间距 1px（padding 默认 1，与模组一致），
  文字高度 = 8px×fontSize；脏矩形各向外扩 2px，避免字形溢出残留（"糊屏"）。
- `drawText` 在文字超出屏幕右/下边缘时也会抛 "Out of boundary"（不裁剪），运行时对越界文字直接跳过。
- `drawText` 的 fg/bg **必须是数字**（nil 会报 `Bad argument #5: (expected Number)`），无背景传 `-1`
  （模组的"无背景"哨兵值）；颜色必须传**有符号 int32**（模组用饱和 `(int)` 转换，无符号值会变成
  0x7FFFFFFE 之类的错误颜色），运行时适配层已统一处理。

若仍有显示问题，用 `scripts/debug_probe.lua` 逐项排查（方法列表 / getSize / fill / 矩形 / 文字 / 坐标基）。

### 已知约定/限制（MVP）

- 帧缓冲坐标约定为 **1-based**（与触摸/鼠标事件一致）；GPU 适配层在调用前统一 `-1`。
  若真机 GPU 的 draw 系列实为 1-based，只需改 `runtime/runtime.lua` 中的 `DRAW_OFFSET = 0`。
- 默认字体按 CC 5×7 计算行高（`fontSize` 为像素倍率）；真实 GPU 字体若有差异会导致轻微垂直偏差。
- 三元表达式降级为 Lua `and/or`：假分支为 `null`/元素时正确；假分支为假值字面量时语义不保真。
- `import` 是**编译期打包**：不支持动态 `import()` / 运行时加载；未被使用的导入会被打包器剔除。
- 无滚动/裁剪：内容超出视口的部分不会绘制，也无法点击。
  **已实现（2025-08）**：`<Scroll>` 容器提供视口裁剪 + 滚轮/拖拽滚动，见「支持范围」。
  已知取舍：滚动内容越过滚动边界的那一行文字会整行出现/消失（字形无法逐像素裁剪，
  纵向按行裁剪）；`scrollStep` 建议设为内容行距（如行高 + gap），滚动时边界行最平滑。
- `useState` 状态按「组件实例 DFS 路径」存放；结构静态时稳定，条件渲染换组件会重置对应槽位（keyed list 里程碑解决）。
- `Input` 的 `value` 是受控的（app 通过 `onChange` 更新）；宽度默认跟随内容
  （value/placeholder 的测量宽度），值变化会改变盒子大小 —— 需要稳定宽度时显式设置 `width`。
- `Input` 对长文本做**真实输入框式处理**：文本被裁剪到内容盒内（不越界绘制），视图随光标
  水平滚动 —— 输入到末尾时文本左移、Home/左移逐步回滚、Backspace 保持文本尾随光标；
  点击映射会按滚动偏移定位到可见字符。光标由 `__layoutInputOffset` 保持在内容盒内。
- 光标闪烁由 `os.startTimer(0.5)` 驱动：输入框聚焦时每 0.5s 产生一次极小脏矩形重绘；
  按键/点击会重置闪烁并重新计时。对性能敏感的场景可在 `onChange` 中自行管理。
- 键盘事件只走 Tom's Peripherals 前缀形态（`tm_keyboard_*`，`fireNativeEvents` 默认 false）；
  原生 `key`/`char` 事件形态未接入。
- 网络（里程碑 3）的 v1 限制：
  - 每条语句**一个** `await`；`await` 只支持在语句层（变量声明初始化、表达式语句、
    `return await E`），**出现在 if/else 分支内会编译报错**（把 await 提到分支上方即可）；
    循环/switch 本就不在 codegen 支持范围。多级**顺序** await 支持。
  - `await` 的 try/catch 未编译：错误处理用 `resp.ok` / `resp.error` 分支。
  - async 组件（含 JSX 的 async 函数）编译期报错——组件必须同步返回元素。
  - `fetch` 需要主程序配置网络（`ui.configureNetwork`）+ 注册 `networkLoop()` 任务；
    未配置时 fetch 解析为 `{ ok = false, error = "network not configured: ..." }`。
  - 网络栈（`docs/lib`）的 IP/ARP/DNS 任务必须在 `simpleParallel.start()` 前构造
    （`configureNetwork` 在 start 前调用即可）；`fetch` 只支持 `http://`（docs/lib 现状）。
