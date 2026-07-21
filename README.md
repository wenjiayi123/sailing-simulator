<div align="center">
  <img src="docs/images/hero.svg" width="100%" alt="航行模拟器项目封面">
  <h1>航行模拟器</h1>
  <p><strong>面向自主航行研究的可审计数字实验系统：统一 3D 仿真、控制基线、港口数据、独立评估与证据回放。</strong></p>
  <p><em>An auditable digital experimentation stack for autonomous-vessel simulation, control, evaluation, and evidence replay.</em></p>
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
    <img alt="Observation" src="https://img.shields.io/badge/observation-21D-8B5CF6">
    <img alt="Version" src="https://img.shields.io/badge/version-0.1.0-FFB000">
    <img alt="Status" src="https://img.shields.io/badge/status-research%20benchmark-00d7e9">
  </p>
</div>

> [!IMPORTANT]
> 这是研究、教学和软件验证项目，不是经认证的船舶导航、避碰或自动驾驶系统，不能用于真实船舶决策。

## 项目定位

航行模拟器不是单一驾驶场景，也不是只展示一条成功曲线的 RL 演示。它是一套由 **交互仿真平面、数值实验平面、数据治理平面和证据回放平面** 组成的研究型系统：Godot 4.7 负责船舶动力、港区场景、交通、航线、遥测与测试结果回放；Python 负责数据切分、无渲染训练、模型冻结和独立测试集评估；版本化 JSON 契约连接两端。

| 能力 | 本项目的实现 |
|---|---|
| 可交互仿真 | 程序化海面、无人船、港区障碍、航标、天气、AIS 目标与双语遥测 HUD |
| 五种可比基线 | PPO、SAC、TD3、DQN，以及控制理论 LOS-PID |
| 严格实验边界 | 训练只读 `train`，测试只读 `test`，训练阶段不渲染 |
| 可替换港口 | `ship_port_dataset_v2`、港区 profile、AIS/GeoJSON 适配器 |
| 可审计产物 | 配置与数据 SHA-256、checkpoint、进度、真实测试轨迹和原始指标 |
| 可信展示 | Godot 只回放测试 rollout，不生成预制成功曲线 |

### 四个设计原则

1. **训练与展示解耦**：训练不依赖帧率、相机或画面刷新，3D 只在独立测试完成后承担解释和复盘。
2. **算法与港口解耦**：算法消费稳定的 21 维观测和 `ship_port_dataset_v2`，更换水域不要求改写算法源码。
3. **配置与结果绑定**：数据、动力学、奖励、安全包络和场景快照共同形成实验指纹，旧模型不能包装新配置结果。
4. **来源与数值分级**：公开观测、时间戳缓存、数值估算、人工场景注入和不可用状态在界面与文档中明确区分。

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

系统按四个平面组织：

| 平面 | 核心职责 | 主要实现 |
|---|---|---|
| 交互仿真平面 | 船舶驾驶、航线、天气、交通、风险、教员注入与遥测 | Godot `main.tscn`、`player.gd`、`scripts/world/`、`scripts/ui/` |
| 数值实验平面 | 环境积分、五基线训练、确定性测试与指标聚合 | Gymnasium、Stable-Baselines3、`tools/ship_rl/` |
| 数据治理平面 | split 隔离、坐标转换、来源元数据、配置和数据指纹 | `ship_port_dataset_v2`、AIS/GeoJSON/Open-Meteo 适配器 |
| 证据回放平面 | 读取测试动作序列、同步动态障碍、显示原始测试结论 | `ship_policy_test_rollout_v3`、Godot policy replay |

这种分层让 UI、数据和算法都可以独立替换，同时保留可验证的连接契约。

## 技术深潜

### 船舶状态与数值积分

环境内部状态为 `(x, z, heading, signed_speed, throttle, rudder)`。每个时间步执行油门和舵角的一阶响应、前进/倒车目标速度、加减速约束、低速转向权、倒车转向符号以及海流平流。这个模型用于算法与软件链路研究，参数可审计、可复现，但不冒充经实船辨识的六自由度水动力模型。

### 21 维观测契约

