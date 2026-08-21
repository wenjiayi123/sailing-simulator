"""Human-authored demonstrations used only to initialize the SAC learner.

The bypass points are never appended to the RL observation or evaluation route.
They produce transparent expert state/action samples; the released policy still
executes only its neural network on the sparse checkpoint observation.
"""

from __future__ import annotations

import math
from typing import Any, Dict, List, Mapping, Sequence, Tuple

import numpy as np

from .environment import CargoCircuitEnv


Point = Tuple[float, float]

MANUAL_BYPASSES: Sequence[Sequence[Point]] = (
    ((-130.0, -15.0),),
    ((-75.0, 80.0),),
    ((10.0, 125.0),),
    ((75.0, 65.0),),
    ((140.0, 55.0), (120.0, -25.0)),
    ((200.0, -160.0), (150.0, -215.0)),
    ((0.0, -125.0),),
    ((-170.0, -205.0), (-205.0, -170.0)),
)


def _wrap(angle: float) -> float:
    return (angle + math.pi) % (2.0 * math.pi) - math.pi


def manual_targets(route: Sequence[Point]) -> List[Tuple[Point, str]]:
    targets: List[Tuple[Point, str]] = []
    for bypasses, checkpoint in zip(MANUAL_BYPASSES, route):
        targets.extend((point, "manual_bypass") for point in bypasses)
        targets.append((checkpoint, "ordered_checkpoint"))
    return targets


def manual_helm(
    env: CargoCircuitEnv,
    target: Point,
    previous_command_rudder: float,
) -> Tuple[List[float], float, Dict[str, float]]:
    x, z, heading, speed, _throttle, _rudder = env.state
    dx, dz = target[0] - x, target[1] - z
    distance = math.hypot(dx, dz)
    heading_error = _wrap(math.atan2(dx, dz) - heading)
    requested_rudder = max(-1.0, min(1.0, heading_error / math.radians(32.0)))
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
    return [throttle_command, rudder_command], rudder_command, {
        "distance": distance,
        "heading_error_degrees": math.degrees(heading_error),
    }


def collect_training_demonstrations(
    config: Dict[str, Any],
    dataset: Dict[str, Any],
    seed: int,
    episodes_per_task: int = 1,
    max_steps: int = 3600,
) -> Dict[str, Any]:
    observations: List[np.ndarray] = []
    next_observations: List[np.ndarray] = []
    actions: List[np.ndarray] = []
    rewards: List[float] = []
    dones: List[bool] = []
    successes = 0
    task_count = len(dataset["splits"]["train"])
    cargo = config.get("cargo_parameters", {})
    throttle_min = float(cargo.get("throttle_action_min", -0.35))
    throttle_max = float(cargo.get("throttle_action_max", 1.0))
    for repetition in range(max(1, episodes_per_task)):
        for task_index in range(task_count):
            env = CargoCircuitEnv(
                config,
                dataset,
                split="train",
                discrete_actions=False,
                max_steps=max_steps,
                seed=seed + repetition * 100 + task_index,
                task_index=task_index,
                render_mode=None,
                physical_action_input=False,
            )
            observation, _info = env.reset(options={"task_index": task_index})
            targets = manual_targets(env.route)
            target_index = 0
            previous_rudder = 0.0
            terminated = truncated = False
            info: Mapping[str, Any] = {}
            while not (terminated or truncated):
                target, target_kind = targets[target_index]
                distance = math.hypot(target[0] - env.state[0], target[1] - env.state[1])
                arrival = 10.0 if target_kind == "manual_bypass" else 12.0
                if distance < arrival and target_index < len(targets) - 1:
                    target_index += 1
                    target, _target_kind = targets[target_index]
                physical_action, previous_rudder, _helm = manual_helm(env, target, previous_rudder)
                normalized_throttle = 2.0 * (
                    (physical_action[0] - throttle_min) / max(throttle_max - throttle_min, 1e-6)
                ) - 1.0
                policy_action = np.asarray(
                    [np.clip(normalized_throttle, -1.0, 1.0), physical_action[1]],
                    dtype=np.float32,
                )
                next_observation, reward, terminated, truncated, info = env.step(policy_action)
                observations.append(np.asarray(observation, dtype=np.float32))
                next_observations.append(np.asarray(next_observation, dtype=np.float32))
                actions.append(policy_action)
                rewards.append(float(reward))
                dones.append(bool(terminated or truncated))
                observation = next_observation
            successes += int(bool(info.get("is_success", False)))
            env.close()
    return {
        "observations": np.asarray(observations, dtype=np.float32),
        "next_observations": np.asarray(next_observations, dtype=np.float32),
        "actions": np.asarray(actions, dtype=np.float32),
        "rewards": np.asarray(rewards, dtype=np.float32),
        "dones": np.asarray(dones, dtype=np.float32),
        "episodes": max(1, episodes_per_task) * task_count,
        "successes": successes,
    }


