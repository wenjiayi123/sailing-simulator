# 强化学习泛化与训练可信度保障 V1

这一层解决的是“如何可信地训练和证明泛化”，不是提前把现有策略重新训练一遍。它保留十套既有基础策略、所有检查点、模型、历史成功/失败报告和本船运动模型，先冻结统一训练之前必须具备的多域实验结构与拒绝门禁。

## 已实现的功能

- 多域矩阵：四类港口原型、四个季节域、四个船型族和五个随机种子，交通行为按单元均衡分配。
- 响应式交通：协同让路、延迟让路、对抗接近和速度匹配四类目标船，可根据本船状态有界改变目标船速度/航向，并生成连续 SHA-256 回执。
- 域外测试：港口原型、季节极端、船型尺度和复合域外四套冻结协议，训练域与评测域必须不相交。
- 配对消融：领域随机化、响应式交通、传感噪声、风浪流、避碰上下文和安全监督六项因素，要求同一随机种子配对比较。
- 压力测试：高密度交通、能见度不良、强横流、高风浪、最小富余水深、传感延迟、全球卫星导航系统欺骗和执行器延迟八类因素。
- 收敛门禁：至少五个随机种子、每种子不少于 100,000 步、逐种子曲线、失败/发散种子保留、平台期判据及验证耐心窗口；短烟测明确不能证明收敛。
- 只读影子运行：记录输入快照、策略哈希、建议、实际轨迹、偏差指标和操作员复核，不允许向执行控制层下发。
- 结果防伪：仅设置布尔标记不能通过门禁；还必须满足哈希绑定、计划单元完整性、置信区间、真实港口/季节数量、影子时长与独立评审。

## 冻结计划

当前评测计划共 410 个单元：

- 320 个港口×季节×船型×随机种子基础单元；
- 30 个配对消融单元；
- 40 个压力测试单元；
- 20 个域外测试单元。

计划在训练前生成并记录 `plan_sha256`，当前所有单元均为 `NOT_RUN`，`test_results_accessed=false`。

## 功能烟测与运动模型边界

四个跨域夹具使用现有 [`PortOpsNavigationEnv`](../tools/ship_rl/port_ops_environment.py) 的 45 维观测、原动作空间、原奖励和原本船运动计算。新增的 [`GeneralizationEvaluationEnv`](../tools/ship_rl/generalization_environment.py) 仅对带有显式 `interaction` 合同的仿真目标船进行有界响应；本船运动模型、观测合同、动作合同和策略全部报告为未修改。

功能烟测只是证明多域参数、响应式交通和回执链能执行，不调用任何已训练策略，不测算法性能，也不构成训练。

## 数据真实性边界

当前真实观测数据仍只有长滩港 2025 年 1 月 1–7 日历史数据，对应一个真实港口和一个真实季节窗口。其余三个港口原型与三个季节是 `SIMULATOR_AUTHORED` 功能域；它们可用于测试接口和压力行为，不能写成真实跨港或跨季节证据。

后续真实泛化结论至少需要：

- 三个来源清晰、时间隔离的真实港口数据包；
- 四个真实季节或等价长期时间窗；
- 四个船型族及其适用模型/标定边界；
- 五个随机种子统一长预算训练并逐种子报告；
- 95% 分层配对 bootstrap 置信区间；
- 完整域外、消融和压力结果；
- 不少于 30 天、1,000 场只读影子运行；
- 独立评审和所有输入、源码、策略、结果哈希。

## 文件与复现

- 活动定义：[`data/verification/rl_generalization_campaign_v1.json`](../data/verification/rl_generalization_campaign_v1.json)
- 空结果模板：[`data/verification/rl_generalization_results_manifest.template.json`](../data/verification/rl_generalization_results_manifest.template.json)
- 冻结计划：[`reports/rl_generalization_evaluation_plan_v1.json`](../reports/rl_generalization_evaluation_plan_v1.json)
- 保障报告：[`reports/rl_generalization_assurance_v1.json`](../reports/rl_generalization_assurance_v1.json)
- 人读报告：[`reports/rl_generalization_assurance_v1.md`](../reports/rl_generalization_assurance_v1.md)
- Godot 专项验收：[`reports/godot_rl_generalization_smoke_v1.json`](../reports/godot_rl_generalization_smoke_v1.json)

```bash
.venv/bin/python tools/run_rl_generalization_assurance.py verify
.venv/bin/python -m unittest tests.test_rl_generalization_assurance -v
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-rl-generalization-smoke
```

当前强制状态为：`training_performed=false`、`convergence_demonstrated=false`、`real_multi_port_generalization_demonstrated=false`、`real_multi_season_generalization_demonstrated=false`、`shadow_operation_completed=false`、`production_authority=false`。
