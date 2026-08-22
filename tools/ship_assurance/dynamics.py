"""Calibratable three-degree-of-freedom surface-vessel dynamics.

The existing RL benchmarks intentionally retain their frozen kinematic contract.
This module supplies the next-version plant model and identification/verification
tools without silently changing historic checkpoints or reports.  Coordinates
use east/north metres, heading clockwise from north, and body axes surge-forward,
sway-starboard, yaw-starboard.
"""

from __future__ import annotations

from dataclasses import MISSING, asdict, dataclass
import math
from typing import Any, Mapping, Sequence

import numpy as np


def _clip(value: float, lower: float, upper: float) -> float:
    return min(max(float(value), lower), upper)


def _wrap_radians(value: float) -> float:
    return (float(value) + math.pi) % (2.0 * math.pi) - math.pi


@dataclass(frozen=True)
class DynamicsConfig:
    """Hydrodynamic and actuator parameters for a generic displacement vessel.

    Values must be replaced by an identified vessel parameter set before field
    use. Added-mass terms are stored as positive effective-mass increments.
    """

    model_id: str
    vessel_length_m: float
    vessel_beam_m: float
    mass_kg: float
    yaw_inertia_kg_m2: float
    added_mass_surge_kg: float
    added_mass_sway_kg: float
    added_yaw_inertia_kg_m2: float
    surge_drag_linear_n_per_mps: float
    surge_drag_quadratic_n_per_mps2: float
    sway_drag_linear_n_per_mps: float
    sway_drag_quadratic_n_per_mps2: float
    yaw_drag_linear_nm_per_radps: float
    yaw_drag_quadratic_nm_per_radps2: float
    max_ahead_thrust_n: float
    astern_thrust_ratio: float
    propeller_time_constant_s: float
    max_throttle_rate_per_s: float
    rudder_area_m2: float
    rudder_x_m: float
    rudder_lift_slope_per_rad: float
    rudder_drag_coefficient: float
    rudder_time_constant_s: float
    max_rudder_angle_deg: float
    max_rudder_rate_deg_s: float
    water_density_kg_m3: float = 1025.0
    integration_substeps: int = 4

    @classmethod
    def from_mapping(cls, value: Mapping[str, Any]) -> "DynamicsConfig":
        fields = cls.__dataclass_fields__
        missing = [
            name
            for name, field in fields.items()
            if name not in value
            and field.default is MISSING
            and field.default_factory is MISSING
        ]
        if missing:
            raise ValueError(f"dynamics config is missing fields: {missing}")
        payload = {name: value[name] for name in fields if name in value}
        config = cls(**payload)
        config.validate()
        return config

    def validate(self) -> None:
        positive = (
            "vessel_length_m",
            "vessel_beam_m",
            "mass_kg",
            "yaw_inertia_kg_m2",
            "surge_drag_linear_n_per_mps",
            "surge_drag_quadratic_n_per_mps2",
            "sway_drag_linear_n_per_mps",
            "sway_drag_quadratic_n_per_mps2",
            "yaw_drag_linear_nm_per_radps",
            "yaw_drag_quadratic_nm_per_radps2",
            "max_ahead_thrust_n",
            "propeller_time_constant_s",
            "max_throttle_rate_per_s",
            "rudder_area_m2",
            "rudder_lift_slope_per_rad",
            "rudder_time_constant_s",
            "max_rudder_angle_deg",
            "max_rudder_rate_deg_s",
            "water_density_kg_m3",
        )
        invalid = [name for name in positive if float(getattr(self, name)) <= 0.0]
        if invalid:
            raise ValueError(f"dynamics parameters must be positive: {invalid}")
        if self.added_mass_surge_kg < 0.0 or self.added_mass_sway_kg < 0.0:
            raise ValueError("added masses must be non-negative")
        if self.added_yaw_inertia_kg_m2 < 0.0:
            raise ValueError("added yaw inertia must be non-negative")
        if not 0.0 < self.astern_thrust_ratio <= 1.0:
            raise ValueError("astern_thrust_ratio must be in (0, 1]")
        if self.rudder_x_m >= 0.0:
            raise ValueError("rudder_x_m must be aft of CG and therefore negative")
        if not 1 <= int(self.integration_substeps) <= 100:
            raise ValueError("integration_substeps must be in [1, 100]")


@dataclass(frozen=True)
class EnvironmentForcing:
    current_east_mps: float = 0.0
    current_north_mps: float = 0.0
    wind_force_body_x_n: float = 0.0
    wind_force_body_y_n: float = 0.0
    wind_yaw_moment_nm: float = 0.0
    wave_force_body_x_n: float = 0.0
    wave_force_body_y_n: float = 0.0
    wave_yaw_moment_nm: float = 0.0


