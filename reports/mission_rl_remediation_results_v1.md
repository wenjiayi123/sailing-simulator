# 场景强化学习本轮验收结果

本报告由实际训练、模型冻结、独立测试和 Godot 原生闭环回执生成。所有接管动作来自 SAC 神经网络；不使用专家演示、传统控制器动作兜底或轨迹搬移。原有模型和失败实验均保留。

| 场景 | 数值独立测试 | 原生闭环与切换准入 | 平均完成时间 | 最小静态/动态净距 | 最小船间中心距 |
|---|---:|---|---:|---:|---:|
| 开放水域 | 20/20 | 通过 | 95.4 秒 | 24.38 米 | 不适用 |
| 港口引航水域 | 20/20 | 通过 | 64.7 秒 | 1.72 米 | 不适用 |
| 自动靠泊评测水域 | 20/20 | 通过 | 74.7 秒 | 8.73 米 | 不适用 |
| 自动离泊评测水域 | 20/20 | 通过 | 60.2 秒 | 4.26 米 | 不适用 |
| 狭水道对遇会船 | 20/20 | 通过 | 83.6 秒 | 20.59 米 | 27.05 米 |
| 右舷来船交叉 | 20/20 | 通过 | 75.7 秒 | 53.85 米 | 126.44 米 |
| 狭水道追越 | 未通过准入 | NOT_CONVERGED | — | — | 不适用 |

净距采用训练环境中半径 3.2 米的本船保守碰撞包络；船间中心距是另一项独立会遇指标。独立测试为各场景 20 个未参与训练与模型选择的种子：完整原始起点，位置 ±1 米、船首向 ±4 度、风浪流幅值 ±10%。模型选择使用另外八个验证种子，种子 0 仅用于标称诊断。

## 业务意义

1. 靠泊以船位、船首向、航速和横荡同时达标并保持三秒为终点，能评估低速稳船能力。离泊另查离开泊位距离和出口航速。
2. 对遇与交叉分别考察足够早的右转、右侧航道保持或从目标船船尾通过，并统计最小船间距离。
3. 接管入口统一在 N 航行任务面板；应用任务后启用场景强化学习，后续切换已准入场景会匹配对应网络。无合格网络或合同不匹配时不会接管。
4. 网络权重、训练代码、动力学与场景来源、独立测试和原生执行版本相互绑定；原生验证必须实际运行当前代码，不能只重新生成哈希来沿用旧结果。

## 仍未解决的范围

未准入候选的完整失败轨迹、训练进度与验证记录保存在各独立实验目录。训练回合成功率可能包含课程起点，不能代替从完整起点开始的验证成功率。

- 完整追越仍未收敛：最后候选累计 727,000 步，本次新增 152,000 步（包含训练策略采样的回放预热）。最后三个完整起点验证回合全部失败：虽走完五个航点并保持本船安全净距，仍未在目标船抵达地图边界前完成驶过。正式 20 回合测试未启动，策略未准入。
- 47 维 p47_pure_attempt_01：100,000 步、24,500 次演员/评论家更新；最低难度验证 37.5% 成功、3 次碰撞。状态 L1_NOT_CONVERGED，未晋级，未访问正式测试集，未替换原有策略。

目标慢船另有独立的 10 维 SAC 航道保持策略：20,000 步训练，20 个独立测试中 20/20 成功，最大航道偏差 3.97 米；90 秒 Godot 原生验证状态为 PASS。这一结果不代替本船的完整追越验收。

- 旧 45 维长滩港多算法基准主要属于短训练，原有不合格结果仍然有效；本轮场景策略不改变该基准的结论。
- 跨港与分布外 410 单元泛化计划尚未完成训练；拖轮、锚泊、系泊和侧推程序模块缺少经过验证的受力转移环境，仍不能列为已训练强化学习能力。

## 证据边界

