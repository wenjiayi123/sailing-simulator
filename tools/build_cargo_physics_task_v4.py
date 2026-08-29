#!/usr/bin/env python3
"""Create an easier, additive 47D physics task without removing any rocks."""

from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DATASET = ROOT / "data/rl/cargo_circuit_hardest_dataset_v3.json"
SOURCE_CONFIG = ROOT / "data/rl/cargo_circuit_hardest_experiment_v3.json"
TARGET_DATASET = ROOT / "data/rl/cargo_circuit_physics_dataset_v4.json"
TARGET_CONFIG = ROOT / "data/rl/cargo_circuit_physics_experiment_v4.json"
DYNAMICS = ROOT / "data/verification/catamaran_usv_dynamics_reference_v2.json"
PHYSICS_HELM = ROOT / "tools/cargo_rl/physics_demonstration.py"
MANIFEST_ID = "taoyuan_large_rocks_reviewed_2026_08_24"


def _write(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    dataset = copy.deepcopy(json.loads(SOURCE_DATASET.read_text(encoding="utf-8")))
    config = copy.deepcopy(json.loads(SOURCE_CONFIG.read_text(encoding="utf-8")))
    dynamics = json.loads(DYNAMICS.read_text(encoding="utf-8"))
    dynamics_sha = hashlib.sha256(DYNAMICS.read_bytes()).hexdigest()

    boxes = config["world"]["obstacles"]["boxes"]
    manifest_boxes = [item for item in boxes if item.get("manifest_id") == MANIFEST_ID]
    if len(manifest_boxes) != 32:
        raise ValueError(f"physics V4 requires all 32 current-map rocks, got {len(manifest_boxes)}")

    dataset["schema_version"] = "cargo_circuit_physics_dataset_v4"
    dataset["name"] = "47D三自由度悬岩动态取货任务"
    dataset["description"] = "保留32个悬岩、全部视觉合同和6艘动态交通；通过短航段课程降低学习难度，不删除障碍。"
    dataset["mission_contract"].update(
        {
            "large_rock_count": 32,
            "dynamic_traffic_count": 6,
            "observation_dimension": 47,
            "dynamics_model_id": dynamics["model_id"],
            "difficulty_adjustment": "short-segment curriculum and reduced randomization; no obstacle removal",
        }
    )
    for split, tasks in dataset["splits"].items():
        for index, task in enumerate(tasks):
            task["id"] = f"cargo_physics_v4_{split}_{index + 1:02d}"
            bypasses = task.get("manual_bypasses", [[] for _point in task.get("route", [])])
            if len(bypasses) != len(task.get("route", [])):
                raise ValueError("physics V4 requires one manual-bypass list per route leg")
            # With sway/yaw inertia active, a late dynamic-traffic avoidance on
            # the east leg can continue drifting west into GroundedPlate_06.
            # These train-only helm labels teach an early eastward offset; no
            # bypass coordinate is exposed to the released neural policy.
            bypasses[2] = [
                {"x": 520.0, "z": -130.0, "detail": "pre-drift east offset"},
                {"x": 520.0, "z": 120.0, "detail": "post-conflict east recovery"},
            ]
            # A zero-speed curriculum start at the east rock gate has no
            # incoming turn history.  Under the shared 3-DOF plant, braking
            # for crossing traffic can otherwise leave the helm oscillating
            # beside GroundedPlate_06 until residual surge/sway carries the
            # vessel into the rock.  Teach the train-only expert to create
            # westward room before the northbound turn.  The released SAC
            # actor receives no bypass coordinates or manual helm fallback.
            bypasses[3] = [
                {"x": 380.0, "z": 360.0, "detail": "pre-turn west inertia margin"},
            ]
            # The west side of GroundedPlate_04 leaves a narrow channel
            # between terrain and the navigation boundary.  The direct helm
            # succeeds with only about 14 m of held-out clearance, so tiny
            # cloned-rudder errors can compound into either a rock strike or
            # a boundary exit.  These train-only labels hold the channel
            # centreline; validation and the released actor receive no bypass
            # coordinates or expert fallback.
            bypasses[6] = [
                {"x": -735.0, "z": 380.0, "detail": "west-channel north centreline"},
                {"x": -735.0, "z": 20.0, "detail": "west-channel rock abeam centreline"},
                {"x": -735.0, "z": -360.0, "detail": "west-channel south centreline"},
            ]
            task["manual_bypasses"] = bypasses

    config["schema_version"] = "cargo_circuit_physics_experiment_v4"
    config["dataset"]["path"] = "res://data/rl/cargo_circuit_physics_dataset_v4.json"
    config["algorithm_decision"] = {
        "primary": "sac",
        "reason": "47D direct continuous control with Godot-matched surge/sway/yaw inertia",
        "new_strategy_id": "SAC-P47",
        "preserves_existing_strategies": True,
    }
    config["pretraining_feasibility_gate"]["path"] = "res://reports/cargo_circuit_physics_manual_feasibility_v4.json"
    config["demonstration_initialization"].update(
        {
            "source": "current_map_3dof_manual_helm_train_split_only",
            "actor_behavior_cloning_epochs": 10,
            # Attempt 10 action-level diagnosis found that the initialized
            # actor issued strong reverse in 98.3% of its final 1,000 stuck
            # states while the train-only expert did so in only 1.7%.  The
            # 47D override corrects that throttle-specific cloning failure;
            # V3 keeps its historical defaults.
            "behavior_clone_throttle_weight": 3.0,
            "behavior_clone_rudder_weight": 1.45,
            "dagger_latest_recovery_epochs": 24,
            "dagger_schedule": [
                {"expert_action_fraction": 0.70, "refit_epochs": 20},
                {"expert_action_fraction": 0.40, "refit_epochs": 16},
                {"expert_action_fraction": 0.20, "refit_epochs": 16},
                {"expert_action_fraction": 0.00, "refit_epochs": 20},
                {"expert_action_fraction": 0.00, "refit_epochs": 20},
            ],
            "physics_manual_helm_sha256": hashlib.sha256(PHYSICS_HELM.read_bytes()).hexdigest(),
        }
    )
    cargo = config["cargo_parameters"]
    cargo.update(
        {
            "dynamic_safe_distance_m": 30.0,
            "safe_speed_ratio": 0.48,
            "throttle_action_min": -0.20,
            "throttle_action_max": 0.55,
            "curriculum_route_lengths": [2, 4, 8],
            "curriculum_obstacles_enabled": [True, True, True],
            "curriculum_randomization_enabled": [False, True, True],
            "curriculum_random_segment": [True, True, False],
            "curriculum_max_steps": [1700, 3000, 5200],
            "curriculum_fractions": [0.25, 0.35, 0.40],
            "difficulty_ladder": [
                {
                    "level": 1,
                    "id": "P47-L1",
                    "name": "单航段·固定海况",
                    "route_length": 1,
                    "random_segment": True,
                    "randomization_enabled": False,
                    "dynamic_traffic_speed_knots": 0.4,
                    "randomization_multiplier": 0.0,
                    "max_steps": 2000,
                    "training_timesteps": 100000,
                },
                {
                    "level": 2,
                    "id": "P47-L2",
                    "name": "双航段·固定海况",
                    "route_length": 2,
                    "random_segment": True,
                    "randomization_enabled": False,
                    "dynamic_traffic_speed_knots": 0.4,
                    "randomization_multiplier": 0.0,
                    "max_steps": 3600,
                    "training_timesteps": 100000,
                },
                {
                    "level": 3,
                    "id": "P47-L3",
                    "name": "双航段·轻度扰动",
                    "route_length": 2,
                    "random_segment": True,
                    "randomization_enabled": True,
                    "dynamic_traffic_speed_knots": 0.4,
                    "randomization_multiplier": 0.5,
                    "max_steps": 3600,
                    "training_timesteps": 120000,
                },
                {
                    "level": 4,
                    "id": "P47-L4",
                    "name": "半环·标准动态交通",
                    "route_length": 4,
                    "random_segment": True,
                    "randomization_enabled": True,
                    "dynamic_traffic_speed_knots": 0.4,
                    "randomization_multiplier": 1.0,
                    "max_steps": 4400,
                    "training_timesteps": 140000,
                },
                {
                    "level": 5,
                    "id": "P47-L5",
                    "name": "完整环图·标准动态交通",
                    "route_length": 8,
                    "random_segment": False,
                    "randomization_enabled": True,
                    "dynamic_traffic_speed_knots": 0.4,
                    "randomization_multiplier": 1.0,
                    "max_steps": 5200,
                    "training_timesteps": 160000,
                },
                {
                    "level": 6,
                    "id": "P47-L6",
                    "name": "完整环图·增强交通海况",
                    "route_length": 8,
                    "random_segment": False,
                    "randomization_enabled": True,
                    "dynamic_traffic_speed_knots": 0.6,
                    "randomization_multiplier": 1.5,
                    "max_steps": 5200,
                    "training_timesteps": 180000,
                },
                {
                    "level": 7,
                    "id": "P47-L7",
                    "name": "完整环图·高速交通强扰动",
                    "route_length": 8,
                    "random_segment": False,
                    "randomization_enabled": True,
                    "dynamic_traffic_speed_knots": 0.8,
                    "randomization_multiplier": 2.0,
                    "max_steps": 5200,
                    "training_timesteps": 200000,
                },
                {
                    "level": 8,
                    "id": "P47-L8",
                    "name": "完整环图·极限交通复合扰动",
                    "route_length": 8,
                    "random_segment": False,
                    "randomization_enabled": True,
                    "dynamic_traffic_speed_knots": 1.0,
                    "randomization_multiplier": 2.5,
                    "max_steps": 5200,
                    "training_timesteps": 220000,
                },
            ],
            "difficulty_promotion_gate": {
                "validation_sweeps": 2,
                "requires_all_episodes_successful": True,
                "requires_zero_collision": True,
                "requires_all_active_checkpoints": True,
                "requires_positive_static_dynamic_and_boundary_clearance": True,
                "requires_all_32_large_rocks": True,
                "requires_all_6_dynamic_vessels": True,
                "requires_sac_actor_updates": True,
                "stop_at_first_unconverged_level": True,
            },
        }
    )
    config["rl_parameters"].update(
        {
            "safe_distance": 34.0,
            "penalty_action_slew": 0.045,
            "penalty_rudder": 0.48,
        }
    )
    environment = config["environment_parameters"]
    environment.update(
        {
            "merge_scene_obstacles": True,
            "start_position_jitter_m": 1.0,
            "start_heading_jitter_degrees": 2.0,
            "current_speed_jitter_knots": 0.08,
            "current_direction_jitter_degrees": 4.0,
            "wind_speed_jitter_knots": 0.5,
            "wind_direction_jitter_degrees": 5.0,
            "wave_height_jitter_m": 0.05,
            "wave_direction_jitter_degrees": 5.0,
            "sensor_distance_noise_std_m": 0.12,
            "sensor_bearing_noise_degrees": 0.20,
            "generated_traffic_count": 6,
            "generated_traffic_speed_knots": 0.4,
        }
    )
    config["ships"][0]["performance"] = {
        "max_forward_speed": 11.0,
        "max_reverse_speed": 4.0,
        "acceleration": 3.6,
        "deceleration": 2.2,
        "brake_acceleration": 6.4,
        "throttle_response": 1.65,
        "rudder_response": 2.45,
        "max_turn_rate_degrees": 26.0,
        "low_speed_turn_factor": 0.18,
        "reverse_turn_factor": 0.58,
    }
    config["world"]["dynamics_contract"] = {
        "path": "res://data/verification/catamaran_usv_dynamics_reference_v2.json",
        "sha256": dynamics_sha,
        "model_id": dynamics["model_id"],
        "model_family": "3DOF_surge_sway_yaw_twin_waterjet_RK4",
        "runtime_physics_hz": 60,
        "control_interval_seconds": config["delta"],
        "godot_runtime_script": "res://scripts/physics/catamaran_three_dof_dynamics.gd",
    }
    config["world"]["obstacles"]["large_rock_manifest_id"] = MANIFEST_ID

    _write(TARGET_DATASET, dataset)
    _write(TARGET_CONFIG, config)
    print(
        json.dumps(
            {
                "dataset": str(TARGET_DATASET),
                "config": str(TARGET_CONFIG),
                "large_rock_count": len(manifest_boxes),
                "dynamic_traffic_count": 6,
                "observation_dimension": 47,
                "dynamics_sha256": dynamics_sha,
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