@dataclass
class ThreeDofState:
    east_m: float = 0.0
    north_m: float = 0.0
    heading_rad: float = 0.0
    surge_mps: float = 0.0
    sway_mps: float = 0.0
    yaw_rate_radps: float = 0.0
    throttle: float = 0.0
    rudder_angle_rad: float = 0.0
    time_s: float = 0.0

    def export(self) -> dict[str, float]:
        payload = asdict(self)
        payload["heading_deg"] = math.degrees(self.heading_rad)
        payload["yaw_rate_deg_s"] = math.degrees(self.yaw_rate_radps)
        payload["rudder_angle_deg"] = math.degrees(self.rudder_angle_rad)
        return payload


class ThreeDofVessel:
    """Deterministic 3-DOF plant with bounded first-order actuators and RK4."""

    def __init__(self, config: DynamicsConfig, state: ThreeDofState | None = None) -> None:
        config.validate()
        self.config = config
        self.state = state if state is not None else ThreeDofState()

    @staticmethod
    def _actuator_step(
        actual: float,
        target: float,
        time_constant: float,
        rate_limit: float,
        dt: float,
    ) -> float:
        requested_rate = (target - actual) / max(time_constant, 1e-9)
        return actual + _clip(requested_rate, -rate_limit, rate_limit) * dt

    def _forces(
        self,
        surge: float,
        sway: float,
        yaw_rate: float,
        throttle: float,
        rudder_angle: float,
        forcing: EnvironmentForcing,
    ) -> tuple[float, float, float]:
        cfg = self.config
        thrust = cfg.max_ahead_thrust_n * (
            throttle if throttle >= 0.0 else cfg.astern_thrust_ratio * throttle
        )
        surge_drag = (
            cfg.surge_drag_linear_n_per_mps * surge
            + cfg.surge_drag_quadratic_n_per_mps2 * abs(surge) * surge
        )
        sway_drag = (
            cfg.sway_drag_linear_n_per_mps * sway
            + cfg.sway_drag_quadratic_n_per_mps2 * abs(sway) * sway
        )
        yaw_drag = (
            cfg.yaw_drag_linear_nm_per_radps * yaw_rate
            + cfg.yaw_drag_quadratic_nm_per_radps2 * abs(yaw_rate) * yaw_rate
        )

        local_lateral = sway + cfg.rudder_x_m * yaw_rate
        inflow = max(math.hypot(surge, local_lateral), 0.25)
        attack = _clip(rudder_angle - math.atan2(local_lateral, max(abs(surge), 0.25)), -0.6, 0.6)
        lift_coefficient = _clip(cfg.rudder_lift_slope_per_rad * attack, -1.2, 1.2)
        dynamic_pressure = 0.5 * cfg.water_density_kg_m3 * inflow * inflow
        # Positive rudder is a starboard turn. The stern force is to port and,
        # because the rudder is aft of CG, produces a positive yaw moment.
        rudder_lateral = -dynamic_pressure * cfg.rudder_area_m2 * lift_coefficient
        rudder_axial = -dynamic_pressure * cfg.rudder_area_m2 * cfg.rudder_drag_coefficient * abs(attack)
        rudder_moment = cfg.rudder_x_m * rudder_lateral

        force_x = thrust - surge_drag + rudder_axial + forcing.wind_force_body_x_n + forcing.wave_force_body_x_n
        force_y = rudder_lateral - sway_drag + forcing.wind_force_body_y_n + forcing.wave_force_body_y_n
        moment = rudder_moment - yaw_drag + forcing.wind_yaw_moment_nm + forcing.wave_yaw_moment_nm
        return force_x, force_y, moment

    def _derivatives(
        self,
        vector: np.ndarray,
        throttle: float,
        rudder_angle: float,
        forcing: EnvironmentForcing,
    ) -> np.ndarray:
        east, north, heading, surge, sway, yaw_rate = (float(item) for item in vector)
        cfg = self.config
        mass_surge = cfg.mass_kg + cfg.added_mass_surge_kg
        mass_sway = cfg.mass_kg + cfg.added_mass_sway_kg
        inertia = cfg.yaw_inertia_kg_m2 + cfg.added_yaw_inertia_kg_m2
        force_x, force_y, moment = self._forces(
            surge, sway, yaw_rate, throttle, rudder_angle, forcing
        )
        surge_dot = (force_x + mass_sway * sway * yaw_rate) / mass_surge
        sway_dot = (force_y - mass_surge * surge * yaw_rate) / mass_sway
        yaw_dot = moment / inertia
        east_dot = (
            surge * math.sin(heading)
            + sway * math.cos(heading)
            + forcing.current_east_mps
        )
        north_dot = (
            surge * math.cos(heading)
            - sway * math.sin(heading)
            + forcing.current_north_mps
        )
        return np.asarray([east_dot, north_dot, yaw_rate, surge_dot, sway_dot, yaw_dot])

    def step(
        self,
        throttle_command: float,
        rudder_command: float,
        dt: float,
        forcing: EnvironmentForcing | None = None,
    ) -> ThreeDofState:
        if not 0.0 < float(dt) <= 5.0:
            raise ValueError("dt must be in (0, 5] seconds")
        cfg = self.config
        forcing = forcing or EnvironmentForcing()
        throttle_target = _clip(throttle_command, -1.0, 1.0)
        rudder_target = math.radians(cfg.max_rudder_angle_deg) * _clip(rudder_command, -1.0, 1.0)
        substeps = int(cfg.integration_substeps)
        step_dt = float(dt) / substeps
        state = self.state
        for _ in range(substeps):
            state.throttle = self._actuator_step(
                state.throttle,
                throttle_target,
                cfg.propeller_time_constant_s,
                cfg.max_throttle_rate_per_s,
                step_dt,
            )
            state.rudder_angle_rad = self._actuator_step(
                state.rudder_angle_rad,
                rudder_target,
                cfg.rudder_time_constant_s,
                math.radians(cfg.max_rudder_rate_deg_s),
                step_dt,
            )
            vector = np.asarray(
                [
                    state.east_m,
                    state.north_m,
                    state.heading_rad,
                    state.surge_mps,
                    state.sway_mps,
                    state.yaw_rate_radps,
                ],
                dtype=np.float64,
            )
            k1 = self._derivatives(vector, state.throttle, state.rudder_angle_rad, forcing)
            k2 = self._derivatives(vector + 0.5 * step_dt * k1, state.throttle, state.rudder_angle_rad, forcing)
            k3 = self._derivatives(vector + 0.5 * step_dt * k2, state.throttle, state.rudder_angle_rad, forcing)
            k4 = self._derivatives(vector + step_dt * k3, state.throttle, state.rudder_angle_rad, forcing)
            vector += step_dt * (k1 + 2.0 * k2 + 2.0 * k3 + k4) / 6.0
            if not np.all(np.isfinite(vector)):
                raise FloatingPointError("non-finite 3-DOF state")
            (
                state.east_m,
                state.north_m,
                state.heading_rad,
                state.surge_mps,
                state.sway_mps,
                state.yaw_rate_radps,
            ) = (float(item) for item in vector)
            state.heading_rad = _wrap_radians(state.heading_rad)
            state.time_s += step_dt
        return state


