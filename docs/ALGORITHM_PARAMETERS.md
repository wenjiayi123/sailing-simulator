# 算法参数实际映射

训练面板只保留已接入训练器或环境的参数。v1 冻结证据保持原五方法；v2 港口环境提供七种 RL 与三种控制算法。不同算法不使用的参数会被忽略，不会写入伪指标。

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

## v2 十算法实现矩阵

| 方法 | 类别 | 动作 | 真实后端 |
|---|---|---|---|
| PPO | on-policy RL | 连续油门/舵角 | Stable-Baselines3 PPO |
| SAC | off-policy RL | 连续油门/舵角 | Stable-Baselines3 SAC |
| TD3 | off-policy RL | 连续油门/舵角 | Stable-Baselines3 TD3 + NormalActionNoise |
| DQN | value-based RL | 九离散油门/舵角组合 | Stable-Baselines3 DQN |
| A2C | on-policy RL | 连续油门/舵角 | Stable-Baselines3 A2C |
| DDPG | off-policy RL | 连续油门/舵角 | Stable-Baselines3 DDPG + NormalActionNoise |
| TRPO | trust-region RL | 连续油门/舵角 | sb3-contrib TRPO |
| LOS-PID | 控制 | 连续油门/舵角 | LOS 航向误差 + PID |
| LQR | 控制 | 连续油门/舵角 | 三状态离散 LQR，迭代求解 DARE |
| MPC | 控制 | 连续油门/舵角 | 8 步低阶运动学滚动优化、20 个候选动作 |

LQR 状态为横向误差、航向误差和航速误差；MPC 代价包含目标距离、航向、航速、控制量、动作变化与近障风险。三种控制器都输出真实动作并经过相同碰撞、搁浅、航道、速度与保守 COLREG 代理评测，不是静态标签或复用 RL 结果。

## 环境交互参数

这些参数不是展示字段，都会写入 `environment_parameters` 并参与状态转移、碰撞或观测：

| 分组 | 参数 | 实际作用 |
|---|---|---|
| 船体包络 | `vessel_radius_m` | 所有障碍和边界碰撞计算使用的船体半径 |
| 静态障碍 | `obstacle_inflation_m` | 岩石、码头、矩形和多边形统一外扩 |
| 悬岩地形 | `cliff_inflation_m` | `cliff/terrain/shoreline` 在通用外扩之外追加净距 |
| 航区 | `boundary_margin_m` | 训练可航边界向内收缩 |
| 感知 | `sensor_range_m`, `tcpa_horizon_seconds` | 最近障碍、三扇区净距、闭合速度、TCPA/DCPA 与动态目标标识 |
| 终止 | `terminate_on_collision` | 碰撞时结束当前训练回合 |
| 场景合并 | `merge_scene_obstacles` | 合并 Godot 当前岩石、悬岩和矩形障碍快照 |
| 域随机化 | 起点、航向、障碍位置/尺寸、风浪流与传感器噪声 | 仅训练 split 默认启用；相同种子可复现 |
| 环境强迫 | `wind_leeway_factor`, `wave_drift_mps_per_meter` | 公开风、浪、流共同进入二维平移状态转移；属于可审计低阶代理动力学 |
| 会遇目标 | `generated_traffic_*` | 训练时生成横越交通船并随仿真步移动 |

界面“预览安全边界”会在 Godot 水面绘制当前船体+障碍/悬岩膨胀后的包络和内缩航区；“应用”同时写入下一次训练使用的实验配置。

## 固定基准参数

项目报告使用 `data/rl/long_beach_public_weather_experiment_v1.json`，不能用界面临时参数替换后继续沿用原指标。

| 项目 | 固定值 |
|---|---|
| 随机种子 | `240705` |
| RL 训练预算 | PPO/SAC/TD3/DQN 各请求 20,000 timestep |
| 最大回合长度 | 1,000 step |
| 仿真步长 | 0.1 s |
| 观测 | 28 维 |
| 连续动作 | 油门、舵角，均归一化到 `[-1, 1]` |
| DQN 动作 | 9 个离散油门/舵角组合 |
| 训练 | `train`，无 Godot 渲染，启用固定范围域随机化 |
| 验证 | `validation`，确定性、不可渲染 |
| 最终测试 | `test`，确定性，配置和模型冻结后访问 |

固定奖励为：

```text
3.2 × 航线推进
+ 1.8 × 航向一致性
+ 0.8 × 速度项
+ 航点/到达奖励
- 48.0 × 碰撞
- 68.0 × 地形碰撞
- 36.0 × 越界
- 1.1 × 障碍接近
- 1.6 × TCPA/DCPA 预测冲突
- 0.12 × 横向航迹误差
- 0.9 × 舵角
- 0.04 × 动作变化
- 0.003 × 时间步
```

这是目标函数的可读结构；具体归一化、门限和航点奖励实现以 `tools/ship_rl/environment.py` 为准。模型检查点同时绑定数据集和完整实验配置 SHA-256，奖励、动力学或安全参数变化后会拒绝沿用旧测试结果。

## 最终指标定义

- 无碰撞到达率：代码旧字段名为 `safe_completion_rate`，其定义是到达目标且该回合碰撞数和地形碰撞数均为 0；该指标不排除近失或风险包络侵入，禁止单独解释为“安全航行率”。
- 碰撞场景率：30 个最终测试场景中发生至少一次碰撞的比例。
- 平均最大 XTE：每个场景最大横向航迹误差的算术平均。
- 平均最小净距：每个场景全程最小障碍净距的算术平均；它不能代替避碰认证。
- DCPA：动态目标在固定相对速度假设下的预测最近会遇距离；报告均值与 P05，不能替代 COLREGs 责任判断。
- 路径效率：参考航线长度除以实际航迹长度，上限截断为 1。
- 安全距离侵入：净距落入 `0—32 m` 的保守事件计数。固定场景航路本身会进入该包络，因此报告中的原始 `near_miss` 字段不应对外翻译为真实“险情率”。

## v2 真实港口扩展

`data/rl/long_beach_ais_port_ops_experiment_v2.json` 使用独立的 `PortOpsNavigationEnv`，不改写 v1 的 28 维环境和已冻结证据。它在同一动力学内新增 17 个观测量，总计 45 维：

| 新观测 | 归一化或编码 |
|---|---|
| 能见度、潮位、水深、UKC | 连续值缩放并裁剪 |
| 航道内外、距航道边缘 | 二值 + 连续边距 |
| 经验速度上限余量 | 当前 SOG 相对任务上限 |
| 船长、吃水 | 船型尺度归一化 |
| 最近动态目标方位 | `sin/cos` |
| head-on / crossing starboard / crossing port / overtaking | one-hot 会遇上下文 |
| give-way | 保守让路责任二值 |
| traffic density | 感知范围内动态目标密度 |

v2 目标函数沿用 v1 的推进、航向、经济航速、航点、碰撞、地形、边界、净距、TCPA/DCPA、XTE、舵角、动作变化和时间项，新增：

```text
- penalty_under_keel_clearance × UKC不足
- penalty_speed_limit × 超过任务速度上限
- penalty_channel_departure × 航道偏离
- penalty_colreg_give_way × 保守让路违例
```

速度上限来自 AIS 历史航速分布的经验代理，不是当地法规限速。COLREG 项只用于离线研究的保守会遇代理，不能解释为合规认证。港口合规完成率同时要求到达、无碰撞、无搁浅、无航道/速度/保守让路违例。
