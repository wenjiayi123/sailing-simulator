<div align="center">
  <img src="docs/images/hero.svg" width="100%" alt="Sailing Simulator project cover">
  <h1>Sailing Simulator</h1>
  <p><strong>An auditable digital experimentation stack for autonomous-vessel simulation, control, evaluation, and evidence replay.</strong></p>
  <p><em>面向自主航行研究的可审计数字实验系统：统一 3D 仿真、控制基线、港口数据、独立评估与证据回放。</em></p>
  <p>
    <a href="README.md">简体中文</a> ·
    <a href="docs/RL_DATA_TRAINING_POLICY_REPLAY_GUIDE.md">Experiment guide</a> ·
    <a href="docs/DATASET_SCHEMA.md">Data contract</a> ·
    <a href="CONTRIBUTING.md">Contributing</a>
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

> [!WARNING]
> This repository is for research, education, and software validation. It is not a certified navigation, collision-avoidance, or vessel-control system and must not be used for real-vessel decisions.

## Positioning

Sailing Simulator is not a single driving scene and not a reinforcement-learning demo that renders one curated success path. It is a research system organized into four explicit planes:

- an **interactive simulation plane** for vessel control, route planning, traffic, weather, telemetry, and review;
- a **numerical experiment plane** for render-free training, frozen checkpoints, and held-out evaluation;
- a **data-governance plane** for split isolation, coordinate conversion, provenance, and fingerprints;
- an **evidence-replay plane** that visualizes recorded test actions without replacing the result.

Godot 4.7 owns the interactive world. Python owns the Gymnasium environment, five baselines, split-aware experiment lifecycle, and machine-readable artifacts. Versioned JSON contracts connect both sides.

| Capability | Concrete implementation |
|---|---|
| Interactive simulation | Procedural water and vessel, harbor obstacles, aids to navigation, weather, AIS targets, bilingual telemetry HUD |
| Five comparable baselines | PPO, SAC, TD3, DQN, and a control-theory LOS-PID baseline |
| Strict experiment boundary | Training reads `train`; evaluation reads `test`; training never renders the Godot scene |
| Interchangeable ports | `ship_port_dataset_v2`, `ship_port_profile_v1`, AIS and GeoJSON adapters |
| Auditable artifacts | Dataset/config SHA-256, checkpoints, real progress, held-out trajectories, and unmodified metrics |
| Evidence-preserving replay | Godot replays evaluated throttle/rudder commands and recorded dynamic traffic positions |

### Design principles

1. **Decouple training from presentation.** Frame rate, camera state, and visual effects never drive optimization.
2. **Decouple algorithms from ports.** Algorithms consume a stable 21D observation and versioned task contract rather than hard-coded port names.
3. **Bind configuration to results.** Dynamics, rewards, safety envelopes, data, and scene snapshots participate in the experiment fingerprint.
4. **Label data by epistemic status.** Public observations, timestamped cache, numerical estimates, scenario injection, and unavailable values remain distinct.

## Real runtime captures

![Simulator overview](docs/images/simulator-overview.png)

<details>
<summary><strong>Route planning and port profile</strong></summary>

![Navigation planning](docs/images/navigation-planning.png)

</details>

<details>
<summary><strong>Training and held-out evaluation console</strong></summary>

![RL console](docs/images/rl-training-console.png)

</details>

The PNG files above are generated from the current `main.tscn` by [`tools/capture_readme_screenshots.gd`](tools/capture_readme_screenshots.gd). They are runtime captures, not concept art. The cover, architecture diagram, icon, and social preview are project-authored vectors.

## Architecture

![Training, evaluation, and replay architecture](docs/images/architecture.svg)

```text
train split -> Python numerical environment -> optimization -> checkpoint
                                                          |
user requests held-out test and replay                    v
test split  -> deterministic rollout -> trajectory/metrics -> Godot replay
```

