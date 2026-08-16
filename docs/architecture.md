# cc-react 架构设计

> 状态：设计讨论结论，尚未实现。
> 本文档记录 2025-08 架构讨论的决策与背景，后续实现如有偏离请更新本文档。

> **实现状态（2025-08）：MVP 已完成**，见文末「附录：MVP 实现记录」。§14 两条验收标准均已通过
> 无头测试（`npm run test`）：静态页面渲染 + 交互/脏矩形重绘闭环。

## 1. 项目概述

为 CC: Tweaked 电脑编写 UI 的框架：开发者用 React 组件（`.tsx`）描述界面，经自研编译器生成 CC 可执行的 Lua 代码，显示输出走 Tom's Peripherals 的 GPU。

- 项目仓库：`/home/worker/cc-react`
- 参考文档：
  - CC 电脑（CC: Tweaked）：https://tweaked.cc/
  - Tom's Peripherals：https://github.com/tom5454/Toms-Peripherals/wiki/
  - **GPU API 真机验证版参考**：`docs/toms-gpu-api.md`（坐标/颜色/字体/启动顺序/事件格式）
  - 游戏内网络栈（fetch 等）：`docs/lib/`（link / arp / ip / icmp / ospf / dns / http / simpleTCP / simplePeripheral）

## 2. 目标与硬约束

| 约束 | 说明 |
|---|---|
| CC 电脑性能非常弱 | 禁止在设备端做 VDOM diff、完整运行时解释等重活 |
| GPU 是像素 framebuffer | 不是终端字符屏；支持窗口分层、自定义字体、像素级绘制 |
| 网络栈是现成 Lua | `docs/lib` 已提供完整 TCP/IP 栈与 `fetch`，UI 层与之对接 |
| 单线程事件驱动 | CC 程序围绕 `os.pullEvent` 构建，无抢占式并发 |
| 禁止原生 Lua 协程 | 原生协程中调用 `sleep()` 会导致协程直接退出 |

### CC 事件模型要点（常见误区）

- `os.pullEvent()` / `os.queueEvent()` 会将事件**广播给每一个消费者**，多个消费者不会争抢事件。
- 因此"后台任务完成"可以安全地用自定义事件通知所有订阅者。

## 3. 架构总览

```
.tsx 组件源码
   │  自研编译器（编译期静态化，无运行时 VDOM/diff）
   ▼
Lua 业务代码（绘制指令生成逻辑，静态展开，代码丑没关系）
   │  与框架运行时打包
   ▼
Lua 框架运行时（不可静态化的三块）：
   - flexbox 布局引擎（运行时全量布局）
   - 事件路由（命中测试）
   - hooks 状态槽
   │
   ▼
Tom's Peripherals GPU（像素 framebuffer）
```

产物形态：MVP 之后为**模块**（框架运行时内嵌在模块文件里，`dist/ui.lua`），由主程序
`require` 后经 simpleParallel（`parallel.waitForAll` 封装）调度：`simpleParallel.add(function() ui.start(side) end)`，
与未来的网络任务并发运行；多文件 `import`（TSX 拆多个模块）仍属后续里程碑。

## 4. 决策汇总

| 维度 | 决策 |
|---|---|
| 编译策略 | 编译期静态化（Svelte 式），运行时无 VDOM/diff |
| 状态模型 | React hooks 风格（useState/useEffect），编译降级为状态槽 + 脏标记 |
| 更新粒度 | MVP：整组件重跑 + 指令/布局结果对比；后续按依赖细粒度优化 |
| 重绘 | 脏矩形增量绘制；事件驱动，无事件不重绘 |
| 布局 | CSS 子集（flexbox），运行时全量布局（文本宽度依赖 GPU `getTextLength`） |
| 动画 | 暂不做（未来可能：声明式 transition / timer 帧循环） |
| 列表 | keyed diff 循环（MVP 之外） |
| 异步/网络 | 首版不接网络；未来 async 编译为事件驱动状态机 |
| 工具链 | 自研 JSX→Lua；起步用 esbuild 擦类型，之后 `tsc --noEmit` 补类型检查 |
| 部署 | 用户自行 SFTP 到游戏环境，工具链不管部署 |
| 显示 | `gpu.setSize(64)` 写死分辨率乘数；视口尺寸运行时 `gpu.getSize()` 获取 |
| 里程碑 | 先做框架/组件库 |

