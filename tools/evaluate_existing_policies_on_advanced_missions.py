#!/usr/bin/env python3
"""Run frozen 36D/44D cargo SAC policies on advanced mission geometry.

This is a zero-training transfer baseline. It does not change the policies and
does not claim that a cargo-route policy is a certified berthing controller.
"""

from __future__ import annotations

import argparse
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


ROOT = Path(__file__).resolve().parents[1]
PROFILE_PATH = ROOT / "data/ports/default_port_profile.json"
BASE_CONFIG_PATH = ROOT / "data/rl/cargo_circuit_hardest_experiment_v3.json"
STATIC_MODEL_PATH = ROOT / "reports/artifacts/cargo_circuit_rl_v1/cargo_sac_policy.zip"
DYNAMIC_MODEL_PATH = ROOT / "reports/artifacts/cargo_circuit_dynamic_rl_v2/cargo_dynamic_sac_policy.zip"
OUTPUT_ROOT = ROOT / "reports/artifacts/advanced_mission_policy_baseline_v1"
SUMMARY_PATH = ROOT / "reports/advanced_mission_existing_policy_baseline_v1.json"
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
ALL_SCENARIOS = (
    "open_water",
    "harbor",
    "auto_berthing",
    "auto_unberthing",
    "narrow_channel_head_on",
    "crossing_starboard",
    "narrow_channel_overtaking",
)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _mission_by_scenario(profile: dict[str, Any], scenario_key: str) -> dict[str, Any]:
    for mission in profile["navigation_missions"]:
        if mission.get("scenario_key") == scenario_key:
            return mission
    raise KeyError(f"navigation mission unavailable: {scenario_key}")


def _task(profile: dict[str, Any], scenario_key: str) -> dict[str, Any]:
    scenario = profile["scenarios"][scenario_key]
    mission = _mission_by_scenario(profile, scenario_key)
    obstacles: list[dict[str, Any]] = []
    for box in scenario.get("boxes", []):
        obstacles.append(
            {
                "name": box["name"],
                "kind": "shoreline",
                "shape": "box",
                "position": box["position"],
                "size": box["size"],
            }
        )
    for index, rock in enumerate(scenario.get("rocks", []), start=1):
        obstacles.append(
            {
                "name": f"MissionRock_{index:02d}",
                "kind": "rock",
                "shape": "circle",
                "x": rock["x"],
                "z": rock["z"],
                "radius": float(rock.get("radius", 6.0)),
            }
        )
    traffic: list[dict[str, Any]] = []
    for item in scenario.get("traffic", []):
        spawn = item["spawn"]
        speed_knots = float(item.get("speed_knots", float(item.get("throttle", 0.0)) * 16.52))
        traffic.append(
            {
                "name": item["id"],
                "kind": "traffic",
                "dynamic": True,
                "shape": "circle",
                "x": spawn["x"],
                "z": spawn["z"],
                "radius": float(item.get("radius", 5.5)),
                "speed_knots": speed_knots,
                "course_degrees": spawn["heading_degrees"],
            }
        )
    return {
        "id": f"advanced::{scenario_key}::deterministic_transfer",
        "start": copy.deepcopy(scenario["spawn"]),
        "route": copy.deepcopy(scenario["route"]),
        "arrival_radius": float(mission["arrival_radius"]),
        "boundary_half_extent": float(scenario["boundary_half_extent"]),
        "obstacles": obstacles,
        "dynamic_obstacles": traffic,
        "sea_state": {
            "wind_speed_knots": 3.0,
            "wind_direction_degrees": 350.0,
            "wave_height_meters": 0.1,
            "wave_direction_degrees": 10.0,
            "wave_period_seconds": 4.0,
            "current_speed_knots": 0.1,
            "current_direction_degrees": 20.0,
        },
    }


