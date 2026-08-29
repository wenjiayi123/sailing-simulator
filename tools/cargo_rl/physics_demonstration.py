"""Physics-aware train-only helm labels for the SAC-P47 strategy."""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
from typing import Any, Dict, List, Mapping, Tuple

import numpy as np

from .environment import CargoCircuitEnv
from .hardest_demonstration import hardest_manual_helm as _base_hardest_manual_helm


ROOT = Path(__file__).resolve().parents[2]
SEGMENT_EXPERT_CACHE = ROOT / "reports/artifacts/cargo_circuit_physics_v4/expert_demonstrations_segments_v4.npz"


def physics_manual_helm(
    env: CargoCircuitEnv,
    target: Tuple[float, float],
    previous_command_rudder: float,
) -> Tuple[list[float], float, Dict[str, float]]:
    """Add a low-speed escape manoeuvre when crossing traffic keeps closing.

    The original helm correctly brakes while yielding, but a stopped vessel can
    still be struck by a moving target.  When the vessel is nearly stopped and
    the measured TCPA/DCPA remain unsafe, command modest ahead thrust and slew
    the rudder away from the target bearing.  Only observations available in
    the 47D state are used; no hidden route bypass is exposed at inference.
    """

    physical_action, rudder_command, helm = _base_hardest_manual_helm(
        env,
        target,
        previous_command_rudder,
    )
    nearest = env._nearest_dynamic_obstacle(False)
    speed = float(env.state[3])
    configured_safe_distance = float(
        env.config.get("cargo_parameters", {}).get("dynamic_safe_distance_m", 30.0)
    )
    escape_latch_distance = max(18.0, configured_safe_distance)
    escape_release_distance = max(34.0, escape_latch_distance + 10.0)
    inside_emergency_separation = bool(
        nearest.get("present", False)
        and float(nearest.get("clearance", 9999.0)) < escape_latch_distance
    )
    predicted_close_approach = bool(
        float(nearest.get("tcpa", 9999.0)) < 35.0
        and float(nearest.get("dcpa", 9999.0)) < 18.0
    )
    escape_latched = bool(
        getattr(env, "_physics_expert_dynamic_escape_active", False)
    )
    if inside_emergency_separation:
        escape_latched = True
    elif (
        not bool(nearest.get("present", False))
        or float(nearest.get("clearance", 9999.0)) >= escape_release_distance
    ):
        escape_latched = False
    setattr(env, "_physics_expert_dynamic_escape_active", escape_latched)
    escape_required = bool(
        nearest.get("present", False)
        and float(nearest.get("clearance", 9999.0)) < escape_release_distance
        and (
            escape_latched
            or (abs(speed) <= 0.35 and predicted_close_approach)
        )
    )
    if escape_required:
        bearing_sign = 1.0 if float(nearest["bearing"]) >= 0.0 else -1.0
        requested_rudder = -bearing_sign
        command_slew = 0.75 * env.delta
        rudder_command = max(
            previous_command_rudder - command_slew,
            min(previous_command_rudder + command_slew, requested_rudder),
        )
        # Enough thrust to create lateral separation through the waterjet, but
        # far below cruise command so this does not become an aggressive crossing.
        physical_action = [0.22 if speed >= -0.10 else 0.32, rudder_command]
    # The 47D actor must learn that vessel inertia changes the safe throttle,
    # not merely imitate a car-like steering command at full ahead.  Label a
    # lower positive thrust when the observable boundary/terrain corridor is
    # narrow, and reduce it further when sway, yaw or drift are already high.
    # This remains train-only supervision: the released neural actor receives
    # the same 47D observation and has no expert or coordinate fallback.
    sway_mps = abs(float(getattr(env, "_physics_status", {}).get("sway_mps", 0.0)))
    yaw_rate_deg_s = abs(
        float(getattr(env, "_physics_status", {}).get("yaw_rate_deg_s", 0.0))
    )
    surge_mps = float(getattr(env, "_physics_status", {}).get("surge_mps", speed))
    drift_degrees = math.degrees(math.atan2(sway_mps, max(abs(surge_mps), 0.1)))
    static_clearance = float(helm.get("static_clearance_meters", 9999.0))
    boundary_clearance = float(helm.get("boundary_clearance_meters", 9999.0))
    inertia_throttle_cap = 0.55
    constrained_inertia_waterway = static_clearance < 58.0 or boundary_clearance < 75.0
    if constrained_inertia_waterway:
        inertia_throttle_cap = 0.35
        if sway_mps > 0.72 or yaw_rate_deg_s > 11.0 or drift_degrees > 9.0:
            inertia_throttle_cap = 0.28
    if physical_action[0] > 0.0:
        physical_action = [min(float(physical_action[0]), inertia_throttle_cap), rudder_command]
    helm = dict(helm)
    helm["low_speed_dynamic_escape"] = float(escape_required)
    helm["dynamic_escape_latched"] = float(escape_latched)
    helm["escape_clearance_meters"] = float(nearest.get("clearance", 9999.0))
    helm["escape_latch_distance_meters"] = float(escape_latch_distance)
    helm["escape_release_distance_meters"] = float(escape_release_distance)
    helm["escape_tcpa_seconds"] = float(nearest.get("tcpa", 9999.0))
    helm["escape_dcpa_meters"] = float(nearest.get("dcpa", 9999.0))
    helm["inertia_throttle_cap"] = float(inertia_throttle_cap)
    helm["constrained_inertia_waterway"] = float(constrained_inertia_waterway)
    helm["inertia_sway_mps"] = float(sway_mps)
    helm["inertia_yaw_rate_degrees_per_second"] = float(yaw_rate_deg_s)
    helm["inertia_drift_degrees"] = float(drift_degrees)
    return physical_action, rudder_command, helm


