# 键盘输入与焦点管理（里程碑 1）

## Input 组件

`<Input>` 是**受控**组件：文本存在 app 的 `useState` 里，`onChange` 回传每次编辑后的新值；
内置编辑（光标插入/删除、方向键、粘贴）都走 `onChange`，Enter 触发 `onSubmit`：

```tsx
function Login() {
  const [name, setName] = useState('');

  return (
    <Panel style={{ backgroundColor: '#131318', padding: 10, flexDirection: 'column' }}>
      <Text style={{ color: '#8a8a95' }}>name:</Text>
      <Input
        value={name}
        onChange={setName}
        placeholder="type your name"
        style={{ width: 180, height: 24, marginTop: 4 }}
        onSubmit={() => print('hello ' + name)}
      />
    </Panel>
  );
}
```

## 焦点模型

- 点击输入框聚焦（光标定位到点击处，边框变为 `focusBorderColor`，光标闪烁）
- Tab / Shift+Tab 在输入框之间循环焦点
- 点击输入框以外的区域失焦
- `onKey(key, isUp)` 可拿到原始按键（**GLFW 键码**，Tom's 键盘透传 Minecraft 键码）

## 内置编辑功能

- 字符插入/删除
- Backspace/Delete
- 方向键/Home/End
- Enter 触发 `onSubmit`
- `tm_keyboard_paste` 粘贴

## 长文本处理

Input 对超出内容盒的文本做**真实输入框式处理**：
- 文本被裁剪到内容盒内（不越界绘制）
- 视图随光标水平滚动 —— 输入到末尾时文本左移、Home/左移逐步回滚、Backspace 保持文本尾随光标
- 点击映射会按滚动偏移定位到可见字符
- 光标由 `__layoutInputOffset` 保持在内容盒内

## 光标闪烁

光标闪烁由 `os.startTimer(0.5)` 驱动：输入框聚焦时每 0.5s 产生一次极小脏矩形重绘；
按键/点击会重置闪烁并重新计时。对性能敏感的场景可在 `onChange` 中自行管理。

## 键盘事件契约

Tom's Peripherals 键盘**透传 Minecraft 的 GLFW 键码**（不是 CC 的 PC scancode）：

| 键 | GLFW 码 | 备注 |
|---|---|---|
| Enter | 257 | 主键盘回车 |
| Tab | 258 | |
| Backspace | 259 | |
| Delete | 261 | |
| Left | 263 | |
| Right | 262 | |
| Home | 268 | |
| End | 269 | |
| Left Shift / Right Shift | 340 / 344 | 修饰键按/释放也是 key / key_up 事件 |

事件形态（fireNativeEvents=false）：
- `tm_keyboard_key`（peripheral, key, **isRepeat**）—— 按下和自动重复都发
- `tm_keyboard_key_up`（peripheral, key）—— 释放单独发
- `tm_keyboard_char`（peripheral, char）—— 可打印字符含空格
- `tm_keyboard_paste`（peripheral, content）—— 剪贴板内容

## 语义要点

- `tm_keyboard_key` 的第二个参数是 **isRepeat**（按住自动重复），**不是** CC 的 `isUp`；
  释放单独发 `tm_keyboard_key_up`
- `tm_keyboard_char` 只覆盖可打印字符（`' '..'~'` 与 `160..255`），空格会发 char 事件