def identify_first_order_nomoto(
    time_s: Sequence[float],
    yaw_rate_rad_s: Sequence[float],
    rudder_angle_rad: Sequence[float],
) -> dict[str, float]:
    """Identify ``T*r_dot + r = K*delta`` using timestamped samples."""

    time = np.asarray(time_s, dtype=np.float64)
    yaw = np.asarray(yaw_rate_rad_s, dtype=np.float64)
    rudder = np.asarray(rudder_angle_rad, dtype=np.float64)
    if not (len(time) == len(yaw) == len(rudder)) or len(time) < 8:
        raise ValueError("Nomoto identification requires at least eight aligned samples")
    if not np.all(np.diff(time) > 0.0):
        raise ValueError("Nomoto timestamps must be strictly increasing")
    derivative = np.gradient(yaw, time)
    design = np.column_stack((yaw, rudder, np.ones_like(yaw)))
    coefficients, *_ = np.linalg.lstsq(design, derivative, rcond=None)
    a, b, bias = (float(item) for item in coefficients)
    if a >= -1e-9:
        raise ValueError("identified Nomoto pole is not stable")
    time_constant = -1.0 / a
    gain = b * time_constant
    predicted = design @ coefficients
    residual = derivative - predicted
    rmse = float(np.sqrt(np.mean(residual * residual)))
    total = float(np.sum((derivative - np.mean(derivative)) ** 2))
    r_squared = 1.0 - float(np.sum(residual * residual)) / max(total, 1e-12)
    return {
        "nomoto_gain_radps_per_rad": gain,
        "nomoto_time_constant_s": time_constant,
        "bias_radps2": bias,
        "derivative_rmse_radps2": rmse,
        "r_squared": r_squared,
        "sample_count": float(len(time)),
    }