def _config(checkpoint_path: Path) -> dict[str, Any]:
    config = json.loads(BASE_CONFIG_PATH.read_text(encoding="utf-8"))
    checkpoint = json.loads(checkpoint_path.read_text(encoding="utf-8"))
    config["delta"] = 0.25
    config["ships"] = [{"performance": SHIP_PERFORMANCE}]
    config["environment_parameters"] = copy.deepcopy(checkpoint["environment_parameters"])
    config["environment_parameters"].update(
        {
            "domain_randomization": False,
            "randomize_evaluation": False,
            "merge_scene_obstacles": False,
            "generated_traffic_count": 0,
            "obstacle_position_jitter_m": 0.0,
            "obstacle_size_jitter_m": 0.0,
            "start_position_jitter_m": 0.0,
            "start_heading_jitter_degrees": 0.0,
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
        "dynamic_proximity_penalty": 1.0,
        "forward_motion_bonus": 0.0,
        "incomplete_mission_penalty": 0.0,
        "throttle_action_min": -0.35,
        "throttle_action_max": 1.0,
    }
    config["world"] = {"obstacles": {"rocks": [], "boxes": []}}
    return config


def _angle_error_degrees(actual: float, target: float) -> float:
    return abs((actual - target + 180.0) % 360.0 - 180.0)


def _berthing_gate(
    scenario: dict[str, Any],
    final_state: np.ndarray,
    route_goal_reached: bool,
) -> dict[str, Any]:
    evaluation = scenario["evaluation"]
    target = evaluation["berth_target"]
    x, z, heading, speed = map(float, final_state[:4])
    distance = math.hypot(x - float(target["x"]), z - float(target["z"]))
    heading_error = _angle_error_degrees(math.degrees(heading) % 360.0, float(target["heading_degrees"]))
    speed_knots = abs(speed) / 0.514444
    partial = {
        "route_goal_reached": route_goal_reached,
        "position_passed": distance <= float(evaluation["position_tolerance_m"]),
        "heading_passed": heading_error <= float(evaluation["heading_tolerance_degrees"]),
        "speed_passed": speed_knots <= float(evaluation["maximum_speed_knots"]),
        "sway_metric_available": False,
    }
    return {
        **partial,
        "berth_distance_m": distance,
        "heading_error_degrees": heading_error,
        "speed_knots": speed_knots,
        "maximum_sway_mps": float(evaluation["maximum_sway_mps"]),
        "full_mission_gate_passed": all(partial.values()),
        "boundary": (
            "Frozen cargo policies expose surge/yaw kinematics but no independent sway state; "
            "the berthing inertia gate therefore fails closed even if route arrival succeeds."
        ),
    }


def _unberthing_gate(
    scenario: dict[str, Any],
    final_state: np.ndarray,
    route_goal_reached: bool,
) -> dict[str, Any]:
    evaluation = scenario["evaluation"]
    spawn = scenario["spawn"]
    x, z, _heading, speed = map(float, final_state[:4])
    clear_distance = math.hypot(x - float(spawn["x"]), z - float(spawn["z"]))
    speed_knots = abs(speed) / 0.514444
    checks = {
        "route_goal_reached": route_goal_reached,
        "minimum_clear_distance_passed": clear_distance
        >= float(evaluation["minimum_clear_distance_m"]),
        "exit_speed_passed": speed_knots
        <= float(evaluation["maximum_exit_speed_knots"]),
    }
    return {
        **checks,
        "clear_distance_m": clear_distance,
        "speed_knots": speed_knots,
        "full_mission_gate_passed": all(checks.values()),
        "boundary": "Frozen-policy transfer checked against the configured route, clearance and exit-speed gates.",
    }


def _signed_heading_change(actual: float, initial: float) -> float:
    return (actual - initial + 180.0) % 360.0 - 180.0


def _encounter_gate(
    scenario_key: str,
    scenario: dict[str, Any],
    trajectory: list[dict[str, Any]],
    route_result: dict[str, Any],
) -> dict[str, Any]:
    evaluation = scenario["evaluation"]
    initial_heading = float(scenario["spawn"]["heading_degrees"])
    first_substantial: dict[str, Any] | None = None
    closest_sample: dict[str, Any] | None = None
    closest_distance = float("inf")
    lane_samples = 0
    lane_compliant = 0
    passed_ahead = False
    for sample in trajectory:
        heading_change = _signed_heading_change(
            float(sample.get("heading_degrees", initial_heading)), initial_heading
        )
        if first_substantial is None and abs(heading_change) >= 10.0:
            first_substantial = {
                "time_seconds": float(sample.get("time", 0.0)),
                "heading_change_degrees": heading_change,
                "side": "STARBOARD" if heading_change > 0.0 else "PORT",
            }
        distance = float(sample.get("nearest_clearance_meters", float("inf")))
        if bool(sample.get("nearest_is_dynamic", False)) and distance < closest_distance:
            closest_distance = distance
            closest_sample = sample
        if scenario_key == "narrow_channel_head_on":
            lane_samples += 1
            if float(sample.get("x", 0.0)) <= 0.0:
                lane_compliant += 1
        if scenario_key == "narrow_channel_overtaking":
            targets = sample.get("dynamic_obstacles", [])
            if targets:
                target = targets[0]
                target_heading = math.radians(
                    float(scenario["traffic"][0]["spawn"]["heading_degrees"])
                )
                forward_x, forward_z = math.sin(target_heading), math.cos(target_heading)
                along = (
                    (float(sample.get("x", 0.0)) - float(target["x"])) * forward_x
                    + (float(sample.get("z", 0.0)) - float(target["z"])) * forward_z
                )
                passed_ahead = passed_ahead or along >= 12.0
    first_action_starboard = (
        first_substantial is not None and first_substantial["side"] == "STARBOARD"
    )
    dynamic_traffic_observed = closest_sample is not None
    separation_passed = dynamic_traffic_observed and closest_distance >= float(
        evaluation["minimum_passing_distance_m"]
    )
    common = {
        "route_goal_reached": bool(route_result.get("goal_reached", False)),
        "collision_free": int(route_result.get("collisions", 0)) == 0,
        "dynamic_traffic_observed": dynamic_traffic_observed,
        "minimum_passing_distance_passed": separation_passed,
        "early_substantial_action_observed": first_substantial is not None,
        "first_substantial_action_starboard": first_action_starboard,
    }
    relation = "UNAVAILABLE"
    task_specific = True
    if scenario_key == "narrow_channel_head_on":
        ratio = lane_compliant / max(lane_samples, 1)
        task_specific = ratio >= 0.90
        common["starboard_lane_compliance_ratio"] = ratio
        common["starboard_lane_compliant"] = task_specific
    elif scenario_key == "crossing_starboard":
        passed_astern = False
        if closest_sample is not None:
            targets = closest_sample.get("dynamic_obstacles", [])
            if targets:
                target = targets[0]
                target_heading = math.radians(
                    float(scenario["traffic"][0]["spawn"]["heading_degrees"])
                )
                forward_x, forward_z = math.sin(target_heading), math.cos(target_heading)
                along = (
                    (float(closest_sample.get("x", 0.0)) - float(target["x"]))
                    * forward_x
                    + (float(closest_sample.get("z", 0.0)) - float(target["z"]))
                    * forward_z
                )
                passed_astern = along < 0.0
                relation = "ASTERN" if passed_astern else "AHEAD"
        task_specific = passed_astern
        common["closest_passing_relation"] = relation
        common["passed_astern"] = passed_astern
    else:
        # The test harness supplies the explicit simulated agreement receipt so
        # this run evaluates policy motion, not radio phraseology.
        common["overtaking_agreement_confirmed_by_test_harness"] = True
        common["passed_target_ahead"] = passed_ahead
        task_specific = passed_ahead
    passed = all(value is True for value in common.values()) and task_specific
    return {
        **common,
        "first_substantial_action": first_substantial,
        "minimum_dynamic_clearance_m": closest_distance if math.isfinite(closest_distance) else None,
        "full_mission_gate_passed": passed,
        "boundary": (
            "Deterministic frozen-policy transfer gate in the numeric simulator; "
            "not a certified COLREG judgement or Godot operator assessment."
        ),
    }


def _scenario_gate(
    scenario_key: str,
    scenario: dict[str, Any],
    final_state: np.ndarray,
    trajectory: list[dict[str, Any]],
    route_result: dict[str, Any],
) -> dict[str, Any]:
    route_goal_reached = bool(route_result.get("goal_reached", False))
    if scenario_key in ("open_water", "harbor"):
        checks = {
            "route_goal_reached": route_goal_reached,
            "collision_free": int(route_result.get("collisions", 0)) == 0,
        }
        return {
            **checks,
            "full_mission_gate_passed": all(checks.values()),
            "boundary": (
                "Frozen-policy route transfer gate in the numeric simulator; "
                "not a long-duration operator or field assessment."
            ),
        }
    if scenario_key == "auto_berthing":
        return _berthing_gate(scenario, final_state, route_goal_reached)
    if scenario_key == "auto_unberthing":
        return _unberthing_gate(scenario, final_state, route_goal_reached)
    return _encounter_gate(scenario_key, scenario, trajectory, route_result)


def _run_policy(
    *,
    scenario_key: str,
    policy_name: str,
    model: SAC,
    static_model: SAC,
    dynamic: bool,
    task: dict[str, Any],
    scenario: dict[str, Any],
    max_steps: int,
) -> dict[str, Any]:
    dataset = {"splits": {"train": [task], "validation": [task], "test": [task]}}
    config = _config(
        ROOT
        / (
            "reports/artifacts/cargo_circuit_dynamic_rl_v2/cargo_dynamic_policy_checkpoint.json"
            if dynamic
            else "reports/artifacts/cargo_circuit_rl_v1/cargo_policy_checkpoint.json"
        )
    )
    env = (CargoDynamicEnv if dynamic else CargoCircuitEnv)(
        config,
        dataset,
        split="test",
        discrete_actions=False,
        max_steps=max_steps,
        seed=260829,
        task_index=0,
        render_mode=None,
    )
    observation, info = env.reset(seed=260829)
    terminated = truncated = False
    total_reward = 0.0
    while not terminated and not truncated:
        policy_action, _ = model.predict(observation, deterministic=True)
        policy_action = np.asarray(policy_action, dtype=np.float32)
        if dynamic:
            base_action, _ = static_model.predict(observation[:36], deterministic=True)
            applied_action = np.clip(
                np.asarray(base_action, dtype=np.float32) + policy_action * np.asarray([2.0, 2.0], dtype=np.float32),
                -1.0,
                1.0,
            )
        else:
            base_action = None
            applied_action = policy_action
        observation, reward, terminated, truncated, info = env.step(applied_action)
        total_reward += float(reward)
        sample = env.trajectory[-1]
        sample["strategy"] = policy_name
        sample["raw_policy_action"] = [round(float(value), 6) for value in policy_action]
        if base_action is not None:
            sample["frozen_static_action"] = [round(float(value), 6) for value in base_action]
            sample["combined_action"] = [round(float(value), 6) for value in applied_action]
    final_state = env.state.copy()
    task_gate = _scenario_gate(
        scenario_key,
        scenario,
        final_state,
        env.trajectory,
        info,
    )
    artifact_dir = OUTPUT_ROOT / scenario_key
    artifact_dir.mkdir(parents=True, exist_ok=True)
    artifact_path = artifact_dir / f"{policy_name.lower().replace('-', '_')}_trajectory.json"
    result = {
        "schema_version": "advanced_mission_policy_transfer_v1",
        "scenario_key": scenario_key,
        "policy_name": policy_name,
        "trained_rl": True,
        "training_performed": False,
        "deterministic": True,
        "observation_size": int(model.observation_space.shape[0]),
        "action_size": int(model.action_space.shape[0]),
        "steps": int(env.steps),
        "elapsed_simulation_seconds": float(env.steps * env.delta),
        "reward": total_reward,
        "route_result": info,
        "task_gate": task_gate,
        "final_state": {
            "x": float(final_state[0]),
            "z": float(final_state[1]),
            "heading_degrees": float(math.degrees(final_state[2]) % 360.0),
            "speed_mps": float(final_state[3]),
            "throttle": float(final_state[4]),
            "rudder": float(final_state[5]),
        },
        "trajectory": env.trajectory,
        "claim_boundary": (
            "Zero-training out-of-distribution transfer baseline in the numeric simulator. "
            "Not evidence of berthing convergence, Godot three-DOF sway control, or field readiness."
        ),
    }
    artifact_path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return {**{key: value for key, value in result.items() if key != "trajectory"}, "artifact_path": str(artifact_path.relative_to(ROOT))}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", default="all")
    parser.add_argument("--max-steps", type=int, default=2400)
    args = parser.parse_args()
    # Avoid macOS BLAS thread-pool overhead for thousands of tiny policy calls.
    import torch

    torch.set_num_threads(1)
    try:
        torch.set_num_interop_threads(1)
    except RuntimeError:
        pass
    profile = json.loads(PROFILE_PATH.read_text(encoding="utf-8"))
    if args.scenario != "all" and args.scenario not in ALL_SCENARIOS:
        raise SystemExit(f"unknown scenario: {args.scenario}")
    before_hashes = {"SAC-S1": _sha256(STATIC_MODEL_PATH), "RES-SAC-D2": _sha256(DYNAMIC_MODEL_PATH)}
    static_model = SAC.load(STATIC_MODEL_PATH, device="cpu")
    dynamic_model = SAC.load(DYNAMIC_MODEL_PATH, device="cpu")
    scenario_keys = ALL_SCENARIOS if args.scenario == "all" else (args.scenario,)
    results: list[dict[str, Any]] = []
    for scenario_key in scenario_keys:
        task = _task(profile, scenario_key)
        scenario = profile["scenarios"][scenario_key]
        results.extend(
            [
                _run_policy(
                    scenario_key=scenario_key,
                    policy_name="SAC-S1",
                    model=static_model,
                    static_model=static_model,
                    dynamic=False,
                    task=task,
                    scenario=scenario,
                    max_steps=args.max_steps,
                ),
                _run_policy(
                    scenario_key=scenario_key,
                    policy_name="RES-SAC-D2",
                    model=dynamic_model,
                    static_model=static_model,
                    dynamic=True,
                    task=task,
                    scenario=scenario,
                    max_steps=args.max_steps,
                ),
            ]
        )
    after_hashes = {"SAC-S1": _sha256(STATIC_MODEL_PATH), "RES-SAC-D2": _sha256(DYNAMIC_MODEL_PATH)}
    summary = {
        "schema_version": "advanced_mission_existing_policy_baseline_v1",
        "scenario_key": args.scenario,
        "scenario_keys": list(scenario_keys),
        "policy_hashes_before": before_hashes,
        "policy_hashes_after": after_hashes,
        "policies_byte_identical": before_hashes == after_hashes,
        "results": results,
        "completed_transfer_count": sum(
            bool(item["task_gate"]["full_mission_gate_passed"]) for item in results
        ),
        "total_transfer_count": len(results),
        "observation_dimensions_tested": sorted(
            {int(item["observation_size"]) for item in results}
        ),
        "dimension_47_used": False,
        "claim_boundary": (
            "The frozen 36D and 44D cargo policies were actually loaded and executed without training. "
            "Transfer failure is an admissible result and does not invalidate simulator task feasibility."
        ),
    }
    SUMMARY_PATH.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(
        "ADVANCED_POLICY_BASELINE:%s:%s"
        % (
            args.scenario,
            ",".join(
                f"{item['policy_name']}={'PASS' if item['task_gate']['full_mission_gate_passed'] else 'FAIL'}"
                for item in results
            ),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
