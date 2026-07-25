#!/usr/bin/env python3
"""Prepare, finalize, and verify the ten-method real-port benchmark."""

from __future__ import annotations

import argparse
from concurrent.futures import ProcessPoolExecutor, as_completed
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
import sb3_contrib  # noqa: E402
import torch  # noqa: E402

from tools.ship_rl.environment import load_experiment  # noqa: E402
from tools.ship_rl.port_ops_environment import (  # noqa: E402
    PORT_OPS_OBSERVATION_SIZE,
)
from tools.ship_rl.port_ops_trainer import (  # noqa: E402
    ALGORITHMS,
    CONTROL_ALGORITHMS,
    EvaluateRequest,
    TrainRequest,
    evaluate_port_ops,
    train_port_ops,
)


CONFIG = ROOT / "data/rl/long_beach_ais_port_ops_experiment_v2.json"
DATASET = ROOT / "data/rl/long_beach_ais_port_ops_benchmark_v2.json"
PREPARED_REPORT = ROOT / "reports/port_ops_benchmark_v2_prepared.json"
FINAL_REPORT = ROOT / "reports/port_ops_benchmark_v2.json"
FINAL_MARKDOWN = ROOT / "reports/port_ops_benchmark_v2.md"
ARTIFACT_ROOT = ROOT / "reports/artifacts/navigation_benchmark_v2"
SEED = 250107
DEFAULT_TIMESTEPS = 2_000
DEFAULT_MAX_STEPS = 1_600
PARALLEL_ALGORITHMS = 4
EVIDENCE_FILES = (
    "data/public/long_beach_ais_2025_w01.provenance.json",
    "data/public/long_beach_noaa_enc_harbour_v1.json",
    "data/public/long_beach_open_meteo_2025_w01_hourly.csv",
    "data/rl/long_beach_ais_port_ops_benchmark_v2.json",
    "data/rl/long_beach_ais_port_ops_experiment_v2.json",
    "tools/build_long_beach_ais_benchmark.py",
    "tools/ship_rl/port_contract.py",
    "tools/ship_rl/port_ops_controllers.py",
    "tools/ship_rl/port_ops_environment.py",
    "tools/ship_rl/port_ops_trainer.py",
    "tools/port_ops_train_baselines.py",
    "tools/run_port_ops_benchmark.py",
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
        "sb3_contrib": sb3_contrib.__version__,
        "torch": torch.__version__,
    }


def _evidence_hashes() -> dict[str, str]:
    return {relative: _sha256(ROOT / relative) for relative in EVIDENCE_FILES}


