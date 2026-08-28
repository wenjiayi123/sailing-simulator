from __future__ import annotations

import math
from types import SimpleNamespace
import unittest

from tools.ship_rl.sac_champion_safety_v5 import (
    SacChampionSafetyConfig,
    SacChampionSafetySupervisor,
)
from tools.assess_sac_champion_v5 import assess


class _SpeedPreviewEnv:
    def __init__(
        self,
        speed: float,
        throttle: float,
        limit_knots: float,
        heading_error_degrees: float = 0.0,
    ) -> None:
        self.state = [0.0, 0.0, 0.0, speed, throttle, 0.0]
        self.delta = 0.5
        self.performance = SimpleNamespace(
            max_forward_speed=5.0,
            max_reverse_speed=1.2,
            acceleration=0.2,
            deceleration=0.15,
            brake_acceleration=0.35,
            throttle_response=0.32,
        )
        self._limit_knots = limit_knots
        self._heading_error_radians = math.radians(heading_error_degrees)

    def _navigation_context(self) -> dict[str, float]:
        return {"speed_limit_knots": self._limit_knots}

    def _heading_error(self) -> float:
        return self._heading_error_radians


class SacChampionSafetyV5Tests(unittest.TestCase):
    def test_safe_sac_action_passes_speed_governor_unchanged(self) -> None:
        supervisor = SacChampionSafetySupervisor()
        env = _SpeedPreviewEnv(speed=1.5, throttle=0.3, limit_knots=8.0)

        governed, reason = supervisor._govern_speed_action(env, (0.4, -0.27))

        self.assertEqual(governed, (0.4, -0.27))
        self.assertEqual(reason, "speed_preview_safe")

    def test_governor_reduces_only_throttle_before_predicted_breach(self) -> None:
        config = SacChampionSafetyConfig(speed_preview_steps=12)
        supervisor = SacChampionSafetySupervisor(config)
        env = _SpeedPreviewEnv(speed=3.85, throttle=0.9, limit_knots=8.0)

        governed, reason = supervisor._govern_speed_action(env, (1.0, 0.31))
        permitted = 8.0 * 0.514444 * (1.0 - config.speed_limit_buffer_ratio)

        self.assertLess(governed[0], 1.0)
        self.assertEqual(governed[1], 0.31)
        self.assertEqual(reason, "speed_preview_throttle_projection")
        self.assertLessEqual(
            supervisor._preview_maximum_speed(env, governed[0]),
            permitted + 1e-6,
        )

    def test_profile_mapping_keeps_v5_governor_fields(self) -> None:
        profile = SacChampionSafetyConfig.from_mapping(
            {
                "profile_id": "test-v5",
                "speed_preview_steps": 18,
                "speed_limit_buffer_ratio": 0.01,
            }
        )

        self.assertEqual(profile.profile_id, "test-v5")
        self.assertEqual(profile.speed_preview_steps, 18)
        self.assertEqual(profile.speed_limit_buffer_ratio, 0.01)

    def test_route_recovery_blends_only_rudder_outside_heading_envelope(self) -> None:
        supervisor = SacChampionSafetySupervisor()
        env = _SpeedPreviewEnv(
            speed=2.0,
            throttle=0.4,
            limit_knots=8.0,
            heading_error_degrees=50.0,
        )

        governed, reason = supervisor._govern_route_action(env, (0.35, -0.8))

        self.assertEqual(governed[0], 0.35)
        self.assertGreater(governed[1], -0.8)
        self.assertEqual(reason, "route_heading_recovery")

    def test_admission_requires_real_rl_and_action_authority(self) -> None:
        thresholds = {
            "minimum_collision_free_arrival_rate": 0.8,
            "minimum_port_compliant_completion_rate": 0.75,
            "minimum_mean_route_completion_ratio": 0.8,
            "maximum_collision_episode_rate": 0.1,
            "maximum_grounding_episode_rate": 0.05,
            "maximum_colreg_violation_episode_rate": 0.1,
            "maximum_channel_departure_episode_rate": 0.05,
            "maximum_speed_violation_episode_rate": 0.05,
            "maximum_hazard_supervisor_intervention_step_rate": 0.2,
            "maximum_fail_closed_episode_rate": 0.05,
            "minimum_raw_sac_action_accepted_step_rate": 0.5,
            "minimum_rl_rudder_retained_step_rate": 0.8,
            "minimum_rl_any_dimension_retained_step_rate": 0.9,
            "maximum_decision_p95_ms": 250.0,
            "maximum_replan_p95_ms": 250.0,
        }
        result = {
            "strategy_id": "candidate",
            "dataset_split": "validation",
            "contains_real_rl": False,
            "metrics": {
                "collision_free_arrival_rate": 0.9,
                "port_compliant_completion_rate": 0.8,
                "mean_route_completion_ratio": 0.9,
                "collision_episode_rate": 0.0,
                "grounding_episode_rate": 0.0,
                "colreg_violation_episode_rate": 0.0,
                "channel_departure_episode_rate": 0.0,
                "speed_violation_episode_rate": 0.0,
            },
            "supervisor_metrics": {
                "fail_closed_episode_rate": 0.0,
                "decision_p95_ms": 10.0,
                "replan_p95_ms": 20.0,
            },
            "rl_authority_metrics": {
                "hazard_supervisor_intervention_step_rate": 0.1,
                "raw_sac_action_accepted_step_rate": 0.9,
                "rl_rudder_retained_step_rate": 0.95,
                "rl_any_dimension_retained_step_rate": 0.98,
            },
        }

        admission = assess(
            result,
            {"profile_id": "test", "thresholds": thresholds},
        )

        self.assertFalse(admission["passed"])
        self.assertEqual(admission["failed_checks"], ["contains_real_rl"])


if __name__ == "__main__":
    unittest.main()