## 5. 编译策略：编译期静态化

- 组件 JSX 在**编译期展开**为命令式绘制逻辑（生成绘制指令树），设备端不存在"运行时解释组件"的过程。
- 可接受的代价：生成的 Lua 代码冗长、难以阅读；换来运行时极薄与最优性能。
- 编译器实现路径（MVP → 演进）：
  1. **起步**：esbuild 将 `.tsx` 擦除类型为 `.jsx`，自研转换器用 `@babel/parser` 解析 JSX AST 生成 Lua。
  2. **补检查**：加 `tsc --noEmit` 做完整类型检查（不改动转译路径）。
  3. **演进**：改用 TypeScript compiler API 直接从 TS AST 生成 Lua，类型信息可辅助静态化分析（如按 props 类型做编译期优化）。
- **编译产物是"样式树"而非直接 draw 调用**：组件输出一棵带 flex 样式的节点树（box / text / list 等），布局引擎运行后才有实际坐标，随后才产生 draw 命令。

## 6. 组件模型（hooks 风格）

- 对外保留 React 心智模型：`useState` / `useEffect` / props / children。
- 静态化下的降级形态：
  - 每个 `useState` 调用点编译为**状态槽索引**；组件函数每次重跑读槽、写槽。
  - 状态槽存储于框架运行时，重跑时返回同一槽值。
  - `useEffect` 编译为"依赖数组 + 回调"注册，由运行时在绘制后比对依赖决定是否触发。
- **更新粒度（MVP）**：状态变化时重跑整个组件函数，与上一份结果对比找脏区。先跑通，再按 hooks 依赖做细粒度更新（仅重跑受影响 JSX 片段）。

## 7. 渲染管线（事件驱动）

MVP 的完整闭环：

```
tm_monitor_touch / tm_monitor_mouse_click / tm_keyboard_* 事件
  → 命中测试（像素坐标 → 最深组件）
  → 组件事件处理器（hooks 状态更新）
  → 重跑受影响组件，生成新样式树
  → flexbox 全量布局（新旧各一遍）
  → 对比布局树中变化的 box → 合并脏矩形
  → 只绘制脏区 → gpu.sync()
```

- 无事件时不重绘（省 CPU）。
- 脏矩形来自**布局结果对比**（元素 box 变化），而非指令对比。
- 动画未来接入时：事件驱动为主 + 有动画时临时开 timer 帧循环，结束后关闭。

## 8. 布局模型（flexbox 子集）

- 实现精简 flexbox 布局引擎，运行时执行。
- 布局**无法静态化**：文本宽度依赖 GPU `getTextLength()` 运行时测量，内容尺寸运行时才确定。
- flexbox 子集范围待定（建议 MVP 仅支持：flexDirection 单轴、justifyContent / alignItems、margin / padding、固定尺寸 / 内容尺寸）。

## 9. 事件模型

- **触摸/鼠标**（GPU 屏幕）：
  - 普通屏幕：`tm_monitor_touch`（参数 x, y, sneaking）
  - Bitmap 屏幕：`tm_monitor_mouse_click`（x, y 为像素坐标，button 为按键 id）
- **键盘**（Tom's Peripherals Keyboard）：`tm_keyboard_key` / `tm_keyboard_char` 等；`fireNativeEvents` 为 false 时事件以 `tm_keyboard_` 为前缀。
- 命中测试：事件坐标 → 布局树 → 最深命中元素 → 触发组件事件处理器（onClick / onMouseDown / onKey 等）。
- 焦点管理：键盘输入组件（Input）需要焦点模型（点击聚焦 / Tab 切换），MVP 范围内。

