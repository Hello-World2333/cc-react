# cc-react 架构设计

> 状态：设计讨论结论，尚未实现。
> 本文档记录 2025-08 架构讨论的决策与背景，后续实现如有偏离请更新本文档。

> **实现状态（2025-08）：MVP 已完成**，见文末「附录：MVP 实现记录」。§14 两条验收标准均已通过
> 无头测试（`npm run test`）：静态页面渲染 + 交互/脏矩形重绘闭环。
> **网络接入（2025-08，里程碑 3）已完成**：async/await 编译为事件驱动状态机 + 运行时 fetch
> （复用 `docs/lib` HTTP 客户端）+ `useRequest` hook，见文末「附录：网络接入」。

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
与未来的网络任务并发运行；多文件 `import`（TSX 拆多个模块）已支持——编译器在 esbuild 层把整个
应用打包进单个 Lua 模块（部署不变，仍是一个 `ui.lua`）。

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
- **键盘**（Tom's Peripherals Keyboard）：`tm_keyboard_key`（**GLFW 键码** + `isRepeat`，按下与
  自动重复都会触发）/ `tm_keyboard_key_up`（释放）/ `tm_keyboard_char`（可打印字符，含空格）/
  `tm_keyboard_paste`（剪贴板）；`fireNativeEvents` 为 false 时事件以 `tm_keyboard_` 为前缀。
- 命中测试：事件坐标 → 布局树 → 最深命中元素 → 触发组件事件处理器（onClick / onMouseDown / onKey 等）。
- 焦点管理：键盘输入组件（Input）需要焦点模型（点击聚焦 / Tab 切换）—— **已实现（里程碑 1）**：
  Input 是唯一可聚焦节点；点击聚焦并把光标定位到点击处、Tab/Shift+Tab 按树序循环焦点、
  点击空白失焦、焦点边框 + `os.startTimer` 驱动的闪烁光标（见附录「键盘输入与焦点管理」）。

## 10. 基础组件与首版范围

MVP 框架包含：

- 基础组件：Box / Text / Button / Panel
- 列表组件：List（keyed diff 循环，行级增删重排，只重绘变化的行）
- 触摸/鼠标事件路由
- 表单与键盘输入：Input 文本框、焦点管理

**不在首版**：网络数据 hook（useRequest/useSWR）、自定义字体/中文支持。

## 11. 异步与网络

- 首版不接网络，纯本地 UI。**已实现（2025-08，里程碑 3）**，见附录「网络接入」。
- 实现方案（已定）：**async 函数编译为事件驱动状态机**——`await` 之后的代码拆成续体（closure），
  由网络事件驱动继续执行；完全避开原生 Lua 协程陷阱，贴合 CC 事件模型。
- 网络能力复用 `docs/lib`（`fetch` 等），在独立的 simpleParallel 任务（`networkLoop`）中执行，
  不阻塞 UI 事件循环。
- `useRequest`（loading / data / error 三态管理）已实现。

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

1. ~~键盘输入 + 焦点管理~~ **已实现（2025-08）**，见附录「键盘输入与焦点管理」
2. 动态列表（keyed diff）
3. ~~网络接入（async 状态机编译；任务侧已就绪 —— 模块的 `start(side)` 可直接与网络栈任务并行）~~
   **已实现（2025-08）**，见附录「网络接入」
4. 动画（声明式 transition）
5. ~~多文件 import（TSX 拆多个模块；产物已模块化，运行时仍内嵌）~~ **已实现（2025-08）**，
   见附录「多文件 import」
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
  已实现；键盘输入 + 焦点管理已实现（见下「键盘输入与焦点管理」）。
