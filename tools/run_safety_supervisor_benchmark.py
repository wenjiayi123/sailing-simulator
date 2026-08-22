#!/usr/bin/env python3
"""Freeze, finalize, and verify the additive V3 safety-supervisor benchmark."""

from __future__ import annotations

import argparse
from concurrent.futures import ProcessPoolExecutor, as_completed
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import sys
import time
from typing import Any, Mapping, Sequence

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.ship_rl.environment import (  # noqa: E402
    dataset_fingerprint,
    experiment_fingerprint,
    load_experiment,
)
from tools.ship_rl.port_ops_environment import PortOpsNavigationEnv  # noqa: E402
from tools.ship_rl.port_ops_trainer import (  # noqa: E402
    ALGORITHMS,
    CONTROL_ALGORITHMS,
    _aggregate,
    _contract,
    _load_policy,
    _policy_action,
    _route_completion_ratio,
)
from tools.ship_rl.safety_supervisor import (  # noqa: E402
    ModelPredictiveSafetySupervisor,
    SafetySupervisorConfig,
)
from tools.ship_rl.trainer import _route_reference_length  # noqa: E402


CONFIG = ROOT / "data/rl/long_beach_ais_port_ops_experiment_v2.json"
SUPERVISOR_CONFIG = ROOT / "data/rl/port_ops_safety_supervisor_v3.json"
V2_PREPARED = ROOT / "reports/port_ops_benchmark_v2_prepared.json"
V2_FINAL = ROOT / "reports/port_ops_benchmark_v2.json"
PREPARED = ROOT / "reports/safety_supervisor_benchmark_v3_prepared.json"
FINAL = ROOT / "reports/safety_supervisor_benchmark_v3.json"
MARKDOWN = ROOT / "reports/safety_supervisor_benchmark_v3.md"
ARTIFACT_ROOT = ROOT / "reports/artifacts/safety_supervisor_v3"
SEED = 250107
DEFAULT_MAX_STEPS = 1_600
DEFAULT_WORKERS = 4
EVIDENCE_FILES = (
    "data/rl/long_beach_ais_port_ops_benchmark_v2.json",
    "data/rl/long_beach_ais_port_ops_experiment_v2.json",
    "data/rl/port_ops_safety_supervisor_v3.json",
    "reports/port_ops_benchmark_v2_prepared.json",
    "reports/port_ops_benchmark_v2.json",
    "tools/ship_rl/safety_supervisor.py",
    "tools/run_safety_supervisor_benchmark.py",
)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _load(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _write_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def _write_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(value, encoding="utf-8")
    temporary.replace(path)


def _relative(path: Path) -> str:
    return os.fspath(path.resolve().relative_to(ROOT))


def _evidence_hashes() -> dict[str, str]:
    return {value: _sha256(ROOT / value) for value in EVIDENCE_FILES}


def _profile() -> SafetySupervisorConfig:
    value = _load(SUPERVISOR_CONFIG)
    return SafetySupervisorConfig.from_mapping(value)


def _percentile(values: Sequence[float], quantile: float) -> float:
    return float(np.quantile(np.asarray(values, dtype=np.float64), quantile)) if values else 0.0


def _episode_record(
    env: PortOpsNavigationEnv,
    info: Mapping[str, Any],
    supervisor: ModelPredictiveSafetySupervisor,
    minimum_ukc: float,
) -> dict[str, Any]:
    reference = _route_reference_length(env.task)
    path_length = float(info.get("path_length_meters", 0.0))
    completion = _route_completion_ratio(env)
    return {
        "task_id": str(env.task.get("id", "unknown")),
        "success": bool(info.get("is_success", False)),
        "port_compliant_success": bool(info.get("port_compliant_success", False)),
        "goal_reached": bool(info.get("goal_reached", False)),
        "collisions": int(info.get("collisions", 0)),
        "terrain_collisions": int(info.get("terrain_collisions", 0)),
        "groundings": int(info.get("groundings", 0)),
        "near_misses": int(info.get("near_misses", 0)),
        "speed_limit_violations": int(info.get("speed_limit_violations", 0)),
        "channel_departures": int(info.get("channel_departures", 0)),
        "colreg_give_way_violations": int(info.get("colreg_give_way_violations", 0)),
        "dynamic_obstacle_count": int(info.get("dynamic_obstacle_count", 0)),
        "minimum_clearance_meters": float(info.get("minimum_clearance_meters", 0.0)),
        "minimum_dcpa_meters": float(info.get("minimum_dcpa_meters", 0.0)),
        "minimum_under_keel_clearance_meters": (
            minimum_ukc if math.isfinite(minimum_ukc) else None
        ),
        "max_cross_track_error_meters": float(info.get("max_cross_track_error_meters", 0.0)),
        "path_length_meters": path_length,
        "reference_route_length_meters": reference,
        "route_completion_ratio": completion,
        "path_efficiency": min(reference * completion / max(path_length, 1e-6), 1.0),
        "elapsed_seconds": env.steps * env.delta,
        "reward": env.total_reward,
        "steps": env.steps,
        "last_collision": dict(info.get("last_collision", {})),
        "safety_supervisor": supervisor.summary(),
    }


def _evaluate_algorithm(
    artifact: Mapping[str, Any],
    split: str,
    max_steps: int,
) -> dict[str, Any]:
    algorithm = str(artifact["algorithm"])
    checkpoint_path = ROOT / str(artifact["checkpoint"])
    checkpoint = _load(checkpoint_path)
    checkpoint["_checkpoint_path"] = os.fspath(checkpoint_path)
    config, dataset, dataset_path = load_experiment(CONFIG)
    contract = _contract(dataset)
    if checkpoint.get("dataset_sha256") != dataset_fingerprint(dataset):
        raise ValueError(f"{algorithm}: dataset fingerprint changed")
    if checkpoint.get("experiment_sha256") != experiment_fingerprint(config):
        raise ValueError(f"{algorithm}: experiment fingerprint changed")
    policy = _load_policy(checkpoint)
    profile = _profile()
    discrete = algorithm == "dqn"
    results: list[dict[str, Any]] = []
    decision_ms: list[float] = []
    replan_ms: list[float] = []
    first_env: PortOpsNavigationEnv | None = None
    first_result: dict[str, Any] = {}
    started = time.perf_counter()
    for index, _task in enumerate(dataset["splits"][split]):
        env = PortOpsNavigationEnv(
            config,
            dataset,
            split=split,
            discrete_actions=discrete,
            max_steps=max_steps,
            seed=SEED + index,
            task_index=index,
            render_mode=None,
        )
        observation, _info = env.reset(options={"task_index": index})
        if algorithm in CONTROL_ALGORITHMS:
            policy.reset()
        supervisor = ModelPredictiveSafetySupervisor(profile)
        minimum_ukc = float("inf")
        info: dict[str, Any] = {}
        while True:
            proposed = _policy_action(policy, algorithm, env, observation)
            decision_started = time.perf_counter()
            decision = supervisor.project(env, proposed)
            elapsed_ms = (time.perf_counter() - decision_started) * 1_000.0
            decision_ms.append(elapsed_ms)
            if decision.candidates_evaluated:
                replan_ms.append(elapsed_ms)
            observation, _reward, terminated, truncated, info = env.step(
                supervisor.environment_action(env, decision)
            )
            ukc = info.get("under_keel_clearance_meters")
            if ukc is not None:
                minimum_ukc = min(minimum_ukc, float(ukc))
            if terminated or truncated:
                break
        record = _episode_record(env, info, supervisor, minimum_ukc)
        results.append(record)
        if first_env is None:
            first_env = env
            first_result = record
    assert first_env is not None
    aggregate = _aggregate(results)
    steps = sum(int(item["steps"]) for item in results)
    intervention_steps = sum(
        int(item["safety_supervisor"]["intervention_steps"]) for item in results
    )
    intervention_events = sum(
        int(item["safety_supervisor"]["interventions"]) for item in results
    )
    fail_closed_events = sum(
        int(item["safety_supervisor"]["fail_closed_events"]) for item in results
    )
    candidate_evaluations = sum(
        int(item["safety_supervisor"]["candidate_evaluations"]) for item in results
    )
    output_dir = ARTIFACT_ROOT / algorithm
    trajectory_path = output_dir / f"{split}_trajectory.json"
    task = first_env.task
    start = task.get("start", {})
    route_points = [
        {"x": float(point.get("x", 0.0)), "z": float(point.get("z", 0.0))}
        for point in task.get("route", [])
        if isinstance(point, Mapping)
    ]
    trajectory = {
        "format": f"ship_port_policy_{split}_safety_v3",
        "source": "deterministic_base_policy_with_model_predictive_safety_supervisor",
        "algorithm": algorithm,
        "strategy_id": f"{algorithm}+safety_v3",
        "checkpoint": _relative(checkpoint_path),
        "base_checkpoint": _relative(checkpoint_path),
        "base_checkpoint_sha256": _sha256(checkpoint_path),
        "dataset_path": _relative(dataset_path) if dataset_path else "runtime_snapshot",
        "dataset_sha256": dataset_fingerprint(dataset),
        "experiment_sha256": experiment_fingerprint(config),
        "dataset_split": split,
        "task_id": first_result["task_id"],
        "playback_mode": "recorded_safety_supervised_test_rollout",
        "start": {
            "x": float(start.get("x", first_env.trajectory[0]["x"])),
            "z": float(start.get("z", first_env.trajectory[0]["z"])),
            "heading_degrees": float(
                start.get(
                    "heading_degrees",
                    first_env.trajectory[0]["heading_degrees"],
                )
            ),
        },
        "goal": route_points[-1],
        "route_points": route_points,
        "evaluation_obstacles": first_env.obstacle_export_records(),
        "safety_profile": profile.to_dict(),
        "port_contract": {
            "research_training_ready": contract["research_training_ready"],
            "live_control_ready": contract["live_control_ready"],
            "deployment_authority": False,
        },
        "samples": first_env.trajectory,
        "evaluation_metrics": first_result,
        "aggregate_metrics": aggregate,
    }
    _write_json(trajectory_path, trajectory)
    return {
        "algorithm": algorithm,
        "strategy_id": f"{algorithm}+safety_v3",
        "base_checkpoint": _relative(checkpoint_path),
        "base_checkpoint_sha256": _sha256(checkpoint_path),
        "dataset_split": split,
        "episodes": len(results),
        "metrics": aggregate,
        "supervisor_metrics": {
            "steps": steps,
            "intervention_events": intervention_events,
            "intervention_steps": intervention_steps,
            "intervention_step_rate": intervention_steps / max(steps, 1),
            "fail_closed_events": fail_closed_events,
            "fail_closed_episode_rate": float(
                np.mean(
                    [
                        int(item["safety_supervisor"]["fail_closed_events"]) > 0
                        for item in results
                    ]
                )
            ),
            "candidate_evaluations": candidate_evaluations,
            "decision_mean_ms": float(np.mean(decision_ms)) if decision_ms else 0.0,
            "decision_p95_ms": _percentile(decision_ms, 0.95),
            "replan_mean_ms": float(np.mean(replan_ms)) if replan_ms else 0.0,
            "replan_p95_ms": _percentile(replan_ms, 0.95),
            "wall_seconds": time.perf_counter() - started,
        },
        "trajectory": _relative(trajectory_path),
        "trajectory_sha256": _sha256(trajectory_path),
    }


def _evaluate_all(split: str, max_steps: int, workers: int) -> list[dict[str, Any]]:
    prepared_v2 = _load(V2_PREPARED)
    artifacts = prepared_v2["artifacts"]
    by_algorithm: dict[str, dict[str, Any]] = {}
    with ProcessPoolExecutor(max_workers=max(1, workers)) as executor:
        futures = {
            executor.submit(_evaluate_algorithm, artifact, split, max_steps): str(
                artifact["algorithm"]
            )
            for artifact in artifacts
        }
        for future in as_completed(futures):
            algorithm = futures[future]
            by_algorithm[algorithm] = future.result()
            print(f"{split} {algorithm}: safety rollout complete", flush=True)
    return [by_algorithm[algorithm] for algorithm in ALGORITHMS]


def _verify_base_artifacts(artifacts: Sequence[Mapping[str, Any]]) -> list[str]:
    errors: list[str] = []
    if [item.get("algorithm") for item in artifacts] != list(ALGORITHMS):
        errors.append("base ten-method inventory changed or reordered")
    for item in artifacts:
        checkpoint = ROOT / str(item.get("checkpoint", ""))
        if not checkpoint.is_file() or _sha256(checkpoint) != item.get("checkpoint_sha256"):
            errors.append(f"base checkpoint changed: {item.get('algorithm')}")
        model_value = item.get("model")
        if model_value:
            model = ROOT / str(model_value)
            if not model.is_file() or _sha256(model) != item.get("model_sha256"):
                errors.append(f"base trained model changed: {item.get('algorithm')}")
    return errors


def prepare(max_steps: int, workers: int) -> int:
    v2_prepared = _load(V2_PREPARED)
    errors = _verify_base_artifacts(v2_prepared["artifacts"])
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    config, dataset, _dataset_path = load_experiment(CONFIG)
    validation = _evaluate_all("validation", max_steps, workers)
    payload = {
        "schema_version": "ship_port_safety_supervisor_benchmark_v3",
        "benchmark_id": "long_beach_ais_port_ops_safety_supervisor_v3",
        "prepared_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "test_split_accessed": False,
        "selection_policy": (
            "the declared supervisor profile and all ten preserved V2 policies were "
            "frozen after validation and before any V3 test evaluation"
        ),
        "software": {
            "python": platform.python_version(),
            "platform": platform.platform(),
            "numpy": np.__version__,
        },
        "evidence_sha256": _evidence_hashes(),
        "data": {
            "split_sizes": {key: len(value) for key, value in dataset["splits"].items()},
            "dataset_sha256": dataset_fingerprint(dataset),
            "experiment_sha256": experiment_fingerprint(config),
        },
        "experiment": {
            "seed": SEED,
            "max_steps_per_episode": max_steps,
            "algorithms": list(ALGORITHMS),
            "strategy_inventory": [f"{value}+safety_v3" for value in ALGORITHMS],
            "base_strategy_count": len(ALGORITHMS),
            "additive_strategy_count": len(ALGORITHMS),
            "safety_profile": _profile().to_dict(),
            "live_control_authorized": False,
        },
        "base_artifacts": v2_prepared["artifacts"],
        "validation_results": validation,
    }
    _write_json(PREPARED, payload)
    print(f"prepared report: {PREPARED}")
    return 0


def _raw_by_algorithm() -> dict[str, Mapping[str, Any]]:
    return {str(item["algorithm"]): item for item in _load(V2_FINAL)["test_results"]}


def _portfolio_impact(test_results: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    raw = _raw_by_algorithm()
    pairs = []
    for result in test_results:
        algorithm = str(result["algorithm"])
        raw_metrics = raw[algorithm]["metrics"]
        shielded = result["metrics"]
        pairs.append(
            {
                "algorithm": algorithm,
                "raw_collision_episode_rate": raw_metrics["collision_episode_rate"],
                "shielded_collision_episode_rate": shielded["collision_episode_rate"],
                "raw_grounding_episode_rate": raw_metrics["grounding_episode_rate"],
                "shielded_grounding_episode_rate": shielded["grounding_episode_rate"],
                "raw_collision_free_arrival_rate": raw_metrics["collision_free_arrival_rate"],
                "shielded_collision_free_arrival_rate": shielded["collision_free_arrival_rate"],
            }
        )
    raw_collision = float(np.mean([item["raw_collision_episode_rate"] for item in pairs]))
    shield_collision = float(np.mean([item["shielded_collision_episode_rate"] for item in pairs]))
    raw_grounding = float(np.mean([item["raw_grounding_episode_rate"] for item in pairs]))
    shield_grounding = float(np.mean([item["shielded_grounding_episode_rate"] for item in pairs]))
    return {
        "by_algorithm": pairs,
        "macro_raw_collision_episode_rate": raw_collision,
        "macro_shielded_collision_episode_rate": shield_collision,
        "macro_raw_grounding_episode_rate": raw_grounding,
        "macro_shielded_grounding_episode_rate": shield_grounding,
        "collision_rate_not_worse": shield_collision <= raw_collision,
        "grounding_rate_not_worse": shield_grounding <= raw_grounding,
    }


def finalize(workers: int) -> int:
    prepared = _load(PREPARED)
    errors = _verify_prepared(prepared)
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    max_steps = int(prepared["experiment"]["max_steps_per_episode"])
    test_results = _evaluate_all("test", max_steps, workers)
    expected = int(prepared["data"]["split_sizes"]["test"])
    complete = bool(
        len(test_results) == len(ALGORITHMS)
        and all(item["dataset_split"] == "test" for item in test_results)
        and sum(int(item["episodes"]) for item in test_results)
        == expected * len(ALGORITHMS)
    )
    impact = _portfolio_impact(test_results)
    admitted = []
    for item in test_results:
        metrics = item["metrics"]
        if (
            metrics["collision_free_arrival_rate"] >= 0.80
            and metrics["collision_episode_rate"] <= 0.10
            and metrics["grounding_episode_rate"] <= 0.05
            and metrics["colreg_violation_episode_rate"] <= 0.10
        ):
            admitted.append(str(item["strategy_id"]))
    latency_passed = all(
        float(item["supervisor_metrics"]["decision_p95_ms"]) <= 250.0
        for item in test_results
    )
    effectiveness = bool(
        complete
        and impact["collision_rate_not_worse"]
        and impact["grounding_rate_not_worse"]
        and latency_passed
    )
    report = {
        **prepared,
        "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "test_split_accessed": True,
        "test_access_policy": (
            "V3 test was accessed only after supervisor configuration, source hashes, "
            "base policy hashes, and validation evidence were frozen"
        ),
        "test_results": test_results,
        "benchmark_complete": complete,
        "portfolio_impact": impact,
        "latency_gate": {"p95_decision_budget_ms": 250.0, "passed": latency_passed},
        "safety_effectiveness_gate": effectiveness,
        "admitted_offline_strategies": admitted,
        "live_control_authorized": False,
        "deployment_decision": "offline_research_only_fail_closed_for_live_control",
    }
    _write_json(FINAL, report)
    _write_text(MARKDOWN, _render_markdown(report))
    print(f"final report: {FINAL}")
    print(f"V3 safety effectiveness: {'PASS' if effectiveness else 'FAIL-CLOSED'}")
    return 0 if complete else 1


def _verify_prepared(value: Mapping[str, Any]) -> list[str]:
    errors: list[str] = []
    if value.get("test_split_accessed") is not False:
        errors.append("prepared V3 report must precede test access")
    if value.get("evidence_sha256") != _evidence_hashes():
        errors.append("V3 evidence source hash changed after preparation")
    errors.extend(_verify_base_artifacts(value.get("base_artifacts", [])))
    validation = value.get("validation_results", [])
    if [item.get("algorithm") for item in validation] != list(ALGORITHMS):
        errors.append("V3 validation strategy inventory is incomplete")
    for item in validation:
        trajectory = ROOT / str(item.get("trajectory", ""))
        if not trajectory.is_file() or _sha256(trajectory) != item.get("trajectory_sha256"):
            errors.append(f"V3 validation trajectory changed: {item.get('algorithm')}")
    return errors


def verify(deep: bool, workers: int) -> int:
    report = _load(FINAL)
    prepared_view = {**report, "test_split_accessed": False}
    errors = _verify_prepared(prepared_view)
    tests = report.get("test_results", [])
    if [item.get("algorithm") for item in tests] != list(ALGORITHMS):
        errors.append("V3 test strategy inventory is incomplete")
    for item in tests:
        trajectory = ROOT / str(item.get("trajectory", ""))
        if not trajectory.is_file() or _sha256(trajectory) != item.get("trajectory_sha256"):
            errors.append(f"V3 test trajectory changed: {item.get('algorithm')}")
    if deep and not errors:
        current = _evaluate_all(
            "test",
            int(report["experiment"]["max_steps_per_episode"]),
            workers,
        )
        for actual, expected in zip(current, tests):
            if actual["metrics"] != expected["metrics"]:
                errors.append(f"V3 deep metrics changed: {expected.get('algorithm')}")
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    print(f"safety supervisor benchmark verify: PASS ({'deep' if deep else 'hash'})")
    return 0


def _render_markdown(report: Mapping[str, Any]) -> str:
    raw = _raw_by_algorithm()
    rows = []
    for item in report["test_results"]:
        algorithm = str(item["algorithm"])
        before = raw[algorithm]["metrics"]
        after = item["metrics"]
        supervisor = item["supervisor_metrics"]
        rows.append(
            "| {name} | {raw_c:.1%} | {safe_c:.1%} | {arrival:.1%} | {intervention:.1%} | {latency:.1f} |".format(
                name=algorithm.upper().replace("_", "-"),
                raw_c=before["collision_episode_rate"],
                safe_c=after["collision_episode_rate"],
                arrival=after["collision_free_arrival_rate"],
                intervention=supervisor["intervention_step_rate"],
                latency=supervisor["decision_p95_ms"],
            )
        )
    impact = report["portfolio_impact"]
    return f"""# 长滩港十策略运行时安全监督基准 V3

生成时间：{report['generated_at']}

本报告是在 V2 十策略、模型、检查点和原始失败结果不变的前提下，外挂同一套模型预测安全监督器。验证集先冻结监督配置，随后一次性评估独立 test；V2 原始结果没有被重写。

| 基础策略 | V2 原始碰撞 | V3 监督后碰撞 | V3 无碰撞到达 | 干预步占比 | 决策 P95(ms) |
|---|---:|---:|---:|---:|---:|
{chr(10).join(rows)}

- 十策略完整性：{'PASS' if report['benchmark_complete'] else 'FAIL'}。
- 宏平均碰撞回合率：{impact['macro_raw_collision_episode_rate']:.1%} → {impact['macro_shielded_collision_episode_rate']:.1%}。
- 运行时安全有效性：{'PASS' if report['safety_effectiveness_gate'] else 'FAIL-CLOSED'}。
- 达到离线准入阈值的新增组合策略：{', '.join(report['admitted_offline_strategies']) or '无'}。

## 边界

该监督层是离线模拟中的软件安全投影，不是 COLREG 认证、船级社认可、型式认可或实船控制授权。历史 AIS 交通下的动作是反事实模拟；没有实时 VTS/TOS、官方在航 ENC、传感器时效、硬件联锁、HIL、海试和主管机关批准，因此 live control 始终 fail-closed。
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("--max-steps", type=int, default=DEFAULT_MAX_STEPS)
    prepare_parser.add_argument("--workers", type=int, default=DEFAULT_WORKERS)
    finalize_parser = subparsers.add_parser("finalize")
    finalize_parser.add_argument("--workers", type=int, default=DEFAULT_WORKERS)
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--deep", action="store_true")
    verify_parser.add_argument("--workers", type=int, default=DEFAULT_WORKERS)
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    if arguments.command == "prepare":
        return prepare(arguments.max_steps, arguments.workers)
    if arguments.command == "finalize":
        return finalize(arguments.workers)
    return verify(arguments.deep, arguments.workers)


if __name__ == "__main__":
    raise SystemExit(main())
