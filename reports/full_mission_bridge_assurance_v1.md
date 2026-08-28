# 全任务软件船桥可信度报告 V1

**功能状态：** `FUNCTIONAL_SOFTWARE_BRIDGE_COMPLETE_EXTERNAL_ACCEPTANCE_BLOCKED`

本层面向强化学习航行模拟和教员训练，把现有雷达/自动雷达标绘仪、电子海图显示与信息系统、综合驾驶信息、执行控制、多岗位驾驶台资源管理、教员时间线和复盘，与新增的全球海上遇险与安全系统/甚高频/数字选择性呼叫程序训练及八扇区软件全向视景连接起来。

| 项目 | 当前证据 |
|---|---:|
| 船桥设备域 | 10/10 |
| Godot 运行验收 | 38/38 |
| 既有策略哈希 | 10/10 |
| 软件全任务船桥 | PASS |
| 物理全任务船桥 | BLOCKED |
| 教员资质与课程认可 | BLOCKED |

## 已实现的任务链

- 雷达量测、自动目标捕获、最近会遇距离/时间、杂波与设备故障。
- 电子海图航线监控、安全等深线、危险报警与确认。
- 遇险报警双步骤保护、紧急/安全/常规数字选择性呼叫、16 频道话音跟进、确认与取消；所有记录均为训练回执，真实射频发送恒为零。
- 自动舵目标首向/速度、推进限幅与反馈、人工立即接管和急停边界。
- 九类岗位、多学员本机网络、复诵、质疑和驾驶台资源管理检查。
- 八个 45° 软件视景扇区及 360° 扫描回执；只改变镜头，不改变船舶状态转移。
- 教员确定性故障时间线、报告和复盘链路。

## 强制阻断

- `physical_full_mission_bridge_verified=false`
- `type_approved_bridge_equipment=false`
- `real_radio_transmission=false`
- `instructor_qualification_verified=false`
- `approved_training_course=false`
- `production_authority=false`

外部证据模板当前状态为 `BLOCKED_EXTERNAL_FULL_MISSION_EVIDENCE_INCOMPLETE`。只有物理投影视场/时延、非回环多学员网络、真实设备、官方航海产品、教员资质、课程认可和独立验收材料全部提交并通过哈希校验后，才可进入独立鉴定；项目自身不能签发认可。

## 复现

```bash
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-full-mission-bridge-smoke
.venv/bin/python tools/run_full_mission_bridge_assurance.py verify
.venv/bin/python -m unittest tests.test_full_mission_bridge -v
```