这是同一场景几何、单次训练种子、小范围扰动下的仿真任务验收，不能推出跨港泛化、实船收敛或现场部署安全。原生验收验证的是自主运动任务，人工任务前检查和培训资质评分单独记录；动作任务通过不代表所有程序训练步骤完成。动作量只是能耗代理，没有燃料或电池标定，未宣称节省费用。

`simulation_mode=true`、`live_data_verified=false`、`production_authority=false`。公开版本提供离线仿真代码与证据，不代表外部系统部署。

## 复现入口

环境：项目 `.venv`，依赖见 `requirements-rl.txt`；训练使用 Stable-Baselines3 SAC，真实在线环境交互。编译物理加速器需要本机 C 编译器。

```bash
.venv/bin/python -m unittest tests.test_mission_rl -v
.venv/bin/python tools/audit_mission_rl.py
.venv/bin/python tools/report_mission_rl.py
# 新实验输出目录必须不存在，避免覆盖历史证据
.venv/bin/python tools/train_mission_rl.py --scenario auto_berthing --output reports/artifacts/mission_rl_v1/NEW_ATTEMPT --steps 300000
```

原生闭环：Godot 执行 `tools/godot_mission_rl_validation.gd`，传入 `--mission-rl-validation`、`--actor=res://.../actor.json` 和独立 `--output=res://.../native_validation_XX.json`；同目录需有 `inference_golden.json`。`tools/godot_mission_rl_switch_smoke.gd` 检查起点、目标船碰撞恢复、合格策略启用与自动换网。

## 每次实验

