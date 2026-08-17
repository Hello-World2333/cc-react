# 故障排查与已知限制

## 真机黑屏（已修复 2025-08）

早期版本在真机上表现为「程序正常运行但完全黑屏」，根因有三，均已修复并验证：

1. **坐标基假设错误**：Tom's Peripherals GPU 的 draw 系列（`filledRectangle` / `drawText` 等）是
   **1-based** 的（从 1.3.1 字节码确认：内部执行 `x-1`，`x<1` 时抛 "Out of boundary"）。
   框架内部与事件一致地使用 1-based 坐标，适配层不再做偏移。
2. **启动顺序**：`refreshSize()` 是**阻塞**的（返回时屏幕已识别）。启动固定按
   `refreshSize()` → `setSize(64)` → `getSize()` 执行，每次启动都重新识别屏幕，屏幕改动后
   重启才能适应；无屏幕时给出明确报错而非黑屏。
3. **Lua nil 空洞**：编译产物中条件渲染产生的 `nil` 会让 `ipairs` 提前停止，导致排在空洞之后的
   兄弟节点（如 Recorded 列表）丢失。`__children` 改为按最大整数键遍历。

## 其他显示问题

- 默认字体为 **5×8**（ascii.bin 头字节 fontHeight=8）；字符间距 1px（padding 默认 1，与模组一致），
  文字高度 = 8px×fontSize；脏矩形各向外扩 2px，避免字形溢出残留（"糊屏"）。
- `drawText` 在文字超出屏幕右/下边缘时也会抛 "Out of boundary"（不裁剪），运行时对越界文字直接跳过。
- `drawText` 的 fg/bg **必须是数字**（nil 会报 `Bad argument #5: (expected Number)`），无背景传 `-1`
  （模组的"无背景"哨兵值）；颜色必须传**有符号 int32**（模组用饱和 `(int)` 转换，无符号值会变成
  0x7FFFFFFE 之类的错误颜色），运行时适配层已统一处理。

若仍有显示问题，用 `scripts/debug_probe.lua` 逐项排查（方法列表 / getSize / fill / 矩形 / 文字 / 坐标基）。

## 已知约定/限制（MVP）

- 帧缓冲坐标约定为 **1-based**（与触摸/鼠标事件一致）；GPU 适配层在调用前统一 `-1`。
  若真机 GPU 的 draw 系列实为 1-based，只需改 `runtime/runtime.lua` 中的 `DRAW_OFFSET = 0`。
- 默认字体按 CC 5×7 计算行高（`fontSize` 为像素倍率）；真实 GPU 字体若有差异会导致轻微垂直偏差。
- 三元表达式降级为 Lua `and/or`：假分支为 `null`/元素时正确；假分支为假值字面量时语义不保真。
- `import` 是**编译期打包**：不支持动态 `import()` / 运行时加载；未被使用的导入会被打包器剔除。
- 无滚动/裁剪：内容超出视口的部分不会绘制，也无法点击。
  **已实现（2025-08）**：`<Scroll>` 容器提供视口裁剪 + 滚轮/拖拽滚动。
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

## 网络（里程碑 3）的 v1 限制

- 每条语句**一个** `await`；`await` 只支持在语句层（变量声明初始化、表达式语句、
  `return await E`），**出现在 if/else 分支内会编译报错**（把 await 提到分支上方即可）；
  循环/switch 本就不在 codegen 支持范围。多级**顺序** await 支持。
- `await` 的 try/catch 未编译：错误处理用 `resp.ok` / `resp.error` 分支。
- async 组件（含 JSX 的 async 函数）编译期报错——组件必须同步返回元素。
- `fetch` 需要主程序构建 docs/lib HTTP client 并传入（`ui.setHttpClient(client)`）；
  worker 已内置于 `ui.start()`（无需额外注册任务）。未传入时 fetch 解析为
  `{ ok = false, error = "http client not set: ..." }`。
- CC 的 `os.queueEvent` 事件参数**携带 function 会变 nil**（真机实测，表内嵌套的函数字段
  同样被丢弃）：fetch 的响应表不经过事件传输（运行时按 job id 存共享表，事件只带 id），
  因此响应上的 `json()` / `text()` 方法可用；自己给 `os.queueEvent` 传含函数的值会踩同样
  的坑。
- 网络栈（`docs/lib`）的 IP/ARP/DNS 任务必须在 `simpleParallel.start()` 前构造
  （主程序构建 client 时即完成）；`fetch` 只支持 `http://`（docs/lib 现状）。

## 调试工具

- `scripts/debug_probe.lua`：逐项排查（方法列表 / getSize / fill / 矩形 / 文字 / 坐标基）
- `scripts/test_*.lua`：各功能模块的无头测试
