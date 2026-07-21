# RL 无渲染训练、独立测试与 3D 回放

## 操作闭环

1. 按 `C` 打开训练页。
2. 选择 PPO、SAC、TD3、DQN 或 LOS-PID。
3. 打开“算法/环境设置”，设置船体包络、悬岩净距、感知/TCPA、域随机化和交通船；可先点击“预览安全边界”核对场景反馈，再点“应用”。
4. 设置训练轮数、每轮步数、并行数值环境和测试回合数。
5. 点击“启动训练”。Godot 暂停世界物理和相机渲染，Python 只读取 `train` split；当前场景岩石、岸线危险区和矩形障碍数值快照参与训练。
6. 进度条读取训练器实际 timestep、episode、step/s、奖励和成功率。
7. 状态显示 `CHECKPOINT READY` 后，确认界面同时显示 `test=NOT_RUN`。
8. 点击“运行测试集并渲染”。此时才读取 `test` split。
9. 测试进程完成后，Godot 恢复 3D，用刚记录的测试油门/舵角序列回放结果；动态交通按每个采样点的位置移动。
10. 成功、失败、碰撞、地形碰撞、近失、最小净距、最大横向误差和用时均按真实结果展示。

## 产物

Godot 默认写到 `user://rl_runs/`：

- `training_progress.json`：实际训练任务状态；
- `policy_checkpoint.json`：算法、模型路径、环境参数、split、数据集指纹和完整实验指纹；
- `<algorithm>_policy.zip`：Stable-Baselines3 模型；
- `<algorithm>_train_episodes.csv`：训练回合指标；
- `evaluation_progress.json`：独立测试状态；
- `policy_test_trajectory.json`：测试动作与状态序列；
- `<algorithm>_test_episodes.csv`：测试回合指标；
- `policy_evaluation_result.json`：Godot 可视化回放产生的运行指标。

LOS-PID 没有可学习参数，因此 checkpoint 会明确写入 `trained=false` 和控制器增益；测试流程与四种 RL 相同。

## 真实性边界

- 默认基准是项目原生数值数据，不冒充实测 AIS。
- 公开 AIS 必须通过数据适配器生成数据集并保留来源；岸线、悬岩、礁石、码头需由 GeoJSON 一并转换，AIS 本身不提供这些几何。
- Godot 回放是测试 rollout 的记录结果，不是实船控制认证。
- 实船接入前必须增加传感器质量、电子海图、COLREGs、失效保护、人机接管和港口审批链路。
