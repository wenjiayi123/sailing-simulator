"""SAC-preserving port safety layer for the additive V5 champion.

The V5 layer keeps the utility-preserving V4 supervisor and adds a cheap,
deterministic speed governor in front of it.  The governor projects only the
throttle component when a short dynamics preview predicts a speed-limit
breach; the SAC rudder proposal remains authoritative unless the downstream
hazard supervisor must intervene.

This is offline simulation assurance.  It is not live-vessel authority,
COLREGs certification, or a replacement for independent hardware interlocks
and human approval.
"""

from __future__ import annotations

from dataclasses import dataclass
import math
from typing import Any

import numpy as np

from .safety_supervisor import SafetyDecision
from .safety_supervisor_v4 import (
    UtilityPreservingSafetyConfig,
    UtilityPreservingSafetySupervisor,
)


@dataclass(frozen=True)
class SacChampionSafetyConfig(UtilityPreservingSafetyConfig):
    """Configuration for the V5 SAC-preserving safety projection."""

    profile_id: str = "sac_champion_preserving_safety_v5"
    speed_preview_steps: int = 12
    speed_limit_buffer_ratio: float = 0.025
    critical_tcpa_seconds: float = 900.0
    speed_governor_search_iterations: int = 14
    action_equality_tolerance: float = 1e-5
    review_aggressive_commands_without_hazard: bool = False
    route_recovery_heading_trigger_degrees: float = 18.0
    route_recovery_heading_full_degrees: float = 60.0
    route_recovery_maximum_blend: float = 0.65
    route_recovery_rudder_gain: float = 1.25


