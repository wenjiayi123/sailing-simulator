# 算法参数实际映射

训练面板只保留已接入训练器或环境的参数。不同算法不使用的参数会被忽略，不会写入伪指标。

| 界面参数 | PPO | SAC | TD3 | DQN | LOS-PID | 后端映射 |
|---|:---:|:---:|:---:|:---:|:---:|---|
| 学习率 | √ | √ | √ | √ |  | `learning_rate` |
| 折扣因子 | √ | √ | √ | √ |  | `gamma` |
| 优势估计、熵、价值损失、裁剪 | √ |  |  |  |  | `gae_lambda`, `ent_coef`, `vf_coef`, `clip_range` |
| 单轮采样步长 | √ |  |  |  |  | PPO `n_steps` |
| mini-batch size | √ |  |  |  |  | PPO `batch_size` |
| 训练 batch size |  | √ | √ | √ |  | 离策略 `batch_size` |
| 回放池、预热步数 |  | √ | √ | √ |  | `buffer_size`, `learning_starts` |
| 目标网络更新间隔 |  |  |  | √ |  | DQN `target_update_interval` |
| epsilon 起止与衰减步数 |  |  |  | √ |  | DQN exploration settings |
| LOS Kp/Ki/Kd |  |  |  |  | √ | checkpoint 中的控制器增益 |
| 奖励、碰撞/地形/越界/净距/舵角惩罚 | √ | √ | √ | √ | 评估 | Gymnasium 环境奖励函数 |
| 随机种子 | √ | √ | √ | √ | √ | 数据任务采样与算法随机源 |

PPO 的实际 rollout 长度会受总 timestep 预算上限约束；训练器会选择能整除 rollout size 的 mini-batch，避免 Stable-Baselines3 的截断 batch。DQN 的 epsilon 衰减步数会换算为占总训练步数的 `exploration_fraction`。

## 环境交互参数

这些参数不是展示字段，都会写入 `environment_parameters` 并参与状态转移、碰撞或观测：

| 分组 | 参数 | 实际作用 |
|---|---|---|
| 船体包络 | `vessel_radius_m` | 所有障碍和边界碰撞计算使用的船体半径 |
| 静态障碍 | `obstacle_inflation_m` | 岩石、码头、矩形和多边形统一外扩 |
| 悬岩地形 | `cliff_inflation_m` | `cliff/terrain/shoreline` 在通用外扩之外追加净距 |
| 航区 | `boundary_margin_m` | 训练可航边界向内收缩 |
| 感知 | `sensor_range_m`, `tcpa_horizon_seconds` | 最近障碍、三扇区净距、闭合速度和 TCPA 观测 |
| 终止 | `terminate_on_collision` | 碰撞时结束当前训练回合 |
| 场景合并 | `merge_scene_obstacles` | 合并 Godot 当前岩石、悬岩和矩形障碍快照 |
| 域随机化 | 起点、航向、障碍位置/尺寸、风流与传感器噪声 | 仅训练 split 默认启用；相同种子可复现 |
| 会遇目标 | `generated_traffic_*` | 训练时生成横越交通船并随仿真步移动 |

界面“预览安全边界”会在 Godot 水面绘制当前船体+障碍/悬岩膨胀后的包络和内缩航区；“应用”同时写入下一次训练使用的实验配置。
