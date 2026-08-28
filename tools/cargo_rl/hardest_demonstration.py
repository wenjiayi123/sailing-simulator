"""Current-map expert initialization for the V3 hardest cargo task.

This module is intentionally separate from the frozen V1 demonstration source.
The expert is used only for train-split feasibility, behavior cloning, and
replay-buffer seeding.  It is never callable by validation or test policies.
"""

from __future__ import annotations

import math
import hashlib
import json
from pathlib import Path
from typing import Any, Dict, List, Mapping, Sequence, Tuple

import numpy as np

from .environment import CargoCircuitEnv
from .hardest_environment import CargoHardestV3Env


Point = Tuple[float, float]
ROOT = Path(__file__).resolve().parents[2]
EXPERT_CACHE = ROOT / "reports/artifacts/cargo_circuit_hardest_v3/expert_demonstrations_v3.npz"


def _wrap(angle: float) -> float:
    return (angle + math.pi) % (2.0 * math.pi) - math.pi


def task_manual_targets(env: CargoCircuitEnv) -> List[Tuple[Point, str]]:
    raw_bypasses = env.task.get("manual_bypasses", [[] for _point in env.route])
    if len(raw_bypasses) != len(env.route):
        raise ValueError("V3 manual bypass contract must contain one entry per route leg")
    targets: List[Tuple[Point, str]] = []
    for raw_leg, checkpoint in zip(raw_bypasses, env.route):
        for point in raw_leg:
            targets.append(((float(point["x"]), float(point["z"])), "manual_bypass"))
        targets.append((checkpoint, "ordered_checkpoint"))
    return targets


def hardest_manual_helm(
    env: CargoCircuitEnv,
    target: Point,
    previous_command_rudder: float,
) -> Tuple[List[float], float, Dict[str, float]]:
    x, z, heading, speed, _throttle, _rudder = env.state
    dx, dz = target[0] - x, target[1] - z
    distance = math.hypot(dx, dz)
    heading_error = _wrap(math.atan2(dx, dz) - heading)

    nearest_dynamic = env._nearest_dynamic_obstacle(False)
    static_clearance = float("inf")
    for obstacle in env.obstacles:
        if obstacle.dynamic:
            continue
        clearance, _bearing, _target_x, _target_z = env._obstacle_distance(obstacle)
        static_clearance = min(static_clearance, float(clearance))
    boundary_clearance = float(env._boundary_clearance())
    constrained_waterway = static_clearance < 62.0 or boundary_clearance < 62.0
    dynamic_conflict = bool(
        nearest_dynamic["present"]
        and float(nearest_dynamic["clearance"]) < 95.0
        and float(nearest_dynamic["tcpa"]) < 60.0
        and float(nearest_dynamic["dcpa"]) < 46.0
    )
    avoidance_bias = 0.0
    if dynamic_conflict and not constrained_waterway:
        relative_bearing = float(nearest_dynamic["bearing"])
        bearing_sign = 1.0 if relative_bearing >= 0.0 else -1.0
        urgency = max(
            0.0,
            min(1.0, (95.0 - float(nearest_dynamic["clearance"])) / 75.0),
        )
        avoidance_bias = -bearing_sign * math.radians(46.0) * (0.40 + 0.60 * urgency)

    requested_rudder = max(
        -1.0,
        min(1.0, (heading_error + avoidance_bias) / math.radians(32.0)),
    )
    command_slew = 0.55 * env.delta
    rudder_command = max(
        previous_command_rudder - command_slew,
        min(previous_command_rudder + command_slew, requested_rudder),
    )
    absolute_error = abs(heading_error)
    if absolute_error > math.radians(65.0) and abs(speed) > 1.0:
        throttle_command = -0.35
    elif absolute_error > math.radians(50.0):
        throttle_command = 0.10
    elif absolute_error > math.radians(32.0):
        throttle_command = 0.28
    elif absolute_error > math.radians(18.0):
        throttle_command = 0.44
    else:
        throttle_command = 0.62
    if distance < 28.0:
        throttle_command = min(throttle_command, 0.30)
    if dynamic_conflict:
        # Yielding must not become an unintended astern crossing.  The old
        # command kept reverse thrust applied after the vessel had stopped,
        # which made a stationary start back into crossing traffic.  Brake
        # only while making meaningful headway, hold neutral around zero, and
        # use a small ahead command solely to arrest accidental sternway.
        if speed > 0.35:
            throttle_command = -0.35
        elif speed < -0.10:
            throttle_command = 0.30
        else:
            throttle_command = 0.0
    elif bool(nearest_dynamic["present"]) and float(nearest_dynamic["clearance"]) < 28.0:
        throttle_command = -0.35
        bearing_sign = 1.0 if float(nearest_dynamic["bearing"]) >= 0.0 else -1.0
        rudder_command = -bearing_sign
    return [throttle_command, rudder_command], rudder_command, {
        "distance": distance,
        "heading_error_degrees": math.degrees(heading_error),
        "dynamic_conflict": float(dynamic_conflict),
        "dynamic_clearance_meters": float(nearest_dynamic["clearance"]),
        "dynamic_tcpa_seconds": float(nearest_dynamic["tcpa"]),
        "dynamic_dcpa_meters": float(nearest_dynamic["dcpa"]),
        "avoidance_bias_degrees": math.degrees(avoidance_bias),
        "static_clearance_meters": static_clearance,
        "boundary_clearance_meters": boundary_clearance,
        "constrained_waterway": float(constrained_waterway),
    }