## 10. 基础组件与首版范围

MVP 框架包含：

- 基础组件：Box / Text / Button / Panel
- 列表组件：List（keyed diff 循环，行级增删重排，只重绘变化的行）
- 触摸/鼠标事件路由
- 表单与键盘输入：Input 文本框、焦点管理

**不在首版**：网络数据 hook（useRequest/useSWR）、自定义字体/中文支持。

## 11. 异步与网络（未来）

- 首版不接网络，纯本地 UI。
- 未来方案（已定）：**async 函数编译为事件驱动状态机**——`await` 之后的代码拆成续体，由网络事件驱动继续执行；完全避开原生 Lua 协程陷阱，贴合 CC 事件模型。
- 网络能力复用 `docs/lib`（`fetch` 等）。
- 可选封装：useRequest（loading / data / error 三态管理），视需求再定。

## 12. 显示环境

- 分辨率乘数写死：`gpu.setSize(64)`（程序启动时调用）。
- 视口尺寸运行时获取：`gpu.getSize()` 返回五个值：
  `widthPx, heightPx, widthBlock, heightBlock, resolution`
- 布局根尺寸、脏矩形范围、命中测试坐标换算均以 `getSize()` 结果为准。
- 字体：默认字体起步，中文/自定义字体（`addNewChar`）后续再议。

## 13. 部署工作流

- 编译产物由开发者自行 SFTP 部署到游戏环境（如 MC 存档 `computer/<id>/` 目录）。
- 工具链不负责部署；不排除未来做自动同步/热重启。

## 14. MVP 验收标准

1. 静态页面渲染：一个带样式/布局的页面能渲染到屏幕上。
2. 交互 + 脏矩形闭环：按钮点击 → 状态变化 → 脏矩形重绘，全链路跑通。

MVP 之外的后续里程碑（按优先级建议）：

1. 键盘输入 + 焦点管理
2. 动态列表（keyed diff）
3. 网络接入（async 状态机编译；任务侧已就绪 —— 模块的 `start(side)` 可直接与网络栈任务并行）
4. 动画（声明式 transition）
5. 多文件 import（TSX 拆多个模块；产物已模块化，运行时仍内嵌）
6. 自定义字体 / 中文

## 15. 待决问题

- flexbox 子集的具体支持范围。
- hooks 在静态化下的精确定义（状态槽数量、重跑语义、useEffect 依赖比对）。
- 脏矩形合并策略（区域合并算法、上限）。
- 未来网络接入时 `fetch` 在 TSX 层的确切形态。

## 附录：MVP 实现记录

MVP 已按本文档落地，代码布局见仓库根目录 README。与本文档的对照与偏差：

- **编译管线**（§5 起步路径）：`esbuild` 擦类型（`jsx: preserve`）→ `@babel/parser` AST →
  自研 codegen 生成 Lua；产物为模块 `dist/ui.lua`（框架运行时内嵌，尾部 `return ccreact`）。
  `tsc --noEmit` 已接入（`npm run typecheck`）。
- **产物形态（2025-08 模块化）**：编译产物不再是独立程序。顶层 `render(<App/>)` 编译为
  `__mount(render_App)`（只登记根组件，require 时不碰 GPU）；模块返回的表含 `start(side)` 任务函数
  —— GPU 初始化（阻塞 `refreshSize`，side 由主程序显式传入，默认 `left`）+ 首帧渲染 + `os.pullEvent`
  事件循环。主程序经 simpleParallel 组合：`simpleParallel.add(function() ui.start("left") end)` +
  网络任务 + `simpleParallel.start()`。CC 的 `parallel.waitForAll` 首轮以空事件 resume 每个任务
  （首帧在首个事件前渲染），随后每个事件广播给所有消费者（无争抢），UI 任务在 `os.pullEvent`
  处让出调度器，因此与网络栈任务并发、互不阻塞。测试桩按真机 `parallel.lua` 语义复刻了该调度
  （`scripts/test_main.lua` 的 parallel stub + 双任务广播断言）。
