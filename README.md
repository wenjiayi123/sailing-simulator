<div align="center">
  <img src="docs/images/hero.svg" width="100%" alt="航行模拟器 / Sailing Simulator">
  <h1>航行模拟器 · Sailing Simulator</h1>
  <p><strong>面向自主航行研究的全栈数字实验系统</strong></p>
  <p><strong>A Full-Stack Digital Experimentation System for Maritime Autonomy Research</strong></p>
  <p>
    统一 3D 仿真、船舶动力学、控制基线、港口数据、独立评估与证据回放<br>
    Unifying 3D simulation, vessel dynamics, control baselines, port data, held-out evaluation, and evidence replay
  </p>
  <p>
    <a href="#系统总览--system-overview">系统总览 / Overview</a> ·
    <a href="#技术架构--technical-architecture">技术架构 / Architecture</a> ·
    <a href="#快速开始--quick-start">快速开始 / Quick Start</a> ·
    <a href="README_EN.md">English-only</a>
  </p>
  <p>
    <img alt="CI" src="https://github.com/wenjiayi123/sailing-simulator/actions/workflows/rl-tests.yml/badge.svg">
    <img alt="License" src="https://img.shields.io/badge/license-Apache--2.0-2ea44f">
    <img alt="Godot" src="https://img.shields.io/badge/Godot-4.7-478CBF?logo=godot-engine&logoColor=white">
    <img alt="Python" src="https://img.shields.io/badge/Python-3.10%2B-3776AB?logo=python&logoColor=white">
    <img alt="Observation" src="https://img.shields.io/badge/observation-21D-8B5CF6">
    <img alt="Version" src="https://img.shields.io/badge/version-0.1.0-FFB000">
    <img alt="Architecture" src="https://img.shields.io/badge/architecture-contract--driven-00B8D9">
  </p>
</div>

## 系统总览 / System Overview

航行模拟器不是单一驾驶场景，也不是用动画包装训练过程的 RL 展示。它是一套**契约驱动、来源可追溯、结果可复算、失败不改写**的自主航行数字实验栈，覆盖从港口数据进入、数值环境构建、策略训练、模型冻结、独立测试到 3D 证据回放的完整生命周期。

*Sailing Simulator is neither a single driving scene nor an RL showcase wrapped around progress animation. It is a **contract-driven, provenance-aware, reproducible, and failure-preserving** maritime autonomy stack covering the full lifecycle from port-data ingestion and numerical environment construction to policy training, model freeze, held-out evaluation, and 3D evidence replay.*

### 系统画像 / System Profile

| 指标 / Signal | 当前实现 / Current Implementation | 工程意义 / Engineering Significance |
|---|---|---|
| **4 个架构平面 / 4 planes** | 交互仿真、数值实验、数据治理、证据回放 / simulation, experiment, data governance, evidence replay | UI、算法、数据和结果解释彼此解耦 / decoupled evolution |
| **5 种统一基线 / 5 baselines** | PPO、SAC、TD3、DQN、LOS-PID | 学习算法与控制理论在同一测试契约下比较 / RL and control under one contract |
| **21 维观测 / 21D observation** | 任务、船态、风险目标、风流、边界、三扇区净距 | 对外稳定的算法接口 / stable algorithm-facing interface |
| **3 个严格 split / 3 strict splits** | `train`、`validation`、`test` | 降低航次和任务泄漏 / reduced voyage and task leakage |
| **3 个版本化契约 / 3 versioned contracts** | dataset、port profile、training experiment | 换港口不改算法 / port substitution without algorithm rewrites |
| **2 级指纹 / dual fingerprints** | 数据集 SHA-256 + 完整实验 SHA-256 | 阻止旧模型包装新配置 / prevents stale-policy reuse |
| **0 训练渲染 / zero training render** | Python 数值环境独立训练 | 训练计算与视觉表现解耦 / compute separated from presentation |
| **9+ 原始指标 / 9+ raw metrics** | 成功、碰撞、地形、近失、净距、XTE、航程、时间、奖励 | reward 不替代安全结论 / reward does not replace safety evidence |

### 核心能力 / Core Capabilities

