<div align="center">
  <img src="docs/images/hero.svg" width="100%" alt="航行模拟器项目封面">
  <h1>航行模拟器</h1>
  <p><strong>把无人船 3D 仿真、可替换港口数据与可审计的强化学习实验放进同一条可复现链路。</strong></p>
  <p>
    <a href="README_EN.md">English</a> ·
    <a href="docs/RL_DATA_TRAINING_POLICY_REPLAY_GUIDE.md">实验指南</a> ·
    <a href="docs/DATASET_SCHEMA.md">数据契约</a> ·
    <a href="CONTRIBUTING.md">参与贡献</a>
  </p>
  <p>
    <img alt="CI" src="https://github.com/wenjiayi123/sailing-simulator/actions/workflows/rl-tests.yml/badge.svg">
    <img alt="License" src="https://img.shields.io/badge/license-Apache--2.0-2ea44f">
    <img alt="Godot" src="https://img.shields.io/badge/Godot-4.7-478CBF?logo=godot-engine&logoColor=white">
    <img alt="Python" src="https://img.shields.io/badge/Python-3.10%2B-3776AB?logo=python&logoColor=white">
    <img alt="Status" src="https://img.shields.io/badge/status-research%20benchmark-00d7e9">
  </p>
</div>

> [!IMPORTANT]
> 这是研究、教学和软件验证项目，不是经认证的船舶导航、避碰或自动驾驶系统，不能用于真实船舶决策。

## 一眼看懂

航行模拟器由 Godot 4.7 和 Python 两部分组成：Godot 负责船舶动力、场景、交通、航线、遥测与测试结果回放；Python 负责数据切分、无渲染训练、模型保存和独立测试集评估。两端共享明确的数据与实验契约。

| 能力 | 本项目的实现 |
|---|---|
| 可交互仿真 | 程序化海面、无人船、港区障碍、航标、天气、AIS 目标与双语遥测 HUD |
| 五种可比基线 | PPO、SAC、TD3、DQN，以及控制理论 LOS-PID |
| 严格实验边界 | 训练只读 `train`，测试只读 `test`，训练阶段不渲染 |
| 可替换港口 | `ship_port_dataset_v2`、港区 profile、AIS/GeoJSON 适配器 |
| 可审计产物 | 配置与数据 SHA-256、checkpoint、进度、真实测试轨迹和原始指标 |
| 可信展示 | Godot 只回放测试 rollout，不生成预制成功曲线 |

## 真实运行画面

![模拟器总览](docs/images/simulator-overview.png)

<details>
<summary><strong>航线规划与港口数据配置</strong></summary>

![航线规划面板](docs/images/navigation-planning.png)

</details>

<details>
<summary><strong>五基线训练与测试控制台</strong></summary>

![强化学习训练控制台](docs/images/rl-training-console.png)

</details>

以上 PNG 均由 [`tools/capture_readme_screenshots.gd`](tools/capture_readme_screenshots.gd) 从当前 `main.tscn` 自动生成，不是概念图。项目封面和架构图是仓库内自绘 SVG。

## 为什么这个项目值得复现

许多仿真演示把“训练进度动画”“预制轨迹”和“模型训练”混在一起。本项目把边界写进代码和数据契约：

- 训练进度来自 Stable-Baselines3 的真实 `num_timesteps`。
- 训练阶段只实例化 `train` split，并且不启动 Godot 渲染。
- checkpoint 记录数据集和完整实验配置的 SHA-256；数据、动力学、奖励或安全参数改变后，旧 checkpoint 会被拒绝。
- 测试阶段对 `test` split 做确定性 rollout；碰撞、超时、偏航和失败不会被改写。
- Godot 回放读取测试产出的逐步油门/舵角序列，不使用内置演示路线。

> [!NOTE]
> 仓库自带的数据集是用于软件复现的项目原生数值基准，不是实测 AIS、测绘数据或生产港口数据。公开数据适配器与默认基准刻意分开标注。

## 系统架构

![训练、测试与回放架构](docs/images/architecture.svg)

```text
train split -> Python 数值环境 -> 真实训练 -> checkpoint
                                                   |
用户点击“运行测试集并渲染”                         v
test split  -> Python 确定性 rollout -> 轨迹/指标 -> Godot 3D 回放
```

数值环境计算圆形、矩形和多边形障碍，区分岸线危险区的额外安全净距，推进动态交通船，并把闭合速度、TCPA、边界净距及前/左/右扇区净距纳入 21 维观测。Godot 场景中的导航岩石、岸线危险区和港区障碍可随实验配置合并。

## 五种基线

| 基线 | 动作空间 | 后端 | 适合比较的问题 |
|---|---|---|---|
| PPO | 连续油门 + 舵角 | Stable-Baselines3 | 稳健的 on-policy 基线 |
| SAC | 连续油门 + 舵角 | Stable-Baselines3 | 样本效率与随机策略 |
| TD3 | 连续油门 + 舵角 | Stable-Baselines3 | 连续控制与价值过估计抑制 |
| DQN | 9 个离散油门/舵角组合 | Stable-Baselines3 | 离散控制对照 |
| LOS-PID | 连续油门 + 舵角 | 项目原生控制器 | 不依赖训练的控制理论基线 |

DQN 使用离散动作，因为标准 DQN 不支持连续动作。所有基线共享同一观测定义、动力学、安全指标和数据切分。参数的实际映射见 [算法参数说明](docs/ALGORITHM_PARAMETERS.md)。