| 观测组 | 维度 | 内容 |
|---|:---:|---|
| 任务几何 | 4 | 目标距离、航向误差 `sin/cos`、横向误差 XTE |
| 船舶状态 | 3 | 归一化航速、油门、舵角 |
| 最近风险目标 | 5 | 净距、相对方位 `sin/cos`、闭合速度、TCPA |
| 环境作用 | 4 | 海流速度、相对流向 `sin/cos`、风速 |
| 航行上下文 | 2 | 航点进度、可航边界净距 |
| 空间感知 | 3 | 前方、左舷、右舷扇区净距 |
| **合计** | **21** | 全部分量归一化到 `[-1, 1]` |

连续算法使用 `Box(-1, 1, shape=(2,))` 输出油门与舵角；DQN 使用由相同控制量构成的 9 个离散组合，因此算法比较仍建立在一致的物理语义上。

### 形状感知安全引擎

- 静态几何支持 `circle`、轴对齐 `box` 和 `polygon`，不是统一退化成质点距离。
- `cliff`、`terrain`、`shoreline` 在船体半径和通用障碍膨胀外叠加专用净距。
- 动态交通船按航向/航速或速度向量推进，环境计算相对运动、闭合速度与 TCPA。
- 感知半径、碰撞终止、边界内缩、障碍膨胀和地形净距全部进入实验配置与指纹。
- 训练可启用起点、航向、障碍尺寸/位置、风流和传感器噪声域随机化；相同种子可复现。

### 奖励与评估分离

训练奖励综合航线推进、航向一致性、速度、舵角使用、近障惩罚、普通碰撞、地形碰撞、越界与航点到达。最终评价不以 reward 代替安全结论，而是单独输出：

| 指标族 | 原始指标 |
|---|---|
| 任务完成 | `success`、`goal_reached`、steps、elapsed time |
| 安全 | collisions、terrain collisions、near misses、minimum clearance |
| 航迹质量 | maximum cross-track error、path length |
| 实验统计 | episode reward、mean reward、success rate、动态障碍数量 |

失败 episode 与成功 episode 使用同一套导出路径；没有“只对成功轨迹生成回放”的旁路。

## 统一基准下的五种算法

| 基线 | 范式 | 动作空间 | 真实接入参数 | 实验角色 |
|---|---|---|---|---|
| PPO | on-policy actor-critic | 连续油门 + 舵角 | learning rate、GAE、clip、entropy、value loss、rollout、mini-batch | 稳健策略优化参照 |
| SAC | off-policy maximum entropy | 连续油门 + 舵角 | learning rate、gamma、batch、replay buffer、warm-up | 样本效率与随机策略参照 |
| TD3 | off-policy deterministic actor-critic | 连续油门 + 舵角 | learning rate、gamma、batch、replay buffer、warm-up | 连续控制和双评论家参照 |
| DQN | off-policy value learning | 9 个离散组合 | replay buffer、target update、epsilon 起止与衰减 | 离散控制对照 |
| LOS-PID | guidance + feedback control | 连续油门 + 舵角 | LOS 与 `Kp/Ki/Kd` 增益 | 无训练控制理论下界 |

DQN 使用离散动作，因为标准 DQN 不支持连续动作。所有基线共享同一观测定义、动力学、安全指标和数据切分。参数的实际映射见 [算法参数说明](docs/ALGORITHM_PARAMETERS.md)。

LOS-PID 的 checkpoint 明确记录 `trained=false` 和控制器增益；它不伪装成学习算法，但经历与四种 RL 完全相同的 held-out 测试与指标计算。

## 实验完整性与证据链

| 阶段 | 允许读取 | 禁止事项 | 可审计产物 |
|---|---|---|---|
| 数据准备 | 原始 AIS/GeoJSON/天气与来源元数据 | 跨 split 复制同一航次 | 数据集、来源 URL/时间、原文件 SHA-256 |
| 训练 | `train`，可用 `validation` 做模型选择 | 读取 `test`、启动 3D 渲染、写死进度 | progress、训练 CSV、模型、checkpoint |
| 冻结 | 数据与完整实验配置 | 更换动力学/奖励/安全参数后复用旧 checkpoint | `dataset_sha256`、`experiment_sha256` |
| 测试 | 冻结模型 + `test` | 修改失败结果、筛除失败 seed | 测试 CSV、聚合指标、原始 trajectory |
| 回放 | 已记录测试动作与动态目标位置 | 使用演示航线替换策略输出 | Godot 3D 轨迹、事件与复盘指标 |

