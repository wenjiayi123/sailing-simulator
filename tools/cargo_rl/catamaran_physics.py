"""Python twin-waterjet catamaran plant matching the Godot runtime model.

The equations and actuator limits mirror
``scripts/physics/catamaran_three_dof_dynamics.gd``.  The shared JSON file is
the authority for both runtimes; no learned-policy code owns vessel constants.
"""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
from typing import Any, Mapping

import numpy as np


def canonical_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _clip(value: float, lower: float, upper: float) -> float:
    return min(max(float(value), lower), upper)


def _wrap(value: float) -> float:
    return (float(value) + math.pi) % (2.0 * math.pi) - math.pi


class TwinWaterjetCatamaran:
    """Deterministic surge/sway/yaw RK4 plant with twin-waterjet actuators."""

    def __init__(self, config: Mapping[str, Any]) -> None:
        self.config = dict(config)
        self._validate()
        self.reset(0.0)

    @classmethod
    def from_json(cls, path: Path) -> "TwinWaterjetCatamaran":
        return cls(json.loads(path.read_text(encoding="utf-8")))

    def reset(self, heading_rad: float, surge_mps: float = 0.0) -> None:
        self.surge_mps = float(surge_mps)
        self.sway_mps = 0.0
        self.yaw_rate_radps = 0.0
        self.heading_rad = _wrap(heading_rad)
        self.port_throttle = 0.0
        self.starboard_throttle = 0.0
        self.steering_angle_rad = 0.0
        self.simulation_time_s = 0.0

    def step(
        self,
        throttle_command: float,
        steering_command: float,
        delta: float,
        forcing: Mapping[str, float] | None = None,
    ) -> dict[str, Any]:
        if delta <= 0.0:
            return self.status(forcing)
        forcing = dict(forcing or {})
        substeps = min(max(int(self.config.get("integration_substeps", 4)), 1), 16)
        step_delta = min(float(delta), 0.25) / float(substeps)
        throttle_target = _clip(throttle_command, -1.0, 1.0)
        steering_target = _clip(steering_command, -1.0, 1.0)
        differential = self._f("differential_thrust_gain") * steering_target
        port_target = _clip(throttle_target + differential, -1.0, 1.0)
        starboard_target = _clip(throttle_target - differential, -1.0, 1.0)
        angle_target = math.radians(self._f("max_steering_angle_deg")) * steering_target
        for _ in range(substeps):
            self.port_throttle = self._actuator_step(
                self.port_throttle,
                port_target,
                self._f("propeller_time_constant_s"),
                self._f("max_throttle_rate_per_s"),
                step_delta,
            )
            self.starboard_throttle = self._actuator_step(
                self.starboard_throttle,
                starboard_target,
                self._f("propeller_time_constant_s"),
                self._f("max_throttle_rate_per_s"),
                step_delta,
            )
            self.steering_angle_rad = self._actuator_step(
                self.steering_angle_rad,
                angle_target,
                self._f("steering_time_constant_s"),
                math.radians(self._f("max_steering_rate_deg_s")),
                step_delta,
            )
            state = np.asarray(
                [self.surge_mps, self.sway_mps, self.yaw_rate_radps, self.heading_rad],
                dtype=np.float64,
            )
            k1 = self._derivative(state, forcing)
            k2 = self._derivative(state + k1 * (step_delta * 0.5), forcing)
            k3 = self._derivative(state + k2 * (step_delta * 0.5), forcing)
            k4 = self._derivative(state + k3 * step_delta, forcing)
            state += (k1 + k2 * 2.0 + k3 * 2.0 + k4) * (step_delta / 6.0)
            if not np.all(np.isfinite(state)):
                raise FloatingPointError("catamaran 3-DOF integration produced a non-finite state")
            self.surge_mps = float(state[0])
            self.sway_mps = float(state[1])
            self.yaw_rate_radps = float(state[2])
            self.heading_rad = _wrap(float(state[3]))
            self.simulation_time_s += step_delta
        return self.status(forcing)

    def status(self, forcing: Mapping[str, float] | None = None) -> dict[str, Any]:
        forcing = dict(forcing or {})
        forward = np.asarray([math.sin(self.heading_rad), math.cos(self.heading_rad)])
        starboard = np.asarray([math.cos(self.heading_rad), -math.sin(self.heading_rad)])
        water_velocity = forward * self.surge_mps + starboard * self.sway_mps
        current = np.asarray(
            [float(forcing.get("current_east_mps", 0.0)), float(forcing.get("current_north_mps", 0.0))]
        )
        return {
            "model_id": str(self.config.get("model_id", "unconfigured_catamaran_3dof")),
            "model_family": "3DOF_surge_sway_yaw_twin_waterjet_RK4",
            "surge_mps": self.surge_mps,
            "sway_mps": self.sway_mps,
            "yaw_rate_radps": self.yaw_rate_radps,
            "yaw_rate_deg_s": math.degrees(self.yaw_rate_radps),
            "heading_rad": self.heading_rad,
            "port_throttle": self.port_throttle,
            "starboard_throttle": self.starboard_throttle,
            "steering_angle_deg": math.degrees(self.steering_angle_rad),
            "water_relative_velocity": water_velocity,
            "ground_velocity": water_velocity + current,
            "simulation_time_s": self.simulation_time_s,
            "finite_state": True,
        }

    def apply_collision_retention(self, retention: float) -> None:
        bounded = _clip(retention, 0.0, 1.0)
        self.surge_mps *= bounded
        self.sway_mps *= bounded
        self.yaw_rate_radps *= bounded

    def _derivative(self, state: np.ndarray, forcing: Mapping[str, float]) -> np.ndarray:
        surge, sway, yaw_rate, _heading = (float(value) for value in state)
        port_thrust = self._signed_thrust(self.port_throttle)
        starboard_thrust = self._signed_thrust(self.starboard_throttle)
        combined_thrust = port_thrust + starboard_thrust
        axial_thrust = combined_thrust * math.cos(self.steering_angle_rad)
        steering_lateral = (
            -combined_thrust
            * math.sin(self.steering_angle_rad)
            * self._f("steering_lateral_efficiency")
        )
        surge_drag = self._f("surge_drag_linear_n_per_mps") * surge + self._f(
            "surge_drag_quadratic_n_per_mps2"
        ) * abs(surge) * surge
        sway_drag = self._f("sway_drag_linear_n_per_mps") * sway + self._f(
            "sway_drag_quadratic_n_per_mps2"
        ) * abs(sway) * sway
        yaw_drag = self._f("yaw_drag_linear_nm_per_radps") * yaw_rate + self._f(
            "yaw_drag_quadratic_nm_per_radps2"
        ) * abs(yaw_rate) * yaw_rate
        force_x = axial_thrust - surge_drag + float(forcing.get("wind_force_body_x_n", 0.0)) + float(
            forcing.get("wave_force_body_x_n", 0.0)
        )
        force_y = steering_lateral - sway_drag + float(forcing.get("wind_force_body_y_n", 0.0)) + float(
            forcing.get("wave_force_body_y_n", 0.0)
        )
        moment = (
            (port_thrust - starboard_thrust) * self._f("twin_waterjet_half_spacing_m")
            + self._f("steering_x_m") * steering_lateral
            - yaw_drag
            + float(forcing.get("environment_yaw_moment_nm", 0.0))
        )
        mass_surge = self._f("mass_kg") + self._f("added_mass_surge_kg")
        mass_sway = self._f("mass_kg") + self._f("added_mass_sway_kg")
        yaw_inertia = self._f("yaw_inertia_kg_m2") + self._f("added_yaw_inertia_kg_m2")
        surge_dot = (force_x + mass_sway * sway * yaw_rate) / max(mass_surge, 1.0)
        sway_dot = (force_y - mass_surge * surge * yaw_rate) / max(mass_sway, 1.0)
        yaw_dot = moment / max(yaw_inertia, 1.0)
        return np.asarray([surge_dot, sway_dot, yaw_dot, yaw_rate], dtype=np.float64)

    def _signed_thrust(self, throttle: float) -> float:
        ratio = 1.0 if throttle >= 0.0 else self._f("astern_thrust_ratio")
        return 0.5 * self._f("max_ahead_thrust_n") * throttle * ratio

    @staticmethod
    def _actuator_step(actual: float, target: float, time_constant: float, rate_limit: float, delta: float) -> float:
        requested_rate = (target - actual) / max(time_constant, 0.001)
        return actual + _clip(requested_rate, -rate_limit, rate_limit) * delta

    def _f(self, key: str) -> float:
        return float(self.config.get(key, 0.0))

    def _validate(self) -> None:
        required_positive = (
            "mass_kg",
            "yaw_inertia_kg_m2",
            "surge_drag_quadratic_n_per_mps2",
            "sway_drag_quadratic_n_per_mps2",
            "yaw_drag_quadratic_nm_per_radps2",
            "max_ahead_thrust_n",
            "propeller_time_constant_s",
            "max_throttle_rate_per_s",
            "twin_waterjet_half_spacing_m",
            "max_steering_angle_deg",
            "steering_time_constant_s",
            "max_steering_rate_deg_s",
            "integration_substeps",
        )
        invalid = [key for key in required_positive if self._f(key) <= 0.0]
        if invalid:
            raise ValueError(f"invalid catamaran dynamics parameters: {invalid}")
