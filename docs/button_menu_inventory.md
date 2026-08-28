# 航行模拟器按钮与流程验收清单

更新时间：2026-08-28

## 验收结论

- 运行时共发现 288 个可交互控件，覆盖 22 个业务面板及 H 总控返回层。
- 实际点击、选择、切换、启动与终止共完成 198 项交互断言，结果为 198/198 通过。
- 主场景导航与面板联动完成 84 项断言，结果为 84/84 通过；包含综合驾驶台、多源传感融合、执行控制闭环、指定船舶数字孪生、港内作业、多驾驶台协同、物理驾驶台、安全案例、复杂避碰规则、RL 泛化可信度、全任务软件船桥、船舶网络安全、港口生产联动入口和快捷键，以及主场景操纵回归。
- 综合驾驶台专项完成 15 项断言，结果为 15/15 通过；覆盖雷达测量边界、自动雷达标绘目标捕获/最近会遇距离/到达最近会遇点时间、电子海图航线检查、操纵信息、传感器故障阻断及冻结策略哈希。
- 多源传感融合专项完成 21 项断言，结果为 21/21 通过；覆盖雷达、自动识别系统、光电、红外、全球卫星导航系统、惯性导航系统，以及遮挡、误报、延迟、欺骗、双失效阻断和冻结策略哈希。
- 执行控制闭环专项完成 28 项断言，结果为 28/28 通过；覆盖自动舵、推进指令、控制权仲裁、幅值/斜率限制、反馈确认、watchdog、人工抢权、急停锁存、故障降级和冻结文件哈希。
- 指定船舶数字孪生专项完成 17 项断言，结果为 17/17 通过；覆盖七类操纵试验、三个装载工况、参数辨识、分工况/跨试验误差包络、模板导出、拒绝门禁和冻结文件哈希。
- 教员站与复盘专项完成 16 项断言，结果为 16/16 通过；覆盖三套时间线、九类设备故障、未知故障阻断、唯一执行回执、故障恢复、复盘接收和冻结策略哈希。
- 港内作业训练专项完成 18 项断言，结果为 18/18 通过；覆盖靠泊、离泊、拖轮、锚泊、系泊、侧推器干运行、显式确认门槛、唯一回执与冻结策略哈希。
- 多驾驶台协同专项完成 21 项断言，结果为 21/21 通过；覆盖岗位权限、闭环复诵、驾驶台质疑/回应、态势简报、团队检查、本机 UDP 收发、外部绑定阻断和冻结策略哈希。
- 物理驾驶台与 HIL 专项完成 21 项断言，结果为 21/21 通过；覆盖目标控制器状态机、WCET、时钟、掉线恢复、双通道急停、真实 I/O 适配合同、现场模板导出、外部门禁和冻结文件哈希。
- 法规与安全案例专项完成 31 项断言，结果为 31/31 通过；覆盖运行设计域、危险/控制、最小风险状态、故障树、远程控制中心、RACI、法规路由、证据哈希、外部审查包和冻结文件哈希。
- 复杂避碰规则专项完成 25 项断言，结果为 25/25 通过；覆盖 16 场景/45 案例、多船逐目标责任图、Rule 9/10/18/19/35、特殊身份、灯号号型、声号、地方规则来源边界、真实检查器、证据导出和 V1 保留。
- RL 泛化可信度专项完成 30 项断言，结果为 30/30 通过；覆盖 410 个冻结单元、多域清单、响应式交通、OOD、消融、压力、收敛拒绝、只读影子回执、十策略哈希和未训练边界。
- 全任务软件船桥专项完成 38 项断言，结果为 38/38 通过；覆盖十设备域、遇险双步骤保护、紧急/安全/常规呼叫、话音跟进、自动舵/推进反馈、人工立即接管、八扇区软件 360° 扫描、任务编排、回执链、十策略哈希和外部认可阻断。
- 船舶网络安全专项完成 61 项断言，结果为 61/61 通过；覆盖七区默认拒绝、四角色最小权限、认证锁定与防重放、RSA 签名更新隔离、软件启动哈希、八规则入侵检测、链式审计、恢复确认、八用例攻击活动、总览入口、F11 快捷键、脱敏导出和十策略哈希。
- 港口生产联动专项完成 53 项断言，结果为 53/53 通过；覆盖六适配器签名、载荷哈希、序号/唯一快照防重放、时效/字段/单位、断链降级、人工确认、调度回执、审计链、总览入口、F10 快捷键、导出和十策略哈希。
- 公开版货运 RL 面板的 5 个精确训练入口因依赖未公开训练包而主动禁用；冻结测试证据仍可查看和回放。这是 fail-closed 边界，不是按钮故障。

## 控件盘点

