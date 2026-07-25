"""Control-theory baselines for the real-port navigation benchmark."""

from __future__ import annotations

import math
from typing import Any

import numpy as np

from .environment import _wrap_angle


def _target_speed(env: Any) -> float:
    context = env._navigation_context()
    limit = float(context.get("speed_limit_knots", 0.0) or 0.0) * 0.514444
    return min(
        env.performance.max_forward_speed * 0.72,
        limit if limit > 0.0 else env.performance.max_forward_speed * 0.72,
    )


def _risk_adjustment(env: Any, throttle: float, rudder: float) -> np.ndarray:
    nearest = env.avoidance_context()
    safe = max(float(env.reward_config["safe_distance"]), 1.0)
    clearance = float(nearest["clearance"])
    if clearance < safe * 1.5:
        proximity = float(np.clip(1.0 - clearance / (safe * 1.5), 0.0, 1.0))
        throttle = min(throttle, 0.42 - 0.55 * proximity)
        bearing = float(nearest["bearing"])
        if abs(bearing) < math.radians(75.0):
            direction = -1.0 if bearing >= 0.0 else 1.0
            rudder = float(np.clip(rudder + direction * proximity * 0.8, -1.0, 1.0))
    return np.asarray(
        [np.clip(throttle, -1.0, 1.0), np.clip(rudder, -1.0, 1.0)],
        dtype=np.float32,
    )


class LqrRouteController:
    """Discrete LQR for cross-track, heading, and speed regulation."""

    def __init__(self) -> None:
        self.previous_action = np.zeros(2, dtype=np.float64)
        self.gain: np.ndarray | None = None

    def reset(self) -> None:
        self.previous_action[:] = 0.0
        self.gain = None

    @staticmethod
    def _solve_gain(env: Any, speed: float) -> np.ndarray:
        delta = float(env.delta)
        velocity = max(abs(speed), 0.8)
        turn_gain = math.radians(env.performance.max_turn_rate_degrees) * delta
        acceleration_gain = env.performance.acceleration * delta
        a = np.asarray(
            [
                [1.0, velocity * delta, 0.0],
                [0.0, 1.0, 0.0],
                [0.0, 0.0, 0.92],
            ],
            dtype=np.float64,
        )
        b = np.asarray(
            [
                [0.0, 0.5 * velocity * delta * turn_gain],
                [0.0, turn_gain],
                [acceleration_gain, 0.0],
            ],
            dtype=np.float64,
        )
        q = np.diag([0.014, 3.6, 0.9])
        r = np.diag([0.55, 0.7])
        p = q.copy()
        for _ in range(120):
            inverse = np.linalg.inv(r + b.T @ p @ b)
            updated = a.T @ p @ a - a.T @ p @ b @ inverse @ b.T @ p @ a + q
            if np.max(np.abs(updated - p)) < 1e-9:
                p = updated
                break
            p = updated
        return np.linalg.solve(r + b.T @ p @ b, b.T @ p @ a)

    def predict(self, env: Any) -> np.ndarray:
        speed = float(env.state[3])
        if self.gain is None:
            self.gain = self._solve_gain(env, speed)
        target_speed = _target_speed(env)
        state = np.asarray(
            [
                float(env._cross_track_error()),
                -float(env._heading_error()),
                speed - target_speed,
            ],
            dtype=np.float64,
        )
        command = -self.gain @ state
        action = _risk_adjustment(env, float(command[0]), float(command[1]))
        action = np.clip(0.78 * action + 0.22 * self.previous_action, -1.0, 1.0)
        self.previous_action[:] = action
        return action.astype(np.float32)


class MpcRouteController:
    """Finite-horizon receding-horizon controller over the vessel kinematics."""

    def __init__(self, horizon: int = 8) -> None:
        self.horizon = horizon
        self.previous_action = np.zeros(2, dtype=np.float64)

    def reset(self) -> None:
        self.previous_action[:] = 0.0

    def _cost(self, env: Any, throttle: float, rudder: float) -> float:
        x, z, heading, speed = (float(value) for value in env.state[:4])
        target = env.route[min(env.waypoint_index, len(env.route) - 1)]
        target_speed = _target_speed(env)
        delta = float(env.delta)
        throttle_state = float(env.state[4])
        rudder_state = float(env.state[5])
        cost = 0.0
        for step in range(self.horizon):
            throttle_state += np.clip(
                throttle - throttle_state,
                -env.performance.throttle_response * delta,
                env.performance.throttle_response * delta,
            )
            rudder_state += np.clip(
                rudder - rudder_state,
                -env.performance.rudder_response * delta,
                env.performance.rudder_response * delta,
            )
            desired_speed = throttle_state * env.performance.max_forward_speed
            rate = (
                env.performance.acceleration
                if desired_speed > speed
                else env.performance.deceleration
            )
            speed += float(np.clip(desired_speed - speed, -rate * delta, rate * delta))
            ratio = float(
                np.clip(speed / max(env.performance.max_forward_speed, 1e-6), 0.0, 1.0)
            )
            authority = env.performance.low_speed_turn_factor + (
                1.0 - env.performance.low_speed_turn_factor
            ) * ratio
            heading = _wrap_angle(
                heading
                + rudder_state
                * math.radians(env.performance.max_turn_rate_degrees)
                * authority
                * delta
            )
            x += math.sin(heading) * speed * delta
            z += math.cos(heading) * speed * delta
            desired_heading = math.atan2(target[0] - x, target[1] - z)
            distance = math.hypot(target[0] - x, target[1] - z)
            heading_error = _wrap_angle(desired_heading - heading)
            cost += (
                0.0025 * distance
                + 2.8 * heading_error * heading_error
                + 0.16 * (speed - target_speed) ** 2
                + 0.025 * throttle * throttle
                + 0.05 * rudder * rudder
            ) * (1.0 + 0.08 * step)
        cost += 0.12 * float(
            np.sum(
                (
                    np.asarray([throttle, rudder], dtype=np.float64)
                    - self.previous_action
                )
                ** 2
            )
        )
        nearest = env.avoidance_context()
        safe = max(float(env.reward_config["safe_distance"]), 1.0)
        clearance = float(nearest["clearance"])
        if clearance < safe * 2.0:
            bearing = float(nearest["bearing"])
            projected_turn = rudder * (1.0 if bearing >= 0.0 else -1.0)
            cost += 30.0 * max(0.0, 1.0 - clearance / (safe * 2.0))
            cost += 8.0 * max(0.0, projected_turn)
            cost += 4.0 * max(0.0, throttle)
        return cost

    def predict(self, env: Any) -> np.ndarray:
        throttles = (-0.15, 0.2, 0.5, 0.78)
        rudders = (-0.85, -0.45, 0.0, 0.45, 0.85)
        best = min(
            (
                (self._cost(env, throttle, rudder), throttle, rudder)
                for throttle in throttles
                for rudder in rudders
            ),
            key=lambda row: row[0],
        )
        action = _risk_adjustment(env, best[1], best[2])
        self.previous_action[:] = action
        return action
