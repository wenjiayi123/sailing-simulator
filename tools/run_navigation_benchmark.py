#!/usr/bin/env python3
"""Prepare, finalize, and verify the fixed five-method navigation benchmark."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import sys
from typing import Any, Mapping


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import gymnasium  # noqa: E402
import numpy  # noqa: E402
import stable_baselines3  # noqa: E402
import torch  # noqa: E402

from tools.ship_rl.environment import OBSERVATION_SIZE, load_experiment  # noqa: E402
from tools.ship_rl.trainer import (  # noqa: E402
    ALGORITHMS,
    EvaluateRequest,
    TrainRequest,
    evaluate,
    train,
)


CONFIG = ROOT / "data/rl/long_beach_public_weather_experiment_v1.json"
DATASET = ROOT / "data/rl/long_beach_public_weather_benchmark_v1.json"
HOURLY = ROOT / "data/public/long_beach_open_meteo_2024_01_04_hourly.csv"
PROVENANCE = ROOT / "data/public/long_beach_open_meteo_2024_01_04.provenance.json"
PREPARED_REPORT = ROOT / "reports/navigation_benchmark_v1_prepared.json"
FINAL_REPORT = ROOT / "reports/navigation_benchmark_v1.json"
FINAL_MARKDOWN = ROOT / "reports/navigation_benchmark_v1.md"
ARTIFACT_ROOT = ROOT / "reports/artifacts/navigation_benchmark_v1"
SEED = 240705
MAX_STEPS = 1_000
RL_TIMESTEPS = 20_000
EVIDENCE_FILES = (
    "data/public/long_beach_open_meteo_2024_01_04_hourly.csv",
    "data/public/long_beach_open_meteo_2024_01_04.provenance.json",
    "data/rl/long_beach_public_weather_benchmark_v1.json",
    "data/rl/long_beach_public_weather_experiment_v1.json",
    "tools/build_public_navigation_benchmark.py",
    "tools/ship_rl/environment.py",
    "tools/ship_rl/trainer.py",
    "tools/rl_train_baselines.py",
    "tools/run_navigation_benchmark.py",
)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _write_json(path: Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def _write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(text, encoding="utf-8")
    temporary.replace(path)


def _relative(path: Path) -> str:
    return str(path.resolve().relative_to(ROOT))


def _software_versions() -> dict[str, str]:
    return {
        "python": platform.python_version(),
        "platform": platform.platform(),
        "numpy": numpy.__version__,
        "gymnasium": gymnasium.__version__,
        "stable_baselines3": stable_baselines3.__version__,
        "torch": torch.__version__,
    }


def _evidence_hashes() -> dict[str, str]:
    return {relative: _sha256(ROOT / relative) for relative in EVIDENCE_FILES}


def _artifact_record(
    algorithm: str,
    run_dir: Path,
    train_result: Mapping[str, Any],
    validation_result: Mapping[str, Any],
) -> dict[str, Any]:
    checkpoint = run_dir / "checkpoint.json"
    checkpoint_payload = json.loads(checkpoint.read_text(encoding="utf-8"))
    model_path: Path | None = None
    if checkpoint_payload.get("model_path"):
        model_path = checkpoint.parent / str(checkpoint_payload["model_path"])
    record = {
        "algorithm": algorithm,
        "seed": SEED,
        "training": {
            "split": train_result["dataset_split"],
            "render": train_result["render"],
            "requested_timesteps": (
                RL_TIMESTEPS if algorithm != "los_pid" else 0
            ),
            "actual_timesteps": train_result["completed_timesteps"],
            "episodes_completed": train_result["episodes_completed"],
            "elapsed_seconds": train_result["elapsed_seconds"],
        },
        "validation": {
            "split": validation_result["dataset_split"],
            "render": validation_result["render"],
            "render_ready": validation_result["render_ready"],
            "metrics": validation_result["aggregate_metrics"],
        },
        "checkpoint": _relative(checkpoint),
        "checkpoint_sha256": _sha256(checkpoint),
        "model": _relative(model_path) if model_path else None,
        "model_sha256": _sha256(model_path) if model_path else None,
        "validation_trajectory": _relative(run_dir / "validation_trajectory.json"),
    }
    return record


def prepare() -> int:
    _config, dataset, _dataset_path = load_experiment(CONFIG)
    validation_count = len(dataset["splits"]["validation"])
    artifacts: list[dict[str, Any]] = []
    for algorithm in ALGORITHMS:
        print(f"prepare {algorithm}: headless train", flush=True)
        run_dir = ARTIFACT_ROOT / algorithm
        run_dir.mkdir(parents=True, exist_ok=True)
        train_result = train(
            TrainRequest(
                algorithm=algorithm,
                config_path=CONFIG,
                output_dir=run_dir,
                progress_path=run_dir / "training_progress.json",
                checkpoint_path=run_dir / "checkpoint.json",
                total_timesteps=RL_TIMESTEPS,
                max_steps=MAX_STEPS,
                parallel_envs=1,
                seed=SEED,
            )
        )
        print(f"prepare {algorithm}: validation-only rollout", flush=True)
        validation_result = evaluate(
            EvaluateRequest(
                algorithm=algorithm,
                config_path=CONFIG,
                output_dir=run_dir,
                progress_path=run_dir / "validation_progress.json",
                checkpoint_path=run_dir / "checkpoint.json",
                trajectory_path=run_dir / "validation_trajectory.json",
                max_steps=MAX_STEPS,
                episodes=validation_count,
                seed=SEED,
                split="validation",
            )
        )
        artifacts.append(
            _artifact_record(
                algorithm,
                run_dir,
                train_result,
                validation_result,
            )
        )
    payload = {
        "schema_version": "1.0",
        "benchmark_id": "ship_navigation_public_weather_v1",
        "prepared_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "test_split_accessed": False,
        "software": _software_versions(),
        "evidence_sha256": _evidence_hashes(),
        "data": {
            "hourly_rows": 2_904,
            "source_period": "2024-01-01..2024-04-30",
            "split_sizes": {
                name: len(tasks) for name, tasks in dataset["splits"].items()
            },
            "split_policy": dataset["split_policy"],
            "source_boundary": dataset["source"],
        },
        "experiment": {
            "seed": SEED,
            "rl_timesteps_per_algorithm": RL_TIMESTEPS,
            "max_steps_per_episode": MAX_STEPS,
            "observation_size": OBSERVATION_SIZE,
            "algorithms": list(ALGORITHMS),
            "training_render_mode": None,
            "validation_render_ready": False,
            "test_render_mode": "recorded_test_rollout",
        },
        "artifacts": artifacts,
    }
    _write_json(PREPARED_REPORT, payload)
    print(f"prepared report: {PREPARED_REPORT}")
    return 0


def _verify_prepared(payload: Mapping[str, Any]) -> list[str]:
    errors: list[str] = []
    if payload.get("test_split_accessed") is not False:
        errors.append("prepared manifest already marks the test split as accessed")
    if payload.get("evidence_sha256") != _evidence_hashes():
        errors.append("data/config/core-code hash changed after preparation")
    artifacts = payload.get("artifacts", [])
    if [item.get("algorithm") for item in artifacts] != list(ALGORITHMS):
        errors.append("prepared artifact algorithm inventory is incomplete or reordered")
    for item in artifacts:
        checkpoint = ROOT / str(item.get("checkpoint", ""))
        if not checkpoint.is_file() or _sha256(checkpoint) != item.get(
            "checkpoint_sha256"
        ):
            errors.append(f"checkpoint changed: {item.get('algorithm')}")
        model_relative = item.get("model")
        if model_relative:
            model = ROOT / str(model_relative)
            if not model.is_file() or _sha256(model) != item.get("model_sha256"):
                errors.append(f"model changed: {item.get('algorithm')}")
        training = item.get("training", {})
        validation = item.get("validation", {})
        if training.get("split") != "train" or training.get("render") is not False:
            errors.append(f"training boundary failed: {item.get('algorithm')}")
        if (
            validation.get("split") != "validation"
            or validation.get("render_ready") is not False
        ):
            errors.append(f"validation boundary failed: {item.get('algorithm')}")
    return errors


def _test_record(
    artifact: Mapping[str, Any],
    result: Mapping[str, Any],
    run_dir: Path,
) -> dict[str, Any]:
    trajectory = run_dir / "test_trajectory.json"
    payload = json.loads(trajectory.read_text(encoding="utf-8"))
    return {
        "algorithm": artifact["algorithm"],
        "seed": artifact["seed"],
        "dataset_split": result["dataset_split"],
        "render_ready": result["render_ready"],
        "trajectory_format": payload["format"],
        "episodes": result["aggregate_metrics"]["episodes"],
        "metrics": result["aggregate_metrics"],
        "trajectory": _relative(trajectory),
        "trajectory_sha256": _sha256(trajectory),
        "episode_metrics_csv": _relative(
            run_dir / f"{artifact['algorithm']}_test_episodes.csv"
        ),
    }


def _ranking_key(item: Mapping[str, Any]) -> tuple[float, ...]:
    metrics = item["metrics"]
    return (
        -float(metrics["safe_completion_rate"]),
        float(metrics["collision_episode_rate"]),
        float(metrics["near_miss_episode_rate"]),
        float(metrics["mean_max_cross_track_error_meters"]),
        -float(metrics["mean_path_efficiency"]),
    )


def _render_markdown(report: Mapping[str, Any]) -> str:
    best = report["best_method"]
    metrics = best["metrics"]
    rows = []
    for result in report["test_results"]:
        value = result["metrics"]
        rows.append(
            "| {algorithm} | {success:.1%} | {collision:.1%} | {near:.1%} | "
            "{xte:.2f} | {clearance:.2f} | {dcpa:.2f} | {efficiency:.1%} |".format(
                algorithm=result["algorithm"].upper().replace("_", "-"),
                success=value["safe_completion_rate"],
                collision=value["collision_episode_rate"],
                near=value["near_miss_episode_rate"],
                xte=value["mean_max_cross_track_error_meters"],
                clearance=value["mean_minimum_clearance_meters"],
                dcpa=value["mean_minimum_dcpa_meters"],
                efficiency=value["mean_path_efficiency"],
            )
        )
    return f"""# 航行模拟器五方法公开海况可靠性基准 v1

