# 航行模拟器：可训练、可评估的无人船航行基准

这是一个 Godot 4.7 + Python 的无人船航行实验项目。Godot 负责船舶操控、港口场景、遥测和测试结果可视化；Python 负责数据集切分、无渲染训练、模型保存和独立测试集评估。

> 本项目用于研究、教学和软件验证，不是经认证的船舶导航、避碰或自动驾驶系统，不能直接用于真实船舶决策。

当前 RL 链路不再使用计时器模拟训练进度，也不再生成写死成功的绕障曲线。界面进度来自 Stable-Baselines3 的实际 `num_timesteps`；测试轨迹来自训练完成后对 `test` split 的确定性 rollout。短训练没有收敛时，界面会如实显示失败。

## 五种基线

| 基线 | 动作空间 | 实现 |
|---|---|---|
| PPO | 连续油门 + 舵角 | Stable-Baselines3 |
| SAC | 连续油门 + 舵角 | Stable-Baselines3 |
| TD3 | 连续油门 + 舵角 | Stable-Baselines3 |
| DQN | 9 个离散油门/舵角组合 | Stable-Baselines3 |
| LOS-PID | 连续油门 + 舵角 | 视线制导 + PID 控制理论基线 |

DQN 只使用离散动作，因为标准 DQN 本身不支持连续动作。四种 RL 与 LOS-PID 使用同一观测定义、动力学、奖励/安全指标和数据集切分，便于做可复现实验。

数值环境不是二维圆点演示：训练会计算圆形、矩形和多边形障碍，区分悬岩/岸线的额外安全净距，推进动态交通船，并把闭合速度、TCPA、边界净距及前/左/右扇区净距纳入 21 维观测。当前 Godot 场景中的岸线危险区、导航岩石和临时港区障碍可随训练配置一起合并。

## 训练与渲染边界

```text
train split -> Python 数值环境 -> 真实训练 -> checkpoint
                                                   |
用户点击“运行测试集并渲染”                         v
test split  -> Python 确定性 rollout -> 真实轨迹/指标 -> Godot 3D 回放
```

- 训练进程不启动 Godot 场景渲染。
- 训练阶段只实例化 `train` split。
- checkpoint 同时记录数据集和完整实验配置 SHA-256；训练后数据、船体动力、奖励或环境安全设置被替换时，测试会拒绝运行。
- 测试失败、碰撞、超时和航线误差不会被改写。
- Godot 回放使用测试 rollout 记录的油门/舵角序列，而不是内置演示路线。

## 本机启动

安装 Python 训练环境：

```bash
cd /path/to/sailing-simulator
bash tools/setup_rl_env.sh
```

运行测试：

```bash
.venv/bin/python -m unittest tests.test_ship_rl -v
```

GitHub Actions 会在 push 和 pull request 上运行同一组数据契约、split 隔离、LOS-PID 闭环和 AIS 转换测试。贡献数据或算法前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

打开 Godot：

```bash
/path/to/Godot --editor --path /path/to/sailing-simulator
```

运行主场景后按 `C` 打开训练页。“算法/环境设置”可配置船体半径、悬岩净距、感知范围、碰撞时间窗、域随机化和生成交通船；“预览安全边界”会把有效包络直接画回场景。选择算法和预算后点击“启动训练”，完成后再点击“运行测试集并渲染”。

基础操作：方向键控制油门与目标航向，按住鼠标右键拖动观察方向，滚轮调整相机距离；`G` 切换开放水域/港口场景，`T` 切换天气，数字键 `1`–`4` 直接选择天气预设。

## 命令行训练

```bash
.venv/bin/python tools/rl_train_baselines.py \
  --mode train \
  --algorithm ppo \
  --config tests/fixtures/ship_training_config.json \
  --episodes 25 \
  --steps 800 \
  --agents 1 \
  --output-dir output/rl_runs \
  --progress-json output/rl_runs/training_progress.json \
  --checkpoint-json output/rl_runs/policy_checkpoint.json
```

