#!/usr/bin/env python3
"""Exercise the complete 36D/44D cargo training path without using 47D.

The run deliberately uses a tiny budget and unobstructed copies of all seven
scenario routes.  Its acceptance target is trainer/checkpoint/inference wiring,
not policy convergence or advanced-mission qualification.
"""

from __future__ import annotations

import copy
import hashlib
import json
import math
from pathlib import Path
from typing import Any

import numpy as np
from stable_baselines3 import SAC

from cargo_rl.dynamic_environment import CargoDynamicEnv
from cargo_rl.environment import CargoCircuitEnv
from cargo_rl.trainer import train_cargo
from ship_rl.trainer import TrainRequest, write_json_atomic


ROOT = Path(__file__).resolve().parents[1]
PROFILE_PATH = ROOT / "data/ports/default_port_profile.json"
BASE_CONFIG_PATH = ROOT / "data/rl/cargo_circuit_hardest_experiment_v3.json"
ARTIFACT_ROOT = ROOT / "reports/artifacts/non47_training_function_smoke_v1"
REPORT_PATH = ROOT / "reports/non47_training_function_smoke_v1.json"
FROZEN_MODELS = {
    "SAC-S1": ROOT / "reports/artifacts/cargo_circuit_rl_v1/cargo_sac_policy.zip",
    "RES-SAC-D2": ROOT / "reports/artifacts/cargo_circuit_dynamic_rl_v2/cargo_dynamic_sac_policy.zip",
}
SHIP_PERFORMANCE = {
    "max_forward_speed": 8.5,
    "max_reverse_speed": 2.2,
    "acceleration": 0.9,
    "deceleration": 0.65,
    "brake_acceleration": 1.6,
    "throttle_response": 0.55,
    "rudder_response": 0.7,
    "max_turn_rate_degrees": 20.0,
    "low_speed_turn_factor": 0.12,
    "reverse_turn_factor": 0.45,
}


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _mission_map(profile: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {
        str(item["scenario_key"]): item
        for item in profile["navigation_missions"]
    }


def _training_task(
    profile: dict[str, Any],
    scenario_key: str,
    split: str,
) -> dict[str, Any]:
    """Keep native route semantics but remove challenge-only disturbances."""
    scenario = profile["scenarios"][scenario_key]
    mission = _mission_map(profile)[scenario_key]
    start = copy.deepcopy(scenario["spawn"])
    route = copy.deepcopy(scenario["route"])
    if route:
        # The first target can be reached within the short smoke horizon while
        # subsequent points preserve the scene's native ordered-route contract.
        heading = math.radians(float(start.get("heading_degrees", 0.0)))
        route[0]["x"] = float(start["x"]) + math.sin(heading) * 8.0
        route[0]["z"] = float(start["z"]) + math.cos(heading) * 8.0
    return {
        "id": f"non47::{split}::{scenario_key}",
        "scenario_key": scenario_key,
        "start": start,
        "route": route,
        "arrival_radius": max(8.0, float(mission["arrival_radius"])),
        "boundary_half_extent": max(260.0, float(scenario["boundary_half_extent"])),
        "obstacles": [],
        "dynamic_obstacles": [],
        "sea_state": {
            "wind_speed_knots": 0.0,
            "wind_direction_degrees": 0.0,
            "wave_height_meters": 0.0,
            "wave_direction_degrees": 0.0,
            "wave_period_seconds": 4.0,
            "current_speed_knots": 0.0,
            "current_direction_degrees": 0.0,
        },
    }


def _dataset(profile: dict[str, Any]) -> dict[str, Any]:
    order = list(profile["scenario_order"])
    return {
        "schema_version": "non47_training_function_dataset_v1",
        "name": "Seven-scenario low-difficulty training-function smoke",
        "source": {
            "profile": "res://data/ports/default_port_profile.json",
            "simulation_only": True,
            "purpose": "trainer and inference wiring; not policy qualification",
        },
        "splits": {
            split: [_training_task(profile, key, split) for key in order]
            for split in ("train", "validation", "test")
        },
    }


def _config(module: str, dataset_path: Path) -> dict[str, Any]:
    config = json.loads(BASE_CONFIG_PATH.read_text(encoding="utf-8"))
    config.update(
        {
            "schema_version": f"non47_training_function_{module}_v1",
            "module": module,
            "delta": 0.25,
            "dataset": {
                "path": f"res://{dataset_path.relative_to(ROOT).as_posix()}",
                "training_split": "train",
                "validation_split": "validation",
                "evaluation_split": "test",
            },
            "pretraining_feasibility_gate": {"required": False},
            "demonstration_initialization": {"enabled_for_sac": False},
            "ships": [{"performance": SHIP_PERFORMANCE}],
            "world": {"obstacles": {"rocks": [], "boxes": []}},
        }
    )
    config["cargo_parameters"] = {
        "checkpoint_bonus": 14.0,
        "destination_bonus": 90.0,
        "reverse_penalty": 0.12,
        "overspeed_penalty": 0.18,
        "boundary_proximity_penalty": 1.5,
        "boundary_warning_distance_m": 30.0,
        "safe_speed_ratio": 0.72,
        "dynamic_safe_distance_m": 24.0,
        "dynamic_proximity_penalty": 0.0,
        "forward_motion_bonus": 0.0,
        "incomplete_mission_penalty": 0.0,
        "residual_policy": False,
        "throttle_action_min": -0.35,
        "throttle_action_max": 1.0,
        "curriculum_route_lengths": [1],
        "curriculum_obstacles_enabled": [False],
        "curriculum_randomization_enabled": [False],
        "curriculum_random_segment": [False],
        "curriculum_max_steps": [32],
        "curriculum_fractions": [1.0],
    }
    environment = copy.deepcopy(config.get("environment_parameters", {}))
    environment.update(
        {
            "merge_scene_obstacles": False,
            "domain_randomization": False,
            "randomize_evaluation": False,
            "generated_traffic_count": 0,
            "start_position_jitter_m": 0.0,
            "start_heading_jitter_degrees": 0.0,
            "obstacle_position_jitter_m": 0.0,
            "obstacle_size_jitter_m": 0.0,
            "current_speed_jitter_knots": 0.0,
            "current_direction_jitter_degrees": 0.0,
            "wind_speed_jitter_knots": 0.0,
            "wind_direction_jitter_degrees": 0.0,
            "wave_height_jitter_m": 0.0,
            "wave_direction_jitter_degrees": 0.0,
            "sensor_distance_noise_std_m": 0.0,
            "sensor_bearing_noise_degrees": 0.0,
            "terminate_on_collision": True,
        }
    )
    config["environment_parameters"] = environment
    config.pop("dynamic_scenarios", None)
    return config


def _run_module(
    module: str,
    observation_size: int,
    dataset: dict[str, Any],
) -> dict[str, Any]:
    label = "36d" if observation_size == 36 else "44d"
    module_root = ARTIFACT_ROOT / label
    module_root.mkdir(parents=True, exist_ok=True)
    dataset_path = module_root / "dataset.json"
    config_path = module_root / "experiment.json"
    checkpoint_path = module_root / "checkpoint.json"
    progress_path = module_root / "progress.json"
    write_json_atomic(dataset_path, dataset)
    config = _config(module, dataset_path)
    write_json_atomic(config_path, config)
    result = train_cargo(
        TrainRequest(
            algorithm="sac",
            config_path=config_path,
            output_dir=module_root,
            progress_path=progress_path,
            checkpoint_path=checkpoint_path,
            total_timesteps=64,
            max_steps=32,
            parallel_envs=1,
            seed=290826 + observation_size,
            learning_rate=3e-4,
            gamma=0.985,
            batch_size=16,
            minibatch_size=16,
            replay_buffer_size=1000,
            warmup_steps=8,
            rollout_horizon=32,
        )
    )
    checkpoint = json.loads(checkpoint_path.read_text(encoding="utf-8"))
    model_path = (checkpoint_path.parent / checkpoint["model_path"]).resolve()
    model = SAC.load(model_path, device="cpu")
    env_class = CargoDynamicEnv if observation_size == 44 else CargoCircuitEnv
    inference_checks: list[dict[str, Any]] = []
    for task_index, task in enumerate(dataset["splits"]["test"]):
        env = env_class(
            config,
            dataset,
            split="test",
            discrete_actions=False,
            max_steps=32,
            task_index=task_index,
            seed=300000 + task_index,
            render_mode=None,
        )
        observation, reset_info = env.reset(seed=300000 + task_index)
        action, _state = model.predict(observation, deterministic=True)
        next_observation, reward, terminated, truncated, step_info = env.step(action)
        passed = bool(
            observation.shape == (observation_size,)
            and next_observation.shape == (observation_size,)
            and np.isfinite(observation).all()
            and np.isfinite(next_observation).all()
            and np.isfinite(action).all()
            and np.isfinite(reward)
            and reset_info.get("observation_size") == observation_size
            and step_info.get("observation_size") == observation_size
        )
        inference_checks.append(
            {
                "scenario_key": task["scenario_key"],
                "passed": passed,
                "observation_size": int(observation.shape[0]),
                "action": [round(float(value), 6) for value in np.asarray(action)],
                "reward": round(float(reward), 6),
                "terminated": bool(terminated),
                "truncated": bool(truncated),
            }
        )
        env.close()
    return {
        "module": module,
        "observation_size": observation_size,
        "training_complete": bool(result.get("ok")) and result.get("status") == "complete",
        "requested_timesteps": 64,
        "completed_timesteps": int(result.get("completed_timesteps", 0)),
        "checkpoint_observation_size": int(checkpoint.get("observation_size", -1)),
        "checkpoint_exists": checkpoint_path.exists(),
        "model_exists": model_path.exists(),
        "model_sha256": _sha256(model_path),
        "scenario_inference_checks": inference_checks,
        "all_scenarios_inference_passed": all(item["passed"] for item in inference_checks),
        "policy_qualification_claimed": False,
    }


def main() -> int:
    profile = json.loads(PROFILE_PATH.read_text(encoding="utf-8"))
    dataset = _dataset(profile)
    frozen_before = {name: _sha256(path) for name, path in FROZEN_MODELS.items()}
    runs = [
        _run_module("cargo_circuit_rl", 36, dataset),
        _run_module("cargo_circuit_dynamic_rl", 44, dataset),
    ]
    frozen_after = {name: _sha256(path) for name, path in FROZEN_MODELS.items()}
    accepted = bool(
        all(item["training_complete"] for item in runs)
        and all(item["completed_timesteps"] >= item["requested_timesteps"] for item in runs)
        and all(item["checkpoint_observation_size"] == item["observation_size"] for item in runs)
        and all(item["checkpoint_exists"] and item["model_exists"] for item in runs)
        and all(item["all_scenarios_inference_passed"] for item in runs)
        and frozen_before == frozen_after
        and {item["observation_size"] for item in runs} == {36, 44}
    )
    report = {
        "schema_version": "non47_training_function_smoke_v1",
        "accepted": accepted,
        "purpose": "training/checkpoint/inference functional acceptance, not policy convergence",
        "scenario_keys": list(profile["scenario_order"]),
        "scenario_count": len(profile["scenario_order"]),
        "observation_dimensions_tested": [36, 44],
        "dimension_47_used": False,
        "runs": runs,
        "frozen_policy_hashes_before": frozen_before,
        "frozen_policy_hashes_after": frozen_after,
        "frozen_policies_unchanged": frozen_before == frozen_after,
        "limitations": [
            "Only 64 SAC timesteps are used per observation contract.",
            "Obstacles and environmental disturbances are disabled for this functional smoke.",
            "Inference success means reset/predict/step completed with finite values; it is not mission qualification.",
        ],
    }
    write_json_atomic(REPORT_PATH, report)
    print(
        "NON47_TRAINING_FUNCTION_SMOKE:%s:36D=%s,44D=%s,SCENES=%d/7"
        % (
            "PASS" if accepted else "FAIL",
            "PASS" if runs[0]["all_scenarios_inference_passed"] else "FAIL",
            "PASS" if runs[1]["all_scenarios_inference_passed"] else "FAIL",
            sum(1 for item in runs[0]["scenario_inference_checks"] if item["passed"]),
        )
    )
    return 0 if accepted else 1


if __name__ == "__main__":
    raise SystemExit(main())