def collect_physics_training_demonstrations(
    config: Dict[str, Any],
    dataset: Dict[str, Any],
    seed: int,
    max_steps: int = 5200,
) -> Dict[str, Any]:
    """Combine full-circuit expert rollouts with every zero-speed segment start."""

    from .hardest_demonstration import collect_hardest_training_demonstrations
    from .physics_environment import CargoPhysicsV4Env, PHYSICS_OBSERVATION_SIZE

    full = collect_hardest_training_demonstrations(
        config,
        dataset,
        seed=seed,
        max_steps=max_steps,
        fail_fast=True,
    )
    relevant = json.loads(json.dumps(config))
    cargo_for_hash = relevant.get("cargo_parameters", {})
    cargo_for_hash.pop("difficulty_ladder", None)
    cargo_for_hash.pop("difficulty_promotion_gate", None)
    curriculum_lengths = (1, 2)
    contract = {
        "format": "cargo_circuit_physics_segment_expert_cache_v4",
        "dataset_sha256": hashlib.sha256(
            json.dumps(dataset, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest(),
        "rollout_config_sha256": hashlib.sha256(
            json.dumps(relevant, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest(),
        "collector_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "seed": seed,
        "segments": 8,
        "curriculum_route_lengths": list(curriculum_lengths),
        "train_tasks": len(dataset["splits"]["train"]),
    }
    if SEGMENT_EXPERT_CACHE.exists():
        cached = np.load(SEGMENT_EXPERT_CACHE, allow_pickle=False)
        if json.loads(str(cached["contract"].item())) == contract:
            segment = {
                "observations": cached["observations"],
                "next_observations": cached["next_observations"],
                "actions": cached["actions"],
                "rewards": cached["rewards"],
                "dones": cached["dones"],
                "episodes": int(cached["episodes"].item()),
                "successes": int(cached["successes"].item()),
            }
            return _merge_demonstrations(full, segment)

    observations: List[np.ndarray] = []
    next_observations: List[np.ndarray] = []
    actions: List[np.ndarray] = []
    rewards: List[float] = []
    dones: List[bool] = []
    successes = 0
    tasks = dataset["splits"]["train"]
    throttle_min = float(config["cargo_parameters"].get("throttle_action_min", -0.35))
    throttle_max = float(config["cargo_parameters"].get("throttle_action_max", 1.0))
    episode_index = 0
    for task_index, task in enumerate(tasks):
        raw_bypasses = task.get("manual_bypasses", [[] for _point in task.get("route", [])])
        route_count = len(task.get("route", []))
        for route_length in curriculum_lengths:
            for segment_index in range(route_count):
                episode_index += 1
                env = CargoPhysicsV4Env(
                    config,
                    dataset,
                    split="train",
                    discrete_actions=False,
                    max_steps=4000 if route_length == 2 else 2600,
                    seed=(
                        seed
                        + 20000
                        + route_length * 10000
                        + task_index * 100
                        + segment_index
                    ),
                    task_index=task_index,
                    render_mode=None,
                    curriculum_route_length=route_length,
                    curriculum_obstacles_enabled=True,
                    curriculum_randomization_enabled=True,
                    curriculum_random_segment=True,
                    curriculum_segment_index=segment_index,
                )
                observation, _info = env.reset(options={"task_index": task_index})
                targets: List[Tuple[Tuple[float, float], str]] = []
                for offset, checkpoint in enumerate(env.route):
                    leg_index = (segment_index + offset) % route_count
                    targets.extend(
                        (
                            (float(point["x"]), float(point["z"])),
                            "manual_bypass",
                        )
                        for point in raw_bypasses[leg_index]
                    )
                    targets.append((checkpoint, "ordered_checkpoint"))
                target_index = 0
                previous_rudder = 0.0
                terminated = truncated = False
                info: Mapping[str, Any] = {}
                while not (terminated or truncated):
                    target, target_kind = targets[target_index]
                    distance = float(np.linalg.norm(np.asarray(target) - env.state[:2]))
                    arrival = 12.0 if target_kind == "manual_bypass" else 16.0
                    if distance < arrival and target_index < len(targets) - 1:
                        target_index += 1
                        target, _target_kind = targets[target_index]
                    physical_action, previous_rudder, _helm = physics_manual_helm(
                        env,
                        target,
                        previous_rudder,
                    )
                    normalized_throttle = 2.0 * (
                        (physical_action[0] - throttle_min)
                        / max(throttle_max - throttle_min, 1e-6)
                    ) - 1.0
                    action = np.asarray(
                        [np.clip(normalized_throttle, -1.0, 1.0), physical_action[1]],
                        dtype=np.float32,
                    )
                    following, reward, terminated, truncated, info = env.step(action)
                    observations.append(np.asarray(observation, dtype=np.float32))
                    next_observations.append(np.asarray(following, dtype=np.float32))
                    actions.append(action)
                    rewards.append(float(reward))
                    dones.append(bool(terminated or truncated))
                    observation = following
                success = bool(info.get("is_success", False))
                successes += int(success)
                failure_context = {
                    "task_id": str(info.get("task_id", env.task.get("id", task_index))),
                    "task_index": task_index,
                    "segment_index": segment_index,
                    "route_length": route_length,
                    "steps": int(env.steps),
                    "max_steps": int(env.max_steps),
                    "collisions": int(info.get("collisions", 0)),
                    "terrain_collisions": int(info.get("terrain_collisions", 0)),
                    "minimum_clearance_meters": float(
                        info.get("minimum_clearance_meters", 0.0)
                    ),
                    "minimum_dynamic_clearance_meters": float(
                        info.get("minimum_dynamic_clearance_meters", 0.0)
                    ),
                    "boundary_clearance_meters": float(env._boundary_clearance()),
                    "distance_to_target_meters": float(
                        np.linalg.norm(np.asarray(env.route[-1]) - env.state[:2])
                    ),
                    "large_rock_count": 32,
                    "dynamic_traffic_count": sum(item.dynamic for item in env.obstacles),
                    "last_collision": dict(getattr(env, "last_collision", {})),
                }
                env.close()
                print(
                    "curriculum expert rollout "
                    f"{episode_index}/{len(tasks) * 8 * len(curriculum_lengths)} "
                    f"length={route_length}: "
                    f"{'passed' if success else 'failed'}",
                    flush=True,
                )
                if not success:
                    raise ValueError(
                        "SAC-P47 curriculum expert gate failed fast: "
                        + json.dumps(failure_context, ensure_ascii=False, sort_keys=True)
                    )
    expected = len(tasks) * 8 * len(curriculum_lengths)
    if successes != expected:
        raise ValueError(f"SAC-P47 segment expert gate failed: {successes}/{expected}")
    segment = {
        "observations": np.asarray(observations, dtype=np.float32),
        "next_observations": np.asarray(next_observations, dtype=np.float32),
        "actions": np.asarray(actions, dtype=np.float32),
        "rewards": np.asarray(rewards, dtype=np.float32),
        "dones": np.asarray(dones, dtype=np.float32),
        "episodes": expected,
        "successes": successes,
    }
    if segment["observations"].shape[1] != PHYSICS_OBSERVATION_SIZE:
        raise ValueError("SAC-P47 segment expert observation size mismatch")
    SEGMENT_EXPERT_CACHE.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        SEGMENT_EXPERT_CACHE,
        contract=np.asarray(json.dumps(contract, sort_keys=True)),
        **{key: value for key, value in segment.items()},
    )
    return _merge_demonstrations(full, segment)


def _merge_demonstrations(full: Mapping[str, Any], segment: Mapping[str, Any]) -> Dict[str, Any]:
    return {
        "observations": np.concatenate((full["observations"], segment["observations"]), axis=0),
        "next_observations": np.concatenate((full["next_observations"], segment["next_observations"]), axis=0),
        "actions": np.concatenate((full["actions"], segment["actions"]), axis=0),
        "rewards": np.concatenate((full["rewards"], segment["rewards"]), axis=0),
        "dones": np.concatenate((full["dones"], segment["dones"]), axis=0),
        "episodes": int(full["episodes"]) + int(segment["episodes"]),
        "successes": int(full["successes"]) + int(segment["successes"]),
    }
