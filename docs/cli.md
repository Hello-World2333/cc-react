# CLI（npm 包）

编译器已封装为 `cc-react` CLI，已发布到 npm（`@linyun-host/cc-react`）

## 安装

```bash
npm i -D @linyun-host/cc-react
```

## 用法

```bash
cc-react src/App.tsx dist/ui.lua        # 编译为单个 Lua 模块
cc-react src/App.tsx --watch            # 监听源文件（含所有 import）变化，自动重编译
cc-react --help                         # 参数说明
```

## 参数说明

```
用法: cc-react <entry.tsx> [out.lua] [options]

参数:
  entry                 入口 .tsx 文件（跨 .tsx/.ts 的 import 在编译期打包）
  out                   输出 Lua 模块（默认 dist/ui.lua）

选项:
  -o, --out <file>      指定输出文件（与位置参数 <out> 等价）
  -w, --watch           源文件变化时自动重编译
  -h, --help            显示帮助
  -v, --version         打印版本
```

退出码：`0` 成功；`1` 编译失败（bundling / codegen / 参数错误）。

## 程序化 API

```js
import { compile } from '@linyun-host/cc-react';
await compile('src/App.tsx', 'dist/ui.lua');
```

## TypeScript 配置

写 `.tsx` 时让编辑器识别框架全局类型（`useState` / `render` / 组件等），在 tsconfig
里加上 `"types": ["@linyun-host/cc-react/framework"]`（本仓库直接用
`"include": ["framework/**/*.d.ts"]`）。CLI 需要 Node ≥ 18。

## 已知限制

编译管线把**入口**强制按 ESM 处理（`export {}` 注入，esbuild 会在产物中剥掉），
因此单文件应用在 `"type": "commonjs"` 项目里也能编译；被 import 的文件只要含
`export`（正常拆分方式）即按 ESM 处理。仅做副作用 import（`import './x'`）且 x 无任何
导出的文件，在 CommonJS 项目中会被 esbuild 包成 CJS 包装（含逗号表达式，codegen 不支持）——
让被 import 的文件至少有一个 `export` 即可。

## 发布内容

发布内容（`files` 字段）：`compiler/`（CLI + 编译管线）、`runtime/runtime.lua`、
`framework/index.d.ts`；demo / scripts / docs 不随包发布。