| Plane | Responsibility | Main implementation |
|---|---|---|
| Interactive simulation | Vessel control, route, weather, traffic, risk, instructor injection, telemetry | Godot `main.tscn`, `player.gd`, `scripts/world/`, `scripts/ui/` |
| Numerical experiment | Dynamics integration, five baselines, deterministic evaluation, aggregation | Gymnasium, Stable-Baselines3, `tools/ship_rl/` |
| Data governance | Split isolation, coordinate normalization, provenance, config/data fingerprints | Versioned schemas, AIS/GeoJSON/Open-Meteo adapters |
| Evidence replay | Recorded commands, dynamic-target synchronization, original outcomes | `ship_policy_test_rollout_v3`, Godot replay controller |

This separation allows the UI, port data, and algorithm implementation to evolve independently while retaining a testable interface between them.

## Technical deep dive

### State and numerical integration

The environment state is `(x, z, heading, signed_speed, throttle, rudder)`. Every step applies first-order throttle and rudder response, forward/reverse target speed, acceleration and deceleration limits, speed-dependent turning authority, reverse steering sign, and current advection.

The model is intentionally transparent and parameterized. It is suitable for algorithm and software-pipeline research; it is not presented as a calibrated six-degree-of-freedom hydrodynamic model.

### The 21-dimensional observation contract

| Observation group | Dimensions | Signals |
|---|:---:|---|
| Mission geometry | 4 | Target distance, heading-error `sin/cos`, cross-track error |
| Vessel state | 3 | Normalized speed, throttle, rudder |
| Nearest risk target | 5 | Clearance, relative-bearing `sin/cos`, closing speed, TCPA |
| Environmental effect | 4 | Current speed, relative-current `sin/cos`, wind speed |
| Navigation context | 2 | Waypoint progress, navigable-boundary clearance |
| Spatial sectors | 3 | Forward, port, and starboard clearances |
| **Total** | **21** | Every component normalized to `[-1, 1]` |

PPO, SAC, TD3, and LOS-PID use `Box(-1, 1, shape=(2,))` throttle/rudder commands. DQN uses nine discrete combinations with the same physical meaning.

### Shape-aware safety interaction

- Static geometry supports circles, axis-aligned boxes, and polygons instead of reducing every hazard to a point.
- `cliff`, `terrain`, and `shoreline` add a dedicated safety margin beyond vessel radius and generic obstacle inflation.
- Dynamic traffic advances from course/speed or metric velocity and participates in relative-motion, closing-speed, and TCPA calculations.
- Sensor range, collision termination, boundary margin, vessel radius, obstacle inflation, and terrain inflation are experiment parameters and fingerprint inputs.
- Training can randomize start position, heading, obstacle position/size, wind/current, and sensor noise while remaining reproducible for a fixed seed.

### Reward is not the safety report

The training reward combines route progress, heading alignment, speed, rudder effort, proximity, collision, terrain collision, boundary violation, and waypoint arrival. Held-out evaluation separately exports the original outcome and safety metrics:

| Metric family | Raw outputs |
|---|---|
| Completion | `success`, `goal_reached`, steps, elapsed time |
| Safety | collisions, terrain collisions, near misses, minimum clearance |
| Track quality | maximum cross-track error, path length |
| Experiment statistics | episode reward, mean reward, success rate, dynamic-obstacle count |

Failed and successful episodes follow the same export path. There is no replay-only success branch.

## Five algorithms under one benchmark contract

| Baseline | Paradigm | Action space | Connected parameters | Experimental role |
|---|---|---|---|---|
| PPO | on-policy actor-critic | Continuous throttle + rudder | learning rate, GAE, clip, entropy, value loss, rollout, mini-batch | Stable policy-optimization reference |
| SAC | off-policy maximum entropy | Continuous throttle + rudder | learning rate, gamma, batch, replay buffer, warm-up | Sample-efficient stochastic reference |
| TD3 | off-policy deterministic actor-critic | Continuous throttle + rudder | learning rate, gamma, batch, replay buffer, warm-up | Continuous-control and twin-critic reference |
| DQN | off-policy value learning | Nine discrete combinations | replay buffer, target update, epsilon schedule | Discrete-control comparison |
| LOS-PID | guidance + feedback control | Continuous throttle + rudder | LOS and `Kp/Ki/Kd` gains | Non-learning control-theory baseline |

All five baselines share the same observation, dynamics, task splits, safety metrics, and evaluation exporter. Standard DQN remains discrete because it does not support continuous actions. LOS-PID checkpoints explicitly record `trained=false` and controller gains; the baseline is never misrepresented as a learned policy.

