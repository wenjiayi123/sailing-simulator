# 复杂避碰规则功能保障 V2 / Complex COLREG Functional Assurance V2

**功能结论：** `PASS`

- 原 V1 基线：6 个双船场景、11 个动作案例，`legacy_v1_replaced=false`。
- V2 复杂层：16/16 场景，45/45 正反动作/信号案例。
- 覆盖：多船责任图、狭水道、分道通航、操纵能力受限船、失去控制船、捕鱼船、灯号号型、能见度不良声号、复杂能见度和地方规则模板。
- 未训练任何策略，未修改船舶运动模型或现有策略。

| 场景 | 目标数 | 主要责任 | 案例匹配 | 结果 |
|---|---:|---|---:|---:|
| multi_ship_mixed_duties | 3 | give_way_to_privileged_vessel | 4/4 | PASS |
| narrow_channel_keep_starboard | 0 | monitor | 3/3 | PASS |
| narrow_channel_crossing_impedance | 1 | give_way | 2/2 | PASS |
| narrow_channel_overtaking_agreement | 1 | give_way | 2/2 | PASS |
| tss_lane_following | 0 | monitor | 3/3 | PASS |
| tss_right_angle_crossing | 0 | monitor | 3/3 | PASS |
| give_way_to_nuc_and_verify_signals | 1 | give_way_to_privileged_vessel | 3/3 | PASS |
| own_nuc_stand_on_status | 1 | stand_on_special_status | 2/2 | PASS |
| give_way_to_ram_and_verify_signals | 1 | give_way_to_privileged_vessel | 3/3 | PASS |
| give_way_to_fishing_nontrawling | 1 | give_way_to_privileged_vessel | 3/3 | PASS |
| fishing_trawling_signature | 1 | give_way_to_privileged_vessel | 2/2 | PASS |
| restricted_visibility_forward_target | 1 | safe_speed_and_avoidance | 4/4 | PASS |
| restricted_visibility_target_abaft_beam | 1 | safe_speed_and_avoidance | 2/2 | PASS |
| restricted_visibility_power_sound | 1 | safe_speed_and_avoidance | 3/3 | PASS |
| restricted_visibility_nuc_sound | 1 | safe_speed_and_avoidance | 2/2 | PASS |
| simulated_local_port_rules | 0 | monitor | 4/4 | PASS |

## 边界

地方规则文件是 `SIMULATOR_AUTHORED_EXERCISE_RULES`，`official_authorization_verified=false`。本报告通过只证明确定性仿真功能和回归门禁，不构成法律解释、官方地方规则接入、《国际海上避碰规则》认证、型式/船级认可或实船控制授权。

## 复现

```bash
.venv/bin/python tools/run_colreg_complex_assurance.py verify
.venv/bin/python -m unittest tests.test_colreg_complex -v
```