## 快速开始

### 1. 准备环境

要求：Godot 4.7、Python 3.10+。macOS、Linux 和 Windows 均可运行；训练默认使用 CPU，也可由 PyTorch 选择可用加速设备。

```bash
git clone https://github.com/wenjiayi123/sailing-simulator.git
cd sailing-simulator
bash tools/setup_rl_env.sh
```

### 2. 验证 Python 链路

```bash
.venv/bin/python -m unittest tests.test_ship_rl -v
```

### 3. 打开模拟器

```bash
godot --editor --path .
```

运行 `main.tscn` 后即可驾驶。按 `C` 直接打开训练页，选择算法与预算，先“启动训练”，完成后再“运行测试集并渲染”。

| 按键 | 功能 |
|---|---|
| 方向键 | 油门 / 舵角控制 |
| 鼠标右键拖动、滚轮 | 环视 / 调整相机距离 |
| `G` | 切换开放水域与港区场景 |
| `T` / `1`–`4` | 循环天气 / 选择天气预设 |
| `N` | 航行任务与航线规划 |
| `I` | AIS 船队态势 |
| `V` | 风险决策面板 |
| `P` | 仿真复盘 |
| `O` | 教员控制台 |
| `Z` / `X` / `C` | RL 面板 / 船舶页 / 训练页 |

## 命令行实验

训练示例：

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

独立测试：

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

短预算 smoke test 只证明数据、环境、checkpoint、测试和回放链路能闭环，不代表策略已经收敛。完整复现约定见 [REPRODUCIBILITY.md](docs/REPRODUCIBILITY.md)。

## 换训练集即可接入港口

项目接受包含 `train`、`validation`、`test` 的 `ship_port_dataset_v2` JSON。算法不依赖具体港口名称：

```bash
export SHIP_RL_DATASET=/absolute/path/to/port_training_dataset.json
```

NOAA/BOEM AccessAIS CSV 或 ZIP 可规范化为统一数据契约：

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

```bash
export SHIP_AIS_TARGETS=/absolute/path/to/ais_targets.json
export SHIP_PORT_PROFILE=/absolute/path/to/port_profile.json
```

AIS 提供历史航迹，GeoJSON 提供岸线、礁石、码头和防波堤；两类数据投影到同一个局部米制坐标系。格式与来源要求见 [数据集契约](docs/DATASET_SCHEMA.md)、[港区配置契约](docs/PORT_PROFILE_SCHEMA.md) 和 [数据来源](docs/DATA_SOURCES.md)。

## 公开海况数据

默认场景读取仓库内带来源元数据的 Open-Meteo 新加坡水域快照，并可异步刷新公开数据。界面会区分 `live`、`cache`、`scenario_override` 与 `manual_override`，不会把缓存或手工场景值标为传感器实测。

```bash
python3 tools/public_data_pipeline.py weather \
  --latitude 1.2644 \
  --longitude 103.8223 \
  --output data/public_cache/marine_weather_singapore.json
```

## 质量门槛

每次 push 和 pull request 会运行数据契约、split 隔离、环境动力学、LOS-PID 闭环与 AIS 转换测试。本地可额外运行 Godot 解析和完整闭环：

```bash
make test
make godot-check
```

发布前检查项见 [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md)。

## 项目结构

```text
.
├── main.tscn / player.gd       # 程序化 3D 主场景与船舶控制
├── scripts/                    # 世界、UI、音频、视觉与测试回放
├── tools/ship_rl/              # 21 维环境与五种基线
├── tools/rl_train_baselines.py # 训练、评估、产物导出入口
├── tools/public_data_pipeline.py
├── data/                       # 原生基准、港区配置、公开缓存
├── tests/                      # 自动化契约与闭环测试
├── docs/                       # 数据、算法、复现与架构说明
└── .github/                    # CI、Issue 和 PR 模板
```

更完整的模块说明见 [project_structure.md](docs/project_structure.md) 和 [模块数据驱动表](docs/MODULE_DATA_DRIVERS.md)。

## 已知边界

- 当前动力学适合算法与软件链路研究，不是经水池试验或实船辨识的六自由度水动力模型。
- 默认交通、港区几何和训练任务是项目原生基准；接入真实数据时仍需自行校核许可、坐标、精度与隐私。
- 短预算 CI 只检查回归和闭环，不给出算法优劣或收敛结论。
- 项目没有船级社认证，也未接入真实执行机构。

路线图见 [ROADMAP.md](docs/ROADMAP.md)。

## 参与项目

- 提交代码前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md) 与 [行为准则](CODE_OF_CONDUCT.md)。
- 问题与使用帮助见 [SUPPORT.md](SUPPORT.md)。
- 安全问题请按 [SECURITY.md](SECURITY.md) 私密报告。
- 新增二进制资产或数据前必须更新 [资产许可审计](docs/ASSET_LICENSE_AUDIT.md)。

## 许可证与引用

项目原生源代码、程序化场景、文档和图形使用 [Apache License 2.0](LICENSE)。Open-Meteo 缓存等第三方条目见 [THIRD_PARTY_ASSETS.md](docs/THIRD_PARTY_ASSETS.md) 与 [NOTICE](NOTICE)。学术或技术报告中引用本项目时，可使用仓库提供的 [`CITATION.cff`](CITATION.cff)。

---

<div align="center">
  <sub>Build transparent maritime autonomy experiments — and keep the evidence boundary visible.</sub>
</div>
