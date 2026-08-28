# RL 泛化与训练可信度保障 V1

**功能框架：** `PASS`

**泛化/收敛证据：** `FUNCTIONAL_FRAMEWORK_COMPLETE_TRAINING_AND_FIELD_EVIDENCE_BLOCKED`

本轮没有训练策略。完成的是训练前必须冻结的多域实验、域外测试、消融、压力和影子运行功能，并用拒绝门禁防止把短烟测或合成场景写成“已收敛、已证明泛化”。

| 维度 | 数量 | 真实观测证据 | 当前解释 |
|---|---:|---:|---|
| 港口原型 | 4 | 1 | 其余 3 个仅为仿真功能域 |
| 季节 | 4 | 1 | 其余 3 个为环境叠加 |
| 船型族 | 4 | 0 个指定船舶标定 | 使用现有环境的船长/船宽/吃水上下文 |
| 随机种子 | 5 | 尚未执行训练 | 未来必须逐种子报告与保留失败种子 |
| 响应式交通行为 | 4 | 仿真交通 | 有界响应和哈希链回执 |

## 冻结评测计划

- 基础多域矩阵：320 个单元；
- 配对消融：30 对；
- 压力测试：40 个单元；
- 域外测试：20 个单元；
- 合计：410 个计划单元，`test_results_accessed=false`。

## 功能烟测

| 功能夹具 | 港口域 | 季节域 | 船型域 | 交通行为 | 回执数 | 结果 |
|---|---|---|---|---|---:|---:|
| smoke_tidal_service_yield | port_sim_tidal_estuary | season_spring_overlay | vessel_harbor_service | traffic_cooperative_yield | 5 | PASS |
| smoke_strait_feeder_delayed | port_sim_narrow_strait | season_summer_overlay | vessel_feeder_container | traffic_delayed_yield | 3 | PASS |
| smoke_archipelago_bulk_adversarial | port_sim_archipelago | season_autumn_overlay | vessel_panamax_bulk | traffic_adversarial_closing | 5 | PASS |
| smoke_reference_tanker_matching | port_long_beach_reference | season_winter_reference | vessel_large_tanker | traffic_speed_matching | 5 | PASS |

全部夹具继续使用原 45 维观测、原动作合同和原本船运动模型；响应式交通只改变明确标记的仿真目标船，并生成连续 SHA-256 回执。只读影子回执烟测产生 4 条建议、0 次下发。

## 当前拒绝门禁

- `training_performed=false`
- `convergence_demonstrated=false`
- `real_multi_port_generalization_demonstrated=false`
- `real_multi_season_generalization_demonstrated=false`
- `ood_acceptance_passed=false`
- `shadow_operation_completed=false`
- `production_authority=false`

真实泛化结论仍需至少 3 个真实港口、4 个真实季节、4 个船型族、5 个随机种子、每种子不少于 100,000 步、逐种子曲线、95% 分层配对 bootstrap 区间、全部域外/消融/压力单元，以及不少于 30 天/1,000 场只读影子运行和独立审查。

## 复现

```bash
.venv/bin/python tools/run_rl_generalization_assurance.py verify
.venv/bin/python -m unittest tests.test_rl_generalization_assurance -v
```