See [ALGORITHM_PARAMETERS.md](docs/ALGORITHM_PARAMETERS.md) for the UI-to-backend parameter map.

## Experiment integrity and evidence chain

| Stage | Allowed inputs | Disallowed shortcuts | Auditable outputs |
|---|---|---|---|
| Data preparation | Raw AIS/GeoJSON/weather plus provenance | Duplicating one voyage across splits | Dataset, source URL/time, original-file SHA-256 |
| Training | `train`; optional `validation` for selection | Reading `test`, rendering 3D, synthetic timer progress | Progress, training CSV, model, checkpoint |
| Freeze | Data and full experiment configuration | Reusing a checkpoint after changing dynamics/rewards/safety | `dataset_sha256`, `experiment_sha256` |
| Evaluation | Frozen policy plus `test` | Rewriting failure, removing failed seeds | Test CSV, aggregate metrics, raw trajectory |
| Replay | Recorded test actions and traffic positions | Replacing output with a built-in demo route | Godot trajectory, events, review metrics |

The public AIS adapter assigns MMSI groups to splits with stable SHA-256 hashing. When a small input needs every required split, whole tasks move between splits; observations are not copied.

## Quick start

Requirements: Godot 4.7 and Python 3.10+.

```bash
git clone https://github.com/wenjiayi123/sailing-simulator.git
cd sailing-simulator
bash tools/setup_rl_env.sh
.venv/bin/python -m unittest tests.test_ship_rl -v
godot --editor --path .
```

Run `main.tscn`. Press `C` to open the training tab, choose a baseline and budget, start training, then run the held-out test and replay only after the checkpoint is ready.

| Key | Function |
|---|---|
| Arrow keys | Throttle and rudder control |
| Right-drag / wheel | Camera orbit and distance |
| `G` | Open-water / harbor scenario |
| `T` / `1`–`4` | Cycle weather / direct preset |
| `N` | Navigation mission and route planning |
| `I` | AIS fleet picture |
| `V` | Risk-decision panel |
| `P` | Simulation review |
| `O` | Instructor console |
| `Z` / `X` / `C` | RL panel / vessel tab / training tab |

## CLI experiment

Train:

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

Evaluate on the held-out split:

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

A short smoke budget proves pipeline closure, not policy convergence.

### Artifact contract

```text
output/rl_runs/
├── training_progress.json
├── policy_checkpoint.json
├── <algorithm>_policy.zip
├── <algorithm>_train_episodes.csv
├── evaluation_progress.json
├── policy_test_trajectory.json
└── <algorithm>_test_episodes.csv
```

A report should record the repository commit, dependency versions, algorithm, seeds, budget, data and experiment fingerprints, multi-seed distribution, every failed case, and held-out metrics. See [REPRODUCIBILITY.md](docs/REPRODUCIBILITY.md).

## Bring your own port

The algorithm layer does not depend on a port name. Point the stable task contract at another dataset:

```bash
export SHIP_RL_DATASET=/absolute/path/to/port_training_dataset.json
export SHIP_AIS_TARGETS=/absolute/path/to/ais_targets.json
export SHIP_PORT_PROFILE=/absolute/path/to/port_profile.json
```

Normalize NOAA/BOEM AccessAIS CSV or ZIP data and WGS84 GeoJSON into a shared local metric frame:

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

AIS supplies historical traffic tracks; GeoJSON supplies coastline and fixed hazards. The converter preserves source filenames, SHA-256, origin, bounds, and feature counts.

### Three stable contracts

| Contract | Responsibility | Port coupling |
|---|---|---|
| `ship_port_dataset_v2` | Train/validation/test tasks, hazards, terrain, traffic, sea state | Algorithms depend on fields, not names |
| `ship_port_profile_v1` | Godot geometry, manual missions, spawn, planned speed | Replaces the interactive scenario |
| `ship_training_experiment_v3` | Algorithm, environment, dynamics, world snapshot, split | Freezes one complete experiment |

The RL held-out task remains separate from Godot manual-driving presets so that a visualization preset cannot overwrite evaluation data at runtime.

## Public weather and provenance

