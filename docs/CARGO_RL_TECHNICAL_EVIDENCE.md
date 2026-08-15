# 环航取货 RL 技术证据（公开审阅版）

这是一份面向技术面试的最小可核验公开面，不是完整项目转储。公开源码来自实际运行模块，不是演示伪代码；训练权重、精确地图、完整轨迹与Godot总控集成继续保留在私有交付范围。

## 可检查的真实实现

- `tools/cargo_rl/environment.py`：36维连续控制环境，包含油门/舵角响应、惯性状态、稀疏检查点、悬岩/边界风险、奖励、课程路线和逐步轨迹字段。
- `tools/cargo_rl/dynamic_environment.py`：在静态环境上增加8个相对运动特征，形成44维观测；代码可直接检查TCPA/DCPA、闭合速度、横纵相对速度，以及冻结SAC与Residual SAC动作合成。
- `reports/cargo_circuit_public_evidence_v1.json`：记录两套策略的留出测试结果、诚实边界，以及未公开模型/轨迹的SHA-256承诺。
- `tests/test_cargo_circuit_public_evidence.py`：自动检查源码继承关系、36D/44D合同、Residual动作链、测试门槛、动态交通和私有资产隔离。

## 两套已验收策略

`SAC-S1`在无渲染数值环境完成30万步课程训练。固定test任务包含7个有序检查点、取货终点、稀疏悬岩和船舶转向约束；结果为7/7检查点、取货成功、零碰撞、零地形碰撞、零倒车，悬岩安全包络最小净距2.48m，路径效率91.14%。

`RES-SAC-D2`不是把动态避障重新包装成动画：它加载冻结的SAC-S1，在44维观测中加入最近动态目标的相对运动特征，并由Residual SAC输出油门/舵角修正。行为克隆只用于初始化，发布测试策略没有人工绕点旁路。含6艘移动交通船的固定test结果为7/7检查点、取货成功、零碰撞、零倒车，动态目标最小净距6.66m，总体净距3.05m，路径效率89.55%。

## 验证命令

```bash
python -m unittest tests.test_cargo_circuit_public_evidence -v
python -m compileall -q tools/cargo_rl tests/test_cargo_circuit_public_evidence.py
```

完整训练数据、精确任务坐标、超参数配置、行为克隆/回放缓存实现、模型文件、逐步测试轨迹及Godot控制面板没有公开。公开清单给出这些冻结产物的SHA-256，可在面试演示或授权审阅时对照本地原件验证。所有结果均为项目原生数值仿真与固定留出任务证据，不代表实船海试、COLREGs认证或生产控制许可。
