"""Dynamic-traffic extension of the frozen static cargo circuit."""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any, Dict, Mapping, Tuple

import numpy as np
from gymnasium import spaces

from .environment import CARGO_OBSERVATION_SIZE, CargoCircuitEnv


DYNAMIC_OBSERVATION_SIZE = 44


class CargoDynamicEnv(CargoCircuitEnv):
    """Adds a dedicated relative-motion sensor without changing ship physics."""

    def __init__(self, experiment_config: Mapping[str, Any], *args: Any, **kwargs: Any) -> None:
        super().__init__(experiment_config, *args, **kwargs)
        # ShipNavigationEnv keeps a shallow task list; isolate overlays so the
        # immutable source dataset and its SHA-256 never change during a run.
        self.tasks = json.loads(json.dumps(self.tasks))
        scenarios = experiment_config.get("dynamic_scenarios", {})
        split_overlays = scenarios.get(self.split, []) if isinstance(scenarios, Mapping) else []
        overlays_by_base_id = {
            str(item.get("base_task_id", "")): item
            for item in split_overlays
            if isinstance(item, Mapping)
        }
        for task in self.tasks:
            overlay = overlays_by_base_id.get(str(task.get("id", "")))
            if overlay is None:
                continue
            task["base_task_id"] = task.get("id")
            task["id"] = str(overlay.get("id", f"{task.get('id', 'cargo')}::dynamic"))
            task["dynamic_obstacles"] = list(overlay.get("dynamic_obstacles", []))
        self.observation_space = spaces.Box(
            low=-1.0,
            high=1.0,
            shape=(DYNAMIC_OBSERVATION_SIZE,),
            dtype=np.float32,
        )

    def _observation(self) -> np.ndarray:
        base = super()._observation()
        nearest = self._nearest_dynamic_obstacle(True)
        sensor_range = float(self.environment_config["sensor_range_m"])
        horizon = float(self.environment_config["tcpa_horizon_seconds"])
        max_speed = max(self.performance.max_forward_speed, 0.1)
        features = np.asarray(
            [
                np.clip(float(nearest["clearance"]) / sensor_range, -1.0, 1.0),
                math.sin(float(nearest["bearing"])),
                math.cos(float(nearest["bearing"])),
                np.clip(float(nearest["closing_speed"]) / max_speed, -1.0, 1.0),
                np.clip(float(nearest["tcpa"]) / horizon, 0.0, 1.0),
                np.clip(float(nearest["dcpa"]) / sensor_range, 0.0, 1.0),
                np.clip(float(nearest["relative_lateral_speed"]) / max_speed, -1.0, 1.0),
                np.clip(float(nearest["relative_forward_speed"]) / max_speed, -1.0, 1.0),
            ],
            dtype=np.float32,
        )
        return np.concatenate((base, features), dtype=np.float32)

    def _info(self, terminated: bool, truncated: bool, goal_reached: bool) -> Dict[str, Any]:
        info = super()._info(terminated, truncated, goal_reached)
        info.update(
            {
                "module": "cargo_circuit_dynamic_rl",
                "observation_size": DYNAMIC_OBSERVATION_SIZE,
                "dynamic_obstacle_count": sum(1 for obstacle in self.obstacles if obstacle.dynamic),
            }
        )
        return info


class CargoDynamicResidualEnv(CargoDynamicEnv):
    """Residual SAC action layered on the frozen, accepted static SAC policy."""

    def __init__(self, experiment_config: Mapping[str, Any], *args: Any, **kwargs: Any) -> None:
        super().__init__(experiment_config, *args, **kwargs)
        cargo = experiment_config.get("cargo_parameters", {})
        self.residual_throttle_scale = float(cargo.get("residual_throttle_scale", 0.45))
        self.residual_rudder_scale = float(cargo.get("residual_rudder_scale", 0.60))
        self.residual_action_penalty = float(cargo.get("residual_action_penalty", 0.0))
        raw_path = str(cargo.get("frozen_static_policy_path", ""))
        if not raw_path:
            raise ValueError("dynamic residual environment requires frozen_static_policy_path")
        project_root = Path(__file__).resolve().parents[2]
        if raw_path.startswith("res://"):
            policy_path = project_root / raw_path.removeprefix("res://")
        else:
            policy_path = Path(raw_path).expanduser()
            if not policy_path.is_absolute():
                policy_path = project_root / policy_path
        if not policy_path.exists():
            raise FileNotFoundError(f"frozen static SAC policy not found: {policy_path}")
        from stable_baselines3 import SAC

        self.frozen_static_policy_path = policy_path.resolve()
        self.frozen_static_policy = SAC.load(self.frozen_static_policy_path, device="auto")
        self.last_base_action = np.zeros(2, dtype=np.float32)
        self.last_residual_action = np.zeros(2, dtype=np.float32)

    def residual_for_combined(self, combined_action: np.ndarray) -> np.ndarray:
        observation = self._observation()
        base_action, _state = self.frozen_static_policy.predict(observation[:CARGO_OBSERVATION_SIZE], deterministic=True)
        scales = np.asarray([self.residual_throttle_scale, self.residual_rudder_scale], dtype=np.float32)
        return np.clip((np.asarray(combined_action, dtype=np.float32) - base_action) / scales, -1.0, 1.0)

    def step(self, action: Any) -> Tuple[np.ndarray, float, bool, bool, Dict[str, Any]]:
        residual = np.clip(np.asarray(action, dtype=np.float32), -1.0, 1.0)
        observation = self._observation()
        base_action, _state = self.frozen_static_policy.predict(observation[:CARGO_OBSERVATION_SIZE], deterministic=True)
        combined = np.clip(
            np.asarray(base_action, dtype=np.float32)
            + np.asarray(
                [self.residual_throttle_scale * residual[0], self.residual_rudder_scale * residual[1]],
                dtype=np.float32,
            ),
            -1.0,
            1.0,
        )
        self.last_base_action[:] = base_action
        self.last_residual_action[:] = residual
        observation, reward, terminated, truncated, info = super().step(combined)
        residual_penalty = self.residual_action_penalty * float(np.dot(residual, residual))
        if residual_penalty > 0.0:
            reward -= residual_penalty
            self.total_reward -= residual_penalty
        if self.trajectory:
            self.trajectory[-1]["reward"] = round(float(reward), 6)
            self.trajectory[-1].update(
                {
                    "frozen_static_throttle_action": round(float(base_action[0]), 5),
                    "frozen_static_rudder_action": round(float(base_action[1]), 5),
                    "dynamic_residual_throttle_action": round(float(residual[0]), 5),
                    "dynamic_residual_rudder_action": round(float(residual[1]), 5),
                }
            )
        return observation, float(reward), terminated, truncated, info
