# Tom's Peripherals GPU API 参考（真机验证版）

> 本文档汇总 cc-react 开发/真机排查过程中确认的 Tom's Peripherals GPU 契约。
> 信息来源：官方 wiki（GPUExt / GPUImpl）+ **1.3.1 版本 jar 字节码反编译验证**（标 ★ 的条目）。
> 适用版本：MC 1.21.1 + Tom's Peripherals 1.3.1。其他版本请以 `gpu.getMethods()` 输出为准。

## 1. 外设与上下文

`peripheral.wrap(side)` 返回的对象同时暴露两类方法：

- **GPU 外设专属**：`refreshSize` / `setSize` / `getSize` / `sync`
- **GPU 上下文（GPUImpl）**：`filledRectangle` / `rectangle` / `drawText` / `getTextLength` / `fill` / `getBounds` 等

## 2. 启动顺序（必须严格遵守）★

```lua
gpu.refreshSize()   -- 阻塞：重新识别连接的屏幕（每次启动都调用，屏幕改动后重启才能适应）
gpu.setSize(64)     -- 分辨率乘数（16..64），每块显示器 = 64×64 像素
local w, h = gpu.getSize()  -- 最后再取尺寸
-- getSize() 返回：widthPx, heightPx, widthBlock, heightBlock, resolution
```

- `refreshSize()` 是**阻塞**的——调用返回时屏幕已识别完毕，**不需要等待/轮询**。
- 顺序必须是 refreshSize → setSize → getSize；跳过 refreshSize 会导致程序沿用上次的屏幕检测结果。
- `getSize()` 的像素尺寸 = 块数 × 分辨率乘数（如 4×3 块 + 64 → 256×192）。

## 3. 坐标约定：1-based ★

- **draw 系列与事件坐标全部 1-based**（左上角为 (1,1)）。
- `filledRectangle` / `drawText` 内部执行 `x-1`、`y-1`（字节码 `iconst_1; isub`）。
- `x < 1` 或 `y < 1` → 抛 `Out of boundary`（所以 `filledRectangle(0,0,...)` 会崩溃）。
- 事件坐标同样 1-based：`monitorPos` 内部 `xP + 1, yP + 1`。
- `filledRectangle` 的**远边会裁剪**（x+w-1 > width 时截断），但近边（x<1）抛错。
- `drawText` **不裁剪**：文字超出右/下边缘直接抛 `Out of boundary`（见 §6）。

## 4. 颜色与参数类型 ★

颜色统一为 ARGB（`0xAARRGGBB`）。**传参必须是有符号 int32**，原因：

| 调用路径 | 转换方式 | 无符号值（如 0xFFFFFFFF）会变成 |
|---|---|---|
| `fill` / `filledRectangle` / `rectangle` | `ParamCheck.toColor` → `Double.longValue()` + `l2i`（回绕） | 正确（回绕等价） |
| `drawText` 的 fg/bg | `optionalInt` → `getInt` → `MathHelper.floor`（`d2i` **饱和** cast） | **0x7FFFFFFE 之类的错误颜色** |

- 所以框架运行时统一用 `__color()` 把无符号 ARGB 转成有符号 int32 再传给 GPU。
- `drawText` 的 fg/bg **必须是数字**：传 `nil` 报 `Bad argument #5: (expected Number)`。
- `bg = -1` 是"无背景"哨兵（`bg <= -1` 时跳过背景绘制）；`fg = -1` 即白色（0xFFFFFFFF）。

## 5. 字体与文本度量 ★

- 默认字体 **5×8**（不是 CC 的 5×7）：`ascii.bin` 首字节 `0x08` 读入 `Font.fontHeight`；
  文件布局 `1 + 4 + 512(字符表) + 256(宽度表) + 256×8×4(字形) = 8965B` 与文件大小吻合。
- **字符前进量** = `(charWidth + padding) × size`；`getTextLength` 与 `drawText` 前进逻辑一致。
- **padding 默认 1**（`optionalInt(args, 6, 1)`）——即默认 1px 字符间距；传 0 会字字粘连。
- **文字高度 = `fontHeight(8) × size`**，padding 不影响高度（边界检查直接用 `font.fontHeight`）。
- 空格宽度固定 5（特殊处理）；未知字符回退 `font.UNKNOWN`。
- 默认 `size = 1`、`padding = 1`；`drawText(x, y, text, [fg], [bg], [size], [padding])`。
- 文字越界检查：`x < 1` 或 `y < 1` 或 `x + textWidth > width` 或 `y + 8 > height`（后两个为字节码
  实际检查，`size` 未参与 y 检查——绘制越底边时会被内部 catch 住丢弃，不崩）。

## 6. 事件格式

CC 外设事件第一个 payload 参数是**外设名**（字符串），坐标在其后：