公开 AIS 适配器按 MMSI 的 SHA-256 稳定分组；小数据集为补齐 split 时移动完整任务，而不是复制观测。该约束用于降低同一船舶轨迹同时进入训练与测试造成的数据泄漏。

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

### 实验产物契约

```text
output/rl_runs/
├── training_progress.json          # 真实 timestep、阶段、速度和近期统计
├── policy_checkpoint.json          # 模型、算法、split 与双重实验指纹
├── <algorithm>_policy.zip          # Stable-Baselines3 冻结模型
├── <algorithm>_train_episodes.csv  # 训练 episode 原始指标
├── evaluation_progress.json        # held-out 测试进度
├── policy_test_trajectory.json     # 状态、动作、动态目标和测试结论
└── <algorithm>_test_episodes.csv   # 测试 episode 原始指标
```

研究报告应至少记录 commit SHA、依赖版本、算法、随机种子、训练预算、数据与实验指纹、多 seed 分布、全部失败案例和 held-out 指标。仓库不接受仅凭一次短训练得出算法优越性或可部署性的结论。

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

### 三个稳定契约

| 契约 | 作用 | 与具体港口的关系 |
|---|---|---|
| `ship_port_dataset_v2` | 训练/验证/测试任务、障碍、地形、动态目标与海况 | 算法只依赖字段，不依赖港口名称 |
| `ship_port_profile_v1` | Godot 场景几何、人工驾驶任务、出生点与计划航速 | 用于可视化和操作场景替换 |
| `ship_training_experiment_v3` | 算法参数、环境参数、船舶动力学、世界快照与 split | 冻结一次实验的完整上下文 |

RL 测试任务与 Godot 人工驾驶预设保持分离，避免可视化场景在运行时覆盖独立测试数据。

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

### 当前自动化覆盖

- 21 维 observation/action 契约与 `train` split 隔离；
- 训练后仅使用 `test` split 的评估与轨迹导出；
- 数据/环境设置变化导致 checkpoint 拒绝；
- LOS-PID 从 checkpoint 到 held-out rollout 的闭环；
- 圆/矩形/多边形地形包络与动态障碍；
- 相同随机种子下的域随机化可复现性；
- AccessAIS 规范化、必需 split 和来源字段。

CI 使用只读仓库权限、固定到完整 commit SHA 的官方 Actions、依赖缓存路径和 15 分钟超时。它验证工程回归，不替代大预算算法 benchmark。

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

## 成熟度与边界

| 领域 | 当前状态 | 进一步达到生产级所需工作 |
|---|---|---|
| 仿真与 UI | 可交互 3D、双语 HUD、多面板、场景注入与复盘 | 人因测试、多设备适配、长期稳定性验证 |
| 动力学 | 参数化二维航行积分与风流作用 | 六自由度模型、船模/实船辨识、浅水与波浪耦合 |
| 学习与控制 | 四种 SB3 算法 + LOS-PID 统一接口 | 大预算多 seed benchmark、超参数研究、泛化评估 |
| 数据 | 原生基准、AIS/GeoJSON/天气适配与来源元数据 | 经许可的港区 GIS、测深、潮汐与传感器质量模型 |
| 安全 | 净距、TCPA、碰撞/地形/近失指标与失败保真 | COLREGs 规则验证、失效保护、人在回路、形式化安全层 |
| 部署 | 可导出模型和动作轨迹 | 中间件、硬件在环、执行器限幅、冗余通信与认证 |

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
  <strong>复杂可以存在于系统内部，但证据边界必须始终清晰。</strong><br>
  <sub>Build sophisticated maritime autonomy experiments — and keep every claim traceable to evidence.</sub>
</div>