生成时间：{report["generated_at"]}

## 结论

- 公开环境输入：Open-Meteo 2024-01-01 至 2024-04-30 共 2,904 条小时级再分析/模式归档，派生 121 个日级仿真场景。
- 时间隔离：60 个训练场景、31 个验证场景、30 个最终测试场景；训练不渲染，验证不可回放，测试完成后才生成 Godot 轨迹。
- 五方法：PPO、SAC、TD3、DQN、LOS-PID；四种 RL 各真实训练 {report["experiment"]["rl_timesteps_per_algorithm"]:,} 步。
- 最终测试共 {report["test_episode_count"]} 个方法-场景 rollout。
- 按预先声明的安全优先排序，最佳方法为 {best["algorithm"].upper().replace("_", "-")}：安全完成率 {metrics["safe_completion_rate"]:.1%}，碰撞场景率 {metrics["collision_episode_rate"]:.1%}，平均最大横向航迹误差 {metrics["mean_max_cross_track_error_meters"]:.2f} m，平均路径效率 {metrics["mean_path_efficiency"]:.1%}。
- 一致性检查：{"PASS" if report["passed"] else "FAIL"}。

## 五方法最终测试

| 方法 | 无碰撞到达率 | 碰撞场景率 | 风险包络侵入率 | 平均最大XTE(m) | 平均最小净距(m) | 平均最小DCPA(m) | 路径效率 |
|---|---:|---:|---:|---:|---:|---:|---:|
{chr(10).join(rows)}

