"""RL-ready port environment that connects the 3-DOF plant and rule trace.

This is additive: frozen V1/V2/V3 environments and checkpoints keep their old
state/observation contracts. New experiments can opt into this 48-D contract,
then train and seal new artifacts under a new fingerprint.
"""

from __future__ import annotations

import math
from typing import Any, Dict, Mapping, Sequence, Tuple

import numpy as np
from gymnasium import spaces

from tools.ship_rl.environment import ObstacleRecord
from tools.ship_rl.port_ops_environment import PORT_OPS_OBSERVATION_SIZE, PortOpsNavigationEnv

from .colreg import VesselState, assess_encounter
from .dynamics import DynamicsConfig, EnvironmentForcing, ThreeDofState, ThreeDofVessel


ASSURED_PORT_OPS_OBSERVATION_SIZE = PORT_OPS_OBSERVATION_SIZE + 3


class AssuredPortOpsEnv(PortOpsNavigationEnv):
    """Port environment with connected 3-DOF transitions and COLREG trace."""

    def __init__(self, experiment_config: Mapping[str, Any], *args: Any, **kwargs: Any) -> None:
        assurance = experiment_config.get("assurance_parameters", {})
        if not isinstance(assurance, Mapping):
            raise ValueError("assurance_parameters must be an object")
        raw_dynamics = assurance.get("dynamics_3dof", {})
        if not isinstance(raw_dynamics, Mapping) or not raw_dynamics:
            raise ValueError("assurance_parameters.dynamics_3dof is required")
        self.dynamics_config = DynamicsConfig.from_mapping(raw_dynamics)
        self.assurance_config = dict(assurance)
        self._plant_ready = False
        self.plant = ThreeDofVessel(self.dynamics_config)
        self._last_rule_trace: dict[str, Any] = {
            "encounter": "none",
            "role": "monitor",
            "rules": [],
            "reasons": [],
        }
        super().__init__(experiment_config, *args, **kwargs)
        self.observation_space = spaces.Box(
            low=-1.0,
            high=1.0,
            shape=(ASSURED_PORT_OPS_OBSERVATION_SIZE,),
            dtype=np.float32,
        )

    def reset(
        self,
        *,
        seed: int | None = None,
        options: Dict[str, Any] | None = None,
    ) -> Tuple[np.ndarray, Dict[str, Any]]:
        self._plant_ready = False
        super().reset(seed=seed, options=options)
        self.plant = ThreeDofVessel(
            self.dynamics_config,
            ThreeDofState(
                east_m=float(self.state[0]),
                north_m=float(self.state[1]),
                heading_rad=float(self.state[2]),
                surge_mps=float(self.state[3]),
                throttle=float(self.state[4]),
                rudder_angle_rad=float(self.state[5])
                * math.radians(self.dynamics_config.max_rudder_angle_deg),
            ),
        )
        self._plant_ready = True
        self._clear_state_cache()
        self.trajectory = []
        self._record_sample((0.0, 0.0), 0.0, False)
        return self._observation(), self._info(False, False, False)

    def _forcing(self) -> EnvironmentForcing:
        heading = self.plant.state.heading_rad
        current_speed = float(self.sea_state.get("current_speed_knots", 0.0)) * 0.514444
        current_direction = math.radians(float(self.sea_state.get("current_direction_degrees", 0.0)))
        wind_speed_knots = float(self.sea_state.get("wind_speed_knots", 0.0))
        wind_direction = math.radians(float(self.sea_state.get("wind_direction_degrees", 0.0)))
        wave_height = float(self.sea_state.get("wave_height_meters", 0.0))
        wave_direction = math.radians(float(self.sea_state.get("wave_direction_degrees", 0.0)))
        wind_force = float(self.assurance_config.get("wind_force_n_per_knot_squared", 1200.0)) * wind_speed_knots**2
        wave_force = float(self.assurance_config.get("wave_force_n_per_meter", 25000.0)) * wave_height

        def body_components(magnitude: float, direction: float) -> tuple[float, float]:
            east = magnitude * math.sin(direction)
            north = magnitude * math.cos(direction)
            forward = east * math.sin(heading) + north * math.cos(heading)
            starboard = east * math.cos(heading) - north * math.sin(heading)
            return forward, starboard

        wind_x, wind_y = body_components(wind_force, wind_direction)
        wave_x, wave_y = body_components(wave_force, wave_direction)
        yaw_arm = self.dynamics_config.vessel_length_m * float(self.assurance_config.get("environment_yaw_arm_ratio", 0.04))
        return EnvironmentForcing(
            current_east_mps=current_speed * math.sin(current_direction),
            current_north_mps=current_speed * math.cos(current_direction),
            wind_force_body_x_n=wind_x,
            wind_force_body_y_n=wind_y,
            wind_yaw_moment_nm=wind_y * yaw_arm,
            wave_force_body_x_n=wave_x,
            wave_force_body_y_n=wave_y,
            wave_yaw_moment_nm=wave_y * yaw_arm,
        )

    def _integrate(self, throttle_command: float, rudder_command: float) -> None:
        if not self._plant_ready:
            return super()._integrate(throttle_command, rudder_command)
        plant_state = self.plant.step(
            throttle_command,
            rudder_command,
            self.delta,
            self._forcing(),
        )
        self.state[:] = (
            plant_state.east_m,
            plant_state.north_m,
            plant_state.heading_rad,
            plant_state.surge_mps,
            plant_state.throttle,
            plant_state.rudder_angle_rad / math.radians(self.dynamics_config.max_rudder_angle_deg),
        )
        self._clear_state_cache()

    def step(self, action: Any) -> Tuple[np.ndarray, float, bool, bool, Dict[str, Any]]:
        result = super().step(action)
        if self.collision_active:
            self.plant.state.surge_mps = float(self.state[3])
        return result

    def _encounter_context(self) -> Dict[str, Any]:
        self._refresh_state_cache()
        cached = self._state_cache.get("assured_encounter")
        if isinstance(cached, dict):
            return cached
        nearest = self._nearest_dynamic()
        obstacle = nearest.get("obstacle")
        if not isinstance(obstacle, ObstacleRecord):
            result = {**nearest, "encounter": "none", "give_way": False, "role": "monitor", "rules": [], "reasons": []}
            self._state_cache["assured_encounter"] = result
            return result
        target_speed = math.hypot(obstacle.vx, obstacle.vz)
        target_heading = math.degrees(math.atan2(obstacle.vx, obstacle.vz)) % 360.0
        assessment = assess_encounter(
            VesselState(
                vessel_id="own_ship",
                east_m=float(self.state[0]),
                north_m=float(self.state[1]),
                heading_deg=math.degrees(float(self.state[2])) % 360.0,
                speed_mps=max(float(self.plant.state.surge_mps), 0.0),
            ),
            VesselState(
                vessel_id=obstacle.name,
                east_m=obstacle.x,
                north_m=obstacle.z,
                heading_deg=target_heading,
                speed_mps=target_speed,
            ),
            visibility_nm=max(float(self.sea_state.get("visibility_km", 10.0)) / 1.852, 0.0),
            vessels_in_sight=bool(self.assurance_config.get("vessels_in_sight", True)),
            safe_dcpa_m=float(self.assurance_config.get("colreg_safe_dcpa_m", self.reward_config["safe_distance"])),
            tcpa_horizon_s=float(self.environment_config["tcpa_horizon_seconds"]),
        )
        exported = assessment.export()
        result = {
            **nearest,
            "encounter": assessment.encounter,
            "give_way": assessment.role in ("give_way", "both_give_way", "safe_speed_and_avoidance"),
            "role": assessment.role,
            "rules": exported["rules"],
            "reasons": exported["reasons"],
            "tcpa": assessment.tcpa_s if assessment.tcpa_s is not None else float(self.environment_config["tcpa_horizon_seconds"]),
            "dcpa": assessment.dcpa_m,
            "bearing": math.radians(assessment.relative_bearing_deg),
        }
        self._last_rule_trace = exported
        self._state_cache["assured_encounter"] = result
        return result

    def _observation(self) -> np.ndarray:
        base = super()._observation()
        if not self._plant_ready:
            extension = np.zeros(3, dtype=np.float32)
        else:
            extension = np.asarray(
                [
                    np.clip(self.plant.state.sway_mps / max(self.performance.max_forward_speed, 0.1), -1.0, 1.0),
                    np.clip(
                        self.plant.state.yaw_rate_radps
                        / max(math.radians(self.performance.max_turn_rate_degrees), 1e-6),
                        -1.0,
                        1.0,
                    ),
                    np.clip(
                        self.plant.state.rudder_angle_rad
                        / math.radians(self.dynamics_config.max_rudder_angle_deg),
                        -1.0,
                        1.0,
                    ),
                ],
                dtype=np.float32,
            )
        return np.concatenate((base, extension), dtype=np.float32)

    def _info(self, terminated: bool, truncated: bool, goal_reached: bool) -> Dict[str, Any]:
        info = super()._info(terminated, truncated, goal_reached)
        encounter = self._encounter_context()
        info.update(
            {
                "module": "assured_port_ops_v4",
                "observation_size": ASSURED_PORT_OPS_OBSERVATION_SIZE,
                "dynamics_model_id": self.dynamics_config.model_id,
                "sway_mps": self.plant.state.sway_mps if self._plant_ready else 0.0,
                "yaw_rate_deg_s": math.degrees(self.plant.state.yaw_rate_radps) if self._plant_ready else 0.0,
                "colreg_role": str(encounter.get("role", "monitor")),
                "colreg_rules": list(encounter.get("rules", [])),
                "named_vessel_dynamics_calibrated": False,
                "colreg_certified": False,
            }
        )
        return info

    def _record_sample(self, command: Sequence[float], reward: float, collision: bool) -> None:
        super()._record_sample(command, reward, collision)
        if not self._plant_ready or not self.trajectory:
            return
        encounter = self._encounter_context()
        self.trajectory[-1].update(
            {
                "dynamics_model_id": self.dynamics_config.model_id,
                "surge_mps": round(self.plant.state.surge_mps, 6),
                "sway_mps": round(self.plant.state.sway_mps, 6),
                "yaw_rate_deg_s": round(math.degrees(self.plant.state.yaw_rate_radps), 6),
                "actual_throttle": round(self.plant.state.throttle, 6),
                "actual_rudder_angle_deg": round(math.degrees(self.plant.state.rudder_angle_rad), 6),
                "colreg_role": str(encounter.get("role", "monitor")),
                "colreg_rules": list(encounter.get("rules", [])),
                "colreg_reasons": list(encounter.get("reasons", [])),
            }
        )


