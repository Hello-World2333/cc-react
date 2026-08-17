# cc-react

用 React 组件（`.tsx`）为 [CC: Tweaked](https://tweaked.cc/) 电脑编写 UI 的框架：
`.tsx` 经自研编译器降级为 Lua，显示输出走 [Tom's Peripherals](https://github.com/tom5454/Toms-Peripherals/wiki/) 的 GPU（像素 framebuffer）。

**当前状态：MVP 已实现**，满足 §14 两条验收标准：静态页面渲染 + 交互/脏矩形重绘闭环；
多文件 `import` 已支持（应用可拆多个 `.tsx`/`.ts` 文件，编译期打包进单个 Lua 模块）；
里程碑 1「键盘输入 + 焦点管理」已实现（`<Input>` 文本框 + 点击聚焦 / Tab 切换 + 光标闪烁）；
**里程碑 3「网络接入」已实现**：`async/await` 编译为事件驱动状态机 + `fetch`（复用 `docs/lib`
HTTP 客户端，后台任务执行）+ `useRequest`（loading/data/error 三态）。
**中文渲染（opt-in）已实现（2025-08）**：`ui.setChineseFont("字库.fnt")` 启用 16px 自定义字体
（可修改字体 + 二进制字库懒加载 + UTF-8→槽号编码，见「中文渲染」）。

## 快速开始

```bash
npm install        # esbuild + @babel/parser + typescript
npm run build      # demo/App.tsx -> dist/ui.lua（模块形态）
npm run test       # luac 语法检查 + 无头测试（stub GPU + 并行调度）
npm run test:all   # typecheck + build + test
```

## 文档

| 文档 | 说明 |
|---|---|
| [architecture.md](docs/architecture.md) | 架构设计与实现记录 |
| [toms-gpu-api.md](docs/toms-gpu-api.md) | Tom's Peripherals GPU API 契约（真机验证版） |
| [getting-started.md](docs/getting-started.md) | 快速开始与目录结构 |
| [cli.md](docs/cli.md) | CLI 使用与程序化 API |
| [deployment.md](docs/deployment.md) | 部署指南与主程序模板 |
| [components.md](docs/components.md) | 组件与应用开发 |
| [keyboard-input.md](docs/keyboard-input.md) | 键盘输入与焦点管理 |
| [network.md](docs/network.md) | 网络接入（async/await + fetch） |
| [chinese-rendering.md](docs/chinese-rendering.md) | 中文渲染与自定义字体 |
| [showcase.md](docs/showcase.md) | 演示应用说明 |
| [troubleshooting.md](docs/troubleshooting.md) | 故障排查与已知限制 |

## 相关资源

- CC 电脑（CC: Tweaked）：https://tweaked.cc/
- Tom's Peripherals：https://github.com/tom5454/Toms-Peripherals/wiki/

## 项目结构

```
compiler/          JSX → Lua 编译器（cli.mjs = cc-react CLI；compile.mjs = 共享管线；index.mjs = 脚本入口）
runtime/           框架运行时（hooks 状态槽、flexbox 布局、脏矩形渲染、事件路由、焦点模型、GPU 适配）
framework/         全局 TS 类型声明（useState/useEffect/render 与 JSX 组件类型）
demo/              演示应用（6 标签页 showcase）
scripts/           无头测试（stub GPU + CC 环境）
dist/ui.lua        编译产物（模块：require 后由主程序组合调度）
docs/              项目文档
```
