"""Headless continuous-control environment for the independent cargo circuit.

The module deliberately reuses the project's validated vessel integration and
collision geometry, but owns its observation contract, reward, mission metrics,
and artifacts.  No Godot renderer is imported during training or evaluation.
"""

from __future__ import annotations

import math
import hashlib
import json
from typing import Any, Dict, Mapping, Sequence, Tuple

import numpy as np
from gymnasium import spaces

try:
    from ship_rl.environment import ShipNavigationEnv
except ModuleNotFoundError:  # package import from repository root
    from tools.ship_rl.environment import ShipNavigationEnv


CARGO_OBSERVATION_SIZE = 36


def cargo_experiment_fingerprint(config: Mapping[str, Any]) -> str:
    """Hash every cargo-specific contract that changes learned behavior."""
    relevant = {
        "schema_version": config.get("schema_version"),
        "delta": config.get("delta"),
        "dataset": config.get("dataset"),
        "algorithm_decision": config.get("algorithm_decision"),
        "demonstration_initialization": config.get("demonstration_initialization"),
        "cargo_parameters": config.get("cargo_parameters"),
        "rl_parameters": config.get("rl_parameters"),
        "environment_parameters": config.get("environment_parameters"),
        "ships": config.get("ships"),
        "world": config.get("world"),
    }
    if "dynamic_scenarios" in config:
        relevant["dynamic_scenarios"] = config.get("dynamic_scenarios")
    canonical = json.dumps(relevant, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


class CargoCircuitEnv(ShipNavigationEnv):
    """Continuous ship-control task with ordered checkpoints and floating cliffs."""

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        self.curriculum_route_length = kwargs.pop("curriculum_route_length", None)
        self.curriculum_obstacles_enabled = bool(kwargs.pop("curriculum_obstacles_enabled", True))
        self.curriculum_randomization_enabled = bool(kwargs.pop("curriculum_randomization_enabled", True))
        self.curriculum_random_segment = bool(kwargs.pop("curriculum_random_segment", False))
        self.physical_action_input = bool(kwargs.pop("physical_action_input", False))
        if bool(kwargs.get("discrete_actions", False)):
            raise ValueError("cargo circuit supports continuous throttle/rudder actions only")
        super().__init__(*args, **kwargs)
        self.observation_space = spaces.Box(
            low=-1.0,
            high=1.0,
            shape=(CARGO_OBSERVATION_SIZE,),
            dtype=np.float32,
        )
        cargo = self.config.get("cargo_parameters", {})
        self.checkpoint_bonus = float(cargo.get("checkpoint_bonus", 14.0))
        self.destination_bonus = float(cargo.get("destination_bonus", 90.0))
        self.reverse_penalty = float(cargo.get("reverse_penalty", 0.12))
        self.overspeed_penalty = float(cargo.get("overspeed_penalty", 0.18))
        self.boundary_proximity_penalty = float(cargo.get("boundary_proximity_penalty", 1.5))
        self.boundary_warning_distance = float(cargo.get("boundary_warning_distance_m", 30.0))
        self.safe_speed_ratio = float(cargo.get("safe_speed_ratio", 0.72))
        self.throttle_action_min = float(cargo.get("throttle_action_min", -0.35))
        self.throttle_action_max = float(cargo.get("throttle_action_max", 1.0))
        self.dynamic_safe_distance = float(cargo.get("dynamic_safe_distance_m", self.reward_config["safe_distance"]))
        self.dynamic_proximity_penalty = float(cargo.get("dynamic_proximity_penalty", 0.0))
        self.forward_motion_bonus = float(cargo.get("forward_motion_bonus", 0.0))
        self.incomplete_mission_penalty = float(cargo.get("incomplete_mission_penalty", 0.0))
        self.minimum_dynamic_clearance = float("inf")

    def _nearest_dynamic_obstacle(self, sensor_limited: bool) -> Dict[str, Any]:
        sensor_range = float(self.environment_config["sensor_range_m"])
        nearest: Dict[str, Any] = {
            "present": False,
            "clearance": sensor_range if sensor_limited else 9999.0,
            "bearing": 0.0,
            "name": "none",
            "closing_speed": 0.0,
            "tcpa": float(self.environment_config["tcpa_horizon_seconds"]),
            "dcpa": sensor_range,
            "relative_lateral_speed": 0.0,
            "relative_forward_speed": 0.0,
        }
        heading = float(self.state[2])
        ship_velocity = np.asarray(
            [math.sin(heading) * self.state[3], math.cos(heading) * self.state[3]],
            dtype=np.float64,
        )
        right = np.asarray([math.cos(heading), -math.sin(heading)], dtype=np.float64)
        forward = np.asarray([math.sin(heading), math.cos(heading)], dtype=np.float64)
        for obstacle in self.obstacles:
            if not obstacle.dynamic:
                continue
            clearance, bearing, target_x, target_z = self._obstacle_distance(obstacle)
            if sensor_limited and clearance > sensor_range:
                continue
            if clearance >= float(nearest["clearance"]):
                continue
            closing, tcpa, dcpa = self._relative_motion(obstacle, target_x, target_z)
            relative_velocity = np.asarray([obstacle.vx, obstacle.vz], dtype=np.float64) - ship_velocity
            nearest = {
                "present": True,
                "clearance": clearance,
                "bearing": bearing,
                "name": obstacle.name,
                "closing_speed": closing,
                "tcpa": tcpa,
                "dcpa": dcpa,
                "relative_lateral_speed": float(np.dot(relative_velocity, right)),
                "relative_forward_speed": float(np.dot(relative_velocity, forward)),
            }
        return nearest

    def _randomization_active(self) -> bool:
        return self.curriculum_randomization_enabled and super()._randomization_active()

    def reset(
        self,
        *,
        seed: int | None = None,
        options: Dict[str, Any] | None = None,
    ) -> Tuple[np.ndarray, Dict[str, Any]]:
        self.minimum_dynamic_clearance = float("inf")
        observation, info = super().reset(seed=seed, options=options)
        route_changed = False
        if self.curriculum_random_segment:
            full_route = list(self.route)
            segment_index = int(self.rng.integers(len(full_route)))
            segment_length = max(
                1,
                min(int(self.curriculum_route_length or 1), len(full_route)),
            )
            original_start = self._point_tuple(self.task.get("start", {}))
            segment_start = original_start if segment_index == 0 else full_route[segment_index - 1]
            segment_target = full_route[segment_index]
            heading = math.atan2(
                segment_target[0] - segment_start[0],
                segment_target[1] - segment_start[1],
            )
            if self._randomization_active():
                start_jitter = float(self.environment_config["start_position_jitter_m"])
                heading += math.radians(
                    float(
                        self.rng.uniform(
                            -float(self.environment_config["start_heading_jitter_degrees"]),
                            float(self.environment_config["start_heading_jitter_degrees"]),
                        )
                    )
                )
            else:
                start_jitter = 0.0
            self.task["start"] = {
                "x": segment_start[0],
                "z": segment_start[1],
                "heading_degrees": math.degrees(heading),
            }
            self.task["id"] = (
                f"{self.task.get('id', 'cargo')}::segment_{segment_index + 1}"
                f"_length_{segment_length}"
            )
            # Sample a contiguous sub-route on the closed circuit.  This teaches
            # checkpoint-to-checkpoint transitions at every heading instead of
            # only resetting directly in front of one rock.
            self.route = [
                full_route[(segment_index + offset) % len(full_route)]
                for offset in range(segment_length)
            ]
            self.state[:] = (
                segment_start[0] + float(self.rng.uniform(-start_jitter, start_jitter)),
                segment_start[1] + float(self.rng.uniform(-start_jitter, start_jitter)),
                heading,
                0.0,
                0.0,
                0.0,
            )
            self.waypoint_index = 0
            nearest = self._nearest_obstacle(False)
            self.minimum_clearance = float(nearest["clearance"])
            route_changed = True
        elif self.curriculum_route_length is not None:
            limit = max(1, min(int(self.curriculum_route_length), len(self.route)))
            if limit < len(self.route):
                self.route = self.route[:limit]
                route_changed = True
        obstacles_changed = False
        if not self.curriculum_obstacles_enabled and self.obstacles:
            self.obstacles = []
            self.minimum_clearance = float("inf")
            obstacles_changed = True
        if not route_changed and not obstacles_changed:
            return observation, info
        # Rebuild the initial sample so its waypoint/checkpoint metadata matches
        # the active curriculum phase rather than the full mission.
        self.trajectory = []
        self._record_sample((0.0, 0.0), 0.0, False)
        return self._observation(), self._info(False, False, False)

    def _observation(self) -> np.ndarray:
        base = super()._observation()
        x, z, heading, speed, _throttle, rudder = self.state
        target_index = min(self.waypoint_index, len(self.route) - 1)
        next_index = min(target_index + 1, len(self.route) - 1)
        target = self.route[target_index]
        next_target = self.route[next_index]
        boundary = max(float(self.task.get("boundary_half_extent", 260.0)), 1.0)
        sensor_range = float(self.environment_config["sensor_range_m"])

        next_dx = next_target[0] - x
        next_dz = next_target[1] - z
        next_distance = math.hypot(next_dx, next_dz)
        next_bearing = self._wrap(math.atan2(next_dx, next_dz) - heading)

        inbound = math.atan2(target[0] - x, target[1] - z)
        outbound = math.atan2(next_target[0] - target[0], next_target[1] - target[1])
        turn_angle = self._wrap(outbound - inbound) if next_index != target_index else 0.0

        max_speed = max(self.performance.max_forward_speed, 0.1)
        speed_ratio = float(np.clip(abs(speed) / max_speed, 0.0, 1.0))
        turn_authority = self.performance.low_speed_turn_factor + (
            1.0 - self.performance.low_speed_turn_factor
        ) * speed_ratio
        yaw_rate = rudder * math.radians(self.performance.max_turn_rate_degrees) * turn_authority
        stopping_distance = (speed * speed) / max(2.0 * self.performance.brake_acceleration, 0.1)
        max_yaw_rate = max(math.radians(self.performance.max_turn_rate_degrees), 1e-6)
        turn_radius = abs(speed) / max(max_yaw_rate * max(turn_authority, 0.05), 1e-6)
        target_distance = max(math.hypot(target[0] - x, target[1] - z), 1.0)

        lookahead = np.asarray(
            [
                np.clip(next_distance / (boundary * 2.0), 0.0, 1.0),
                math.sin(next_bearing),
                math.cos(next_bearing),
                math.sin(turn_angle),
                math.cos(turn_angle),
                np.clip(yaw_rate / max_yaw_rate, -1.0, 1.0),
                np.clip(stopping_distance / sensor_range, 0.0, 1.0),
                np.clip(turn_radius / target_distance, 0.0, 1.0),
            ],
            dtype=np.float32,
        )
        return np.concatenate((base, lookahead), dtype=np.float32)

    def step(self, action: Any) -> Tuple[np.ndarray, float, bool, bool, Dict[str, Any]]:
        policy_action = np.clip(np.asarray(action, dtype=np.float32), -1.0, 1.0)
        command = policy_action.copy()
        if not self.physical_action_input:
            command[0] = self.throttle_action_min + (float(policy_action[0]) + 1.0) * 0.5 * (
                self.throttle_action_max - self.throttle_action_min
            )
        action_slew = float(np.sum(np.abs(policy_action - self.previous_action)))
        previous = self.state[:2].copy()
        previous_distance = self._distance_to_target()
        self._advance_dynamic_obstacles()
        self._integrate(float(command[0]), float(command[1]))
        self.steps += 1
        distance = self._distance_to_target()
        collision, boundary, collision_obstacle = self._collision_status()
        collision_event = collision and not self.collision_active
        if collision_event:
            self.collision_count += 1
            if collision_obstacle and collision_obstacle.kind in ("cliff", "terrain", "shoreline"):
                self.terrain_collision_count += 1
            self.last_collision = {
                "name": collision_obstacle.name if collision_obstacle else "navigation_boundary",
                "kind": collision_obstacle.kind if collision_obstacle else "boundary",
                "step": self.steps,
            }
        self.collision_active = collision
        if collision:
            self.state[3] *= 0.25

        nearest = self._nearest_obstacle(False)
        clearance = float(nearest["clearance"])
        self.minimum_clearance = min(self.minimum_clearance, clearance)
        nearest_dynamic = self._nearest_dynamic_obstacle(False)
        if bool(nearest_dynamic["present"]):
            dynamic_clearance = float(nearest_dynamic["clearance"])
            self.minimum_dynamic_clearance = min(self.minimum_dynamic_clearance, dynamic_clearance)
            self.minimum_dcpa = min(self.minimum_dcpa, float(nearest_dynamic["dcpa"]))
        else:
            dynamic_clearance = float("inf")
        cross_track = self._cross_track_error()
        self.max_cross_track_error = max(self.max_cross_track_error, abs(cross_track))
        self.path_length += float(np.linalg.norm(self.state[:2] - previous))

        safe_distance = max(self.reward_config["safe_distance"], 1.0)
        predicted_dynamic_conflict = bool(
            nearest_dynamic["present"]
            and float(nearest_dynamic["tcpa"]) < float(self.environment_config["tcpa_horizon_seconds"])
            and float(nearest_dynamic["dcpa"]) < self.dynamic_safe_distance
        )
        near_miss = (
            0.0 < clearance < safe_distance
            or 0.0 < dynamic_clearance < self.dynamic_safe_distance
            or predicted_dynamic_conflict
        )
        if near_miss and not self.near_miss_active:
            self.near_miss_count += 1
        self.near_miss_active = near_miss

        reached_waypoint = distance <= float(self.task.get("arrival_radius", 13.0))
        goal_reached = False
        if reached_waypoint:
            if self.waypoint_index >= len(self.route) - 1:
                goal_reached = True
            else:
                self.waypoint_index += 1
        terminated = goal_reached or (
            collision and bool(self.environment_config["terminate_on_collision"])
        )
        truncated = self.steps >= self.max_steps and not terminated

        heading_error = abs(self._heading_error())
        speed_ratio = abs(self.state[3]) / max(self.performance.max_forward_speed, 0.1)
        clearance_ratio = float(np.clip(clearance / safe_distance, 0.0, 1.0))
        turn_demand = min(1.0, heading_error / math.radians(70.0))
        desired_speed_ratio = self.safe_speed_ratio * (0.55 + 0.45 * clearance_ratio) * (
            1.0 - 0.35 * turn_demand
        )

        reward = (previous_distance - distance) * self.reward_config["progress"]
        reward += math.cos(heading_error) * self.reward_config["heading"] * 0.018
        reward += max(0.0, 1.0 - abs(speed_ratio - desired_speed_ratio)) * self.reward_config["speed"] * 0.012
        if self.state[3] > 0.0:
            reward += self.forward_motion_bonus * min(
                self.state[3] / max(self.performance.max_forward_speed, 0.1), 1.0
            )
        reward -= abs(self.state[5]) * self.reward_config["rudder"] * 0.006
        reward -= min(abs(cross_track) / safe_distance, 3.0) * self.reward_config["cross_track"]
        reward -= action_slew * self.reward_config["action_slew"]
        reward -= self.reward_config["step"]
        if self.state[3] < -0.05:
            reward -= self.reverse_penalty * min(abs(self.state[3]) / max(self.performance.max_reverse_speed, 0.1), 1.0)
        if speed_ratio > desired_speed_ratio:
            reward -= (speed_ratio - desired_speed_ratio) * self.overspeed_penalty
        if clearance < safe_distance:
            danger = (safe_distance - clearance) / safe_distance
            reward -= danger * danger * self.reward_config["proximity"]
        if dynamic_clearance < self.dynamic_safe_distance:
            danger = (self.dynamic_safe_distance - dynamic_clearance) / max(self.dynamic_safe_distance, 1.0)
            reward -= danger * danger * self.dynamic_proximity_penalty
        if predicted_dynamic_conflict:
            horizon = float(self.environment_config["tcpa_horizon_seconds"])
            dcpa_factor = (self.dynamic_safe_distance - float(nearest_dynamic["dcpa"])) / max(
                self.dynamic_safe_distance, 1.0
            )
            urgency = 1.0 - float(nearest_dynamic["tcpa"]) / max(horizon, 1.0)
            reward -= max(0.0, dcpa_factor) * max(0.0, urgency) * self.reward_config["predicted_collision"]
        boundary_clearance = self._boundary_clearance()
        if boundary_clearance < self.boundary_warning_distance:
            boundary_danger = (
                self.boundary_warning_distance - boundary_clearance
            ) / max(self.boundary_warning_distance, 1.0)
            reward -= boundary_danger * boundary_danger * self.boundary_proximity_penalty
        if collision_event:
            if boundary:
                reward -= self.reward_config["boundary"]
            elif collision_obstacle and collision_obstacle.kind in ("cliff", "terrain", "shoreline"):
                reward -= self.reward_config["terrain_collision"]
            else:
                reward -= self.reward_config["collision"]
        if reached_waypoint:
            reward += self.destination_bonus if goal_reached else self.checkpoint_bonus
        if truncated:
            remaining_ratio = (len(self.route) - self.waypoint_index) / max(len(self.route), 1)
            reward -= self.incomplete_mission_penalty * (0.5 + 0.5 * remaining_ratio)

        self.total_reward += reward
        self.previous_action[:] = policy_action
        self._record_sample(command, reward, collision)
        self.trajectory[-1]["policy_throttle_action"] = round(float(policy_action[0]), 5)
        self.trajectory[-1]["policy_rudder_action"] = round(float(policy_action[1]), 5)
        info = self._info(terminated, truncated, goal_reached)
        if terminated or truncated:
            info["episode"] = {"r": round(self.total_reward, 6), "l": self.steps}
        return self._observation(), float(reward), terminated, truncated, info

    def _info(self, terminated: bool, truncated: bool, goal_reached: bool) -> Dict[str, Any]:
        info = super()._info(terminated, truncated, goal_reached)
        total_checkpoints = max(len(self.route) - 1, 0)
        passed = min(self.waypoint_index, total_checkpoints)
        info.update(
            {
                "module": "cargo_circuit_rl",
                "observation_size": CARGO_OBSERVATION_SIZE,
                "checkpoints_passed": passed,
                "total_checkpoints": total_checkpoints,
                "checkpoint_completion_ratio": passed / max(total_checkpoints, 1),
                "cargo_retrieved": bool(goal_reached),
                "is_success": bool(goal_reached and self.collision_count == 0),
                "minimum_dynamic_clearance_meters": (
                    self.minimum_dynamic_clearance
                    if math.isfinite(self.minimum_dynamic_clearance)
                    else float(self.environment_config["sensor_range_m"])
                ),
            }
        )
        return info

    def _record_sample(self, command: Sequence[float], reward: float, collision: bool) -> None:
        super()._record_sample(command, reward, collision)
        sample = self.trajectory[-1]
        speed_ratio = float(np.clip(abs(self.state[3]) / max(self.performance.max_forward_speed, 0.1), 0.0, 1.0))
        authority = self.performance.low_speed_turn_factor + (
            1.0 - self.performance.low_speed_turn_factor
        ) * speed_ratio
        sample.update(
            {
                "actual_throttle": round(float(self.state[4]), 5),
                "actual_rudder": round(float(self.state[5]), 5),
                "yaw_rate_degrees_per_second": round(
                    float(self.state[5]) * self.performance.max_turn_rate_degrees * authority,
                    5,
                ),
                "checkpoints_passed": min(self.waypoint_index, max(len(self.route) - 1, 0)),
                "total_checkpoints": max(len(self.route) - 1, 0),
            }
        )

    @staticmethod
    def _wrap(angle: float) -> float:
        return (angle + math.pi) % (2.0 * math.pi) - math.pi