def _artifact_record(
    algorithm: str,
    run_dir: Path,
    train_result: Mapping[str, Any],
    validation_result: Mapping[str, Any],
    requested_timesteps: int,
) -> dict[str, Any]:
    checkpoint = run_dir / "checkpoint.json"
    checkpoint_payload = json.loads(checkpoint.read_text(encoding="utf-8"))
    model_path: Path | None = None
    if checkpoint_payload.get("model_path"):
        model_path = checkpoint.parent / str(checkpoint_payload["model_path"])
    return {
        "algorithm": algorithm,
        "seed": SEED,
        "training": {
            "split": train_result["dataset_split"],
            "render": train_result["render"],
            "requested_timesteps": (
                requested_timesteps if algorithm not in CONTROL_ALGORITHMS else 0
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
        "validation_trajectory": _relative(
            run_dir / "validation_trajectory.json"
        ),
    }


def _prepare_algorithm(
    algorithm: str,
    timesteps: int,
    max_steps: int,
    validation_count: int,
) -> dict[str, Any]:
    run_dir = ARTIFACT_ROOT / algorithm
    run_dir.mkdir(parents=True, exist_ok=True)
    train_result = train_port_ops(
        TrainRequest(
            algorithm=algorithm,
            config_path=CONFIG,
            output_dir=run_dir,
            progress_path=run_dir / "training_progress.json",
            checkpoint_path=run_dir / "checkpoint.json",
            total_timesteps=timesteps,
            max_steps=max_steps,
            parallel_envs=1,
            seed=SEED,
        )
    )
    validation_result = evaluate_port_ops(
        EvaluateRequest(
            algorithm=algorithm,
            config_path=CONFIG,
            output_dir=run_dir,
            progress_path=run_dir / "validation_progress.json",
            checkpoint_path=run_dir / "checkpoint.json",
            trajectory_path=run_dir / "validation_trajectory.json",
            max_steps=max_steps,
            episodes=validation_count,
            seed=SEED,
            split="validation",
        )
    )
    return _artifact_record(
        algorithm,
        run_dir,
        train_result,
        validation_result,
        timesteps,
    )


def prepare(timesteps: int, max_steps: int) -> int:
    _config, dataset, _dataset_path = load_experiment(CONFIG)
    validation_count = len(dataset["splits"]["validation"])
    by_algorithm: dict[str, dict[str, Any]] = {}
    with ProcessPoolExecutor(max_workers=PARALLEL_ALGORITHMS) as executor:
        futures = {
            executor.submit(
                _prepare_algorithm,
                algorithm,
                timesteps,
                max_steps,
                validation_count,
            ): algorithm
            for algorithm in ALGORITHMS
        }
        for future in as_completed(futures):
            algorithm = futures[future]
            by_algorithm[algorithm] = future.result()
            print(
                f"prepare {algorithm}: train + validation complete",
                flush=True,
            )
    artifacts = [
        by_algorithm[algorithm]
        for algorithm in ALGORITHMS
    ]
    source = dataset["source"]
    payload = {
        "schema_version": "2.0",
        "benchmark_id": "ship_port_ops_long_beach_ais_v2",
        "prepared_at": datetime.now(timezone.utc).replace(
            microsecond=0
        ).isoformat(),
        "test_split_accessed": False,
        "software": _software_versions(),
        "evidence_sha256": _evidence_hashes(),
        "data": {
            "split_sizes": {
                name: len(tasks) for name, tasks in dataset["splits"].items()
            },
            "split_policy": dataset["split_policy"],
            "source_boundary": source,
            "port": dataset["port"],
        },
        "experiment": {
            "seed": SEED,
            "rl_timesteps_per_algorithm": timesteps,
            "max_steps_per_episode": max_steps,
            "observation_size": PORT_OPS_OBSERVATION_SIZE,
            "observation_profile": "port_ops_45",
            "algorithms": list(ALGORITHMS),
            "training_render_mode": None,
            "validation_render_ready": False,
            "test_render_mode": "recorded_test_rollout",
            "evaluation_intent": (
                "simulator factor and ten-baseline execution coverage; "
                "not an algorithm-convergence claim"
            ),
        },
        "artifacts": artifacts,
    }
    _write_json(PREPARED_REPORT, payload)
    print(f"prepared report: {PREPARED_REPORT}")
    return 0


def _verify_prepared(payload: Mapping[str, Any]) -> list[str]:
    errors: list[str] = []
    if payload.get("test_split_accessed") is not False:
        errors.append("prepared report already marks test split as accessed")
    if payload.get("evidence_sha256") != _evidence_hashes():
        errors.append("v2 data/config/core-code hash changed after preparation")
    artifacts = payload.get("artifacts", [])
    if [item.get("algorithm") for item in artifacts] != list(ALGORITHMS):
        errors.append("ten-method inventory is incomplete or reordered")
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
        -float(metrics["port_compliant_completion_rate"]),
        -float(metrics["collision_free_arrival_rate"]),
        float(metrics["collision_episode_rate"]),
        float(metrics["grounding_episode_rate"]),
        float(metrics["colreg_violation_episode_rate"]),
        float(metrics["channel_departure_episode_rate"]),
        float(metrics["speed_violation_episode_rate"]),
        float(metrics["mean_max_cross_track_error_meters"]),
        -float(metrics["mean_path_efficiency"]),
    )


def _finalize_algorithm(
    artifact: Mapping[str, Any],
    test_count: int,
    max_steps: int,
) -> dict[str, Any]:
    algorithm = str(artifact["algorithm"])
    run_dir = ARTIFACT_ROOT / algorithm
    result = evaluate_port_ops(
        EvaluateRequest(
            algorithm=algorithm,
            config_path=CONFIG,
            output_dir=run_dir,
            progress_path=run_dir / "test_progress.json",
            checkpoint_path=ROOT / artifact["checkpoint"],
            trajectory_path=run_dir / "test_trajectory.json",
            max_steps=max_steps,
            episodes=test_count,
            seed=SEED,
            split="test",
        )
    )
    return _test_record(artifact, result, run_dir)


def finalize() -> int:
    prepared = json.loads(PREPARED_REPORT.read_text(encoding="utf-8"))
    errors = _verify_prepared(prepared)
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    _config, dataset, _dataset_path = load_experiment(CONFIG)
    test_count = len(dataset["splits"]["test"])
    max_steps = int(prepared["experiment"]["max_steps_per_episode"])
    by_algorithm: dict[str, dict[str, Any]] = {}
    with ProcessPoolExecutor(max_workers=PARALLEL_ALGORITHMS) as executor:
        futures = {
            executor.submit(
                _finalize_algorithm,
                artifact,
                test_count,
                max_steps,
            ): str(artifact["algorithm"])
            for artifact in prepared["artifacts"]
        }
        for future in as_completed(futures):
            algorithm = futures[future]
            by_algorithm[algorithm] = future.result()
            print(f"finalize {algorithm}: fixed test complete", flush=True)
    test_results = [
        by_algorithm[algorithm]
        for algorithm in ALGORITHMS
    ]
    ordered = sorted(test_results, key=_ranking_key)
    best = ordered[0]
    completed = sum(item["episodes"] for item in test_results)
    metrics = best["metrics"]
    benchmark_complete = bool(
        len(test_results) == len(ALGORITHMS)
        and completed == len(ALGORITHMS) * test_count
        and all(item["dataset_split"] == "test" for item in test_results)
        and all(item["render_ready"] for item in test_results)
    )
    safety_admission_passed = bool(
        metrics["collision_free_arrival_rate"] >= 0.80
        and metrics["collision_episode_rate"] <= 0.10
        and metrics["grounding_episode_rate"] <= 0.05
        and metrics["colreg_violation_episode_rate"] <= 0.10
    )
    report = {
        **prepared,
        "generated_at": datetime.now(timezone.utc).replace(
            microsecond=0
        ).isoformat(),
        "test_split_accessed": True,
        "test_access_policy": (
            "fixed test split was evaluated only after training and validation "
            "artifacts were frozen in port_ops_benchmark_v2_prepared.json"
        ),
        "test_episode_count": completed,
        "test_results": test_results,
        "ranking_policy": (
            "port compliance and collision-free arrival desc; collision, "
            "grounding, COLREG, channel, speed and XTE risk asc; efficiency desc"
        ),
        "best_method": best,
        "benchmark_complete": benchmark_complete,
        "safety_admission_passed": safety_admission_passed,
        "deployment_decision": (
            "offline_research_candidate"
            if safety_admission_passed
            else "fail_closed_research_only"
        ),
    }
    _write_json(FINAL_REPORT, report)
    _write_text(FINAL_MARKDOWN, _render_markdown(report))
    print(f"final report: {FINAL_REPORT}")
    print(f"benchmark completeness: {'PASS' if benchmark_complete else 'FAIL'}")
    print(
        "safety admission: "
        f"{'PASS' if safety_admission_passed else 'FAIL-CLOSED'}"
    )
    return 0 if benchmark_complete else 1


def _render_markdown(report: Mapping[str, Any]) -> str:
    rows = []
    for result in report["test_results"]:
        value = result["metrics"]
        rows.append(
            "| {algorithm} | {arrival:.1%} | {compliant:.1%} | "
            "{collision:.1%} | {grounding:.1%} | {colreg:.1%} | "
            "{channel:.1%} | {speed:.1%} | {xte:.1f} |".format(
                algorithm=result["algorithm"].upper().replace("_", "-"),
                arrival=value["collision_free_arrival_rate"],
                compliant=value["port_compliant_completion_rate"],
                collision=value["collision_episode_rate"],
                grounding=value["grounding_episode_rate"],
                colreg=value["colreg_violation_episode_rate"],
                channel=value["channel_departure_episode_rate"],
                speed=value["speed_violation_episode_rate"],
                xte=value["mean_max_cross_track_error_meters"],
            )
        )
    split_sizes = report["data"]["split_sizes"]
    return f"""# 长滩港真实 AIS + ENC 十方法覆盖性测试 v2

生成时间：{report["generated_at"]}

## 证据范围

- 数据：NOAA AccessAIS 2025-01-01 至 2025-01-07 历史 AIS 全国日档，经长滩港边界筛选；NOAA ENC Direct 港区水深、航道、障碍、限制区与 TSS 派生 GIS；Open-Meteo 同期逐小时风、能见度、浪、流和模式海平面。
- 时间隔离：{split_sizes["train"]} 个训练任务、{split_sizes["validation"]} 个验证任务、{split_sizes["test"]} 个最终测试任务。
- 方法：PPO、SAC、TD3、DQN、A2C、DDPG、TRPO、LOS-PID、LQR、MPC；七种 RL 各训练 {report["experiment"]["rl_timesteps_per_algorithm"]:,} 步，三种控制基线无需训练。
- 环境：45 维观测，连续或九离散油门/舵角动作，真实船型尺度、动态交通、吃水/水深/UKC、航道、经验速度上限、COLREG 遭遇上下文。
- 目的：验证模拟器因素覆盖、十基线可执行性和证据链，不以任一算法收敛或调参追分为验收。
- 完整性门禁：{"PASS" if report["benchmark_complete"] else "FAIL"}；安全准入：{"PASS" if report["safety_admission_passed"] else "FAIL-CLOSED"}。

## 最终独立测试

| 方法 | 无碰撞到达 | 港口合规完成 | 碰撞 | 搁浅 | COLREG违例 | 偏离航道 | 超速 | 平均最大XTE(m) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
{chr(10).join(rows)}

## 现实边界

历史 AIS 不是实时交通，ENC Direct 是 NOAA ENC 的 GIS 派生服务，公开海况模式也不用于近岸导航。本基准证明数据契约、训练/验证/测试隔离、算法实现和可复核离线结果，不构成实船海试、COLREG 认证或自动驾驶授权。实船接口、官方航海产品、当地限速/航路规则、传感器时效和人工控制权限未全部验证时，系统保持 fail-closed。
"""


def verify(*, deep: bool) -> int:
    report = json.loads(FINAL_REPORT.read_text(encoding="utf-8"))
    errors: list[str] = []
    if report.get("evidence_sha256") != _evidence_hashes():
        errors.append("v2 data/config/core-code differs from final report")
    for result in report.get("test_results", []):
        trajectory = ROOT / result["trajectory"]
        if not trajectory.is_file() or _sha256(trajectory) != result.get(
            "trajectory_sha256"
        ):
            errors.append(f"test trajectory changed: {result.get('algorithm')}")
    errors.extend(_verify_prepared({**report, "test_split_accessed": False}))
    if deep and not errors:
        max_steps = int(report["experiment"]["max_steps_per_episode"])
        test_count = int(report["data"]["split_sizes"]["test"])
        for artifact, expected in zip(
            report["artifacts"],
            report["test_results"],
        ):
            algorithm = str(artifact["algorithm"])
            print(f"deep verify {algorithm}", flush=True)
            run_dir = ARTIFACT_ROOT / algorithm
            current = evaluate_port_ops(
                EvaluateRequest(
                    algorithm=algorithm,
                    config_path=CONFIG,
                    output_dir=run_dir,
                    progress_path=run_dir / "verify_progress.json",
                    checkpoint_path=ROOT / artifact["checkpoint"],
                    trajectory_path=run_dir / "verify_trajectory.json",
                    max_steps=max_steps,
                    episodes=test_count,
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
    print(f"port operations benchmark verify: PASS ({'deep' if deep else 'hash'})")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument(
        "--timesteps", type=int, default=DEFAULT_TIMESTEPS
    )
    prepare_parser.add_argument(
        "--max-steps", type=int, default=DEFAULT_MAX_STEPS
    )
    subparsers.add_parser("finalize")
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--deep", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    if arguments.command == "prepare":
        return prepare(arguments.timesteps, arguments.max_steps)
    if arguments.command == "finalize":
        return finalize()
    return verify(deep=arguments.deep)


if __name__ == "__main__":
    raise SystemExit(main())