| 能力域 / Capability Domain | 系统实现 / System Implementation |
|---|---|
| **自主航行数字孪生 / Maritime autonomy digital twin** | 程序化海面与船体、港区障碍、航标、动态目标、天气、航线和双语遥测 / procedural sea and vessel, harbor geometry, aids to navigation, traffic, weather, routes, bilingual telemetry |
| **算法与控制实验室 / Algorithm and control laboratory** | 四种 Stable-Baselines3 算法与 LOS-PID 控制理论基线，共享观测、动力学和指标 / four SB3 algorithms plus LOS-PID sharing observations, dynamics, and metrics |
| **风险几何引擎 / Risk geometry engine** | 圆、矩形、多边形、地形额外净距、动态会遇、闭合速度、TCPA 与扇区感知 / shape-aware hazards, terrain margins, moving encounters, closing speed, TCPA, sector sensing |
| **港口数据智能层 / Port data intelligence layer** | AccessAIS、WGS84 GeoJSON、Open-Meteo、局部米制坐标与来源元数据 / AccessAIS, GeoJSON, Open-Meteo, local metric projection, provenance metadata |
| **实验控制平面 / Experiment control plane** | split 隔离、参数映射、配置冻结、checkpoint 指纹与 held-out 测试 / split isolation, parameter mapping, config freeze, checkpoint fingerprints, held-out tests |
| **证据保真回放 / Evidence-preserving replay** | 回放测试产生的油门/舵角、动态交通位置和原始失败结论 / replay of evaluated commands, recorded traffic positions, and original failure outcomes |

## 真实运行界面 / Real Runtime Interface

![模拟器总览 / Simulator overview](docs/images/simulator-overview.png)

<details>
<summary><strong>航线规划与港口配置 / Route Planning and Port Configuration</strong></summary>

![航线规划面板 / Navigation planning panel](docs/images/navigation-planning.png)

</details>

<details>
<summary><strong>五基线训练与独立测试 / Five-Baseline Training and Held-Out Evaluation</strong></summary>

![强化学习训练控制台 / RL experiment console](docs/images/rl-training-console.png)

</details>

以上 PNG 由 [`tools/capture_readme_screenshots.gd`](tools/capture_readme_screenshots.gd) 从当前 `main.tscn` 自动生成。封面、架构图、图标和社交预览均为项目原生图形。

*The PNG files above are generated from the current `main.tscn` by [`tools/capture_readme_screenshots.gd`](tools/capture_readme_screenshots.gd). The cover, architecture diagram, icon, and social preview are project-authored assets.*

## 技术架构 / Technical Architecture

![训练、测试与回放架构 / Train-test-replay architecture](docs/images/architecture.svg)

```text
Port Data / Scene Snapshot
           │
           ▼
ship_port_dataset_v2 ──► train split ──► Headless Numerical Training
           │                                      │
           │                                      ▼
           │                         Frozen Model + Dual Fingerprints
           │                                      │
           └──────────────► test split ────────────┤
                                                  ▼
                                     Deterministic Held-out Rollout
                                                  │
                                  Raw Metrics + Recorded Trajectory
                                                  │
                                                  ▼
                                        Godot Evidence Replay
```

### 四平面架构 / Four-Plane Architecture

| 架构平面 / Plane | 核心职责 / Responsibility | 主要实现 / Main Implementation |
|---|---|---|
| **交互仿真平面 / Interactive simulation** | 驾驶、航线、场景、天气、交通、风险、教员注入、遥测和复盘 / control, route, scene, weather, traffic, risk, instructor injection, telemetry, review | Godot `main.tscn`、`player.gd`、`scripts/world/`、`scripts/ui/` |
| **数值实验平面 / Numerical experiment** | 动力学积分、五基线训练、确定性测试和指标聚合 / dynamics integration, five-baseline training, deterministic evaluation, aggregation | Gymnasium、Stable-Baselines3、`tools/ship_rl/` |
| **数据治理平面 / Data governance** | split 隔离、坐标转换、来源记录、数据和配置指纹 / split isolation, coordinate transformation, provenance, fingerprints | versioned JSON contracts、AIS/GeoJSON/Open-Meteo adapters |
| **证据回放平面 / Evidence replay** | 读取测试动作、同步动态目标、显示原始结果 / recorded commands, synchronized traffic, original outcome | `ship_policy_test_rollout_v3`、Godot replay controller |

