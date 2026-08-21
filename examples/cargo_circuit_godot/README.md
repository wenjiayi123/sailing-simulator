# Godot 环航取货源码摘录

这里公开的是实际项目使用的两个 GDScript 源文件，便于检查策略准入、测试轨迹回放和 H 总控交互：

- `cargo_circuit_replay_controller.gd`：读取已准入的 held-out test 轨迹，驱动船体、检查点、风险包络、动态目标和回放状态。
- `cargo_circuit_rl_panel.gd`：七算法训练入口、策略清单、无渲染 validation/test、回放准入和总控按钮。

它们是源码审阅材料，不是独立 Godot 场景。完整 `main.tscn` 集成、精确任务配置、模型权重和逐步轨迹未随公开仓库提供；因此路径常量展示真实接口，但克隆后不会伪装成可以直接播放私有策略。