class SacChampionSafetySupervisor(UtilityPreservingSafetySupervisor):
    """Apply speed governance before V4 while measuring SAC authority."""

    config: SacChampionSafetyConfig

    def __init__(self, config: SacChampionSafetyConfig | None = None) -> None:
        super().__init__(config or SacChampionSafetyConfig())
        self.project_calls = 0
        self.speed_governor_steps = 0
        self.route_recovery_steps = 0
        self.hazard_supervisor_intervention_steps = 0
        self.raw_sac_action_accepted_steps = 0
        self.rl_rudder_retained_steps = 0
        self.rl_any_dimension_retained_steps = 0
        self.governor_reason_counts: dict[str, int] = {}

    @staticmethod
    def _move_toward(value: float, target: float, maximum_delta: float) -> float:
        if value < target:
            return min(value + maximum_delta, target)
        return max(value - maximum_delta, target)

    def _preview_maximum_speed(
        self,
        env: Any,
        throttle_command: float,
    ) -> float:
        """Mirror the simulator's longitudinal dynamics without moving state."""

        speed = float(env.state[3])
        throttle = float(env.state[4])
        performance = env.performance
        delta = float(env.delta)
        maximum_speed = abs(speed)
        for _ in range(max(1, int(self.config.speed_preview_steps))):
            throttle = self._move_toward(
                throttle,
                throttle_command,
                float(performance.throttle_response) * delta,
            )
            target_speed = throttle * (
                float(performance.max_forward_speed)
                if throttle >= 0.0
                else float(performance.max_reverse_speed)
            )
            rate = (
                float(performance.acceleration)
                if abs(target_speed) > abs(speed)
                else float(performance.deceleration)
            )
            if speed * target_speed < -0.05:
                rate = float(performance.brake_acceleration)
            speed = self._move_toward(speed, target_speed, rate * delta)
            maximum_speed = max(maximum_speed, abs(speed))
        return maximum_speed

    def _govern_speed_action(
        self,
        env: Any,
        proposed: tuple[float, float],
    ) -> tuple[tuple[float, float], str]:
        navigation = env._navigation_context()
        speed_limit_knots = float(
            navigation.get("speed_limit_knots", 0.0) or 0.0
        )
        if speed_limit_knots <= 0.0:
            return proposed, "no_speed_limit"

        limit_mps = speed_limit_knots * 0.514444
        permitted = limit_mps * (
            1.0 - float(self.config.speed_limit_buffer_ratio)
        )
        proposed_throttle = float(proposed[0])
        if self._preview_maximum_speed(env, proposed_throttle) <= permitted:
            return proposed, "speed_preview_safe"

        lower = -1.0
        if self._preview_maximum_speed(env, lower) > permitted:
            return (lower, proposed[1]), "speed_recovery_full_brake"

        upper = proposed_throttle
        for _ in range(
            max(1, int(self.config.speed_governor_search_iterations))
        ):
            candidate = (lower + upper) * 0.5
            if self._preview_maximum_speed(env, candidate) <= permitted:
                lower = candidate
            else:
                upper = candidate
        return (lower, proposed[1]), "speed_preview_throttle_projection"

    def _govern_route_action(
        self,
        env: Any,
        proposed: tuple[float, float],
    ) -> tuple[tuple[float, float], str]:
        heading_error = float(env._heading_error())
        magnitude_degrees = abs(math.degrees(heading_error))
        trigger = float(self.config.route_recovery_heading_trigger_degrees)
        full = max(
            float(self.config.route_recovery_heading_full_degrees),
            trigger + 1e-6,
        )
        if magnitude_degrees <= trigger:
            return proposed, "route_heading_inside_envelope"
        urgency = float(
            np.clip((magnitude_degrees - trigger) / (full - trigger), 0.0, 1.0)
        )
        blend = urgency * float(self.config.route_recovery_maximum_blend)
        route_rudder = float(
            np.clip(
                float(self.config.route_recovery_rudder_gain) * heading_error,
                -1.0,
                1.0,
            )
        )
        rudder = (1.0 - blend) * proposed[1] + blend * route_rudder
        return (proposed[0], float(np.clip(rudder, -1.0, 1.0))), "route_heading_recovery"

    def _requires_review(
        self,
        env: Any,
        proposed: tuple[float, float],
    ) -> tuple[bool, str]:
        review, reason = super()._requires_review(env, proposed)
        if (
            reason == "aggressive_command"
            and not self.config.review_aggressive_commands_without_hazard
        ):
            return False, "pass_through"
        if reason == "speed_margin":
            # The V5 governor has already mirrored twelve steps of the exact
            # longitudinal dynamics and bounded the command below the limit.
            return False, "speed_governor_authoritative"
        return review, reason

    def project(self, env: Any, action: Any) -> SafetyDecision:
        raw = self._continuous_action(env, action)
        tolerance = float(self.config.action_equality_tolerance)
        route_governed, route_reason = self._govern_route_action(env, raw)
        route_changed = bool(
            np.max(np.abs(np.asarray(route_governed) - np.asarray(raw)))
            > tolerance
        )
        governed, speed_reason = self._govern_speed_action(env, route_governed)
        speed_changed = bool(
            np.max(
                np.abs(np.asarray(governed) - np.asarray(route_governed))
            )
            > tolerance
        )
        governor_changed = route_changed or speed_changed

        decision = super().project(env, governed)
        supervisor_changed = bool(decision.intervened)
        if supervisor_changed:
            self.hazard_supervisor_intervention_steps += 1
        combined_changed = bool(
            np.max(
                np.abs(np.asarray(decision.applied_action) - np.asarray(raw))
            )
            > tolerance
        )

        # V4 counts changes relative to the governed action.  Count a governor-
        # only projection too, while ensuring a step changed by both layers is
        # still counted once.
        if combined_changed and not supervisor_changed:
            self.interventions += 1
            self.intervention_steps += 1
        elif not combined_changed and supervisor_changed:
            self.interventions = max(0, self.interventions - 1)
            self.intervention_steps = max(0, self.intervention_steps - 1)

        self.project_calls += 1
        if route_changed:
            self.route_recovery_steps += 1
            self.governor_reason_counts[route_reason] = (
                self.governor_reason_counts.get(route_reason, 0) + 1
            )
        if speed_changed:
            self.speed_governor_steps += 1
            self.governor_reason_counts[speed_reason] = (
                self.governor_reason_counts.get(speed_reason, 0) + 1
            )
        if not combined_changed:
            self.raw_sac_action_accepted_steps += 1
        throttle_retained = (
            abs(float(decision.applied_action[0]) - raw[0]) <= tolerance
        )
        rudder_retained = (
            abs(float(decision.applied_action[1]) - raw[1]) <= tolerance
        )
        if rudder_retained:
            self.rl_rudder_retained_steps += 1
        if throttle_retained or rudder_retained:
            self.rl_any_dimension_retained_steps += 1

        reason = str(decision.reason)
        if governor_changed:
            governor_reasons = [
                value
                for changed, value in (
                    (route_changed, route_reason),
                    (speed_changed, speed_reason),
                )
                if changed
            ]
            governor_reason = "+".join(governor_reasons)
            reason = (
                governor_reason
                if reason == "pass_through"
                else f"{governor_reason}+{reason}"
            )
        return SafetyDecision(
            proposed_action=raw,
            applied_action=decision.applied_action,
            intervened=combined_changed,
            feasible=decision.feasible,
            fail_closed=decision.fail_closed,
            reason=reason,
            candidates_evaluated=decision.candidates_evaluated,
            predicted_minimum_clearance_meters=(
                decision.predicted_minimum_clearance_meters
            ),
            predicted_minimum_dcpa_meters=(
                decision.predicted_minimum_dcpa_meters
            ),
            predicted_collision=decision.predicted_collision,
            predicted_grounding=decision.predicted_grounding,
            predicted_channel_violation=(
                decision.predicted_channel_violation
            ),
            predicted_colreg_violation=decision.predicted_colreg_violation,
            predicted_speed_violation=decision.predicted_speed_violation,
            risk_score=decision.risk_score,
        )

    def summary(self) -> dict[str, Any]:
        value = super().summary()
        steps = max(self.project_calls, 1)
        value.update(
            {
                "project_calls": self.project_calls,
                "speed_governor_steps": self.speed_governor_steps,
                "speed_governor_step_rate": self.speed_governor_steps / steps,
                "route_recovery_steps": self.route_recovery_steps,
                "route_recovery_step_rate": self.route_recovery_steps / steps,
                "hazard_supervisor_intervention_steps": (
                    self.hazard_supervisor_intervention_steps
                ),
                "hazard_supervisor_intervention_step_rate": (
                    self.hazard_supervisor_intervention_steps / steps
                ),
                "raw_sac_action_accepted_steps": (
                    self.raw_sac_action_accepted_steps
                ),
                "raw_sac_action_accepted_step_rate": (
                    self.raw_sac_action_accepted_steps / steps
                ),
                "rl_rudder_retained_steps": self.rl_rudder_retained_steps,
                "rl_rudder_retained_step_rate": (
                    self.rl_rudder_retained_steps / steps
                ),
                "rl_any_dimension_retained_steps": (
                    self.rl_any_dimension_retained_steps
                ),
                "rl_any_dimension_retained_step_rate": (
                    self.rl_any_dimension_retained_steps / steps
                ),
                "governor_reason_counts": dict(self.governor_reason_counts),
            }
        )
        return value


__all__ = [
    "SacChampionSafetyConfig",
    "SacChampionSafetySupervisor",
]
