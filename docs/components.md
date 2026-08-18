# 组件与应用开发

## 作者模型

`.tsx` 里定义组件，`render(<App/>)` 挂载根组件；编译产物是模块，
GPU 初始化与事件循环都在 `start(side)` 里（由主程序经 simpleParallel 调用）。

应用可以按正常 React 习惯拆成多个文件：编译器在编译期把整个应用（`import`/`export`）
**打包**进同一个 Lua 模块，部署仍只拷一个 `ui.lua`。

## 基本示例

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

## 多文件（import / export）

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

## 支持范围（MVP）

- **组件**：`Box` / `Panel` / `Text` / `Button` / `Scroll`（滚动容器，也接受小写 `scroll` 等）/
  `Input`（文本框，里程碑 1）/ `Switch`（开关切换）/ `ProgressBar`（进度条）/ `Slider`（滑动条）
- **hooks**：`useState`（含函数式更新）、`useEffect`（依赖数组比对）
- **布局**：flexbox 子集 —— `flexDirection`（默认 column）、`justifyContent`、`alignItems`（含 stretch）、
  `gap`、`margin` / `padding`（数值或四边对象，支持 `marginTop` 等单边）、固定尺寸 / 内容尺寸 / `width: '100%'`
- **颜色**：`#rgb` / `#rrggbb` / `#aarrggbb`，编译期转 ARGB
- **事件**：`tm_monitor_touch`（普通屏点击）与 `tm_monitor_mouse_click/up`（Bitmap 屏，含按下视觉反馈）
- **键盘输入** + 焦点管理（里程碑 1）：见 [keyboard-input.md](keyboard-input.md)
- **滚动**：`<Scroll>` 容器 —— 内容按完整尺寸布局、视口裁剪（不越界绘制），
  滚轮（`tm_monitor_mouse_scroll`，方向语义与真机一致：向下滚动 dir=+1）与触摸拖拽滚动；
  `scrollStep` 控制步长（默认 8px = 一个 5×8 行）；滚动偏移按路径持久化、两端自动钳制
- **JSX 表达式**：三元（真值分支）、`&&` / `||`、`.map()`（→ 运行时 `__map`）、数组展开（→ `__arr`）、模板/拼接文本
- **多文件 import**：应用可拆成多个 `.tsx` / `.ts` 文件（`import` / `export`），编译期打包进单个 Lua 模块；
  同名组件自动改名、跨文件 hooks/props/常量均可用；编译产物是模块，
  `start(side)` 作为 simpleParallel 任务被主程序调度（见 [deployment.md](deployment.md)）
- **网络**（里程碑 3）：见 [network.md](network.md)
- **禁用态**：`Button` / `Input` / `Scroll` / `Box`（带 `onClick`）均支持 `disabled` 属性。
  设为 `true` 时：交互事件被阻止（点击/键盘输入/滚动），
  控件显示为灰色外观（`Button` 背景变暗、文字变灰；`Input` 背景/边框/文字变灰且隐藏光标）。
  焦点不会落在禁用的 `Input` 上，Tab 切换也会跳过它们。

## Switch（开关切换）

`<Switch>` 是一个布尔开关控件，点击可切换开/关状态。

### Props

| 属性 | 类型 | 说明 |
|---|---|---|
| `value` | `boolean` | 当前开关状态（`true` = 开，`false` = 关） |
| `onChange` | `(value: boolean) => void` | 切换时回调，参数为新状态 |
| `disabled` | `boolean` | 禁用时不可交互，显示灰色外观 |
| `style` | `Style` | 样式（可自定义尺寸、颜色等） |

### 样式颜色

| 样式属性 | 默认值 | 说明 |
|---|---|---|
| `color` | `#7ec8ff` | 开关打开时的轨道颜色（强调色） |
| `backgroundColor` | `#3a3a48` | 开关关闭时的轨道颜色 |
| `borderColor` | `#4a4a5a` | 轨道边框颜色 |

### 默认尺寸

开关默认为 **16×9 像素**（轨道），内部有 7×7 滑动旋钮。可通过 `style.width` / `style.height` 自定义。

### 使用示例

```tsx
function Settings() {
  const [darkMode, setDarkMode] = useState(false);
  const [notifications, setNotifications] = useState(true);

  return (
    <Panel style={{ flexDirection: 'column', gap: 8, padding: 8 }}>
      <Text style={{ fontSize: 1 }}>设置</Text>
      <Box style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
        <Text>深色模式</Text>
        <Switch value={darkMode} onChange={setDarkMode} />
      </Box>
      <Box style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
        <Text>通知</Text>
        <Switch value={notifications} onChange={setNotifications} />
      </Box>
    </Panel>
  );
}
```

## ProgressBar（进度条）

`<ProgressBar>` 是一个只读显示组件，用于表示 0 到 1 之间的进度值。

### Props

| 属性 | 类型 | 说明 |
|---|---|---|
| `value` | `number` | 进度值（0 到 1），超出范围会被钳制 |
| `color` | `string` | 填充颜色（默认 `#7ec8ff` 强调色） |
| `backgroundColor` | `string` | 轨道背景颜色（默认 `#2a2a35`） |
| `style` | `Style` | 样式（可自定义尺寸等） |

### 默认尺寸

进度条默认为 **100×9 像素**。可通过 `style.width` / `style.height` 自定义。

### 使用示例

```tsx
function ProgressDemo() {
  const [progress, setProgress] = useState(0.3);

  return (
    <Panel style={{ flexDirection: 'column', gap: 8, padding: 8 }}>
      <Text>进度: {Math.round(progress * 100)}%</Text>
      <ProgressBar value={progress} style={{ width: 150 }} />
      <Slider value={progress} onChange={setProgress} style={{ width: 150 }} />
    </Panel>
  );
}
```

## Slider（滑动条）

`<Slider>` 是一个可交互的滑动条控件，用户可以通过点击或拖拽来设置数值。

### Props

| 属性 | 类型 | 说明 |
|---|---|---|
| `value` | `number` | 当前值 |
| `min` | `number` | 最小值（默认 0） |
| `max` | `number` | 最大值（默认 1） |
| `step` | `number` | 步进值（默认 0.01） |
| `onChange` | `(value: number) => void` | 值变化时回调 |
| `color` | `string` | 强调色（滑块 + 填充轨道颜色，默认 `#7ec8ff`） |
| `backgroundColor` | `string` | 轨道背景颜色（默认 `#2a2a35`） |
| `disabled` | `boolean` | 禁用时不可交互，显示灰色外观 |
| `style` | `Style` | 样式（可自定义尺寸等） |

### 默认尺寸

滑动条默认宽度填满父容器，高度为 **9 像素**。可通过 `style.width` / `style.height` 自定义。

### 使用示例

```tsx
function VolumeControl() {
  const [volume, setVolume] = useState(0.7);

  return (
    <Panel style={{ flexDirection: 'column', gap: 8, padding: 8 }}>
      <Text>音量: {Math.round(volume * 100)}%</Text>
      <Slider
        value={volume}
        onChange={setVolume}
        min={0}
        max={1}
        step={0.05}
        style={{ width: 150 }}
        color="#00c853"
      />
    </Panel>
  );
}
```