### 契约驱动的模块边界 / Contract-Driven Module Boundaries

系统不让 Godot UI 直接决定训练结论，也不让 Python 训练器依赖具体场景名称。两端通过版本化配置、进度、checkpoint 和 trajectory 文件协作，使训练、测试、可视化与数据替换具备独立演化能力。

*The Godot UI does not determine training outcomes, and the Python trainer does not depend on scene names. Both sides collaborate through versioned configuration, progress, checkpoint, and trajectory artifacts, allowing training, evaluation, visualization, and port substitution to evolve independently.*

## 自主航行数值核心 / Autonomous Navigation Numerical Core

### 六状态船舶积分模型 / Six-State Vessel Integrator

环境状态为 `(x, z, heading, signed_speed, throttle, rudder)`。每个时间步执行：

*The environment state is `(x, z, heading, signed_speed, throttle, rudder)`. Every step applies:*

- 油门与舵角的一阶执行器响应 / first-order throttle and rudder response;
- 前进与倒车目标速度、加速和减速约束 / forward/reverse target speed with acceleration and deceleration limits;
- 随速度变化的转向权与倒车转向符号 / speed-dependent turning authority and reverse steering sign;
- 海流速度与流向产生的平流位移 / current-driven advection;
- 航点推进、航段横向误差和到达判定 / waypoint progression, segment XTE, and arrival logic.

该模型强调参数透明、配置可冻结和结果可复算，是算法与软件链路研究的稳定底座。

*The model emphasizes transparent parameters, frozen configurations, and reproducible transitions, providing a stable base for algorithm and software-pipeline research.*

### 21 维观测契约 / 21D Observation Contract

| 观测组 / Group | 维度 / Dim. | 信号 / Signals |
|---|:---:|---|
| 任务几何 / Mission geometry | 4 | 目标距离、航向误差 `sin/cos`、横向误差 / target distance, heading-error `sin/cos`, XTE |
| 船舶状态 / Vessel state | 3 | 归一化航速、油门、舵角 / normalized speed, throttle, rudder |
| 最近风险目标 / Nearest risk target | 5 | 净距、相对方位 `sin/cos`、闭合速度、TCPA / clearance, bearing, closing speed, TCPA |
| 环境作用 / Environmental effect | 4 | 海流速度、相对流向 `sin/cos`、风速 / current speed, relative-current direction, wind |
| 航行上下文 / Navigation context | 2 | 航点进度、边界净距 / waypoint progress, boundary clearance |
| 空间扇区 / Spatial sectors | 3 | 前方、左舷、右舷净距 / forward, port, starboard clearances |
| **合计 / Total** | **21** | 全部分量归一化至 `[-1, 1]` / all components normalized to `[-1, 1]` |

连续算法输出 `Box(-1, 1, shape=(2,))` 的油门与舵角；DQN 使用具备相同物理语义的 9 个离散组合。

*Continuous methods output throttle and rudder in `Box(-1, 1, shape=(2,))`; DQN uses nine discrete combinations with the same physical semantics.*

### 形状感知风险几何 / Shape-Aware Risk Geometry

| 能力 / Capability | 实际计算 / Actual Computation |
|---|---|
| 静态障碍 / Static hazards | `circle`、axis-aligned `box`、`polygon` 的形状距离 / shape-aware distance |
| 地形安全层 / Terrain safety layer | `cliff`、`terrain`、`shoreline` 叠加专用净距 / dedicated terrain inflation |
| 动态会遇 / Dynamic encounters | 航向/航速或速度向量推进 / propagation from course-speed or velocity |
| 相对运动 / Relative motion | closing speed、TCPA、nearest clearance |
| 空间感知 / Spatial sensing | sensor range、front/port/starboard sector clearance |
| 航区约束 / Navigation boundary | vessel radius + inward boundary margin |
| 域随机化 / Domain randomization | 起点、航向、障碍、风流、传感器噪声；固定 seed 可复现 / seeded start, hazards, weather, sensor noise |

## 算法与控制实验室 / Algorithm and Control Laboratory

