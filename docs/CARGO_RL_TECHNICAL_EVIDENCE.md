# 环航取货强化学习

本模块提供连续控制环境、动态交通扩展、训练入口、冻结权重、检查点、留出轨迹和 episode 摘要。版本清单记录发布文件的 SHA-256；精确地图、冻结实验配置及完整 Godot 场景和视觉资产不在本仓库中。

## 实现组成

- `tools/cargo_rl/environment.py`：36维连续控制环境，包含油门/舵角响应、惯性状态、稀疏检查点、悬岩/边界风险、奖励、课程路线和逐步轨迹字段。
- `tools/cargo_rl/dynamic_environment.py`：在静态环境上增加8个相对运动特征，形成44维观测；代码可直接检查TCPA/DCPA、闭合速度、横纵相对速度，以及冻结SAC与Residual SAC动作合成。
- `tools/cargo_rl/trainer.py` 与 `tools/cargo_rl_train.py`：SAC/PPO/TD3/A2C/DDPG/TQC/TRPO 训练入口、无渲染训练、冻结 checkpoint、validation/test 隔离和结果导出。
- `tools/cargo_rl/demonstration.py`：行为克隆初始化与经验回放预填所使用的透明舵令采集实现；最终test不调用该控制器。
- `examples/cargo_circuit_godot/cargo_circuit_replay_controller.gd` 与 `examples/cargo_circuit_godot/cargo_circuit_rl_panel.gd`：Godot 测试轨迹回放、准入检查、策略选择、训练/验证/测试命令和总控交互源码；示例目录不包含完整场景。
- `docs/media/cargo-circuit-sac-heldout-test.mp4`：SAC-S1 held-out test 的 Godot 回放片段，保留检查点、取货和任务完成阶段；视频为 1600×900、30 fps、22 秒、无声 H.264。`docs/media/cargo-circuit-sac-inline-preview.gif` 是 README 中的 12 秒循环预览。
- `reports/artifacts/cargo_circuit_rl_v1/` 与 `reports/artifacts/cargo_circuit_dynamic_rl_v2/`：SAC-S1 和 RES-SAC-D2 冻结权重、检查点、留出测试轨迹及 episode 摘要。
- `reports/cargo_circuit_public_evidence_v1.json`：记录两套策略的留出测试结果及发布文件 SHA-256。
- `tests/test_cargo_circuit_public_evidence.py`：自动检查源码继承关系、36D/44D 合同、Residual 动作链、测试阈值、动态交通和文件哈希。

## 策略结果

`SAC-S1`在无渲染数值环境完成30万步课程训练。固定test任务包含7个有序检查点、取货终点、稀疏悬岩和船舶转向约束；结果为7/7检查点、取货成功、零碰撞、零地形碰撞、零倒车，悬岩安全包络最小净距2.48m，路径效率91.14%。

`RES-SAC-D2` 加载冻结的 SAC-S1，在 44 维观测中加入最近动态目标的相对运动特征，并由 Residual SAC 输出油门/舵角修正。行为克隆只用于初始化，测试策略不使用人工绕点旁路。含 6 艘移动交通船的固定 test 结果为 7/7 检查点、取货成功、零碰撞、零倒车，动态目标最小净距 6.66 m，总体净距 3.05 m，路径效率 89.55%。

## 验证命令

```bash
python -m unittest tests.test_cargo_circuit_public_evidence -v
python -m compileall -q tools/cargo_rl tests/test_cargo_circuit_public_evidence.py
PYTHONPATH=tools python -c 'from stable_baselines3 import SAC; print(SAC.load("reports/artifacts/cargo_circuit_rl_v1/cargo_sac_policy.zip", device="cpu").observation_space)'
```

仓库提供两套策略的模型文件、检查点、逐步测试轨迹与 episode 摘要；完整训练数据、精确任务坐标、冻结实验配置及完整 Godot 场景和视觉资产不在本仓库中。版本清单逐文件给出 SHA-256。Stable-Baselines3 压缩包可能包含 Python 序列化对象，只应从可信仓库版本加载并先核对哈希。所有结果均来自项目数值仿真与固定留出任务，不代表实船海试、COLREGs 认证或生产控制许可。
