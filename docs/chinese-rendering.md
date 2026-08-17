# 中文渲染（自定义字体，2025-08）

## 概述

Tom's GPU 的默认字体（ascii）是**只读**的（真机验证 `Selected font is not modifiable`），
且只有 256 个 ASCII 字形。中文支持走「可修改字体 + 二进制字库文件 + 懒加载」。

## 启用方式

主程序调用 `ui.setChineseFont("hanchan16-common.fnt")`（`start()` 之前）。
`start()` 内初始化：`setFont("unicode_page_e0")`（切到可修改字体）→ `clearChars()`
→ 注册 ASCII 0x20-0x7E + □ 回退槽（0xFF）。

不调 `setChineseFont` 时行为与之前完全一致（默认 5x8 字体）。

## 字库文件格式

字库文件（format v1，`make_font_bin.py` 生成）放电脑磁盘：
`"CCF1"` 魔数 + 条目数 + 37B 定长条目（码点 u32 BE + 宽度 u8 + 16×u16 BE 位图行，
bit0=最左像素），按码点升序 → 运行时 `fs.open("rb")` + 二分查找按需读取。

## 渲染流程

**所有文本**在进 `drawText`/`getTextLength` 前过 UTF-8→槽号编码：ASCII 直通，
汉字按需从字库注册（`addNewChar`，槽 0x80-0xFE，最多 127 个不同汉字/会话），
字库中没有的字渲染为 **□**（槽 0xFF）。度量、裁剪、Input 光标均按编码后串计算。

## 生成字库

```bash
python3 make_font_bin.py chinese16px.ttf -o hanchan16-common.fnt --chars-file 字表.txt
```

3755 GB2312 一级 ≈ 139KB，含 ASCII。

## 要点与限制

- **Opt-in**：不调 `setChineseFont` 时行为与之前完全一致（默认 5x8 字体）。
- 启用后所有文字按 **16px** 字高渲染（`fontSize` 为倍率），行高 = 16×fontSize；
  空格宽度被模组硬编码为 5+1=6px（与度量一致）。
- 槽位上限 127 个汉字/会话：超过后新字显示 □。动态内容（网络/用户输入）会懒加载
  新字形，槽满后可自行加 LRU 淘汰（`delChar` + `addNewChar`，已在探针中验证）。
- `Input` 编辑已改为**按字符**操作（Backspace/Delete/方向键不会拆坏多字节汉字）。
