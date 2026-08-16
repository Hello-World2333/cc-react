# cc-react

用 React 组件（`.tsx`）为 [CC: Tweaked](https://tweaked.cc/) 电脑编写 UI 的框架：
`.tsx` 经自研编译器降级为 Lua，显示输出走 [Tom's Peripherals](https://github.com/tom5454/Toms-Peripherals/wiki/) 的 GPU（像素 framebuffer）。

架构设计见 [docs/architecture.md](docs/architecture.md)。**当前状态：MVP 已实现**，满足 §14 两条验收标准：
静态页面渲染 + 交互/脏矩形重绘闭环。

## 目录

```
compiler/          JSX → Lua 编译器（esbuild 擦类型 → @babel/parser AST → codegen）
runtime/           框架运行时（hooks 状态槽、flexbox 布局、脏矩形渲染、事件路由、GPU 适配）
framework/         全局 TS 类型声明（useState/useEffect/render 与 JSX 组件类型）
demo/App.tsx       MVP 演示应用（计数器 + 条件徽章 + 动态列表）
scripts/           无头测试（stub GPU + CC 环境，跑通验收标准）
dist/main.lua      编译产物（单文件，拷进电脑即可运行）
```

## 快速开始

```bash
npm install        # esbuild + @babel/parser + typescript
npm run build      # demo/App.tsx -> dist/main.lua
npm run test       # luac 语法检查 + 无头测试（stub GPU）
npm run test:all   # typecheck + build + test
```

## 部署

把 `dist/main.lua` 通过 SFTP 拷进游戏存档的电脑目录（`saves/<存档>/computers/<id>/`），
然后在游戏内运行：

```
lua main.lua left
```

`left` 是 GPU 外设所在的 side（默认 `left`）。屏幕至少需要 **3 块横向拼接的显示器**
（192px 宽；示例的完整界面在 3×4 = 192×256 上最佳，基础界面在 3×2 上即可）。

## 写一个应用

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

### 支持范围（MVP）

- 组件：`Box` / `Panel` / `Text` / `Button`（也接受小写 `box` 等）
- hooks：`useState`（含函数式更新）、`useEffect`（依赖数组比对）
- 布局：flexbox 子集 —— `flexDirection`（默认 column）、`justifyContent`、`alignItems`（含 stretch）、
  `gap`、`margin` / `padding`（数值或四边对象，支持 `marginTop` 等单边）、固定尺寸 / 内容尺寸 / `width: '100%'`
- 颜色：`#rgb` / `#rrggbb` / `#aarrggbb`，编译期转 ARGB
- 事件：`tm_monitor_touch`（普通屏点击）与 `tm_monitor_mouse_click/up`（Bitmap 屏，含按下视觉反馈）
- JSX 表达式：三元（真值分支）、`&&` / `||`、`.map()`（→ 运行时 `__map`）、数组展开（→ `__arr`）、模板/拼接文本
- 单文件应用：组件必须与 `render(<App/>)` 在同一个 `.tsx` 里（多文件 import 与 keyed list 是后续里程碑）

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
- 无滚动/裁剪：内容超出视口的部分不会绘制，也无法点击。
- `useState` 状态按「组件实例 DFS 路径」存放；结构静态时稳定，条件渲染换组件会重置对应槽位（keyed list 里程碑解决）。
