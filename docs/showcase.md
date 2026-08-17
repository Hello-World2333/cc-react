# 演示应用（showcase）

`demo/` 是一个 6 标签页的完整演示，覆盖（几乎）所有框架功能；编译、部署方式与普通应用
完全一致（见 [deployment.md](deployment.md)），推荐 **3×4 = 192×256** 的显示器拼接。

每个标签页一个文件：

## 标签页说明

- **Home**：静态渲染 —— 标题 + 功能清单（`lib/features.ts` 经 `.map()`）+ 三种 hex 格式
  色块（`#rgb` / `#rrggbb` / `#aarrggbb`；颜色常量从 `lib/theme.ts` 导入，运行时解析）

- **Layout**：flexbox 游乐场 —— `J- / J+ / A- / A+` 循环 `justifyContent` / `alignItems`
  的全部取值（含 `stretch`）；下方展示 padding/margin 的**四边对象**写法

- **Counter**：交互闭环 —— `useState`（函数式更新 + 数组展开 `[...history, count]`）、
  `useEffect` 依赖比对、条件渲染徽章（count ≥ 5 出现）、Recorded 列表（`<Scroll>`
  视口裁剪 + 滚轮 / 拖拽滚动）

- **Input**：键盘输入 + 焦点 —— 三个受控 `<Input>`（placeholder / 点击聚焦并定位光标 /
  Tab 与 Shift+Tab 循环焦点 / Enter 触发 `onSubmit` / `onKey` 原始键码 / 长文本随光标
  水平滚动）

- **Scroll**：滚动容器 —— 12 行 + 超长行（水平裁剪）+ 底部按钮（滚动后仍可点击，
  点击穿透），`scrollStep` 可用按钮实时调整（4..24px）

- **Network**：网络 —— `async/await`（顺序 await / 失败分支 / `await` 非 future 透传）+
  `useRequest`（挂载自动请求 / loading / error / refetch），worker 内置于 `ui.start()`

## 额外展示的功能

演示还顺带展示了多文件 import（组件、`.ts` 工具模块、`import { X as Y }` 别名）、
模板字符串、`.map()`、数组展开与三元 / `&&` 条件渲染。

## 注意事项

标签页是条件渲染的子节点，切换标签会**重置**该页的本地状态（hook 状态按组件实例路径存放，
结构变化即重置槽位 —— 这是 MVP 的已知行为，见 [troubleshooting.md](troubleshooting.md)）。