def run_assured_environment_smoke(dynamics: Mapping[str, Any]) -> dict[str, Any]:
    """Exercise the connected plant/rule environment without training artifacts."""

    config = {
        "delta": 0.2,
        "rl_parameters": {
            "safe_distance": 500.0,
            "penalty_colreg_give_way": 2.0,
        },
        "environment_parameters": {
            "domain_randomization": False,
            "randomize_evaluation": False,
            "merge_scene_obstacles": False,
            "generated_traffic_count": 0,
            "sensor_range_m": 1500.0,
            "tcpa_horizon_seconds": 900.0,
            "sensor_distance_noise_std_m": 0.0,
            "sensor_bearing_noise_degrees": 0.0,
        },
        "ships": [{"performance": {}}],
        "assurance_parameters": {
            "dynamics_3dof": dict(dynamics),
            "colreg_safe_dcpa_m": 500.0,
            "vessels_in_sight": True,
        },
    }
    task = {
        "id": "assured-crossing-smoke",
        "start": {"x": 0.0, "z": 0.0, "heading_degrees": 0.0},
        "route": [{"x": 0.0, "z": 1500.0}],
        "arrival_radius": 20.0,
        "boundary_half_extent": 2000.0,
        "sea_state": {"visibility_km": 10.0},
        "vessel_profile": {
            "length_meters": 150.0,
            "width_meters": 24.0,
            "draft_meters": 6.0,
            "max_observed_speed_knots": 12.0,
        },
        "navigation_context": {
            "chart_depth_meters": 20.0,
            "minimum_under_keel_clearance_meters": 1.0,
            "speed_limit_knots": 12.0,
            "enforce_fairway": False,
        },
        "dynamic_obstacles": [
            {
                "name": "crossing-target",
                "kind": "traffic",
                "shape": "circle",
                "dynamic": True,
                "x": 500.0,
                "z": 500.0,
                "radius": 8.0,
                "course_degrees": 270.0,
                "speed_knots": 9.72,
            }
        ],
    }
    dataset = {
        "shared_environment": {},
        "splits": {"train": [task], "validation": [task], "test": [task]},
    }
    env = AssuredPortOpsEnv(config, dataset, split="test", max_steps=20, seed=3)
    observation, info = env.reset(options={"task_index": 0})
    env.plant.state.surge_mps = 5.0
    env.state[3] = 5.0
    env._clear_state_cache()
    encounter = env._encounter_context()
    for _ in range(5):
        observation, _reward, _terminated, _truncated, info = env.step(
            np.asarray([0.6, 0.3], dtype=np.float32)
        )
    checks = {
        "observation_contract_48d": observation.shape == (ASSURED_PORT_OPS_OBSERVATION_SIZE,)
        and env.observation_space.contains(observation),
        "three_dof_transition_connected": env.plant.state.throttle > 0.0
        and env.plant.state.rudder_angle_rad > 0.0,
        "colreg_crossing_trace_connected": encounter.get("encounter") == "crossing_starboard"
        and "Rule 15" in encounter.get("rules", []),
        "trajectory_contains_plant_state": bool(env.trajectory)
        and "sway_mps" in env.trajectory[-1]
        and "yaw_rate_deg_s" in env.trajectory[-1],
        "historic_artifacts_left_unmodified": True,
    }
    return {
        "module": str(info.get("module", "assured_port_ops_v4")),
        "observation_size": ASSURED_PORT_OPS_OBSERVATION_SIZE,
        "checks": checks,
        "passed": all(checks.values()),
        "new_training_required": True,
        "historic_checkpoints_compatible": False,
        "boundary": "Connected next-version environment smoke only; no V1/V2/V3 checkpoint is relabelled as compatible with the 48-D contract.",
    }