- **键盘输入与焦点管理（2025-08，里程碑 1）**：新增 `<Input>` 宿主组件（`__input` 节点）与焦点模型。
  - **焦点模型**：`__focusedPath`（当前焦点节点路径）+ `__focusList`（当前树中的可聚焦节点，每次
    `__render` 经 `__assignPaths` 重建，按树序）。可聚焦 = Input（MVP 范围，扩展点 `__isFocusable`）。
    点击 Input 聚焦并把光标定位到点击处（逐字符测量定位）；点击非 Input 区域失焦；Tab 258 /
    Shift+Tab（`__modsDown` 跟踪 340/344 的按下/释放）按树序循环焦点；焦点节点被条件渲染移除时
    （`__focusSeen` 标记）自动清理焦点状态。
  - **Input 语义**：受控组件 —— `value` 由 app 持有，所有内置编辑（字符插入、Backspace/Delete、
    Home/End/方向键、`tm_keyboard_paste` 粘贴）算出新串后经 `onChange` 回传；Enter 触发 `onSubmit`；
    可选 `onKey(key, isUp)` 原始按键钩子（内置编辑之后调用）。光标位置存于 `__inputState[path]`
    （按节点路径持久化，编辑时钳制到 value 长度）。绘制：value（空时 placeholder + placeholderColor）、
    焦点边框（`focusBorderColor`）、2px 插入条光标（`cursorColor`，`os.startTimer(0.5)` 驱动闪烁，
    `timer` 事件切换 `cursorVisible` 后走脏矩形重绘；每次编辑重置闪烁）。测量：宽度 = value 或
    placeholder 的文本宽度（都空时一个字符格），显式 `width` 优先。
  - **长文本滚动与裁剪（2025-08 追加）**：Input 对超出内容盒的文本做**真实输入框式处理** ——
    文本按内容盒裁剪（`__gpu.drawText` 的 clip 子区间拆分，复用 Scroll 的逐字符裁剪），视图随
    光标水平滚动：`__layoutInputOffset`（布局期，盒宽已知）按「光标保持在内容盒内」的策略计算
    偏移，存于 `__inputState[path].offsetX`（持久化，随光标/值变化增量调整 —— 输入到末尾文本
    左移、Home/左移逐步回滚、Backspace 保持文本尾随光标；值变短时钳制）。点击定位按偏移映射到
    可见字符；光标条（2px）始终在盒内。为此 `__gpu.drawText` 的 clip 路径不再受「x<1 / 越视口」
    早退约束（clip 由 `__clipIntersect` 统一钳制到视口内，负 x 的滚动文本安全绘制），
    `__clipIntersect` 增加视口钳制（顺带修正 Scroll 容器部分出屏时的越界风险）。脏矩形 =
    内容盒（文本不再越界绘制，`__visualRect` 的 Input 扩展分支移除）。
  - **键盘事件契约（真机源码验证）**：Tom's Peripherals 键盘**透传 Minecraft 的 GLFW 键码**
    （不是 CC 的 PC scancode）：Enter 257 / Tab 258 / Backspace 259 / Delete 261 / Left 263 /
    Right 262 / Home 268 / End 269 / Shift 340/344。事件形态（fireNativeEvents=false）：
    `tm_keyboard_key`（peripheral, key, **isRepeat** —— 与 CC 原生 key 事件的 isUp 语义不同，
    按下和自动重复都发）、`tm_keyboard_key_up`（peripheral, key，释放单独发）、
    `tm_keyboard_char`（peripheral, char，可打印字符含空格）、`tm_keyboard_paste`（peripheral, content）。
    运行时按 key-down（含 repeat，自动重复删字/移光标）处理编辑、`char`/`paste` 插入文本；
    修饰键状态从 key/key_up 事件维护。
  - **脏矩形**：`__sameNode` 新增 value/placeholder/focused/cursor/cursorVisible 比较 ——
    焦点边框、光标移动、闪烁都产生极小脏矩形增量重绘。
  - **验证**：`scripts/fixtures/input/`（双输入框 + 占位 + onKey 计数器）与 `scripts/test_input.lua`
    （点击聚焦/光标定位、逐键编辑、Tab/Shift+Tab、失焦、Enter 提交、粘贴、闪烁 timer tick、
    自动重复、像素级焦点边框/占位/光标断言）。
  - **附带修复**：JSX 注释 `{/* ... */}`（babel 解析为空的 JSXExpressionContainer）不再报错 ——
    codegen 的 children 收集跳过 `JSXEmptyExpression`。