### 统一基准下的五种方法 / Five Methods Under One Benchmark

| 方法 / Method | 范式 / Paradigm | 动作空间 / Action Space | 真实接入参数 / Connected Parameters | 实验角色 / Role |
|---|---|---|---|---|
| **PPO** | on-policy actor-critic | 连续 / continuous | learning rate、GAE、clip、entropy、value loss、rollout、mini-batch | 策略优化参照 / policy-optimization reference |
| **SAC** | off-policy maximum entropy | 连续 / continuous | learning rate、gamma、batch、replay buffer、warm-up | 样本效率参照 / sample-efficient stochastic reference |
| **TD3** | off-policy deterministic actor-critic | 连续 / continuous | learning rate、gamma、batch、replay buffer、warm-up | 连续控制参照 / continuous-control reference |
| **DQN** | off-policy value learning | 9 个离散组合 / 9 discrete commands | replay buffer、target update、epsilon schedule | 离散控制对照 / discrete-control comparison |
| **LOS-PID** | guidance + feedback control | 连续 / continuous | LOS、`Kp/Ki/Kd` | 无训练控制基线 / non-learning control baseline |

所有方法共享观测、动力学、任务 split、安全包络、指标和导出器。DQN 保持离散动作，因为标准 DQN 不支持连续动作；LOS-PID checkpoint 明确记录 `trained=false` 与控制器增益，不伪装成学习算法。

*All methods share observations, dynamics, task splits, safety envelopes, metrics, and exporters. DQN remains discrete because standard DQN does not support continuous actions. LOS-PID checkpoints explicitly record `trained=false` and controller gains rather than misrepresenting the controller as a learned policy.*

参数到后端的真实映射见 [算法参数说明 / Algorithm Parameters](docs/ALGORITHM_PARAMETERS.md)。

### Reward 与安全指标分离 / Reward-Safety Separation

训练 reward 综合航线推进、航向一致性、速度、舵角使用、近障惩罚、普通碰撞、地形碰撞、越界和航点到达。最终评价不把 reward 当成安全结论，而是独立输出原始指标。

*The training reward combines route progress, heading alignment, speed, rudder effort, proximity, collision, terrain collision, boundary violation, and waypoint arrival. Final evaluation exports raw safety and task metrics independently instead of treating reward as a safety conclusion.*

| 指标族 / Metric Family | 输出 / Outputs |
|---|---|
| 任务完成 / Completion | `success`、`goal_reached`、steps、elapsed time |
| 安全 / Safety | collisions、terrain collisions、near misses、minimum clearance |
| 航迹质量 / Track quality | maximum cross-track error、path length |
| 实验统计 / Experiment statistics | episode reward、mean reward、success rate、dynamic-obstacle count |

## 实验控制平面 / Experiment Control Plane

### Train → Freeze → Test → Replay

```text
TRAIN     train split only ──► optimization ──► model + checkpoint
FREEZE    dataset SHA-256 + experiment SHA-256 ──► immutable experiment identity
TEST      frozen policy + test split ──► deterministic rollout + raw metrics
REPLAY    recorded actions + traffic states ──► Godot 3D evidence playback
```

### 证据完整性矩阵 / Evidence-Integrity Matrix

| 阶段 / Stage | 允许输入 / Allowed Inputs | 被阻止的捷径 / Blocked Shortcuts | 可审计产物 / Auditable Outputs |
|---|---|---|---|
| 数据准备 / Preparation | 原始 AIS、GeoJSON、天气和来源元数据 / raw data and provenance | 同一航次跨 split / voyage leakage | dataset、source URL/time、original SHA-256 |
| 训练 / Training | `train`；`validation` 可用于选择 / optional validation | 读取 `test`、3D 渲染、计时器进度 / test access, rendering, timer progress | progress、train CSV、model、checkpoint |
| 冻结 / Freeze | 数据与完整实验配置 / data and full config | 改参数后复用旧模型 / stale-policy reuse | `dataset_sha256`、`experiment_sha256` |
| 测试 / Evaluation | frozen policy + `test` | 改写失败、筛除失败 seed / failure rewriting | test CSV、aggregate metrics、trajectory |
| 回放 / Replay | 已记录动作和交通位置 / recorded actions and traffic | 演示路线替换策略输出 / demo-path substitution | 3D trajectory、events、review metrics |