| 实验 | 场景 | 累计模型步数 | 本次新增步数 | 状态 |
|---|---|---:|---:|---|
| [berthing_attempt_01](artifacts/mission_rl_v1/berthing_attempt_01/manifest.json) | auto_berthing | 25000 | 见父模型及回执 | INTERRUPTED_REPORT_SERIALIZATION |
| [berthing_attempt_02](artifacts/mission_rl_v1/berthing_attempt_02/manifest.json) | auto_berthing | 200000 | 见父模型及回执 | PASS |
| [crossing_attempt_01](artifacts/mission_rl_v1/crossing_attempt_01/manifest.json) | crossing_starboard | 25000 | 见父模型及回执 | INTERRUPTED_REPORT_SERIALIZATION |
| [crossing_qualification_01](artifacts/mission_rl_v1/crossing_qualification_01/receipt.json) | crossing_starboard | 25000 | 见父模型及回执 | PASS |
| [harbor_attempt_01](artifacts/mission_rl_v1/harbor_attempt_01/manifest.json) | harbor | 275000 | 见父模型及回执 | NOT_CONVERGED |
| [harbor_business_02](artifacts/mission_rl_v1/harbor_business_02/manifest.json) | harbor | 275000 | 见父模型及回执 | NOT_CONVERGED |
| [harbor_business_05](artifacts/mission_rl_v1/harbor_business_05/manifest.json) | harbor | 350000 | 75000 | PASS |
| [harbor_terminal_03](artifacts/mission_rl_v1/harbor_terminal_03/manifest.json) | harbor | 100000 | 见父模型及回执 | NOT_CONVERGED |
| [harbor_terminal_04](artifacts/mission_rl_v1/harbor_terminal_04/manifest.json) | harbor | 100000 | 见父模型及回执 | NOT_CONVERGED |
| [harbor_terminal_06](artifacts/mission_rl_v1/harbor_terminal_06/manifest.json) | harbor | 60000 | 见父模型及回执 | INTERRUPTED_ALTERNATIVE_PASSED |
| [head_on_attempt_01](artifacts/mission_rl_v1/head_on_attempt_01/manifest.json) | narrow_channel_head_on | 25000 | 见父模型及回执 | INTERRUPTED_REPORT_SERIALIZATION |
| [head_on_attempt_02](artifacts/mission_rl_v1/head_on_attempt_02/manifest.json) | narrow_channel_head_on | 75000 | 见父模型及回执 | PASS |
| [open_water_attempt_01](artifacts/mission_rl_v1/open_water_attempt_01/manifest.json) | open_water | 75000 | 见父模型及回执 | PASS |
| [overtaking_attempt_01](artifacts/mission_rl_v1/overtaking_attempt_01/manifest.json) | narrow_channel_overtaking | 300000 | 见父模型及回执 | NOT_CONVERGED |
| [overtaking_business_02](artifacts/mission_rl_v1/overtaking_business_02/manifest.json) | narrow_channel_overtaking | 300000 | 见父模型及回执 | NOT_CONVERGED |
| [overtaking_clearance_curriculum_12](artifacts/mission_rl_v1/overtaking_clearance_curriculum_12/manifest.json) | narrow_channel_overtaking | 727000 | 152000 | NOT_CONVERGED |
| [overtaking_constrained_04](artifacts/mission_rl_v1/overtaking_constrained_04/manifest.json) | narrow_channel_overtaking | 575000 | 200000 | NOT_CONVERGED |
| [overtaking_dual_sac_07](artifacts/mission_rl_v1/overtaking_dual_sac_07/manifest.json) | narrow_channel_overtaking | 775000 | 200000 | NOT_CONVERGED |
| [overtaking_dual_sac_08](artifacts/mission_rl_v1/overtaking_dual_sac_08/manifest.json) | narrow_channel_overtaking | 727000 | 152000 | NOT_CONVERGED |
| [overtaking_dual_sac_09](artifacts/mission_rl_v1/overtaking_dual_sac_09/manifest.json) | narrow_channel_overtaking | 727000 | 152000 | NOT_CONVERGED |
| [overtaking_exploration_10](artifacts/mission_rl_v1/overtaking_exploration_10/receipt.json) | 训练探索或中断记录 | — | 见父模型及回执 | TRAINING_EXPLORATION_ONLY |
| [overtaking_exploration_11](artifacts/mission_rl_v1/overtaking_exploration_11/receipt.json) | 训练探索或中断记录 | — | 见父模型及回执 | TRAINING_EXPLORATION_ONLY |
| [overtaking_full_authority_03](artifacts/mission_rl_v1/overtaking_full_authority_03/manifest.json) | narrow_channel_overtaking | 450000 | 150000 | NOT_CONVERGED |
| [overtaking_full_mission_05](artifacts/mission_rl_v1/overtaking_full_mission_05/manifest.json) | narrow_channel_overtaking | 500000 | 见父模型及回执 | INTERRUPTED_CONFIGURATION_DIAGNOSIS |
| [overtaking_full_mission_06](artifacts/mission_rl_v1/overtaking_full_mission_06/manifest.json) | narrow_channel_overtaking | 700000 | 200000 | NOT_CONVERGED |
| [p47_pure_attempt_01](artifacts/mission_rl_v1/p47_pure_attempt_01/manifest.json) | P47-L1 | 100000 | 见父模型及回执 | L1_NOT_CONVERGED |
| [traffic_lane_attempt_01](artifacts/mission_rl_v1/traffic_lane_attempt_01/manifest.json) | slow_traffic_lane_holding | 120000 | 见父模型及回执 | PASS |
| [traffic_lane_attempt_02](artifacts/mission_rl_v1/traffic_lane_attempt_02/manifest.json) | slow_traffic_lane_holding | 20000 | 见父模型及回执 | PASS |
| [unberthing_attempt_01](artifacts/mission_rl_v1/unberthing_attempt_01/manifest.json) | auto_unberthing | 25000 | 见父模型及回执 | INTERRUPTED_REPORT_SERIALIZATION |
| [unberthing_attempt_02](artifacts/mission_rl_v1/unberthing_attempt_02/manifest.json) | auto_unberthing | 75000 | 见父模型及回执 | PASS |
