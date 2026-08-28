# 物理驾驶台与硬件在环就绪检查 V1

**软件就绪门禁：** `PASS`

**现场状态：** `BLOCKED_PHYSICAL_BRIDGE_EVIDENCE_INCOMPLETE`

本报告证明检查器能够读取物理硬件清单、输入输出通道、安全联锁、时延/看门狗、校准/见证和标准映射，并在模板没有现场证据时保持阻断。它不证明已经连接物理驾驶台。

| 模块 | 当前结果 | 缺口 |
|---|---:|---|
| 物理硬件清单 | BLOCKED | helm_input, engine_telegraph, emergency_stop_channel_a, emergency_stop_channel_b, manual_override, gnss_receiver, heading_sensor, speed_log, rudder_feedback, throttle_feedback, bridge_display, target_controller, real_io_rack, safety_relay, clock_source |
| 输入输出通道合同 | BLOCKED | heading_deg, position_lat_lon, speed_knots, rudder_command, rudder_feedback, throttle_command, throttle_feedback, emergency_stop_channel_a, emergency_stop_channel_b, manual_reset_key, manual_override, watchdog_heartbeat, target_controller_health, io_rack_health, clock_sync |
| 独立安全联锁 | BLOCKED | independent_emergency_stop, manual_control_priority, hardwired_neutral_state, power_loss_neutralization, watchdog_independent_of_application, network_isolation, hazard_analysis, cybersecurity_review, dual_channel_estop_independence, controller_deadline_monitor, feedback_disagreement_trip, recovery_manual_rearm |
| 时延、抖动、最坏执行时间、时钟 | BLOCKED | 需要目标硬件原始日志和见证 |
| 目标控制器、实时操作系统、真实 I/O 与双通道急停 | BLOCKED | 需要设备身份、构建版本、接线、掉线恢复和 12 项见证测试 |
| 现场、标定和签字证据 | BLOCKED | 需要现场填写与外部鉴定 |
| 标准追踪 | 13 项已路由 | 13 项开放/部分/未评估 |

## 强制状态

- `physical_hil_verified=false`
- `site_delivery_ready=false`
- `stcw_approved=false`
- `dnv_certified=false`
- `production_authority=false`

## 复现

```bash
.venv/bin/python tools/run_physical_bridge_readiness.py verify
.venv/bin/python tools/run_physical_hil_runtime.py verify
.venv/bin/python -m unittest tests.test_physical_bridge_readiness -v
```
