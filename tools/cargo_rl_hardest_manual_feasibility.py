#!/usr/bin/env python3
"""Run a transparent manual-helm feasibility gate for cargo V3."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
from typing import Any, Dict, List, Mapping

import numpy as np

from cargo_rl.hardest_demonstration import hardest_manual_helm, task_manual_targets
from cargo_rl.environment import cargo_experiment_fingerprint
from cargo_rl.hardest_environment import CargoHardestV3Env
from ship_rl.environment import dataset_fingerprint, load_experiment
from ship_rl.trainer import write_json_atomic


ROOT = Path(__file__).resolve().parents[1]


def _run_episode(
    config: Dict[str, Any],
    dataset: Dict[str, Any],
    task_index: int,
    seed: int,
    max_steps: int,
    split: str = "train",
) -> tuple[Dict[str, Any], CargoHardestV3Env]:
    env = CargoHardestV3Env(
        config,
        dataset,
        split=split,
        discrete_actions=False,
        max_steps=max_steps,
        seed=seed,
        task_index=task_index,
        render_mode=None,
    )
    _observation, _info = env.reset(options={"task_index": task_index})
    targets = task_manual_targets(env)
    target_index = 0
    previous_rudder = 0.0
    avoidance_steps = 0
    maximum_avoidance_bias = 0.0
    terminated = truncated = False
    info: Mapping[str, Any] = {}
    cargo = config.get("cargo_parameters", {})
    throttle_min = float(cargo.get("throttle_action_min", -0.35))
    throttle_max = float(cargo.get("throttle_action_max", 1.0))
    while not (terminated or truncated):
        target, target_kind = targets[target_index]
        distance = math.hypot(target[0] - env.state[0], target[1] - env.state[1])
        arrival = 12.0 if target_kind == "manual_bypass" else 16.0
        if distance < arrival and target_index < len(targets) - 1:
            target_index += 1
            target, _target_kind = targets[target_index]
        physical_action, previous_rudder, helm = hardest_manual_helm(env, target, previous_rudder)
        avoidance_steps += int(bool(helm["dynamic_conflict"]))
        maximum_avoidance_bias = max(maximum_avoidance_bias, abs(helm["avoidance_bias_degrees"]))
        normalized_throttle = 2.0 * (
            (physical_action[0] - throttle_min) / max(throttle_max - throttle_min, 1e-6)
        ) - 1.0
        action = np.asarray(
            [np.clip(normalized_throttle, -1.0, 1.0), physical_action[1]],
            dtype=np.float32,
        )
        _observation, _reward, terminated, truncated, info = env.step(action)
    result = {
        "task_id": env.task.get("id"),
        "seed": seed,
        "success": bool(info.get("is_success", False)),
        "cargo_retrieved": bool(info.get("cargo_retrieved", False)),
        "checkpoints_passed": int(info.get("checkpoints_passed", 0)),
        "total_checkpoints": int(info.get("total_checkpoints", 0)),
        "collisions": int(info.get("collisions", 0)),
        "terrain_collisions": int(info.get("terrain_collisions", 0)),
        "steps": int(info.get("steps", env.steps)),
        "minimum_safety_envelope_clearance_meters": float(info.get("minimum_clearance_meters", env.minimum_clearance)),
        "minimum_dynamic_clearance_meters": float(info.get("minimum_dynamic_clearance_meters", env.minimum_dynamic_clearance)),
        "minimum_boundary_clearance_meters": float(info.get("minimum_boundary_clearance_meters", env._boundary_clearance())),
        "dynamic_traffic_count": int(info.get("dynamic_obstacle_count", 0)),
        "dynamic_avoidance_steps": avoidance_steps,
        "maximum_avoidance_bias_degrees": maximum_avoidance_bias,
        "last_collision": dict(env.last_collision),
    }
    return result, env


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=ROOT / "data/rl/cargo_circuit_hardest_experiment_v3.json")
    parser.add_argument("--episodes", type=int, default=5)
    parser.add_argument("--seed", type=int, default=280826)
    parser.add_argument("--max-steps", type=int, default=5200)
    parser.add_argument("--split", choices=("train", "validation"), default="train")
    parser.add_argument("--report", type=Path, default=ROOT / "reports/cargo_circuit_hardest_manual_feasibility_v3.json")
    parser.add_argument("--trajectory", type=Path, default=ROOT / "reports/artifacts/cargo_circuit_hardest_v3/manual_feasibility_trajectory.json")
    args = parser.parse_args()

    config_path = args.config.expanduser().resolve()
    config, dataset, dataset_path = load_experiment(config_path)
    episode_count = max(1, args.episodes)
    task_count = len(dataset["splits"][args.split])
    episodes: List[Dict[str, Any]] = []
    selected_env: CargoHardestV3Env | None = None
    selected_metrics: Dict[str, Any] | None = None
    for index in range(episode_count):
        metrics, env = _run_episode(
            config,
            dataset,
            task_index=index % task_count,
            seed=args.seed + index,
            max_steps=max(1, args.max_steps),
            split=args.split,
        )
        episodes.append(metrics)
        if selected_env is None or (metrics["success"] and not episodes[0]["success"]):
            if selected_env is not None:
                selected_env.close()
            selected_env = env
            selected_metrics = metrics
        else:
            env.close()

    successes = sum(int(item["success"]) for item in episodes)
    total_collisions = sum(item["collisions"] for item in episodes)
    minimum_clearance = min(item["minimum_safety_envelope_clearance_meters"] for item in episodes)
    minimum_dynamic = min(item["minimum_dynamic_clearance_meters"] for item in episodes)
    total_avoidance_steps = sum(item["dynamic_avoidance_steps"] for item in episodes)
    passed = bool(
        successes == episode_count
        and total_collisions == 0
        and minimum_clearance > 0.0
        and minimum_dynamic > 0.0
        and total_avoidance_steps > 0
        and all(item["dynamic_traffic_count"] >= 6 for item in episodes)
    )
    report = {
        "format": "cargo_circuit_hardest_manual_feasibility_v3",
        "module": "cargo_circuit_dynamic_rl",
        "source": "transparent_human_authored_helm_feasibility_rollout",
        "trained_rl": False,
        "dataset_path": str(dataset_path) if dataset_path else "",
        "dataset_sha256": dataset_fingerprint(dataset),
        "experiment_sha256": cargo_experiment_fingerprint(config),
        "scene_snapshot_sha256": config.get("world", {}).get("obstacles", {}).get("snapshot_sha256"),
        "dataset_split": args.split,
        "mission": {
            "full_circuit": True,
            "ordered_checkpoints": 7,
            "cargo_return": True,
            "large_rock_count": 32,
            "dynamic_traffic_count": 6,
            "manual_targets_available_to_final_policy": False,
        },
        "episodes": episodes,
        "aggregate": {
            "episodes": episode_count,
            "success_rate": successes / episode_count,
            "total_collisions": total_collisions,
            "minimum_safety_envelope_clearance_meters": minimum_clearance,
            "minimum_dynamic_clearance_meters": minimum_dynamic,
            "dynamic_avoidance_steps": total_avoidance_steps,
        },
        "acceptance_gate": {
            "passed": passed,
            "requires_all_episodes_successful": True,
            "requires_zero_collision": True,
            "requires_positive_static_and_dynamic_clearance": True,
            "requires_observed_dynamic_avoidance": True,
        },
    }
    write_json_atomic(args.report.expanduser().resolve(), report)

    if selected_env is not None:
        trajectory = {
            "format": "cargo_circuit_hardest_manual_feasibility_rollout_v3",
            "module": "cargo_circuit_dynamic_rl",
            "source": "transparent_human_authored_helm_feasibility_rollout",
            "trained_rl": False,
            "dataset_split": args.split,
            "task_id": selected_env.task.get("id"),
            "start": selected_env.task.get("start"),
            "goal": selected_env.task.get("route", [])[-1],
            "route_points": selected_env.task.get("route", []),
            "evaluation_obstacles": selected_env.obstacle_export_records(),
            "samples": selected_env.trajectory,
            "metrics": selected_metrics or episodes[0],
            "manual_targets_available_to_final_policy": False,
        }
        write_json_atomic(args.trajectory.expanduser().resolve(), trajectory)
        selected_env.close()

    print(json.dumps({"passed": passed, **report["aggregate"]}, ensure_ascii=False))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
