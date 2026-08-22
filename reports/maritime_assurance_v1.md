# 航海保障验证 V1 / Maritime Assurance Verification V1

**软件保障结论 / Software assurance:** `PASS`

**生产就绪 / Production readiness:** `BLOCKED_EXTERNAL_EVIDENCE_REQUIRED`

本报告新增可执行的三自由度动力学验证、可追溯 COLREG 场景回归、HIL 软件回环与故障注入，以及海试证据防伪门禁。通过只代表软件层验证成功，不代表指定船舶标定、COLREG 认证、物理 HIL、实船海试或生产授权。

This report adds executable 3-DOF dynamics checks, traceable COLREG scenario regression, HIL software loopback/fault injection, and a sea-trial evidence-completeness refusal gate. A pass is software evidence only—not named-vessel calibration, COLREG certification, physical HIL, a real-vessel sea trial, or production authority.

| 模块 / Module | 已完成的软件证据 / Completed software evidence | 结果 / Result | 仍需外部证据 / External evidence still required |
|---|---|---:|---|
| 动力学 / Dynamics | 3-DOF surge-sway-yaw、附加质量、非线性阻尼、桨/舵执行器、RK4；6/6 checks；48-D RL 环境连接 | PASS | 指定船舶辨识、zig-zag、回转圈、停船、装载工况标定；按新合同重新训练 |
| COLREG | 6/6 scenarios；11/11 positive/negative action cases | PASS | 多船/复杂水域验证、主管机关/船级/法律审查 |
| HIL | UDP JSON 完整性、NMEA 校验、时效/顺序/限幅、watchdog、drop/corrupt/replay/stale/range/session fault injection 和授权重启 | PASS | 目标控制器、真实传感/执行 I/O、独立急停、WCET/时钟、见证测试 |
| 海试 / Sea trial | 协议、遥测判据和“仿真指标再好也不得标记海试完成”的证据完整性拒绝门禁 | PASS | 船舶、许可、船长/操作员、独立见证、校准、风险评估、物理 HIL、原始日志与签字记录 |

## 明确状态 / Explicit status

- `named_vessel_dynamics_calibrated=false`
- `colreg_certified=false`
- `physical_hil_verified=false`
- `real_vessel_sea_trial_completed=false`
- `production_authority=false`

## 可复现命令 / Reproduction

```bash
.venv/bin/python tools/run_maritime_assurance.py verify
.venv/bin/python -m unittest tests.test_maritime_assurance -v
```