def collect_hardest_training_demonstrations(
    config: Dict[str, Any],
    dataset: Dict[str, Any],
    seed: int,
    max_steps: int | None = None,
    fail_fast: bool = False,
) -> Dict[str, Any]:
    """Collect successful direct 44D SAC actions on every V3 train task."""
    repetitions = 3
    contract = {
        "format": "cargo_circuit_hardest_expert_cache_v3",
        "dataset_sha256": hashlib.sha256(
            json.dumps(dataset, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest(),
        "experiment_sha256": hashlib.sha256(
            json.dumps(config, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest(),
        "collector_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "seed": seed,
        "repetitions_per_train_task": repetitions,
    }
    if EXPERT_CACHE.exists():
        cached = np.load(EXPERT_CACHE, allow_pickle=False)
        cached_contract = json.loads(str(cached["contract"].item()))
        if cached_contract == contract:
            return {
                "observations": cached["observations"],
                "next_observations": cached["next_observations"],
                "actions": cached["actions"],
                "rewards": cached["rewards"],
                "dones": cached["dones"],
                "episodes": int(cached["episodes"].item()),
                "successes": int(cached["successes"].item()),
            }
    observations: List[np.ndarray] = []
    next_observations: List[np.ndarray] = []
    actions: List[np.ndarray] = []
    rewards: List[float] = []
    dones: List[bool] = []
    successes = 0
    cargo = config.get("cargo_parameters", {})
    throttle_min = float(cargo.get("throttle_action_min", -0.35))
    throttle_max = float(cargo.get("throttle_action_max", 1.0))
    if max_steps is None:
        limits = cargo.get("curriculum_max_steps", [5200])
        max_steps = max(int(value) for value in limits)
    task_count = len(dataset["splits"]["train"])
    for repetition in range(repetitions):
        for task_index in range(task_count):
            env = CargoHardestV3Env(
                config,
                dataset,
                split="train",
                discrete_actions=False,
                max_steps=max_steps,
                seed=seed + repetition * 100 + task_index,
                task_index=task_index,
                render_mode=None,
            )
            observation, _info = env.reset(options={"task_index": task_index})
            targets = task_manual_targets(env)
            target_index = 0
            previous_rudder = 0.0
            terminated = truncated = False
            info: Mapping[str, Any] = {}
            while not (terminated or truncated):
                target, target_kind = targets[target_index]
                distance = math.hypot(target[0] - env.state[0], target[1] - env.state[1])
                arrival = 12.0 if target_kind == "manual_bypass" else 16.0
                if distance < arrival and target_index < len(targets) - 1:
                    target_index += 1
                    target, _target_kind = targets[target_index]
                physical_action, previous_rudder, _helm = hardest_manual_helm(
                    env, target, previous_rudder
                )
                normalized_throttle = 2.0 * (
                    (physical_action[0] - throttle_min) / max(throttle_max - throttle_min, 1e-6)
                ) - 1.0
                action = np.asarray(
                    [np.clip(normalized_throttle, -1.0, 1.0), physical_action[1]],
                    dtype=np.float32,
                )
                next_observation, reward, terminated, truncated, info = env.step(action)
                observations.append(np.asarray(observation, dtype=np.float32))
                next_observations.append(np.asarray(next_observation, dtype=np.float32))
                actions.append(action)
                rewards.append(float(reward))
                dones.append(bool(terminated or truncated))
                observation = next_observation
            successes += int(bool(info.get("is_success", False)))
            env.close()
            print(
                "expert rollout "
                f"{repetition * task_count + task_index + 1}/{task_count * repetitions}: "
                f"{'passed' if bool(info.get('is_success', False)) else 'failed'}",
                flush=True,
            )
            if fail_fast and not bool(info.get("is_success", False)):
                raise ValueError(
                    "SAC-P47 full-circuit expert gate failed fast: "
                    + json.dumps(
                        {
                            "task_id": str(info.get("task_id", task_index)),
                            "task_index": task_index,
                            "repetition": repetition,
                            "steps": int(env.steps),
                            "max_steps": int(env.max_steps),
                            "collisions": int(info.get("collisions", 0)),
                            "terrain_collisions": int(info.get("terrain_collisions", 0)),
                            "checkpoints_passed": int(info.get("checkpoints_passed", 0)),
                            "total_checkpoints": int(info.get("total_checkpoints", 0)),
                            "minimum_clearance_meters": float(
                                info.get("minimum_clearance_meters", 0.0)
                            ),
                            "minimum_dynamic_clearance_meters": float(
                                info.get("minimum_dynamic_clearance_meters", 0.0)
                            ),
                            "last_collision": dict(getattr(env, "last_collision", {})),
                        },
                        ensure_ascii=False,
                        sort_keys=True,
                    )
                )
    expected_successes = task_count * repetitions
    if successes != expected_successes:
        raise ValueError(
            f"V3 expert initialization became stale: {successes}/{expected_successes} train rollouts succeeded"
        )
    result = {
        "observations": np.asarray(observations, dtype=np.float32),
        "next_observations": np.asarray(next_observations, dtype=np.float32),
        "actions": np.asarray(actions, dtype=np.float32),
        "rewards": np.asarray(rewards, dtype=np.float32),
        "dones": np.asarray(dones, dtype=np.float32),
        "episodes": expected_successes,
        "successes": successes,
    }
    EXPERT_CACHE.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        EXPERT_CACHE,
        contract=np.asarray(json.dumps(contract, sort_keys=True)),
        observations=result["observations"],
        next_observations=result["next_observations"],
        actions=result["actions"],
        rewards=result["rewards"],
        dones=result["dones"],
        episodes=np.asarray(result["episodes"]),
        successes=np.asarray(result["successes"]),
    )
    return result