| 事件 | payload（去掉事件名与外设名后） | 说明 |
|---|---|---|
| `tm_monitor_touch` | `x, y, sneaking` | 普通屏点击 |
| `tm_monitor_mouse_click` | `x, y, button` | Bitmap 屏按下（button: 1=左键） |
| `tm_monitor_mouse_up` | `x, y, button` | Bitmap 屏抬起 |
| `tm_monitor_mouse_move` / `_drag` / `_scroll` | `x, y` / `x, y` / `x, y, direction` | 指针移动 |
| `tm_keyboard_key` | `key, isRepeat` | 键盘按下/自动重复（fireNativeEvents=false 时前缀） |
| `tm_keyboard_key_up` | `key` | 键盘释放（独立事件） |
| `tm_keyboard_char` | `char` | 可打印字符（含空格） |
| `tm_keyboard_paste` | `content` | 剪贴板内容（Ctrl+V 由客户端截获，只经此事件到达） |

运行时 `__eventArgs()` 用 `type(e[2]) == "string"` 判断并跳过外设名。

### 键盘键码：GLFW（源码验证）★

Tom's Peripherals 键盘**透传 Minecraft 的 GLFW 键码**（`KeyboardWidget.keyPressed` 的 key 参数
原样发送），**不是** CC: Tweaked 原生键盘的 PC scancode。常用值：

| 键 | GLFW 码 | 备注 |
|---|---|---|
| Enter | 257 | 主键盘回车 |
| Tab | 258 | |
| Backspace | 259 | |
| Insert / Delete | 260 / 261 | |
| Right / Left / Down / Up | 262 / 263 / 264 / 265 | |
| Home / End | 268 / 269 | |
| Left Shift / Right Shift | 340 / 344 | 修饰键按/释放也是 key / key_up 事件，可跟踪 |
| Ctrl（Left/Right） | 341 / 345 | Ctrl+R/S/T/V 被客户端截获（重启/关机/终止/粘贴） |

另外两个语义要点（与 CC 原生 `key` 事件不同）：

- `tm_keyboard_key` 的第二个参数是 **isRepeat**（按住自动重复），**不是** CC 的 `isUp`；
  释放单独发 `tm_keyboard_key_up`。
- `tm_keyboard_char` 只覆盖可打印字符（`' '..'~'` 与 `160..255`），空格会发 char 事件。

## 7. 显示器连接规则

- GPU 只能识别 **Tom's Peripherals 的 Monitor 方块**（普通 CC 显示器不行）。
- 从**紧邻 GPU 的那块**显示器开始，向 GPU 的**右方和上方**延伸拼成矩形（`connectMonitors` 逻辑）。
- 拼接不合规则 → 识别不到 → `getSize()` 返回 0 → 启动报错（框架会明确提示）。

## 8. 框架已处理的坑（运行时适配层）

| 坑 | 处理 |
|---|---|
| draw 系列 1-based | 适配层坐标直通，无偏移 |
| `drawText` 越界抛错 | `__gpu.drawText` 先按 `getTextLength` 测量，越界直接跳过 |
| `filledRectangle` x<1 抛错 | 适配层把盒裁剪到视口内再调用 |
| fg/bg 必须是数字 | `fg` 缺省白、`bg` 缺省 `-1` |
| 颜色饱和转换 | `__color()` 统一转有符号 int32 |
| 字符间距 | `textPadding` 默认 1（与模组一致） |
| 行高 | 高度 = 8 × fontSize，padding 不影响 |
| 脏矩形残留 | 脏矩形外扩 2px（`DIRTY_PAD`）覆盖字形越界 |

## 9. 验证方法（如何反编译确认语义）

```bash
# 下载对应版本 jar（modrinth API）
curl -L "https://cdn.modrinth.com/data/ljgxd2P8/versions/<version>/toms-peripherals-1.21-<ver>.jar" -o tp.jar
unzip -o tp.jar -d tpjar
# 查看方法签名
javap -p com/tom/peripherals/gpu/BaseGPU.class        # 或 GPUBlockEntity\$GPUPeripheral
# 无 JDK 时可用项目内 scripts/ 之外的临时 Python class 解析器（本项目排查时用过）
```

关键类：
- `com/tom/peripherals/gpu/BaseGPU`（drawText / filledRectangle / getTextLength / fill）
- `com/tom/peripherals/util/ParamCheck`（getInt / toColor / optionalInt）
- `com/tom/peripherals/math/MathHelper`（floor = 饱和 `(int)` cast）
- `com/tom/peripherals/gpu/font/Font`（字体文件格式）
- `com/tom/peripherals/block/entity/GPUBlockEntity$GPUPeripheral`（屏幕缓冲、事件）

## 10. 排查经验（2025-08 真机问题回顾）

1. **纯黑屏、程序正常运行** → 启动时未调 `refreshSize()`（或顺序错误）→ 视口为 0 → 什么都不画。
   修复：固定 refreshSize → setSize → getSize。
2. **运行一次后崩溃 "Out of boundary"** → 坐标按 0-based 传（`x=0` 非法）。修复：1-based 直通。
3. **`Bad argument #5: (expected Number)`** → `drawText` 的 bg 传了 `nil`。修复：缺省传 `-1`。
4. **文字互相穿插/行重叠** → 行高按 5×7 算（实际 5×8）。修复：`FONT_H = 8`。
5. **字横向粘连** → padding 传 0（模组默认 1 = 字符间距）。修复：默认 `textPadding = 1`。
6. **文字超出背景、增量重绘留残影** → auto 尺寸容器漏算自身 padding + 文字越界不在脏矩形内。
   修复：`__measure` 返回内容+padding；脏矩形外扩 2px。
