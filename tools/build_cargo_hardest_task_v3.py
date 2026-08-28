#!/usr/bin/env python3
"""Freeze the current Godot obstacle snapshot into the hardest cargo task.

The generated contract deliberately uses the current 32-large-rock map and a
single full-circuit objective.  Train/validation/test differ in start state,
sea state, sensor noise seed, and moving-traffic encounters; they never reuse a
rendered test trajectory as training input.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Sequence, Tuple


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_ID = "taoyuan_large_rocks_reviewed_2026_08_24"
START = {"x": 0.0, "z": -650.0, "heading_degrees": 85.0}
ROUTE: Sequence[Tuple[str, float, float]] = (
    ("检查点 1 · 南部起航门", 350.0, -620.0),
    ("检查点 2 · 东南动障门", 460.0, -250.0),
    ("检查点 3 · 东部巨岩门", 460.0, 250.0),
    ("检查点 4 · 东北转向门", 400.0, 600.0),
    ("检查点 5 · 北部横越门", 80.0, 700.0),
    ("检查点 6 · 西北边界门", -700.0, 660.0),
    ("检查点 7 · 西部狭水门", -735.0, -450.0),
    ("返航取货站", 0.0, -650.0),
)


def _canonical(value: Mapping[str, Any]) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _discover_scene_snapshot() -> Path:
    base = Path.home() / "Library/Application Support/Godot/app_userdata"
    matches = sorted(base.glob("**/large_rock_training_contract_smoke.json"))
    if not matches:
        raise FileNotFoundError(
            "current Godot obstacle snapshot is missing; run the large-rock training contract smoke first"
        )
    return matches[-1]


def _route_payload() -> List[Dict[str, Any]]:
    return [{"name": name, "x": x, "z": z} for name, x, z in ROUTE]


def _sea_state(index: int, split: str) -> Dict[str, float]:
    split_bias = {"train": 0.0, "validation": 13.0, "test": 27.0}[split]
    return {
        "wind_speed_knots": 7.0 + 1.4 * (index % 4),
        "wind_direction_degrees": (35.0 + split_bias + 71.0 * index) % 360.0,
        "current_speed_knots": 0.45 + 0.11 * (index % 3),
        "current_direction_degrees": (95.0 + split_bias + 83.0 * index) % 360.0,
        "wave_height_meters": 0.45 + 0.12 * (index % 4),
        "wave_direction_degrees": (20.0 + split_bias + 67.0 * index) % 360.0,
    }


def _task(split: str, index: int) -> Dict[str, Any]:
    start_offsets = ((0.0, 0.0, 0.0), (3.5, -2.0, 4.0), (-3.0, 2.5, -5.0), (1.5, 3.0, 7.0), (-2.0, -3.5, -7.0))
    dx, dz, dh = start_offsets[index % len(start_offsets)]
    return {
        "id": f"cargo_hardest_{split}_{index + 1:02d}",
        "start": {
            "x": START["x"] + dx,
            "z": START["z"] + dz,
            "heading_degrees": START["heading_degrees"] + dh,
        },
        "route": _route_payload(),
        "arrival_radius": 18.0,
        "boundary_half_extent": 780.0,
        "manual_bypasses": [[] for _point in ROUTE],
        "sea_state": _sea_state(index, split),
    }


def _segment_box_clearance(
    start: Tuple[float, float],
    end: Tuple[float, float],
    box: Mapping[str, Any],
) -> float:
    position = box.get("position", {})
    size = box.get("size", {})
    length = max(1, int(math.ceil(math.hypot(end[0] - start[0], end[1] - start[1]))))
    best = float("inf")
    for step in range(length + 1):
        ratio = step / length
        x = start[0] + (end[0] - start[0]) * ratio
        z = start[1] + (end[1] - start[1]) * ratio
        dx = max(abs(x - float(position.get("x", 0.0))) - float(size.get("x", 0.0)) * 0.5, 0.0)
        dz = max(abs(z - float(position.get("z", 0.0))) - float(size.get("z", 0.0)) * 0.5, 0.0)
        best = min(best, math.hypot(dx, dz))
    return best


def _verify_route(boxes: Sequence[Mapping[str, Any]]) -> Dict[str, Any]:
    points = [(float(START["x"]), float(START["z"])), *[(x, z) for _name, x, z in ROUTE]]
    minimum = float("inf")
    nearest = ""
    nearest_leg = -1
    for leg, (start, end) in enumerate(zip(points, points[1:])):
        for box in boxes:
            clearance = _segment_box_clearance(start, end, box)
            if clearance < minimum:
                minimum = clearance
                nearest = str(box.get("name", "unnamed"))
                nearest_leg = leg + 1
    # 5 m numeric collision inflation plus a 20 m planning reserve.
    if minimum < 25.0:
        raise ValueError(
            f"hardest-task route is not physically feasible: leg {nearest_leg} has only {minimum:.2f} m raw clearance to {nearest}"
        )
    return {
        "minimum_raw_aabb_clearance_meters": minimum,
        "nearest_static_obstacle": nearest,
        "nearest_route_leg": nearest_leg,
        "required_minimum_raw_clearance_meters": 25.0,
    }


def build(scene_snapshot_path: Path, dataset_path: Path, config_path: Path) -> Dict[str, Any]:
    snapshot_bytes = scene_snapshot_path.read_bytes()
    snapshot = json.loads(snapshot_bytes)
    obstacles = snapshot.get("world", {}).get("obstacles", {})
    boxes = list(obstacles.get("boxes", []))
    manifest_boxes = [box for box in boxes if box.get("manifest_id") == MANIFEST_ID]
    if len(manifest_boxes) != 32:
        raise ValueError(f"current scene snapshot must contain 32 manifest rocks, got {len(manifest_boxes)}")
    route_gate = _verify_route(manifest_boxes)

    split_counts = {"train": 5, "validation": 3, "test": 5}
    dataset = {
        "schema_version": "cargo_circuit_hardest_dataset_v3",
        "name": "当前地图终极环航动静障碍取货基准",
        "description": "完整环形航线、七个有序节点、返航取货、当前 Godot 静态障碍、移动交通和惯性漂移。",
        "coordinate_system": {"type": "local_cartesian_meters", "axes": "x_east_z_north"},
        "source": {
            "type": "project_native_current_godot_snapshot",
            "simulation_only": True,
            "large_rock_manifest_id": MANIFEST_ID,
            "scene_snapshot_sha256": _sha256_bytes(snapshot_bytes),
        },
        "mission_contract": {
            "ordered_checkpoints": True,
            "checkpoint_count": 7,
            "destination": "返航取货站",
            "full_circuit": True,
            "static_obstacle_count": len(obstacles.get("rocks", [])) + len(boxes),
            "large_rock_count": len(manifest_boxes),
            "dynamic_traffic_count": 6,
            "training_render": False,
            "accepted_test_only_render": True,
            "route_feasibility_gate": route_gate,
        },
        "splits": {
            split: [_task(split, index) for index in range(count)]
            for split, count in split_counts.items()
        },
    }
    dataset_sha = _sha256_bytes(_canonical(dataset))

    config = {
        "schema_version": "cargo_circuit_hardest_experiment_v3",
        "module": "cargo_circuit_dynamic_rl",
        "headless": True,
        "render": False,
        "delta": 0.25,
        "dataset": {
            "path": f"res://{dataset_path.relative_to(ROOT).as_posix()}",
            "training_split": "train",
            "validation_split": "validation",
            "evaluation_split": "test",
        },
        "algorithm_decision": {
            "primary": "sac",
            "reason": "direct continuous throttle/rudder learning on the single hardest current-map task",
            "benchmarks": ["ppo", "td3", "los_pid"],
        },
        "pretraining_feasibility_gate": {
            "required": True,
            "path": "res://reports/cargo_circuit_hardest_manual_feasibility_v3.json",
            "requires_matching_dataset_and_experiment_sha256": True,
        },
        "demonstration_initialization": {
            "enabled_for_sac": True,
            "source": "current_map_transparent_manual_helm_train_split_only",
            "fixed_seed": 280826,
            "actor_behavior_cloning_epochs": 6,
            "replay_buffer_prefill": True,
            "note": "Expert actions initialize SAC only; validation/test execute the neural policy without manual targets or fallback control.",
        },
        "cargo_parameters": {
            "checkpoint_bonus": 55.0,
            "destination_bonus": 260.0,
            "reverse_penalty": 1.5,
            "overspeed_penalty": 0.26,
            "boundary_proximity_penalty": 2.4,
            "boundary_warning_distance_m": 55.0,
            "safe_speed_ratio": 0.66,
            "dynamic_safe_distance_m": 42.0,
            "dynamic_proximity_penalty": 3.6,
            "forward_motion_bonus": 0.10,
            "incomplete_mission_penalty": 900.0,
            "residual_policy": False,
            "throttle_action_min": -0.35,
            "throttle_action_max": 1.0,
            "curriculum_route_lengths": [8],
            "curriculum_obstacles_enabled": [True],
            "curriculum_randomization_enabled": [True],
            "curriculum_random_segment": [False],
            "curriculum_max_steps": [5200],
            "curriculum_fractions": [1.0],
        },
        "rl_parameters": {
            "reward_progress": 3.2,
            "reward_heading": 1.4,
            "reward_speed": 0.8,
            "penalty_collision": 1300.0,
            "penalty_terrain_collision": 1500.0,
            "penalty_boundary": 1300.0,
            "penalty_rudder": 0.36,
            "penalty_proximity": 3.4,
            "penalty_predicted_collision": 6.0,
            "penalty_cross_track": 0.012,
            "penalty_action_slew": 0.028,
            "penalty_step": 0.005,
            "safe_distance": 48.0,
        },
        "environment_parameters": {
            "vessel_radius_m": 3.2,
            "obstacle_inflation_m": 1.8,
            "cliff_inflation_m": 3.0,
            "boundary_margin_m": 5.0,
            "sensor_range_m": 180.0,
            "tcpa_horizon_seconds": 100.0,
            "terminate_on_collision": True,
            "merge_scene_obstacles": True,
            "domain_randomization": True,
            "randomize_evaluation": True,
            "start_position_jitter_m": 3.0,
            "start_heading_jitter_degrees": 7.0,
            "obstacle_position_jitter_m": 0.0,
            "obstacle_size_jitter_m": 0.0,
            "current_speed_jitter_knots": 0.16,
            "current_direction_jitter_degrees": 9.0,
            "wind_speed_jitter_knots": 1.2,
            "wind_direction_jitter_degrees": 10.0,
            "wave_height_jitter_m": 0.12,
            "wave_direction_jitter_degrees": 10.0,
            "wind_leeway_factor": 0.012,
            "wave_drift_mps_per_meter": 0.06,
            "sensor_distance_noise_std_m": 0.25,
            "sensor_bearing_noise_degrees": 0.45,
            "generated_traffic_count": 6,
            "generated_traffic_speed_knots": 1.5,
            "generated_traffic_radius_m": 5.5,
        },
        "ships": [{
            "performance": {
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
        }],
        "world": {
            "water_level_y": snapshot.get("world", {}).get("water_level_y"),
            "obstacles": {
                "boundary_half_extent": 780.0,
                "rocks": list(obstacles.get("rocks", [])),
                "boxes": boxes,
                "snapshot_sha256": _sha256_bytes(snapshot_bytes),
                "large_rock_manifest_id": MANIFEST_ID,
            },
        },
    }

    dataset_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.parent.mkdir(parents=True, exist_ok=True)
    dataset_path.write_text(json.dumps(dataset, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    config_path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return {
        "dataset": str(dataset_path),
        "config": str(config_path),
        "dataset_sha256": dataset_sha,
        "scene_snapshot_sha256": _sha256_bytes(snapshot_bytes),
        "large_rock_count": len(manifest_boxes),
        "static_obstacle_count": len(obstacles.get("rocks", [])) + len(boxes),
        "dynamic_traffic_count": 6,
        "route_gate": route_gate,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scene-snapshot", type=Path)
    parser.add_argument("--dataset", type=Path, default=ROOT / "data/rl/cargo_circuit_hardest_dataset_v3.json")
    parser.add_argument("--config", type=Path, default=ROOT / "data/rl/cargo_circuit_hardest_experiment_v3.json")
    args = parser.parse_args()
    scene_snapshot = (args.scene_snapshot or _discover_scene_snapshot()).expanduser().resolve()
    result = build(scene_snapshot, args.dataset.expanduser().resolve(), args.config.expanduser().resolve())
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