- **显示环境**（§12）：`gpu.setSize(64)`、视口取 `gpu.getSize()`。**坐标约定**：帧缓冲内部与事件一致为
  1-based；已从 1.3.1 字节码确认 draw 系列也是 1-based（`filledRectangle`/`drawText` 内部执行 `x-1`，
  `x<1` 或文字越界时抛 "Out of boundary"），适配层不做偏移，并对越界绘制做跳过/裁剪。
  颜色必须传有符号 int32（`fill`/`filledRectangle` 走 `toColor` 的 longValue 回绕，`drawText` 的 fg/bg
  走 `MathHelper.floor` 的饱和 `(int)` 转换——两者只有有符号值都正确）；`drawText` 的 fg/bg 不允许 nil，
  `-1` 为"无背景"哨兵。默认字体 **5×8**（ascii.bin 头字节 fontHeight=8）。**文本度量与模组一致**：
  字符前进量 = (charWidth + padding) × size，padding 默认 **1px**（字符间距）；文字高度 = 8px×fontSize
  （padding 不影响高度）。`__measure` 返回完整盒尺寸（内容 + 自身 padding），auto 尺寸容器正确计入 padding。
  脏矩形各向外扩 2px 以覆盖字形越界残留。
- **滚动（2025-08）**：新增 `<Scroll>` 宿主组件（`__scroll` 节点）。内容按**完整尺寸**布局
  （滚动轴方向以 `SCROLL_MAX` 为界测量），再按滚动偏移平移进屏幕坐标——滚出视口的内容落在
  容器 box 之外，绘制时被**裁剪**：`__gpu.*` 适配层增加 clip 参数（矩形裁剪、文字按字符宽度
  子区间拆分），`__drawNode` 对 scroll 节点的子树收窄到其视口 box（嵌套 scroll 自动组合）。
  滚动偏移存于 `__scrollState[path]`（按节点路径持久化，`__layoutScroll` 每次按当前内容尺寸
  钳制）。交互：`tm_monitor_mouse_scroll`（方向语义经源码验证：Minecraft 滚轮 delta<0 →
  dir=+1 = 向下滚动，`scrollStep` 默认 8px）与触摸拖拽（click+drag，内容跟随手指，位移超过
  `DRAG_TAP_SLOP` 时取消本次 tap 的点击）。命中测试无需改动——子节点屏幕坐标已含偏移。
  已知取舍：字形无法逐像素裁剪，纵向按整行裁剪，滚动边界行会整行出现/消失；建议
  `scrollStep` 设为内容行距。
- **与文档的偏差**：
  - 组件对外命名为 `Box / Panel / Text / Button / Scroll`（§10 大写命名），编译器同时接受小写别名。
  - 编译入口为顶层 `render(<App/>)`（挂载根组件；产物是模块，运行时由 `start(side)` 启动）。
    多文件 import 已支持（见下「多文件 import」）。
  - 三元表达式降级为 Lua `and/or`，要求真值分支为真值（元素/数字/字符串），文档化限制。
- **多文件 import（2025-08）**：应用可按正常 React 习惯拆成多个 `.tsx` / `.ts` 文件并用
  `import` / `export` 组织。编译管线改为 `esbuild.build({ bundle: true, jsx: 'preserve' })`
  把整个应用打包成单个 chunk 再交给 codegen（§5 起步路径的升级）：Lua 产物仍是**单个模块**
  （运行时内嵌、`start(side)` 任务、部署拷一个 `ui.lua`），文件拆分只是编译期的源码组织。
  要点：
  - 同名组件冲突由打包器改名（如 `Widget` → `Widget2`），JSX 标签与 `render_*` 函数名保持一致；
    跨文件 hooks / props / 事件回调 / 常量均可用（hooks 状态槽按实例路径 + fnId 寻址，与源文件无关）。
  - 入口文件的 `export { ... }`（esbuild `format: 'esm'` 产物）由 codegen 直接忽略；
    `import` 语句在打包后不再出现，codegen 保留报错作为防御。
  - 颜色常量可从其他文件导入：编译器只折叠**同文件内的** `#hex` 字符串字面量，跨文件的颜色常量
    以字符串进入运行时，`__color` 增加 `#rgb/#rrggbb/#aarrggbb` 字符串解析（与编译期折叠同语义）。
  - 组件/工具函数参数支持解构（`function Header({ title })` → `local title = props.title`）；
    `if (x) return y;` 这类无花括号分支也归一化处理。
  - 验证：`demo/` 已拆分为多文件（`demo/components/*`），新增多文件夹具
    `scripts/fixtures/multi/`（同名组件冲突、默认导出、`.ts` 工具模块、跨文件 hooks、导入颜色常量）
    与 `scripts/test_multiimport.lua`，共享 `scripts/cc_stub.lua` 桩环境（从 `test_main.lua` 抽出）。
