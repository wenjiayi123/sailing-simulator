# 港口替换与上线门禁

项目把算法与港口数据分离。十种方法、45 维观测、动作空间、目标函数、训练器和评测器不依赖长滩港名称；更换港口时替换 `ship_port_dataset_v3` 数据包与 `ship_training_experiment_v3` 指针，不复制算法代码。

“换一个场景”在这里指换一套带来源和门禁的港口数据包，不是只换背景贴图。国际港口的水深基准、VTS、引航、拖轮、泊位、限速和地方规则不同，未提供或未核验的因素必须保持显式缺失，不能沿用长滩港假设。

## 最短接入路径

1. 复制 [`data/ports/port_package_manifest_v3.example.json`](../data/ports/port_package_manifest_v3.example.json)，填写港口身份、坐标原点、官方来源、时间切分和上线状态。
2. 将历史 AIS、授权的岸线/水深/航道/限制区 GIS、逐小时风浪流/能见度/潮位对齐到同一时钟与局部米制坐标系。
3. 输出 `ship_port_dataset_v3`。每个任务必须包含真实来源时间、航迹、船长/船宽/吃水、动态交通快照、海况和速度约束；共享环境必须包含岸线/固定危险、水深区与可用航道信息。
4. 运行契约校验：

   ```bash
   .venv/bin/python tools/validate_port_package.py \
     /absolute/path/to/port_dataset.json \
     --require-research-ready \
     --report /absolute/path/to/port_contract_report.json
   ```

5. 将实验 JSON 的 `dataset.path` 指向新数据包，先对十种方法做短 coverage smoke，再冻结训练和验证产物，最后一次性访问独立 `test`：

   ```bash
   .venv/bin/python tools/port_ops_train_baselines.py \
     --mode train --algorithm ppo \
     --config /absolute/path/to/experiment.json \
     --total-timesteps 40000 --steps 1600 \
     --output-dir /absolute/path/to/run/ppo \
     --progress-json /absolute/path/to/run/ppo/train.json \
     --checkpoint-json /absolute/path/to/run/ppo/checkpoint.json
   ```

6. 启动 Godot 时指定实验。训练中心会调用同一个 45 维后端，测试完成后才读取记录轨迹进行三维回放：

   ```bash
   SHIP_PORT_EXPERIMENT=/absolute/path/to/experiment.json godot --path .
   ```

## 研究训练必需因素

| 因素 | v3 数据位置 | 运行时作用 |
|---|---|---|
| 历史 AIS 与来源哈希 | `source.raw_files`, `source_track` | 真实航线、航速与时序拆分 |
| 船长、船宽、吃水 | `vessel_profile` | 碰撞包络、低阶操纵性能与 UKC |
| 岸线和固定危险 | `shared_environment.terrain/obstacles` | 净距、碰撞和地形终止 |
| 水深与潮位 | `depth_areas`, `sea_state.tide_meters` | 吃水余量与搁浅终止 |
| 航道、限制区与 TSS | `fairways`, `restricted_areas`, `traffic_separation` | 航道偏离与交通上下文 |
| 风、浪、流、能见度 | `sea_state` | 状态转移、观测与域随机化 |
| 动态交通 | `dynamic_obstacles` | TCPA/DCPA、会遇类型与保守让路代理 |
| 速度约束 | `navigation_context` | 超速事件与目标函数惩罚 |

## 45 维观测与动作

前 28 维与 v1 保持一致：相对目标、航向、速度/舵角、最近障碍、三扇区距离、动态目标、TCPA/DCPA、风浪流、边界和横向误差。v2 新增 17 维：能见度、潮位、水深、UKC、航道内外与边距、速度余量、船长/吃水、动态目标方位正余弦、四类会遇 one-hot、让路责任和交通密度。

PPO、SAC、TD3、A2C、DDPG、TRPO 使用归一化连续 `[油门, 舵角]`；DQN 使用同一控制量的九离散组合。LOS-PID、离散代数 Riccati 方程求解的 LQR、以及低阶船舶运动学滚动时域 MPC 是三种独立控制理论基线。七种 RL 与三种控制基线共享环境、切分和评测指标。

## 目标函数

目标函数奖励航线推进、航向一致、经济航速和到达航点，惩罚碰撞、岸线/固定危险、越界、净距不足、TCPA/DCPA 预测冲突、横向误差、大舵角、动作突变和时间成本。v2 另外惩罚 UKC 不足、经验速度上限、航道偏离和保守 COLREG 让路违例。全部权重保存在实验 JSON，并绑定数据与实验 SHA-256。

## 上线必须另行验证

研究数据通过不等于实船可用。`deployment_factor_coverage` 必须逐项为真，包含：

- 水深垂直基准与 UKC 规则；
- 当前官方航海产品和航行通告；
- 当地 VTS、限速、无线电与报告程序；
- 引航、拖轮、泊位与终端约束；
- 实时交通/海况、传感器时效与质量；
- 本船操纵模型、载况和执行器标定；
- 通信/控制接口认证；
- 冗余、故障安全、网络安全和人工最终权限。

任何一项未验证，`live_control_ready` 都保持 `false`，系统只允许离线研究与记录回放。