公开 AIS 适配器使用 MMSI 的 SHA-256 进行稳定分组；即使输入很小，也移动完整任务补齐 split，不复制观测。

*The public AIS adapter uses stable MMSI SHA-256 grouping. Even for small inputs, whole tasks move to complete required splits; observations are never duplicated.*

### 版本化实验产物 / Versioned Experiment Artifacts

```text
output/rl_runs/
├── training_progress.json          # real timestep, stage, throughput, recent metrics
├── policy_checkpoint.json          # model, algorithm, split, dual fingerprints
├── <algorithm>_policy.zip          # frozen Stable-Baselines3 model
├── <algorithm>_train_episodes.csv  # raw training episodes
├── evaluation_progress.json        # held-out evaluation state
├── policy_test_trajectory.json     # state, action, traffic, raw outcome
└── <algorithm>_test_episodes.csv   # raw test episodes
```

短预算 smoke test 只证明链路闭环，不等同于策略收敛。正式报告应记录 commit、依赖、随机种子、预算、双重指纹、多 seed 分布和全部失败案例。

*A short smoke budget proves pipeline closure, not policy convergence. Formal reports should retain the commit, dependencies, seeds, budget, dual fingerprints, multi-seed distributions, and every failed case.*

## 港口数据智能 / Port Data Intelligence

### 三个稳定接口 / Three Stable Contracts

| 契约 / Contract | 作用 / Responsibility | 解耦价值 / Decoupling Value |
|---|---|---|
| `ship_port_dataset_v2` | train/validation/test 任务、障碍、地形、交通和海况 / tasks, hazards, terrain, traffic, sea state | 算法只依赖字段，不依赖港口名称 / algorithms depend on fields, not port names |
| `ship_port_profile_v1` | Godot 场景、人工任务、出生点和计划航速 / interactive scene and manual missions | 替换可视化港口 / replaces the visual port layer |
| `ship_training_experiment_v3` | 算法、环境、动力学、世界快照和 split / algorithm, environment, dynamics, world, split | 冻结完整实验上下文 / freezes the full experiment context |

符合契约的新数据集可直接替换实验水域，无需修改算法源码。RL held-out task 与 Godot 人工驾驶预设保持分离，防止可视化配置覆盖独立测试。

*A compliant dataset can replace the experimental waterway without modifying algorithm source. Held-out RL tasks remain separate from Godot manual-driving presets so visualization settings cannot overwrite evaluation data.*

### AccessAIS + GeoJSON 数据管道 / AccessAIS + GeoJSON Pipeline

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

AIS 提供历史交通轨迹；GeoJSON 提供岸线、礁石、码头和防波堤。转换器投影到统一局部米制坐标系，并保留来源文件名、SHA-256、原点、边界和特征数量。

*AIS supplies historical traffic tracks; GeoJSON supplies coastline, reefs, piers, and breakwaters. The adapter projects both into one local metric frame and preserves source filename, SHA-256, origin, bounds, and feature counts.*

```bash
export SHIP_RL_DATASET=/absolute/path/to/port_training_dataset.json
export SHIP_AIS_TARGETS=/absolute/path/to/ais_targets.json
export SHIP_PORT_PROFILE=/absolute/path/to/port_profile.json
```

### 公开海况与来源状态 / Public Weather and Provenance State

默认场景读取带时间戳的 Open-Meteo 新加坡水域海况快照，并可异步刷新。界面区分 `live`、`cache_fallback`、`scenario_override` 和 `manual_override`。

*The default scene reads a timestamped Open-Meteo marine snapshot for Singapore waters and can refresh asynchronously. The UI distinguishes `live`, `cache_fallback`, `scenario_override`, and `manual_override`.*

```bash
python3 tools/public_data_pipeline.py weather \
  --latitude 1.2644 \
  --longitude 103.8223 \
  --output data/public_cache/marine_weather_singapore.json
```

## 交互式航行控制台 / Interactive Maritime Operations Console