| 面板 | 控件数 | 核心流程 |
|---|---:|---|
| 货运电路 RL / H 总控 | 23 | 策略选择、冻结回放、速度、镜头、8 个模块入口 |
| 系统与指标总览 | 22 | 数据契约校验、指标页、训练顾问、证据矩阵、边界审查、综合驾驶台、全任务软件船桥、船舶网络安全、港口生产联动、多源传感融合、执行控制闭环、指定船舶数字孪生、港内作业、多驾驶台协同、HIL、安全案例、复杂避碰规则和 RL 泛化可信度入口 |
| RL 训练中心 | 26 | 船舶、数据集、算法、策略、训练、测试回放、安全设置 |
| 航线规划 | 8 | 任务、联动场景、船舶重定位、规划参数、任务快照 |
| 风险决策 | 6 | 策略预设、验证刷新、规则与证据入口 |
| 海况与时间 | 11 | 公共天气、天气模式、时间倍率、昼夜锁定 |
| AIS 船队态势 | 3 | 船舶选择、跟随/取消跟随 |
| 训练与仿真复盘 | 6 | 记录、评分、导出、策略归因 |
| 小懿系统助手 | 35 | 船舶/风险/障碍/天气/模式/设备故障矩阵/演练时间线/报告联动 |
| 综合驾驶台 | 12 | 雷达量程/增益/杂波、显示方式、自动雷达标绘捕获与释放、电子海图安全参数、图层、航线检查、告警确认 |
| 多源传感融合 | 8 | 雷达/自动识别系统/光电/红外/全球卫星导航系统/惯性导航系统健康、六类故障注入、恢复和审计回执 |
| 执行控制闭环 | 13 | 仿真武装、RL 控制权、自动舵、人工接管、急停/复位、链路/反馈/执行器故障与恢复 |
| 指定船舶数字孪生 | 6 | 实船证据覆盖、七类试验选择、误差包络、缺口浏览、证据模板导出与关闭 |
| 港内作业训练 | 11 | 六套程序、显式确认、闭环复诵、训练几何确认、侧推器干运行、步骤提交、导出 |
| 多驾驶台协同 | 16 | 会话、岗位、消息权限、复诵、质疑、态势简报、团队检查、本机 UDP、导出 |
| 物理驾驶台就绪 | 6 | 运行证据检查器、运行 HIL 状态机烟测、导出现场模板、重新载入、标准条目浏览、关闭 |
| 法规与安全案例 | 9 | 运行安全案例、导出外部审查包、危险/MRC/主张浏览、ODD越界演练、证据缺口和关闭 |
| 复杂避碰规则 | 8 | 真实规则验收、场景选择、前后切换、案例检查、证据包导出、重新载入和关闭 |
| RL 泛化可信度 | 8 | 真实框架验收、多域/夹具选择、夹具轮换、证据缺口、冻结计划导出、重新载入和关闭 |
| 全任务软件船桥 | 27 | 五专业子台、任务准备、离港检查、自动舵/推进、人工接管、八扇区/全向扫描、遇险/紧急/安全/常规通信、导出与关闭 |
| 船舶网络安全 | 13 | 训练身份登录/退出、允许/阻断流、软件完整性、签名/篡改更新、恢复点/确认恢复、八用例攻击活动、告警确认、脱敏导出和关闭 |
| 港口生产联动 | 11 | 六适配器选择/接入、断链/恢复、时效看门狗、引航/拖轮人工确认、回执、导出和关闭 |
| **合计** | **288** | **198 项通用交互 + 15 项驾驶台 + 21 项多源传感 + 28 项执行控制 + 17 项指定船舶孪生 + 16 项教员站 + 18 项港作 + 21 项协同 + 21 项 HIL + 31 项安全案例 + 25 项复杂避碰规则 + 30 项泛化可信度 + 38 项全任务船桥 + 61 项船舶网络安全 + 53 项港口生产联动专项** |

## 已修复与完善

1. 数据契约校验由“只显示子进程 PID”改为同步读取真实退出码和输出；失败时不会显示成功。
2. 公开版缺失精确训练脚本和配置时，相关入口主动禁用，并显示 `READ-ONLY EVIDENCE` 边界提示。
3. RL 算法、复盘策略、航线任务及联动开关现在均有即时状态反馈，不再出现“选择后界面无反应”的歧义。
4. 新增运行时按钮盘点和全流程交互回归，覆盖动态生成按钮、弹窗、文件导出、短时训练进程启动与立即终止。
5. 新增研究级综合驾驶台；它只读接入模拟器状态，不发出舵/车钟指令，并明确标注历史公开 AIS、非官方海图、非型式认可和无生产权限边界。

## 回归证据