- **组件模型**（§6）：`useState` / `useEffect` 编译到运行时 `__useState` / `__useEffect`；
  状态按「组件实例 DFS 路径 + hook 索引」存放，组件 fnId 变更时重置槽位（无 key 的 MVP 身份模型）。
  更新粒度 = 整树重跑 + 布局结果对比（§6 一致）。
- **渲染管线**（§7）：事件驱动，无事件不重绘；脏矩形来自**布局树对比**（节点视觉与 box 都参与比较，
  因此纯布局位移也会标记脏区，比「仅 box 变化」更保守）；合并后面积超过视口 40% 时整屏重绘。
- **真机适配（2025-08 修复）**：① draw 系列确认为 1-based（见上）；② 启动顺序固定为
  `refreshSize()`（**阻塞**，重新识别屏幕）→ `setSize(64)` → `getSize()`——每次启动都先
  refreshSize，屏幕改动后重启才能适应；不轮询（运行中动态识别不做）；③ `__children` 按最大
  整数键遍历，规避 Lua nil 空洞导致条件渲染兄弟节点丢失。
- **布局模型**（§8）：运行时 flexbox 子集已实现 —— `flexDirection`（默认 **column**，RN 风格）、
  `justifyContent`（start/center/end/space-between/space-around）、`alignItems`（含 stretch）、
  `gap`、`margin`/`padding`（数值、四边对象、单边 `marginTop` 等）、固定尺寸/内容尺寸/`width: "100%"`。
- **事件模型**（§9）：`tm_monitor_touch` 与 `tm_monitor_mouse_click/up`（Bitmap 屏带按下视觉）命中测试
  已实现；键盘事件仅预留分支，Input/焦点管理未做（属于 §14 里程碑 1）。
- **显示环境**（§12）：`gpu.setSize(64)`、视口取 `gpu.getSize()`。**坐标约定**：帧缓冲内部与事件一致为
  1-based；已从 1.3.1 字节码确认 draw 系列也是 1-based（`filledRectangle`/`drawText` 内部执行 `x-1`，
  `x<1` 或文字越界时抛 "Out of boundary"），适配层不做偏移，并对越界绘制做跳过/裁剪。
  颜色必须传有符号 int32（`fill`/`filledRectangle` 走 `toColor` 的 longValue 回绕，`drawText` 的 fg/bg
  走 `MathHelper.floor` 的饱和 `(int)` 转换——两者只有有符号值都正确）；`drawText` 的 fg/bg 不允许 nil，
  `-1` 为"无背景"哨兵。默认字体 **5×8**（ascii.bin 头字节 fontHeight=8）。**文本度量与模组一致**：
  字符前进量 = (charWidth + padding) × size，padding 默认 **1px**（字符间距）；文字高度 = 8px×fontSize
  （padding 不影响高度）。`__measure` 返回完整盒尺寸（内容 + 自身 padding），auto 尺寸容器正确计入 padding。
  脏矩形各向外扩 2px 以覆盖字形越界残留。
- **与文档的偏差**：
  - 组件对外命名为 `Box / Panel / Text / Button`（§10 大写命名），编译器同时接受小写别名。
  - 编译入口为顶层 `render(<App/>)`（挂载根组件；产物是模块，运行时由 `start(side)` 启动），
    **仅支持单文件模块**（多文件 import 未做）。
  - 三元表达式降级为 Lua `and/or`，要求真值分支为真值（元素/数字/字符串），文档化限制。
  - 无滚动/裁剪；内容溢出视口不绘制也不可点击。
- **工具链**（§13）：部署仍由开发者自行 SFTP，工具链不负责。