| 模块 / Module | 能力 / Capability | 数据边界 / Data Boundary |
|---|---|---|
| 遥测 HUD / Telemetry HUD | 航向、航速、舵角、路线、雷达、环境、告警 / heading, speed, rudder, route, radar, environment | live simulator state |
| 航线规划 / Route planning | 任务、航图、航点、到达半径、计划航速 / mission, chart, waypoints, radius, speed | versioned port profile |
| AIS 舰队 / AIS fleet | 历史目标与场景交通 / historical targets and scenario traffic | source-labelled, not live surveillance |
| 风险决策 / Risk decision | CPA/TCPA、XTE、净距和风险阈值 / CPA/TCPA, XTE, clearance, thresholds | deterministic local computation |
| 天气海况 / Weather and sea | public live/cache + manual/scenario modes | explicit source state |
| 教员控制 / Instructor console | 天气、事故、临时障碍注入 / weather, incident, temporary-hazard injection | explicitly labelled scenario injection |
| 仿真复盘 / Simulation review | 航程、时间、事件和估算指标 / distance, time, events, modeled metrics | runtime record and model estimates |
| RL 控制 / RL control | 算法配置、环境包络、训练、测试和回放 / algorithm, envelope, train, test, replay | real process and artifact state |

## 快速开始 / Quick Start

### 环境 / Requirements

- Godot 4.7
- Python 3.10+
- macOS、Linux 或 Windows / macOS, Linux, or Windows

```bash
git clone https://github.com/wenjiayi123/sailing-simulator.git
cd sailing-simulator
bash tools/setup_rl_env.sh
.venv/bin/python -m unittest tests.test_ship_rl -v
godot --editor --path .
```

运行 `main.tscn`，按 `C` 打开训练页；选择算法与预算，完成训练后再执行 held-out test 与 3D replay。

*Run `main.tscn` and press `C` to open the training tab. Select an algorithm and budget, complete training, then execute the held-out test and 3D replay.*

### 操作键 / Controls

| 按键 / Key | 功能 / Function |
|---|---|
| 方向键 / Arrow keys | 油门与舵角 / throttle and rudder |
| 鼠标右键拖动、滚轮 / Right-drag, wheel | 环视与相机距离 / orbit and distance |
| `G` | 开放水域 / 港区场景 / open-water or harbor scenario |
| `T` / `1`–`4` | 天气循环 / 直接预设 / weather cycle or preset |
| `N` | 航行任务与航线规划 / mission and route planning |
| `I` | AIS 舰队态势 / AIS fleet picture |
| `V` | 风险决策 / risk decision |
| `P` | 仿真复盘 / simulation review |
| `O` | 教员控制台 / instructor console |
| `Z` / `X` / `C` | RL 面板 / 船舶页 / 训练页 |

### 命令行训练 / CLI Training

```bash
.venv/bin/python tools/rl_train_baselines.py \
  --mode train \
  --algorithm ppo \
  --config tests/fixtures/ship_training_config.json \
  --episodes 25 --steps 800 --agents 1 \
  --output-dir output/rl_runs \
  --progress-json output/rl_runs/training_progress.json \
  --checkpoint-json output/rl_runs/policy_checkpoint.json
```

### 独立测试 / Held-Out Evaluation

```bash
.venv/bin/python tools/rl_train_baselines.py \
  --mode evaluate \
  --algorithm ppo \
  --config tests/fixtures/ship_training_config.json \
  --steps 800 --eval-episodes 1 \
  --output-dir output/rl_runs \
  --progress-json output/rl_runs/evaluation_progress.json \
  --checkpoint-json output/rl_runs/policy_checkpoint.json \
  --trajectory-json output/rl_runs/policy_test_trajectory.json
```

## 工程质量与复现 / Engineering Quality and Reproducibility

```bash
make test          # Python data, environment, controller, and adapter tests
make godot-check   # Godot scene startup and script parsing
make godot-smoke   # Godot RL config and safety-envelope smoke test
```

### 自动化覆盖 / Automated Coverage

