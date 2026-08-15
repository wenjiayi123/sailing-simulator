#!/usr/bin/env python3
"""Headless physical-feasibility gate for the dynamic-traffic cargo circuit."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any, Dict, List

from cargo_rl.demonstration import MANUAL_BYPASSES, manual_helm, manual_targets
from cargo_rl.dynamic_environment import CargoDynamicEnv
from cargo_rl.environment import cargo_experiment_fingerprint
from ship_rl.environment import dataset_fingerprint, load_experiment
from ship_rl.trainer import write_json_atomic


def run_episode(
    config: Dict[str, Any],
    dataset: Dict[str, Any],
    split: str,
    task_index: int,
    seed: int,
    max_steps: int,
) -> tuple[Dict[str, Any], CargoDynamicEnv]:
    env = CargoDynamicEnv(
        config,
        dataset,
        split=split,
        task_index=task_index,
        max_steps=max_steps,
        seed=seed,
        render_mode=None,
        physical_action_input=True,
    )
    env.reset(options={"task_index": task_index})
    targets = manual_targets(env.route)
    target_index = 0
    previous_rudder = 0.0
    max_yaw_rate = 0.0
    max_speed = 0.0
    terminated = truncated = False
    info: Dict[str, Any] = {}
    while not (terminated or truncated):
        target, target_kind = targets[target_index]
        distance = math.hypot(target[0] - env.state[0], target[1] - env.state[1])
        arrival = 10.0 if target_kind == "manual_bypass" else 12.0
        if distance < arrival and target_index < len(targets) - 1:
            target_index += 1
            target, _target_kind = targets[target_index]
        action, previous_rudder, _helm = manual_helm(env, target, previous_rudder)
        _observation, _reward, terminated, truncated, info = env.step(action)
        speed_ratio = min(abs(env.state[3]) / max(env.performance.max_forward_speed, 0.1), 1.0)
        authority = env.performance.low_speed_turn_factor + (1.0 - env.performance.low_speed_turn_factor) * speed_ratio
        max_yaw_rate = max(max_yaw_rate, abs(env.state[5]) * env.performance.max_turn_rate_degrees * authority)
        max_speed = max(max_speed, abs(env.state[3]))
    effective_boundary = (
        float(env.task.get("boundary_half_extent", 240.0))
        - float(env.environment_config["boundary_margin_m"])
        - float(env.environment_config["vessel_radius_m"])
    )
    minimum_boundary_clearance = min(
        effective_boundary - max(abs(float(sample["x"])), abs(float(sample["z"])))
        for sample in env.trajectory
    )
    result = {
        "task_id": str(info.get("task_id", task_index)),
        "dataset_split": split,
        "seed": seed,
        "success": bool(info.get("is_success", False)),
        "cargo_retrieved": bool(info.get("cargo_retrieved", False)),
        "checkpoints_passed": int(info.get("checkpoints_passed", 0)),
        "total_checkpoints": int(info.get("total_checkpoints", 0)),
        "collisions": int(info.get("collisions", 0)),
        "dynamic_obstacle_count": int(info.get("dynamic_obstacle_count", 0)),
        "minimum_safety_envelope_clearance_meters": float(info.get("minimum_clearance_meters", 0.0)),
        "minimum_dynamic_clearance_meters": float(info.get("minimum_dynamic_clearance_meters", 0.0)),
        "minimum_boundary_clearance_meters": float(minimum_boundary_clearance),
        "minimum_predicted_dcpa_meters": float(info.get("minimum_dcpa_meters", 0.0)),
        "maximum_yaw_rate_degrees_per_second": max_yaw_rate,
        "maximum_speed_mps": max_speed,
        "steps": env.steps,
        "elapsed_simulation_seconds": env.steps * env.delta,
        "headless": True,
        "render": False,
    }
    return result, env


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run dynamic-traffic physical feasibility before RL training.")
    parser.add_argument("--config", default="data/rl/cargo_circuit_dynamic_experiment_v2.json")
    parser.add_argument("--report", default="reports/cargo_circuit_dynamic_manual_feasibility_v2.json")
    parser.add_argument("--max-steps", type=int, default=4000)
    parser.add_argument("--seed", type=int, default=260815)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config_path = Path(args.config).expanduser().resolve()
    config, dataset, dataset_path = load_experiment(config_path)
    results: List[Dict[str, Any]] = []
    for split in ("train", "validation", "test"):
        for task_index in range(len(dataset["splits"][split])):
            result, _env = run_episode(
                config,
                dataset,
                split,
                task_index,
                args.seed,
                args.max_steps,
            )
            results.append(result)
    passed = all(
        row["success"]
        and row["collisions"] == 0
        and row["checkpoints_passed"] == row["total_checkpoints"]
        and row["dynamic_obstacle_count"] >= 6
        and row["minimum_safety_envelope_clearance_meters"] > 0.0
        and row["minimum_dynamic_clearance_meters"] > 0.0
        and row["minimum_boundary_clearance_meters"] > 0.0
        for row in results
    )
    report = {
        "format": "cargo_circuit_dynamic_manual_feasibility_v2",
        "module": "cargo_circuit_dynamic_rl",
        "purpose": "pre-training physical reachability with moving traffic",
        "controller": {
            "type": "human_authored_bypass_points_and_helm_law",
            "learned": False,
            "rl_evidence": False,
            "dynamic_policy": False,
            "note": "Feasibility gate only; never used as the released dynamic policy.",
        },
        "traffic_phase_contract": {
            "fixed_seed": args.seed,
            "purpose": "prove at least one reproducible feasible trajectory per task; not a robustness claim",
            "training_still_uses_randomized_traffic": True
        },
        "dataset_path": str(dataset_path),
        "dataset_sha256": dataset_fingerprint(dataset),
        "experiment_sha256": cargo_experiment_fingerprint(config),
        "manual_bypasses": [[{"x": x, "z": z} for x, z in group] for group in MANUAL_BYPASSES],
        "episodes": results,
        "aggregate": {
            "episodes": len(results),
            "success_rate": sum(row["success"] for row in results) / len(results),
            "total_collisions": sum(row["collisions"] for row in results),
            "minimum_safety_envelope_clearance_meters": min(row["minimum_safety_envelope_clearance_meters"] for row in results),
            "minimum_dynamic_clearance_meters": min(row["minimum_dynamic_clearance_meters"] for row in results),
            "minimum_boundary_clearance_meters": min(row["minimum_boundary_clearance_meters"] for row in results),
            "maximum_yaw_rate_degrees_per_second": max(row["maximum_yaw_rate_degrees_per_second"] for row in results),
        },
        "acceptance_gate": {
            "passed": passed,
            "requires_all_splits": True,
            "requires_all_checkpoints": True,
            "requires_zero_collisions": True,
            "requires_at_least_six_dynamic_obstacles": True,
            "requires_positive_static_dynamic_and_boundary_clearance": True,
        },
    }
    report_path = Path(args.report).expanduser().resolve()
    write_json_atomic(report_path, report)
    print(json.dumps({"ok": passed, "report": str(report_path), "aggregate": report["aggregate"]}, ensure_ascii=False))
    return 0 if passed else 2


if __name__ == "__main__":
    raise SystemExit(main())