## 功能与可靠性口径

环境包含 28 维观测、连续油门/舵角和 DQN 九离散动作，处理圆形、矩形、多边形障碍、岸线/礁石额外安全包络、动态交通船、TCPA/DCPA、闭合速度、边界和三扇区净距；风、浪、流均进入状态转移，风浪相对方向同时进入观测。模型、数据、奖励、船体动力学和环境参数均绑定 SHA-256；任一变化都会拒绝旧模型评估。

奖励函数由航线推进、航向、速度和到达航点奖励，减去碰撞/地形/边界、当前净距、基于 TCPA/DCPA 的预测冲突、横向航迹误差、舵角、动作变化和时间步成本组成。全部权重位于实验 JSON，不存在按测试结果改写指标。

## 边界

Open-Meteo数据是公开再分析/数值模式产品，只用于离线环境强迫，不适合沿海导航。航线、障碍、船舶动力学和动作响应是仿真假设；本报告不是实船海试、避碰认证、COLREGs合规结论、生产SLA或商业收益。

## 复现

```bash
python tools/build_public_navigation_benchmark.py
python tools/run_navigation_benchmark.py verify
python tools/run_navigation_benchmark.py verify --deep
```
"""


def finalize() -> int:
    prepared = json.loads(PREPARED_REPORT.read_text(encoding="utf-8"))
    errors = _verify_prepared(prepared)
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    _config, dataset, _dataset_path = load_experiment(CONFIG)
    test_count = len(dataset["splits"]["test"])
    test_results: list[dict[str, Any]] = []
    for artifact in prepared["artifacts"]:
        algorithm = str(artifact["algorithm"])
        print(f"finalize {algorithm}: first fixed-test evaluation", flush=True)
        run_dir = ARTIFACT_ROOT / algorithm
        result = evaluate(
            EvaluateRequest(
                algorithm=algorithm,
                config_path=CONFIG,
                output_dir=run_dir,
                progress_path=run_dir / "test_progress.json",
                checkpoint_path=ROOT / artifact["checkpoint"],
                trajectory_path=run_dir / "test_trajectory.json",
                max_steps=MAX_STEPS,
                episodes=test_count,
                seed=SEED,
                split="test",
            )
        )
        test_results.append(_test_record(artifact, result, run_dir))
    ordered = sorted(test_results, key=_ranking_key)
    best = ordered[0]
    completed = sum(item["episodes"] for item in test_results)
    passed = bool(
        len(test_results) == len(ALGORITHMS)
        and completed == len(ALGORITHMS) * test_count
        and all(item["dataset_split"] == "test" for item in test_results)
        and all(item["render_ready"] for item in test_results)
        and best["metrics"]["safe_completion_rate"] >= 0.90
        and best["metrics"]["collision_episode_rate"] <= 0.05
    )
    report = {
        **prepared,
        "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "test_split_accessed": True,
        "test_access_policy": (
            "final test was evaluated only after training and validation artifacts "
            "were frozen in navigation_benchmark_v1_prepared.json"
        ),
        "test_episode_count": completed,
        "test_results": test_results,
        "ranking_policy": (
            "safe completion desc, collision episode rate asc, near-miss episode "
            "rate asc, mean max cross-track error asc, path efficiency desc"
        ),
        "best_method": best,
        "passed": passed,
    }
    _write_json(FINAL_REPORT, report)
    _write_text(FINAL_MARKDOWN, _render_markdown(report))
    print(f"final report: {FINAL_REPORT}")
    print(f"benchmark integrity: {'PASS' if passed else 'FAIL'}")
    return 0 if passed else 1


def verify(*, deep: bool) -> int:
    report = json.loads(FINAL_REPORT.read_text(encoding="utf-8"))
    errors = []
    if report.get("evidence_sha256") != _evidence_hashes():
        errors.append("data/config/core-code hash differs from final report")
    for result in report.get("test_results", []):
        trajectory = ROOT / result["trajectory"]
        if not trajectory.is_file() or _sha256(trajectory) != result.get(
            "trajectory_sha256"
        ):
            errors.append(f"test trajectory changed: {result.get('algorithm')}")
    prepared_errors = _verify_prepared(
        {**report, "test_split_accessed": False}
    )
    errors.extend(prepared_errors)
    if deep and not errors:
        print("deep verify reruns deterministic final-test rollouts", flush=True)
        for artifact, expected in zip(
            report["artifacts"],
            report["test_results"],
        ):
            algorithm = artifact["algorithm"]
            run_dir = ARTIFACT_ROOT / algorithm
            current = evaluate(
                EvaluateRequest(
                    algorithm=algorithm,
                    config_path=CONFIG,
                    output_dir=run_dir,
                    progress_path=run_dir / "verify_progress.json",
                    checkpoint_path=ROOT / artifact["checkpoint"],
                    trajectory_path=run_dir / "verify_trajectory.json",
                    max_steps=MAX_STEPS,
                    episodes=report["data"]["split_sizes"]["test"],
                    seed=SEED,
                    split="test",
                )
            )
            if current["aggregate_metrics"] != expected["metrics"]:
                errors.append(f"deep metrics differ: {algorithm}")
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    print(f"navigation benchmark verify: PASS ({'deep' if deep else 'hash-only'})")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("prepare")
    subparsers.add_parser("finalize")
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--deep", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    if arguments.command == "prepare":
        return prepare()
    if arguments.command == "finalize":
        return finalize()
    return verify(deep=arguments.deep)


if __name__ == "__main__":
    raise SystemExit(main())