- 21D observation/action contract 与 `train` split 隔离 / contract and split isolation;
- test-only evaluation 与 trajectory export / held-out evaluation and trajectory export;
- 数据或环境变化后的 checkpoint 拒绝 / checkpoint rejection after mutation;
- LOS-PID checkpoint-to-rollout 闭环 / control-baseline lifecycle closure;
- circle/box/polygon 地形包络与动态障碍 / shape-aware envelopes and moving hazards;
- 固定随机种子的域随机化复现 / seeded randomization reproducibility;
- AccessAIS 规范化、必需 split 与来源字段 / normalization, mandatory splits, provenance.

GitHub Actions 使用只读仓库权限、固定到完整 commit SHA 的官方 Actions、明确依赖缓存和超时。CI 负责工程回归；大预算多 seed benchmark 负责算法结论。

*GitHub Actions uses read-only repository permissions, official actions pinned to full commit SHAs, explicit dependency caching, and timeouts. CI protects engineering integrity; large-budget multi-seed benchmarks support algorithmic conclusions.*

## 研究与工程应用 / Research and Engineering Applications

| 场景 / Application | 可直接使用的能力 / Immediately Available Capability |
|---|---|
| 自主航行算法研究 / autonomy research | 五基线、统一观测、可替换任务与 held-out 指标 |
| 控制与 RL 对照 / control-vs-RL studies | LOS-PID 与四种 RL 的同契约比较 |
| 港口数据适配 / port-data integration | AIS、GeoJSON、天气、局部坐标和来源追踪 |
| 数字孪生交互 / digital-twin interaction | 3D 场景、遥测、风险、规划、教员与复盘面板 |
| 实验治理 / experiment governance | split、fingerprint、artifact、failure-preserving replay |
| 教学与课程 / education | 从动力学、控制、RL、数据工程到可视化的完整链路 |

## 工程目录 / Engineering Map

```text
.
├── main.tscn / player.gd       # 3D entry point and vessel control
├── scripts/
│   ├── world/                  # route, hazards, scenario, weather
│   ├── ui/                     # telemetry, planning, AIS, risk, RL, review
│   ├── rl/                     # fleet config and policy replay
│   ├── audio/                  # procedural runtime audio
│   └── visual/                 # wake and visual systems
├── tools/ship_rl/              # 21D Gymnasium environment and five baselines
├── tools/rl_train_baselines.py # train/evaluate/export entry point
├── tools/public_data_pipeline.py
├── data/                       # native benchmark, port profile, public cache
├── tests/                      # contract and closed-loop regression tests
├── docs/                       # algorithms, schemas, provenance, reproduction
└── .github/                    # CI, dependency updates, issue and PR forms
```

进一步阅读 / Further reading:

- [数据集契约 / Dataset schema](docs/DATASET_SCHEMA.md)
- [港口配置契约 / Port profile schema](docs/PORT_PROFILE_SCHEMA.md)
- [模块数据边界 / Module data drivers](docs/MODULE_DATA_DRIVERS.md)
- [训练测试回放指南 / Train-test-replay guide](docs/RL_DATA_TRAINING_POLICY_REPLAY_GUIDE.md)
- [可复现实验 / Reproducibility](docs/REPRODUCIBILITY.md)
- [路线图 / Roadmap](docs/ROADMAP.md)

## 社区、许可与使用范围 / Community, License, and Scope

- [参与贡献 / Contributing](CONTRIBUTING.md)
- [行为准则 / Code of Conduct](CODE_OF_CONDUCT.md)
- [安全政策 / Security](SECURITY.md)
- [支持说明 / Support](SUPPORT.md)
- [资产许可审计 / Asset License Audit](docs/ASSET_LICENSE_AUDIT.md)
- [第三方清单 / Third-Party Notices](docs/THIRD_PARTY_ASSETS.md)
- [引用信息 / Citation](CITATION.cff)

项目原生代码、程序化场景、文档和图形使用 [Apache License 2.0](LICENSE)。本系统用于自主航行研究、教学和软件验证，不是经认证的实船导航或控制系统。

*Project-authored source, procedural scenes, documentation, and graphics are licensed under [Apache License 2.0](LICENSE). The system targets maritime-autonomy research, education, and software validation; it is not a certified real-vessel navigation or control system.*

---

<div align="center">
  <strong>复杂能力进入系统，可信证据留在链路。</strong><br>
  <strong>Sophisticated capability inside the system. Traceable evidence across the lifecycle.</strong>
</div>
