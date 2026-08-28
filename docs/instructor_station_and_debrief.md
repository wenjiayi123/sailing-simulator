# 教员站、设备故障矩阵与复盘边界

更新时间：2026-08-28

## 已实现

- 三套确定性演练时间线：受限能见度驾驶台设备处置、位置与首向传感器不一致、操纵信息反馈链失效。
- 九类显示设备故障：雷达电源、雷达距离/方位偏差、电罗经偏差、全球导航卫星系统位置冻结、船舶自动识别系统丢失、计程仪、舵角反馈和测深仪失效。
- 每次载入、启动、暂停、手动推进、故障注入、恢复和复位均生成带序号、协调世界时、演练时刻、来源与执行状态的唯一回执。
- 未知模板和未知故障主动拒绝；设备控制器不可用时不会伪造成功。
- 教员报告同时保存场景、天气、船队、航线、障碍、事故、操作日志、完整时间线、故障矩阵和执行回执，复盘面板可接收并继续导出。

## 不变边界

- 故障只作用于研究级雷达、自动雷达标绘、电子海图和操纵信息显示；不会改变船舶运动模型或实际舵效。
- 不修改、重训或覆盖任何既有策略、权重、测试轨迹和失败记录。
- 当前结果不是认可的全任务驾驶台教员站验收、型式认可或海上试验。

## 复现

```bash
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-instructor-debrief-smoke
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-button-interaction-smoke
```

运行证据：`reports/godot_instructor_debrief_smoke_v2.json` 为 16/16，`reports/godot_button_interaction_smoke_v1.json` 为 186/186。