- `reports/godot_button_inventory_v1.json`：288 个运行时控件及其 handler、可见性、禁用原因和选项。
- `reports/godot_button_interaction_smoke_v1.json`：198 项实际交互及预期结果。
- `reports/godot_ui_navigation_smoke_v1.json`：84 项导航与面板联动结果。
- `reports/godot_integrated_bridge_smoke_v1.json`：15 项综合驾驶台专项运行结果与冻结策略哈希。
- `reports/godot_multisensor_fusion_smoke_v1.json`：六通道、时间/来源/质量、故障降级、外部接入拒绝与冻结策略哈希。
- `reports/godot_execution_control_smoke_v1.json`：执行控制、反馈、仲裁、watchdog、人工接管、急停与冻结文件哈希。
- `reports/godot_named_vessel_twin_smoke_v1.json`：海试辨识工作流、分工况误差包络、证据模板、拒绝门禁与冻结文件哈希。
- `reports/named_vessel_twin_readiness_v1.json`：指定船舶实测数据、仪器、装载和独立审查缺口。
- `reports/godot_instructor_debrief_smoke_v2.json`：16 项教员时间线、设备故障矩阵与复盘证据链运行结果。
- `reports/godot_port_operations_training_smoke_v1.json`：18 项港内作业程序、门槛、回执和不改变动力学边界结果。
- `reports/godot_bridge_team_collaboration_smoke_v1.json`：21 项岗位、闭环通信、驾驶台资源管理和本机 UDP 运行结果。
- `reports/godot_physical_bridge_readiness_smoke_v1.json`：21 项目标控制器运行时、HIL/标准、模板导出、现场准入与拒绝门禁结果。
- `reports/physical_hil_runtime_functional_smoke_v1.json`：17 项时序、故障、恢复、双通道急停和回执链功能烟测。
- `reports/godot_safety_case_smoke_v1.json`：31 项运行设计域、安全案例、界面、外部审查包和拒绝门禁验收。
- `reports/godot_colreg_complex_smoke_v1.json`：25 项复杂规则场景、责任、信号、界面、V1 保留和外部边界验收。
- `reports/colreg_complex_assurance_v2.json`：16 场景/45 案例、十类能力覆盖、规则追踪和地方规则来源边界。
- `reports/godot_rl_generalization_smoke_v1.json`：30 项多域、响应式交通、冻结评测、拒绝门禁、界面与导出验收。
- `reports/rl_generalization_assurance_v1.json`：410 个计划单元、十策略哈希、功能烟测和真实泛化证据状态。
- `reports/godot_full_mission_bridge_smoke_v1.json`：38 项软件船桥任务链、通信、操纵、全向视景和边界验收。
- `reports/full_mission_bridge_assurance_v1.json`：十设备域、十策略哈希、外部物理/资质证据门禁和机器可读结论。
- `reports/godot_bridge_cybersecurity_smoke_v1.json`：61 项网络分区、身份、签名、检测、恢复、攻击活动、界面与边界验收。
- `reports/maritime_cybersecurity_assurance_v1.json`：十五项功能与证据门禁、十策略哈希及生产网络安全阻断结论。
- `reports/godot_port_production_integration_smoke_v1.json`：53 项六适配器、数据/降级/协调/回执/审计、界面和边界验收。
- `reports/port_production_integration_assurance_v1.json`：十四项功能闭环、十策略哈希及真实港口站点准入阻断结论。
- `reports/mass_safety_case_assessment_v1.json`：主张、危险、控制、证据、责任和外部准入状态的机器可读评估。
- `reports/physical_bridge_readiness_v1.json`：物理硬件、通道、联锁、时序、现场证据与标准映射的机器可读检查。
- `reports/godot_acceptance_v1.json`、`reports/godot_acceptance_v3.json`：Godot/Python 跨平台接受测试。

## 复现命令

```bash
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-button-inventory
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-button-interaction-smoke
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-ui-navigation-smoke
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-integrated-bridge-smoke
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-multisensor-fusion-smoke
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-execution-control-smoke
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-named-vessel-twin-smoke
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-instructor-debrief-smoke
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-port-operations-training-smoke
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-bridge-team-collaboration-smoke
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-physical-bridge-readiness-smoke
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-safety-case-smoke
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-colreg-complex-smoke
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-rl-generalization-smoke
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-full-mission-bridge-smoke
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-bridge-cybersecurity-smoke
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-port-production-integration-smoke
.venv/bin/python tools/run_colreg_complex_assurance.py verify
.venv/bin/python tools/run_rl_generalization_assurance.py verify
.venv/bin/python tools/run_full_mission_bridge_assurance.py verify
.venv/bin/python tools/run_maritime_cybersecurity_assurance.py verify
.venv/bin/python tools/run_port_production_integration_assurance.py verify
.venv/bin/python -m unittest discover -s tests -v
```

交互回归中的“启动训练”仅验证进程能够从界面按正确参数启动，并立即终止；它不等于训练收敛、实船测试或生产部署。