def run_dynamics_acceptance(config: DynamicsConfig) -> dict[str, Any]:
    """Execute deterministic software-level checks on a dynamics parameter set."""

    def rollout(command: tuple[float, float], duration: float = 120.0, dt: float = 0.2) -> ThreeDofState:
        vessel = ThreeDofVessel(config)
        for _ in range(round(duration / dt)):
            vessel.step(command[0], command[1], dt)
        return vessel.state

    first = rollout((0.62, 0.35))
    second = rollout((0.62, 0.35))
    deterministic_error = max(
        abs(first.export()[key] - second.export()[key])
        for key in ("east_m", "north_m", "heading_rad", "surge_mps", "sway_mps", "yaw_rate_radps")
    )
    starboard = rollout((0.62, 0.45))
    port = rollout((0.62, -0.45))

    decay = ThreeDofVessel(
        config,
        ThreeDofState(surge_mps=4.0, sway_mps=0.7, yaw_rate_radps=math.radians(2.0)),
    )
    initial_energy_proxy = decay.state.surge_mps**2 + decay.state.sway_mps**2 + decay.state.yaw_rate_radps**2
    for _ in range(600):
        decay.step(0.0, 0.0, 0.2)
    final_energy_proxy = decay.state.surge_mps**2 + decay.state.sway_mps**2 + decay.state.yaw_rate_radps**2

    coarse = ThreeDofVessel(config)
    fine_config = DynamicsConfig(**{**asdict(config), "integration_substeps": max(8, config.integration_substeps * 2)})
    fine = ThreeDofVessel(fine_config)
    for _ in range(500):
        coarse.step(0.7, 0.3, 0.2)
        fine.step(0.7, 0.3, 0.2)
    integration_position_error = math.hypot(
        coarse.state.east_m - fine.state.east_m,
        coarse.state.north_m - fine.state.north_m,
    )

    actuator_probe = ThreeDofVessel(config)
    max_rudder = 0.0
    max_throttle = 0.0
    finite = True
    for index in range(1000):
        state = actuator_probe.step(2.0, 2.0 if index < 500 else -2.0, 0.1)
        max_rudder = max(max_rudder, abs(math.degrees(state.rudder_angle_rad)))
        max_throttle = max(max_throttle, abs(state.throttle))
        finite = finite and all(math.isfinite(value) for value in state.export().values())

    symmetry_error = abs(starboard.yaw_rate_radps + port.yaw_rate_radps)
    checks = [
        {
            "id": "DYN-DET-001",
            "passed": deterministic_error <= 1e-12,
            "value": deterministic_error,
            "limit": 1e-12,
        },
        {
            "id": "DYN-DAMP-002",
            "passed": final_energy_proxy < initial_energy_proxy * 0.02,
            "value": final_energy_proxy / initial_energy_proxy,
            "limit": 0.02,
        },
        {
            "id": "DYN-YAW-003",
            "passed": starboard.yaw_rate_radps > 0.0 and port.yaw_rate_radps < 0.0,
            "starboard_yaw_rate_deg_s": math.degrees(starboard.yaw_rate_radps),
            "port_yaw_rate_deg_s": math.degrees(port.yaw_rate_radps),
        },
        {
            "id": "DYN-SYM-004",
            "passed": symmetry_error <= math.radians(0.02),
            "value_deg_s": math.degrees(symmetry_error),
            "limit_deg_s": 0.02,
        },
        {
            "id": "DYN-ACT-005",
            "passed": max_throttle <= 1.000001 and max_rudder <= config.max_rudder_angle_deg + 1e-6,
            "max_throttle": max_throttle,
            "max_rudder_angle_deg": max_rudder,
        },
        {
            "id": "DYN-NUM-006",
            "passed": finite and integration_position_error <= max(config.vessel_length_m * 0.02, 1.0),
            "position_error_m": integration_position_error,
            "limit_m": max(config.vessel_length_m * 0.02, 1.0),
        },
    ]
    return {
        "model_id": config.model_id,
        "model_family": "3-DOF surge-sway-yaw with added mass, nonlinear drag, rudder/propeller dynamics and RK4",
        "check_count": len(checks),
        "passed_count": sum(int(item["passed"]) for item in checks),
        "passed": all(bool(item["passed"]) for item in checks),
        "checks": checks,
        "vessel_specific_calibration_verified": False,
        "boundary": "Software plant-model verification only; parameters are a generic reference until identified against a named vessel.",
    }
