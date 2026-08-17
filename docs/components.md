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
  `Input`（文本框，里程碑 1）
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
