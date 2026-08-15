#!/usr/bin/env python3
"""Human-authored helm feasibility run for the static cargo circuit.

This is deliberately not an RL policy.  It proves that the ordered-checkpoint
mission is physically reachable under the exact same dynamics and collision
envelope before compute is spent on learning.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any, Dict, List, Sequence, Tuple

from cargo_rl.demonstration import MANUAL_BYPASSES, manual_helm, manual_targets
from cargo_rl.environment import CargoCircuitEnv, cargo_experiment_fingerprint
from ship_rl.environment import dataset_fingerprint, load_experiment
from ship_rl.trainer import write_json_atomic


def run_episode(
    config: Dict[str, Any],
    dataset: Dict[str, Any],
    split: str,
    task_index: int,
    seed: int,
    max_steps: int,
) -> Tuple[Dict[str, Any], CargoCircuitEnv]:
    env = CargoCircuitEnv(
        config,
        dataset,
        split=split,
        discrete_actions=False,
        max_steps=max_steps,
        seed=seed,
        task_index=task_index,
        render_mode=None,
        physical_action_input=True,
    )
    env.reset(options={"task_index": task_index})
    targets = manual_targets(env.route)
    target_index = 0
    previous_rudder = 0.0
    max_command_rudder = 0.0
    max_actual_rudder = 0.0
    max_yaw_rate = 0.0
    max_speed = 0.0
    braking_steps = 0
    terminated = truncated = False
    info: Dict[str, Any] = {}
    while not (terminated or truncated):
        target, target_kind = targets[target_index]
        distance = math.hypot(target[0] - env.state[0], target[1] - env.state[1])
        arrival = 10.0 if target_kind == "manual_bypass" else 12.0
        if distance < arrival and target_index < len(targets) - 1:
            target_index += 1
            target, target_kind = targets[target_index]
        action, previous_rudder, _helm = manual_helm(env, target, previous_rudder)
        if action[0] < 0.0:
            braking_steps += 1
        _observation, _reward, terminated, truncated, info = env.step(action)
        speed_ratio = min(abs(env.state[3]) / max(env.performance.max_forward_speed, 0.1), 1.0)
        turn_authority = env.performance.low_speed_turn_factor + (
            1.0 - env.performance.low_speed_turn_factor
        ) * speed_ratio
        yaw_rate = abs(env.state[5]) * env.performance.max_turn_rate_degrees * turn_authority
        max_command_rudder = max(max_command_rudder, abs(action[1]))
        max_actual_rudder = max(max_actual_rudder, abs(env.state[5]))
        max_yaw_rate = max(max_yaw_rate, yaw_rate)
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
    checkpoint_points = [env._point_tuple(env.task.get("start", {})), *env.route]
    checkpoint_spacings = [
        math.hypot(bx - ax, bz - az)
        for (ax, az), (bx, bz) in zip(checkpoint_points, checkpoint_points[1:])
    ]
    result = {
        "task_id": str(info.get("task_id", task_index)),
        "dataset_split": split,
        "seed": seed,
        "success": bool(info.get("is_success", False)),
        "cargo_retrieved": bool(info.get("cargo_retrieved", False)),
        "checkpoints_passed": int(info.get("checkpoints_passed", 0)),
        "total_checkpoints": int(info.get("total_checkpoints", 0)),
        "collisions": int(info.get("collisions", 0)),
        "terrain_collisions": int(info.get("terrain_collisions", 0)),
        "minimum_safety_envelope_clearance_meters": float(info.get("minimum_clearance_meters", 0.0)),
        "minimum_boundary_clearance_meters": float(minimum_boundary_clearance),
        "minimum_checkpoint_spacing_meters": float(min(checkpoint_spacings)),
        "maximum_checkpoint_spacing_meters": float(max(checkpoint_spacings)),
        "path_length_meters": float(info.get("path_length_meters", 0.0)),
        "elapsed_simulation_seconds": env.steps * env.delta,
        "steps": env.steps,
        "maximum_commanded_rudder_normalized": max_command_rudder,
        "maximum_actual_rudder_normalized": max_actual_rudder,
        "maximum_yaw_rate_degrees_per_second": max_yaw_rate,
        "maximum_speed_mps": max_speed,
        "braking_steps": braking_steps,
        "headless": True,
        "render": False,
    }
    return result, env


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the non-learning manual cargo-circuit feasibility gate.")
    parser.add_argument("--config", default="data/rl/cargo_circuit_experiment_v1.json")
    parser.add_argument("--report", default="reports/cargo_circuit_manual_feasibility_v1.json")
    parser.add_argument(
        "--trajectory",
        default="reports/artifacts/cargo_circuit_rl_v1/manual_feasibility_trajectory.json",
    )
    parser.add_argument("--max-steps", type=int, default=3600)
    parser.add_argument("--seed", type=int, default=260815)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config_path = Path(args.config).expanduser().resolve()
    config, dataset, dataset_path = load_experiment(config_path)
    results: List[Dict[str, Any]] = []
    selected_env: CargoCircuitEnv | None = None
    for split in ("train", "validation", "test"):
        for task_index in range(len(dataset["splits"][split])):
            result, env = run_episode(
                config,
                dataset,
                split,
                task_index,
                args.seed + task_index,
                args.max_steps,
            )
            results.append(result)
            if split == "test" and selected_env is None:
                selected_env = env
    assert selected_env is not None
    all_passed = all(
        row["success"]
        and row["collisions"] == 0
        and row["checkpoints_passed"] == row["total_checkpoints"]
        and row["minimum_safety_envelope_clearance_meters"] > 0.0
        and row["minimum_boundary_clearance_meters"] > 0.0
        for row in results
    )
    report = {
        "format": "cargo_circuit_manual_feasibility_v1",
        "module": "cargo_circuit_rl",
        "purpose": "pre-training physical reachability gate",
        "controller": {
            "type": "human_authored_bypass_points_and_helm_law",
            "learned": False,
            "rl_evidence": False,
            "note": "This proves task feasibility only and must never be presented as a trained policy.",
        },
        "dynamic_obstacles": {
            "included": False,
            "phase": "future_advanced_goal_after_static_policy_acceptance",
        },
        "dataset_path": str(dataset_path),
        "dataset_sha256": dataset_fingerprint(dataset),
        "experiment_sha256": cargo_experiment_fingerprint(config),
        "ship_performance": config.get("ships", [{}])[0].get("performance", {}),
        "manual_bypasses": [[{"x": x, "z": z} for x, z in group] for group in MANUAL_BYPASSES],
        "episodes": results,
        "aggregate": {
            "episodes": len(results),
            "success_rate": sum(row["success"] for row in results) / len(results),
            "total_collisions": sum(row["collisions"] for row in results),
            "minimum_safety_envelope_clearance_meters": min(row["minimum_safety_envelope_clearance_meters"] for row in results),
            "minimum_boundary_clearance_meters": min(row["minimum_boundary_clearance_meters"] for row in results),
            "maximum_yaw_rate_degrees_per_second": max(row["maximum_yaw_rate_degrees_per_second"] for row in results),
            "maximum_actual_rudder_normalized": max(row["maximum_actual_rudder_normalized"] for row in results),
        },
        "acceptance_gate": {
            "passed": all_passed,
            "requires_all_splits": True,
            "requires_all_checkpoints": True,
            "requires_zero_collisions": True,
            "requires_positive_obstacle_and_boundary_clearance": True,
        },
    }
    report_path = Path(args.report).expanduser().resolve()
    write_json_atomic(report_path, report)
    task = selected_env.task
    start = task.get("start", {})
    route_points = [
        {"name": str(point.get("name", f"航点 {index + 1}")), "x": float(point["x"]), "z": float(point["z"])}
        for index, point in enumerate(task.get("route", []))
    ]
    trajectory = {
        "format": "cargo_circuit_manual_feasibility_rollout_v1",
        "module": "cargo_circuit_rl",
        "source": "human_authored_helm_feasibility_rollout",
        "trained_rl": False,
        "dataset_split": "test",
        "task_id": str(task.get("id", "cargo_test")),
        "playback_mode": "recorded_numeric_test_states",
        "rendered_during_run": False,
        "start": {"x": float(start.get("x", 0.0)), "z": float(start.get("z", 0.0)), "heading_degrees": float(start.get("heading_degrees", 0.0))},
        "goal": route_points[-1],
        "route_points": route_points,
        "evaluation_obstacles": selected_env.obstacle_export_records(),
        "samples": selected_env.trajectory,
        "evaluation_metrics": next(row for row in results if row["dataset_split"] == "test"),
        "acceptance_gate": report["acceptance_gate"],
        "disclaimer": "manual feasibility only; not RL evidence",
    }
    trajectory_path = Path(args.trajectory).expanduser().resolve()
    write_json_atomic(trajectory_path, trajectory)
    print(json.dumps({"ok": all_passed, "report": str(report_path), "trajectory": str(trajectory_path), "aggregate": report["aggregate"]}, ensure_ascii=False))
    return 0 if all_passed else 2


if __name__ == "__main__":
    raise SystemExit(main())