The default scene reads a timestamped Open-Meteo marine snapshot for Singapore waters and can refresh public data asynchronously. The UI distinguishes `live`, `cache_fallback`, `scenario_override`, and `manual_override`; cache and injected values are not labeled as sensor observations.

```bash
python3 tools/public_data_pipeline.py weather \
  --latitude 1.2644 \
  --longitude 103.8223 \
  --output data/public_cache/marine_weather_singapore.json
```

See [DATASET_SCHEMA.md](docs/DATASET_SCHEMA.md), [PORT_PROFILE_SCHEMA.md](docs/PORT_PROFILE_SCHEMA.md), [DATA_SOURCES.md](docs/DATA_SOURCES.md), and [MODULE_DATA_DRIVERS.md](docs/MODULE_DATA_DRIVERS.md).

## Engineering quality gates

```bash
make test
make godot-check
make godot-smoke
```

Current automated coverage includes:

- the 21D observation/action contract and `train` split isolation;
- test-only evaluation and trajectory export;
- checkpoint rejection after data or environment mutation;
- LOS-PID checkpoint-to-held-out-rollout closure;
- circle/box/polygon terrain envelopes and moving hazards;
- seeded domain-randomization reproducibility;
- AccessAIS normalization, mandatory splits, and provenance fields.

GitHub Actions runs with read-only repository permissions, official actions pinned to full commit SHAs, an explicit dependency-cache path, and a 15-minute timeout. CI verifies engineering regression; it does not replace a large-budget algorithm benchmark.

## Repository structure

```text
.
├── main.tscn / player.gd       # Procedural 3D entry point and vessel control
├── scripts/                    # World, UI, audio, visual, and policy replay
├── tools/ship_rl/              # 21D environment and five baselines
├── tools/rl_train_baselines.py # Train, evaluate, and export artifacts
├── tools/public_data_pipeline.py
├── data/                       # Native benchmark, port profiles, public cache
├── tests/                      # Contract and closed-loop regression tests
├── docs/                       # Data, algorithms, provenance, reproduction
└── .github/                    # CI, dependency updates, issue and PR forms
```

## Maturity and boundaries

| Domain | Current implementation | Required for production-grade use |
|---|---|---|
| Simulation and UI | Interactive 3D, bilingual HUD, multi-panel operation and review | Human-factors study, multi-device validation, endurance testing |
| Dynamics | Parameterized planar navigation with current effect | 6-DOF model, vessel identification, shallow-water and wave coupling |
| Learning and control | Four SB3 algorithms plus LOS-PID under one contract | Large-budget multi-seed benchmark, generalization and tuning studies |
| Data | Native benchmark, AIS/GeoJSON/weather adapters and provenance | Licensed port GIS, bathymetry, tides, sensor-quality models |
| Safety | Clearance, TCPA, collision/terrain/near-miss metrics | COLREG validation, fail-safe control, human takeover, formal safety layer |
| Deployment | Exported models and action trajectories | Middleware, hardware-in-the-loop, actuator limits, redundant communication, certification |

The bundled traffic, port geometry, and training tasks are project-authored benchmark inputs. A short CI run does not establish convergence or rank algorithms. The repository contains no certified execution interface and no real-vessel actuation path.

See [ROADMAP.md](docs/ROADMAP.md) and [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md).

## Community, security, and license

Please read [CONTRIBUTING.md](CONTRIBUTING.md), [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md), and [SUPPORT.md](SUPPORT.md) before contributing. Report security issues privately as described in [SECURITY.md](SECURITY.md). New binary assets or datasets must pass the [asset-license audit](docs/ASSET_LICENSE_AUDIT.md).

Project-authored source, procedural scenes, documentation, and graphics are licensed under [Apache-2.0](LICENSE). Third-party runtime and public-data notices are listed in [THIRD_PARTY_ASSETS.md](docs/THIRD_PARTY_ASSETS.md) and [NOTICE](NOTICE). Use [`CITATION.cff`](CITATION.cff) when citing the project.

---

<div align="center">
  <strong>Sophistication belongs inside the system; the evidence boundary must remain explicit.</strong><br>
  <sub>Build sophisticated maritime autonomy experiments — and keep every claim traceable to evidence.</sub>
</div>