def collect_dynamic_training_demonstrations(
    config: Dict[str, Any],
    dataset: Dict[str, Any],
    seed: int,
    max_steps: int = 4000,
) -> Dict[str, Any]:
    """Collect successful 44D dynamic transitions for replay seeding only."""
    from .dynamic_environment import CargoDynamicEnv, CargoDynamicResidualEnv

    observations: List[np.ndarray] = []
    next_observations: List[np.ndarray] = []
    actions: List[np.ndarray] = []
    rewards: List[float] = []
    dones: List[bool] = []
    successes = 0
    cargo = config.get("cargo_parameters", {})
    throttle_min = float(cargo.get("throttle_action_min", -0.35))
    throttle_max = float(cargo.get("throttle_action_max", 1.0))
    task_count = len(dataset["splits"]["train"])
    for task_index in range(task_count):
        environment_class = (
            CargoDynamicResidualEnv
            if bool(config.get("cargo_parameters", {}).get("residual_policy", False))
            else CargoDynamicEnv
        )
        env = environment_class(
            config,
            dataset,
            split="train",
            discrete_actions=False,
            max_steps=max_steps,
            seed=seed,
            task_index=task_index,
            render_mode=None,
            physical_action_input=False,
        )
        observation, _info = env.reset(options={"task_index": task_index})
        targets = manual_targets(env.route)
        target_index = 0
        previous_rudder = 0.0
        terminated = truncated = False
        info: Mapping[str, Any] = {}
        while not (terminated or truncated):
            target, target_kind = targets[target_index]
            distance = math.hypot(target[0] - env.state[0], target[1] - env.state[1])
            arrival = 10.0 if target_kind == "manual_bypass" else 12.0
            if distance < arrival and target_index < len(targets) - 1:
                target_index += 1
                target, _target_kind = targets[target_index]
            physical_action, previous_rudder, _helm = manual_helm(env, target, previous_rudder)
            normalized_throttle = 2.0 * (
                (physical_action[0] - throttle_min) / max(throttle_max - throttle_min, 1e-6)
            ) - 1.0
            policy_action = np.asarray(
                [np.clip(normalized_throttle, -1.0, 1.0), physical_action[1]],
                dtype=np.float32,
            )
            environment_action = (
                env.residual_for_combined(policy_action)
                if hasattr(env, "residual_for_combined")
                else policy_action
            )
            next_observation, reward, terminated, truncated, info = env.step(environment_action)
            observations.append(np.asarray(observation, dtype=np.float32))
            next_observations.append(np.asarray(next_observation, dtype=np.float32))
            actions.append(np.asarray(environment_action, dtype=np.float32))
            rewards.append(float(reward))
            dones.append(bool(terminated or truncated))
            observation = next_observation
        successes += int(bool(info.get("is_success", False)))
        env.close()
    return {
        "observations": np.asarray(observations, dtype=np.float32),
        "next_observations": np.asarray(next_observations, dtype=np.float32),
        "actions": np.asarray(actions, dtype=np.float32),
        "rewards": np.asarray(rewards, dtype=np.float32),
        "dones": np.asarray(dones, dtype=np.float32),
        "episodes": task_count,
        "successes": successes,
    }