训练后独立测试：

```bash
.venv/bin/python tools/rl_train_baselines.py \
  --mode evaluate \
  --algorithm ppo \
  --config tests/fixtures/ship_training_config.json \
  --steps 800 \
  --eval-episodes 1 \
  --output-dir output/rl_runs \
  --progress-json output/rl_runs/evaluation_progress.json \
  --checkpoint-json output/rl_runs/policy_checkpoint.json \
  --trajectory-json output/rl_runs/policy_test_trajectory.json
```

## 接入真实港口

项目接受包含 `train`、`validation`、`test` 的 `ship_port_dataset_v2` JSON。只需把环境变量指向新数据集，无需修改算法代码：

```bash
export SHIP_RL_DATASET=/absolute/path/to/port_training_dataset.json
```

NOAA/BOEM AccessAIS CSV 或 ZIP 可直接规范化：

```bash
python3 tools/public_data_pipeline.py ais \
  --input /path/to/AccessAIS-export.zip \
  --origin-lat 33.73 \
  --origin-lon -118.27 \
  --bbox -118.35 33.68 -118.15 33.82 \
  --environment-geojson /path/to/port_environment.geojson \
  --dataset-output /path/to/port_training_dataset.json \
  --targets-output /path/to/ais_targets.json
```

AIS 态势面板读取：

```bash
export SHIP_AIS_TARGETS=/absolute/path/to/ais_targets.json
```

AIS 提供历史航迹，GeoJSON 提供岸线、悬岩、礁石、码头和防波堤；二者会投影到同一个局部米制坐标系。港口场景配置可通过 `SHIP_PORT_PROFILE` 或 `user://port_profile.json` 替换。RL 测试回放直接读取测试任务中的航线、地形、静态障碍和动态交通，因此换训练集/测试集即可更换算法实验水域。

## 公开海况数据

默认启动会读取仓库内带来源元数据的 Open-Meteo 新加坡水域快照，并异步刷新实时公开数据。气象面板会显示 `live`、`cache`、`manual` 等真实来源状态；点击天气预设或手动改数值后，来源会明确变成 `scenario_override`/`manual_override`。

也可离线更新缓存：

```bash
python3 tools/public_data_pipeline.py weather \
  --latitude 1.2644 \
  --longitude 103.8223 \
  --output data/public_cache/marine_weather_singapore.json
```

## 关键目录

- `tools/ship_rl/`：Gymnasium 环境、五基线训练和测试。
- `tools/rl_train_baselines.py`：Godot 与命令行共用入口。
- `data/rl/default_port_dataset.json`：项目原生可复现实验基准，不冒充实测 AIS。
- `tools/public_data_pipeline.py`：公开气象和 NOAA AIS 数据适配器。
- `scripts/ui/ship_rl_control_panel.gd`：真实训练/测试任务控制台。
- `scripts/rl/ship_policy_replay_controller.gd`：测试动作序列可视化回放。
- `docs/DATASET_SCHEMA.md`：数据契约与港口接入说明。
- `docs/PORT_PROFILE_SCHEMA.md`：Godot 港口场景与航行任务配置。
- `docs/MODULE_DATA_DRIVERS.md`：每个面板的数据源、计算边界和替换入口。
- `docs/ALGORITHM_PARAMETERS.md`：训练面板参数到五种基线后端的实际映射。
- `docs/THIRD_PARTY_ASSETS.md`：公开数据、运行依赖与署名清单。

## 许可证与公开数据

项目源代码、程序化场景、程序化音效和项目原生文档使用 Apache-2.0。仓库不包含来源不明的角色、纹理、照片、录音、软著工作材料或训练产物。公开数据来源与署名要求见 [数据来源](docs/DATA_SOURCES.md) 和 [第三方清单](docs/THIRD_PARTY_ASSETS.md)。
