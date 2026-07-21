# 可复现实验说明

本文定义“能够运行”和“能够作为实验结果复现”的区别。短预算 smoke test 只验证链路，不证明策略收敛。

## 环境记录

报告结果时至少记录：

- 仓库 commit SHA 与 `VERSION`；
- 操作系统、Python、Godot、NumPy、Gymnasium、Stable-Baselines3 和 PyTorch 版本；
- 算法、随机种子、训练步数、episode 数、并行环境数与设备；
- 数据集文件 SHA-256、配置指纹和 split 统计；
- 是否使用默认基准、公开数据转换结果或自有数据。

```bash
git rev-parse HEAD
.venv/bin/python --version
.venv/bin/python -m pip freeze
godot --version
```

## 标准流程

1. 从干净 checkout 创建虚拟环境：`bash tools/setup_rl_env.sh`。
2. 运行 `make test`，确认数据契约与 split 隔离通过。
3. 固定数据集、配置、算法、随机种子与训练预算。
4. 只在 `train` split 上训练；`validation` 仅用于模型选择。
5. 保存 checkpoint、训练进度与环境元数据。
6. 冻结模型后，对 `test` split 做确定性 rollout。
7. 原样保存轨迹和所有指标；失败、碰撞或超时也必须报告。
8. 如需展示，在 Godot 中回放已记录的 test 动作序列。

## 必须保留的产物

| 产物 | 用途 |
|---|---|
| `training_progress.json` | 真实训练阶段与 `num_timesteps` |
| `policy_checkpoint.json` | 算法、模型路径、数据/配置指纹 |
| Stable-Baselines3 模型文件 | 冻结的策略参数 |
| `evaluation_progress.json` | 测试过程状态 |
| `policy_test_trajectory.json` | test split 动作、状态与原始指标 |
| 数据和实验配置 | 复算 SHA-256 与重建环境 |

`output/` 默认不进入版本控制。正式实验应把产物放进独立、带版本和访问控制的归档，而不是直接提交大文件到源码仓库。

## 公平比较

- 五种基线必须使用相同数据版本、观测、动力学、奖励和安全参数。
- 预算应明确按环境步数、wall-clock 或二者同时报告；不要只比较 episode 数。
- 每个学习算法至少报告多个随机种子及分布统计。
- LOS-PID 不使用训练预算，但必须经历完全相同的 test 任务和指标计算。
- 任何失败 seed 都应保留；不得只展示最佳轨迹。

## 结果声明

可以声明：“在 commit X、数据指纹 Y、配置指纹 Z 下，链路通过并得到以下 held-out 指标。”

不应仅凭短训练声明：“算法已收敛”“优于其他算法”“可以真实部署”。后者需要充分预算、多种子统计、独立数据、校准动力学与现实世界验证。
