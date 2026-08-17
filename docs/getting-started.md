# 快速开始

用 React 组件（`.tsx`）为 [CC: Tweaked](https://tweaked.cc/) 电脑编写 UI 的框架：
`.tsx` 经自研编译器降级为 Lua，显示输出走 [Tom's Peripherals](https://github.com/tom5454/Toms-Peripherals/wiki/) 的 GPU（像素 framebuffer）。

## 安装与构建

```bash
npm install        # esbuild + @babel/parser + typescript
npm run build      # demo/App.tsx -> dist/ui.lua（模块形态）
npm run test       # luac 语法检查 + 无头测试（stub GPU + 并行调度）
npm run test:all   # typecheck + build + test
```

## 目录结构

```
compiler/          JSX → Lua 编译器（cli.mjs = cc-react CLI；compile.mjs = 共享管线；index.mjs = 脚本入口）
runtime/           框架运行时（hooks 状态槽、flexbox 布局、脏矩形渲染、事件路由、焦点模型、GPU 适配）
framework/         全局 TS 类型声明（useState/useEffect/render 与 JSX 组件类型）
demo/App.tsx       演示入口（6 标签页 showcase：静态渲染 / flexbox / 交互 / 键盘 / 滚动 / 网络）
demo/components/   演示组件（TabBar + 每标签页一个文件 + CounterControls / Badge / HistoryList）
demo/lib/          演示辅助模块（theme 颜色常量 / features 数据 / format 纯函数，均为 .ts）
demo/main.lua      演示主程序（require 编译产物，经 simpleParallel 非阻塞调度 UI 任务）
scripts/           无头测试（stub GPU + CC 环境：验收标准 + 模块/并行契约 + 多文件 import + 滚动 + 键盘输入 + 网络用例）
dist/ui.lua        编译产物（模块：require 后由主程序组合调度，拷进电脑即可用）
```

## 相关文档

- 架构设计：[architecture.md](architecture.md)
- Tom's Peripherals GPU API：[toms-gpu-api.md](toms-gpu-api.md)
- 部署指南：[deployment.md](deployment.md)
- CLI 使用：[cli.md](cli.md)
- 组件与应用开发：[components.md](components.md)
- 键盘输入：[keyboard-input.md](keyboard-input.md)
- 网络接入：[network.md](network.md)
- 中文渲染：[chinese-rendering.md](chinese-rendering.md)
- 故障排查：[troubleshooting.md](troubleshooting.md)
