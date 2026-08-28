"""47-dimensional current-map cargo environment with Godot-matched inertia."""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any, Dict, Mapping, Tuple

import numpy as np
from gymnasium import spaces

from .catamaran_physics import TwinWaterjetCatamaran, canonical_sha256
from .dynamic_environment import CargoDynamicEnv
from .hardest_environment import CargoHardestV3Env


PHYSICS_OBSERVATION_SIZE = 47
PHYSICS_OBSERVATION_CONTRACT = "cargo_circuit_physics_v4_continuous_47d"
PHYSICS_MODEL_FAMILY = "3DOF_surge_sway_yaw_twin_waterjet_RK4"


class CargoPhysicsV4Env(CargoHardestV3Env):
    """Keeps all 32 rocks and six traffic vessels while adding vessel inertia."""

    def __init__(self, experiment_config: Mapping[str, Any], *args: Any, **kwargs: Any) -> None:
        self.curriculum_segment_index = kwargs.pop("curriculum_segment_index", None)
        self._physics: TwinWaterjetCatamaran | None = None
        self._physics_status: Dict[str, Any] = {}
        self._physics_path, self._physics_sha256 = self._resolve_physics_contract(experiment_config)
        self._physics_config = json.loads(self._physics_path.read_text(encoding="utf-8"))
        super().__init__(experiment_config, *args, **kwargs)
        self.observation_space = spaces.Box(
            low=-1.0,
            high=1.0,
            shape=(PHYSICS_OBSERVATION_SIZE,),
            dtype=np.float32,
        )

    @staticmethod
    def _resolve_physics_contract(experiment_config: Mapping[str, Any]) -> Tuple[Path, str]:
        world = experiment_config.get("world", {})
        contract = world.get("dynamics_contract", {}) if isinstance(world, Mapping) else {}
        raw_path = str(contract.get("path", ""))
        expected_sha = str(contract.get("sha256", ""))
        if not raw_path or not expected_sha:
            raise ValueError("physics V4 requires world.dynamics_contract path and sha256")
        project_root = Path(__file__).resolve().parents[2]
        path = project_root / raw_path.removeprefix("res://") if raw_path.startswith("res://") else Path(raw_path)
        path = path.expanduser().resolve()
        actual_sha = canonical_sha256(path)
        if actual_sha != expected_sha:
            raise ValueError(
                f"Godot/Python vessel dynamics mismatch: expected {expected_sha}, got {actual_sha}"
            )
        payload = json.loads(path.read_text(encoding="utf-8"))
        if str(payload.get("model_id", "")) != str(contract.get("model_id", "")):
            raise ValueError("Godot/Python vessel dynamics model_id mismatch")
        if int(contract.get("runtime_physics_hz", 0)) != 60:
            raise ValueError("physics V4 requires the Godot 60 Hz runtime contract")
        return path, actual_sha

    def reset(self, *args: Any, **kwargs: Any):
        forced_segment = self.curriculum_segment_index
        if forced_segment is not None and self.curriculum_random_segment:
            route_length = self.curriculum_route_length
            random_segment = self.curriculum_random_segment
            self.curriculum_route_length = None
            self.curriculum_random_segment = False
            try:
                _observation, info = super().reset(*args, **kwargs)
            finally:
                self.curriculum_route_length = route_length
                self.curriculum_random_segment = random_segment
            self._apply_forced_segment(int(forced_segment), int(route_length or 1))
        else:
            _observation, info = super().reset(*args, **kwargs)
        self._physics = TwinWaterjetCatamaran(self._physics_config)
        self._physics.reset(float(self.state[2]), float(self.state[3]))
        self._sync_from_physics(self._forcing())
        self.trajectory = []
        self._record_sample((0.0, 0.0), 0.0, False)
        return self._observation(), self._physics_info(info)

    def _apply_forced_segment(self, segment_index: int, segment_length: int) -> None:
        full_route = [self._point_tuple(point) for point in self.task.get("route", [])]
        if not full_route:
            raise ValueError("forced SAC-P47 segment requires a non-empty route")
        index = segment_index % len(full_route)
        length = max(1, min(segment_length, len(full_route)))
        original_start = self._point_tuple(self.task.get("start", {}))
        segment_start = original_start if index == 0 else full_route[index - 1]
        segment_target = full_route[index]
        heading = math.atan2(
            segment_target[0] - segment_start[0],
            segment_target[1] - segment_start[1],
        )
        start_jitter = 0.0
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
        self.task["start"] = {
            "x": segment_start[0],
            "z": segment_start[1],
            "heading_degrees": math.degrees(heading),
        }
        self.task["id"] = (
            f"{self.task.get('id', 'cargo')}::segment_{index + 1}_length_{length}"
        )
        self.route = [full_route[(index + offset) % len(full_route)] for offset in range(length)]
        self.state[:] = (
            segment_start[0] + float(self.rng.uniform(-start_jitter, start_jitter)),
            segment_start[1] + float(self.rng.uniform(-start_jitter, start_jitter)),
            heading,
            0.0,
            0.0,
            0.0,
        )
        self.waypoint_index = 0
        self.minimum_clearance = float(self._nearest_obstacle(False)["clearance"])

    def _build_obstacles(self, randomize: bool):
        records = super()._build_obstacles(randomize)
        required_dynamic = int(self.environment_config["generated_traffic_count"])
        present_dynamic = sum(1 for obstacle in records if obstacle.dynamic)
        if present_dynamic < required_dynamic:
            existing_names = {obstacle.name for obstacle in records}
            for obstacle in self._generated_traffic(records):
                if obstacle.name in existing_names:
                    continue
                records.append(obstacle)
                existing_names.add(obstacle.name)
                present_dynamic += 1
                if present_dynamic >= required_dynamic:
                    break
        return records

    def _integrate(self, throttle_command: float, rudder_command: float) -> None:
        if self._physics is None:
            self._physics = TwinWaterjetCatamaran(self._physics_config)
            self._physics.reset(float(self.state[2]), float(self.state[3]))
        runtime_hz = int(self.config["world"]["dynamics_contract"]["runtime_physics_hz"])
        frame_count = max(1, int(round(self.delta * runtime_hz)))
        frame_delta = self.delta / float(frame_count)
        for _ in range(frame_count):
            forcing = self._forcing()
            self._physics_status = self._physics.step(
                throttle_command,
                rudder_command,
                frame_delta,
                forcing,
            )
            velocity = self._physics_status["ground_velocity"]
            self.state[0] += float(velocity[0]) * frame_delta
            self.state[1] += float(velocity[1]) * frame_delta
        self._sync_from_physics(self._forcing())

    def _sync_from_physics(self, forcing: Mapping[str, float]) -> None:
        if self._physics is None:
            return
        self._physics_status = self._physics.status(forcing)
        self.state[2] = float(self._physics_status["heading_rad"])
        self.state[3] = float(self._physics_status["surge_mps"])
        self.state[4] = 0.5 * (
            float(self._physics_status["port_throttle"])
            + float(self._physics_status["starboard_throttle"])
        )
        maximum_steering = max(float(self._physics_config["max_steering_angle_deg"]), 0.1)
        self.state[5] = float(np.clip(float(self._physics_status["steering_angle_deg"]) / maximum_steering, -1.0, 1.0))

    def _forcing(self) -> Dict[str, float]:
        heading = float(self._physics.heading_rad if self._physics is not None else self.state[2])
        wind_speed = float(self.sea_state.get("wind_speed_knots", 0.0)) * 0.514444
        wind_direction = math.radians(float(self.sea_state.get("wind_direction_degrees", 0.0)))
        wind_magnitude = (
            0.5
            * float(self._physics_config.get("air_density_kg_m3", 1.225))
            * float(self._physics_config.get("wind_drag_coefficient", 1.0))
            * float(self._physics_config.get("wind_lateral_area_m2", 1.0))
            * wind_speed
            * wind_speed
        )
        wave_height = float(self.sea_state.get("wave_height_meters", 0.0))
        wave_direction = math.radians(
            float(self.sea_state.get("wave_direction_degrees", self.sea_state.get("wind_direction_degrees", 0.0)))
        )
        wave_period = max(float(self.sea_state.get("wave_period_seconds", 6.0)), 1.0)
        simulation_time = float(self._physics.simulation_time_s if self._physics is not None else 0.0)
        wave_phase = math.sin(simulation_time * math.tau / wave_period)
        wave_magnitude = (
            float(self._physics_config.get("wave_drift_force_n_per_meter", 0.0))
            * wave_height
            * (0.65 + 0.35 * wave_phase)
        )
        wind_body = self._world_force_to_body(wind_magnitude, wind_direction, heading)
        wave_body = self._world_force_to_body(wave_magnitude, wave_direction, heading)
        current_speed = float(self.sea_state.get("current_speed_knots", 0.0)) * 0.514444
        current_direction = math.radians(float(self.sea_state.get("current_direction_degrees", 0.0)))
        yaw_arm = float(self._physics_config.get("environment_yaw_arm_m", 0.0))
        return {
            "current_east_mps": math.sin(current_direction) * current_speed,
            "current_north_mps": math.cos(current_direction) * current_speed,
            "wind_force_body_x_n": wind_body[0],
            "wind_force_body_y_n": wind_body[1],
            "wave_force_body_x_n": wave_body[0],
            "wave_force_body_y_n": wave_body[1],
            "environment_yaw_moment_nm": (wind_body[1] + wave_body[1]) * yaw_arm,
        }

    @staticmethod
    def _world_force_to_body(magnitude: float, direction: float, heading: float) -> Tuple[float, float]:
        world = np.asarray([math.sin(direction) * magnitude, math.cos(direction) * magnitude])
        forward = np.asarray([math.sin(heading), math.cos(heading)])
        starboard = np.asarray([math.cos(heading), -math.sin(heading)])
        return float(np.dot(world, forward)), float(np.dot(world, starboard))

    def _ship_ground_velocity(self) -> np.ndarray:
        if self._physics_status:
            return np.asarray(self._physics_status["ground_velocity"], dtype=np.float64)
        return np.asarray(
            [math.sin(float(self.state[2])) * float(self.state[3]), math.cos(float(self.state[2])) * float(self.state[3])]
        )

    def _relative_motion(self, obstacle, target_x: float, target_z: float):
        relative = np.asarray([target_x - self.state[0], target_z - self.state[1]], dtype=np.float64)
        relative_velocity = np.asarray([obstacle.vx, obstacle.vz], dtype=np.float64) - self._ship_ground_velocity()
        distance = float(np.linalg.norm(relative))
        closing = -float(np.dot(relative / max(distance, 1e-6), relative_velocity))
        speed_squared = float(np.dot(relative_velocity, relative_velocity))
        horizon = float(self.environment_config["tcpa_horizon_seconds"])
        raw_tcpa = (
            -float(np.dot(relative, relative_velocity)) / speed_squared
            if speed_squared > 1e-8
            else horizon
        )
        # Consumers use ``tcpa < horizon`` as the predicted-conflict gate.  A
        # conventional clamp would turn a receding contact into TCPA=0 and
        # therefore report an immediate collision risk forever.  Represent
        # contacts whose closest point is now/in the past with the explicit
        # "no conflict inside the prediction horizon" sentinel instead.
        tcpa = horizon if raw_tcpa <= 0.0 else float(np.clip(raw_tcpa, 0.0, horizon))
        closest = relative + relative_velocity * tcpa
        dcpa = float(np.linalg.norm(closest))
        if obstacle.shape == "circle":
            dcpa -= obstacle.radius + self._obstacle_inflation(obstacle)
        return closing, tcpa, max(0.0, dcpa)

    def _nearest_dynamic_obstacle(self, sensor_limited: bool):
        nearest = super()._nearest_dynamic_obstacle(sensor_limited)
        if not bool(nearest.get("present", False)):
            return nearest
        heading = float(self.state[2])
        right = np.asarray([math.cos(heading), -math.sin(heading)])
        forward = np.asarray([math.sin(heading), math.cos(heading)])
        obstacle = next((item for item in self.obstacles if item.name == nearest["name"]), None)
        if obstacle is not None:
            relative_velocity = np.asarray([obstacle.vx, obstacle.vz]) - self._ship_ground_velocity()
            nearest["relative_lateral_speed"] = float(np.dot(relative_velocity, right))
            nearest["relative_forward_speed"] = float(np.dot(relative_velocity, forward))
        return nearest

    def _observation(self) -> np.ndarray:
        base = CargoDynamicEnv._observation(self)
        sway = float(self._physics_status.get("sway_mps", 0.0))
        yaw_rate = float(self._physics_status.get("yaw_rate_radps", 0.0))
        ground = self._ship_ground_velocity()
        water_speed = math.hypot(
            float(self._physics_status.get("surge_mps", self.state[3])), sway
        )
        course = math.atan2(float(ground[0]), float(ground[1])) if np.dot(ground, ground) > 0.001 else float(self.state[2])
        drift = (float(self.state[2]) - course + math.pi) % (2.0 * math.pi) - math.pi if water_speed >= 0.75 else 0.0
        features = np.asarray(
            [
                np.clip(sway / 4.0, -1.0, 1.0),
                np.clip(yaw_rate / max(math.radians(26.0), 1e-6), -1.0, 1.0),
                math.sin(drift),
            ],
            dtype=np.float32,
        )
        return np.concatenate((base, features), dtype=np.float32)

    def _record_sample(self, command, reward: float, collision: bool) -> None:
        super()._record_sample(command, reward, collision)
        sample = self.trajectory[-1]
        ground = self._ship_ground_velocity()
        course = math.atan2(float(ground[0]), float(ground[1])) if np.dot(ground, ground) > 0.001 else float(self.state[2])
        drift = (float(self.state[2]) - course + math.pi) % (2.0 * math.pi) - math.pi
        sample.update(
            {
                "dynamics_model_id": str(self._physics_config.get("model_id", "")),
                "dynamics_sha256": self._physics_sha256,
                "sway_mps": round(float(self._physics_status.get("sway_mps", 0.0)), 6),
                "yaw_rate_degrees_per_second": round(float(self._physics_status.get("yaw_rate_deg_s", 0.0)), 6),
                "course_degrees": round(math.degrees(course) % 360.0, 5),
                "drift_angle_degrees": round(math.degrees(drift), 6),
                "ground_velocity_x_mps": round(float(ground[0]), 6),
                "ground_velocity_z_mps": round(float(ground[1]), 6),
            }
        )

    def _physics_info(self, info: Mapping[str, Any]) -> Dict[str, Any]:
        result = dict(info)
        result.update(
            {
                "observation_size": PHYSICS_OBSERVATION_SIZE,
                "observation_contract": PHYSICS_OBSERVATION_CONTRACT,
                "dynamics_model_id": str(self._physics_config.get("model_id", "")),
                "dynamics_model_family": PHYSICS_MODEL_FAMILY,
                "dynamics_sha256": self._physics_sha256,
                "sway_mps": float(self._physics_status.get("sway_mps", 0.0)),
                "yaw_rate_degrees_per_second": float(self._physics_status.get("yaw_rate_deg_s", 0.0)),
            }
        )
        return result

    def _info(self, terminated: bool, truncated: bool, goal_reached: bool):
        return self._physics_info(super()._info(terminated, truncated, goal_reached))