- **工具链**（§13）：部署仍由开发者自行 SFTP，工具链不负责。
- **网络接入（2025-08，里程碑 3）**：async/await 编译为事件驱动状态机 + 运行时 fetch（复用
  `docs/lib` HTTP 客户端）+ `useRequest` hook。落地方式与 §11 一致，要点：
  - **async 降级（编译器，`codegen.mjs`）**：`async function` / `async () =>` 编译为普通 Lua
    函数：体部同步执行到第一个 `await`，随后把「await 之后的所有代码」注册为续体闭包
    （`__await(未来对象, function(值) ... end)`），函数立即返回自己的 future
    （`__newFuture()`，结束时 `__resolveFuture(__self, 返回值)`）。续体内部再遇 `await`
    则递归再拆——**纯闭包链，全程不创建原生 Lua 协程**（规避 sleep() 杀协程陷阱）。
    v1 范围（README 已文档化）：每条语句一个 `await`，支持 `const x = await E`（绑定即续体参数）、
    表达式语句（函数调用等）、`return await E`、多级顺序 await；`await` 出现在 if/else 分支内会
    编译报错（提示把 await 提到分支上方）；循环/switch 本来就不在 codegen 支持范围。嵌套 async
    函数自成一体（编译期不往下钻）。`await` 非 future 值按 JS 语义直接透传（`await 42` → 42）。
  - **fetch（运行时网络桥）**：`fetch(url, options)` 编译为 `__fetch`——登记一个作业并
    `os.queueEvent("ccreact_net_job")` 唤醒网络 worker，返回 future。worker 是模块暴露的
    `networkLoop()` 任务（主程序 `simpleParallel.add(function() ui.networkLoop() end)`），
    阻塞式调用 `docs/lib` 的 HTTP client（在 simpleParallel 协程内可安全 sleep/收包），完成后
    `os.queueEvent("ccreact_net_done", id, resp)`；UI 事件循环收到后解析 future，续体运行
    （状态更新走正常脏矩形重绘）。作业队列每唤醒必排空，worker 在阻塞 fetch 期间错过唤醒事件也
    不会丢作业。错误（连接失败/DNS/未配置）统一归一化为 `{ ok = false, error = msg }` 响应表，
    事件载荷**绝不携带 nil 参数**（nil 会在事件表里留空洞，调度器 unpack 会丢后续参数）。
  - **网络客户端注入**：**HTTP client 实例由主程序构建并传入**（框架不拼 IP 栈——网络配置属于
    部署环境）。主程序在 `simpleParallel.start()` **之前**用 `docs/lib` 构建 client
    （`IP.new({ mode="host", interfaces = {...} })` → `HTTP.newClient(ipIface, { dnsServer, timeout })`），
    然后 `ui.setHttpClient(client)` —— IP 栈（`lib.ip` 的 ARP/DNS 收包任务）在构造时注册，必须
    早于 start；client 构建失败（如没有网卡）由主程序自行处理（demo 用 pcall 包住，让应用继续
    运行、fetch 上报错误）。未传入时 fetch 解析为
    `{ ok = false, error = "http client not set: ..." }`。
  - **useRequest（运行时 hook）**：`useRequest(fetcher, deps)` 管理 data/loading/error + token
    四槽位：挂载与 deps 变化时触发请求；`refetch()` 立即重发；token 机制丢弃过期响应（新请求已
    发起时旧续体直接返回，不会用旧数据覆盖新数据）。返回 `{ data, loading, error, refetch }`。
  - **验证**：新增 `scripts/fixtures/network/`（顺序 await 值流、错误路径、await 非 future、
    useRequest 挂载/加载/refetch/过期保护/无关重渲染不重发）与 `scripts/test_network.lua`
    （无头测试：`networkLoop` 作为 parallel 第二任务 + `ui.setNetworkBackend` 桩后端 +
    `getNetworkJobs`/`resolveNetworkJob` 手动喂响应）。`cc_stub.lua` 增加 `os.queueEvent`
    与队列优先排空（先于 step 脚本），模拟真实 CC 的「排队事件广播给所有消费者」。
  - **与文档的偏差**：`fetch`/`useRequest` 是全局（`MAPPED_FUNCS` 映射到运行时），TS 类型层
    `Future<T>` 以 `PromiseLike<T>` 呈现以便 `await` 解包类型。async 组件（含 JSX 的 async 函数）
    编译期报错。

