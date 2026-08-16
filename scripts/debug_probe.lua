--[[
  cc-react 诊断探针 —— 在游戏里运行以定位"黑屏"问题。

  用法（在 CC 电脑里）:
      lua debug_probe.lua left      (left 换成你的 GPU 所在 side)

  它会打印诊断信息并做几个醒目的测试绘制。请把终端输出和屏幕显示结果
  一起反馈（详见 README 或直接回复）。
]]

local side = arg and arg[1] or "left"
local gpu = peripheral.wrap(side)
if not gpu then
  error("在 side '" .. side .. "' 上找不到 GPU 外设", 0)
end
print("== cc-react 诊断探针 ==")
print("side:", side)

-- 1) 方法列表（确认 API 名称与 wiki 一致）
local okm, methods = pcall(function() return gpu.getMethods() end)
if okm and methods then
  local ser
  if textutils and textutils.serialize then
    local okSer, s = pcall(textutils.serialize, methods)
    ser = okSer and s or tostring(methods)
  else
    ser = tostring(methods)
  end
  print("getMethods:", ser)
else
  print("getMethods: 不可用/无此方法")
end

-- 2) 初始尺寸（程序启动时的视口来源）
local w, h, bw, bh, res = gpu.getSize()
print("初始 getSize():", w, h, bw, bh, res)

-- 3) refreshSize 之后（异步检测显示器，可能需要时间）
gpu.refreshSize()
sleep(0.5)
local w2, h2, bw2, bh2, res2 = gpu.getSize()
print("refreshSize 后:", w2, h2, bw2, bh2, res2)

-- 4) setSize(64) 之后
gpu.setSize(64)
local w3, h3, bw3, bh3, res3 = gpu.getSize()
print("setSize(64) 后:", w3, h3, bw3, bh3, res3)

-- 5) 全屏红色 —— 用于验证 fill + sync 链路
--    注意：如果颜色转换有误，看到的会是"白色"而非红色，请留意！
gpu.fill(0xFFFF0000)
gpu.sync()
sleep(0.5)
print("--- 屏幕现在应该是【红色】；如果是白色/其他颜色请反馈 ---")

-- 6) 绿色矩形 + 白色文字
gpu.filledRectangle(10, 10, 60, 60, 0xFF00FF00)
gpu.drawText(5, 80, "HELLO", 0xFFFFFFFF, 0xFF000000, 1, 0)
gpu.sync()
sleep(0.5)
print("--- 现在应该看到绿色方块和 HELLO 文字 ---")

-- 7) 坐标基验证（1-based）：draw 系列在 x/y < 1 时会抛 "Out of boundary"
--    （0 是非法坐标，因为 API 内部会做 x-1）。这一步预期会崩溃，属于正常诊断。
gpu.fill(0xFF000000)
local ok7, err7 = pcall(function()
  gpu.filledRectangle(1, 1, 5, 5, 0xFF00FF00)
  gpu.drawText(1, 8, "1BASED", 0xFFFFFFFF, 0xFF000000, 1, 0)
  gpu.sync()
  sleep(0.5)
  print("--- 左上角应有一个绿色方块和 1BASED 文字 ---")
  gpu.filledRectangle(0, 0, 5, 5, 0xFFFFFF00)
  gpu.sync()
  print("(0,0) 没有报错 —— 说明坐标是 0-based")
end)
if not ok7 then
  print("(0,0) 抛错: " .. tostring(err7) .. " —— 坐标是 1-based（符合预期）")
end

print("== 探针结束 ==")
print("请反馈：1) 上面的 print 输出  2) 每一步屏幕实际显示的颜色/形状")
