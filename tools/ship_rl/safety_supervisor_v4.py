"""Utility-preserving runtime safety supervisor for port navigation.

V4 is additive: it does not modify the frozen V3 supervisor or any V1/V2/V3
evidence.  It keeps model-predictive action checking, but reviews only hazards
that are closing or operationally relevant, replans every active step instead
of caching a coarse command for twenty steps, and ranks feasible commands by
both safety and route utility.

The implementation remains an offline simulation safety layer.  It is not a
COLREGs certificate, a hardware interlock, or authority for live-vessel use.
"""

from __future__ import annotations

import copy
from dataclasses import dataclass
import math
from typing import Any, Sequence

import numpy as np

from .safety_supervisor import (
    ModelPredictiveSafetySupervisor,
    SafetyDecision,
    SafetySupervisorConfig,
)


@dataclass(frozen=True)
class UtilityPreservingSafetyConfig(SafetySupervisorConfig):
    profile_id: str = "port_ops_utility_preserving_safety_v4"
    trigger_clearance_meters: float = 72.0
    target_clearance_meters: float = 48.0
    hard_clearance_meters: float = 4.0
    horizon_steps: int = 10
    decision_interval_steps: int = 1
    action_deviation_weight: float = 2.5
    route_progress_weight: float = 0.45
    heading_error_weight: float = 0.9
    clearance_weight: float = 5.0
    dcpa_weight: float = 3.0
    fail_closed_reverse_throttle: float = -0.55
    critical_tcpa_seconds: float = 900.0
    closing_speed_threshold_mps: float = 0.05
    forward_hazard_bearing_degrees: float = 100.0
    stopping_distance_margin_meters: float = 12.0
    maximum_dynamic_trigger_meters: float = 140.0
    colreg_trigger_buffer_meters: float = 25.0
    operational_preview_steps: int = 10
    escape_sequence_horizon_steps: int = 120
    escape_sequence_switch_steps: int = 3
    escape_search_retry_steps: int = 120
    guardian_route_gain: float = 1.35
    guardian_avoidance_gain: float = 0.85
    preferred_speed_ratio: float = 0.68


class UtilityPreservingSafetySupervisor(ModelPredictiveSafetySupervisor):
    """Safety projection that preserves a feasible base command when possible."""

    config: UtilityPreservingSafetyConfig

    def __init__(
        self,
        config: UtilityPreservingSafetyConfig | None = None,
    ) -> None:
        super().__init__(config or UtilityPreservingSafetyConfig())
        self._escape_plan: list[tuple[float, float]] = []
        self._escape_prediction: dict[str, Any] = {}
        self._next_escape_search_step = 0
        self._escape_search_obstacle_name: str | None = None
        self.escape_plans_activated = 0
        self.escape_plan_steps = 0
        self.escape_sequence_evaluations = 0

    def reset(self) -> None:
        super().reset()
        self._escape_plan = []
        self._escape_prediction = {}
        self._next_escape_search_step = 0
        self._escape_search_obstacle_name = None

    def _stopping_trigger(self, env: Any) -> float:
        speed = max(float(env.state[3]), 0.0)
        deceleration = max(float(env.performance.brake_acceleration), 0.05)
        stopping_distance = speed * speed / (2.0 * deceleration)
        response_distance = speed * float(env.delta) * 2.0
        return max(
            self.config.hard_clearance_meters * 2.0,
            min(
                self.config.maximum_dynamic_trigger_meters,
                stopping_distance
                + response_distance
                + self.config.stopping_distance_margin_meters,
            ),
        )

    def _near_term_operational_conflict(
        self,
        env: Any,
        proposed: Sequence[float],
    ) -> str | None:
        """Mirror near-term operational checks before allowing pass-through.

        The environment classifies only the nearest dynamic target *after* all
        traffic and the own ship have moved.  A different target can therefore
        become authoritative in the next step even when the current nearest
        target is benign.  Depth coverage, fairway membership, and speed can
        likewise cross a discrete boundary in one step.  This preview copies
        mutable state and never advances the live environment.
        """

        simulated = copy.copy(env)
        simulated.state = env.state.copy()
        simulated.previous_action = env.previous_action.copy()
        simulated.obstacles = [
            copy.copy(obstacle)
            for obstacle in env.obstacles
            if obstacle.dynamic
        ]
        simulated._obstacle_bbox_by_name = {
            obstacle.name: simulated._obstacle_bbox(obstacle)
            for obstacle in simulated.obstacles
        }
        simulated._state_cache_key = None
        simulated._state_cache = {}
        minimum_ukc = float(
            simulated._navigation_context().get(
                "minimum_under_keel_clearance_meters",
                simulated.config.get("rl_parameters", {}).get(
                    "minimum_under_keel_clearance_meters", 1.0
                ),
            )
        )
        command = tuple(float(value) for value in proposed)
        for _ in range(max(1, self.config.operational_preview_steps)):
            simulated._advance_dynamic_obstacles()
            simulated._integrate(command[0], command[1])
            simulated.steps += 1
            simulated._obstacle_bbox_by_name = {
                obstacle.name: simulated._obstacle_bbox(obstacle)
                for obstacle in simulated.obstacles
            }
            simulated._clear_state_cache()
            ukc, ukc_valid = simulated._under_keel_clearance()
            if not ukc_valid or ukc <= minimum_ukc:
                return "near_term_under_keel_clearance"
            fairway_inside, _fairway_margin, fairway_valid = (
                simulated._fairway_context()
            )
            if (
                bool(
                    simulated._navigation_context().get(
                        "enforce_fairway", False
                    )
                )
                and fairway_valid
                and not fairway_inside
            ):
                return "near_term_outside_enforced_fairway"
            speed_limit = float(
                simulated._navigation_context().get(
                    "speed_limit_knots", 0.0
                )
                or 0.0
            )
            speed_knots = abs(float(simulated.state[3])) / 0.514444
            if speed_limit > 0.0 and speed_knots > speed_limit:
                return "near_term_speed_violation"

            encounter = simulated._encounter_context()
            predicted_conflict = bool(
                encounter.get("give_way", False)
                and float(encounter.get("tcpa", math.inf))
                < float(simulated.environment_config["tcpa_horizon_seconds"])
                and float(encounter.get("dcpa", math.inf))
                < float(simulated.reward_config["safe_distance"])
            )
            encounter_name = str(encounter.get("encounter", "none"))
            violation = bool(
                predicted_conflict
                and (
                    (
                        encounter_name
                        in {"head_on", "crossing_starboard"}
                        and command[1] < 0.1
                        and command[0] > 0.15
                    )
                    or (
                        encounter_name == "overtaking"
                        and command[0] > 0.35
                    )
                )
            )
            if violation:
                return "near_term_colreg_conflict"
        return None

    def _requires_review(
        self,
        env: Any,
        proposed: Sequence[float],
    ) -> tuple[bool, str]:
        if not self.config.enabled:
            return False, "disabled"

        ukc, ukc_valid = env._under_keel_clearance()
        minimum_ukc = float(
            env._navigation_context().get(
                "minimum_under_keel_clearance_meters",
                env.config.get("rl_parameters", {}).get(
                    "minimum_under_keel_clearance_meters", 1.0
                ),
            )
        )
        if not ukc_valid or ukc <= minimum_ukc:
            return True, "under_keel_clearance"

        fairway_inside, _fairway_margin, fairway_valid = env._fairway_context()
        if (
            bool(env._navigation_context().get("enforce_fairway", False))
            and fairway_valid
            and not fairway_inside
        ):
            return True, "outside_enforced_fairway"

        speed_limit = float(
            env._navigation_context().get("speed_limit_knots", 0.0) or 0.0
        )
        speed_knots = abs(float(env.state[3])) / 0.514444
        if speed_limit > 0.0 and speed_knots > speed_limit * 0.985:
            return True, "speed_margin"

        encounter = env._encounter_context()
        tcpa = float(encounter.get("tcpa", math.inf))
        dcpa = float(encounter.get("dcpa", math.inf))
        colreg_clearance = max(
            self.config.target_clearance_meters,
            float(env.reward_config.get("safe_distance", 0.0)),
        )
        dynamic_conflict = bool(
            encounter.get("obstacle") is not None
            and 0.0 <= tcpa <= self.config.critical_tcpa_seconds
            and dcpa
            < colreg_clearance + self.config.colreg_trigger_buffer_meters
        )
        if not dynamic_conflict:
            for obstacle, _clearance, _bearing, target_x, target_z in (
                env._obstacle_measurements()
            ):
                if not obstacle.dynamic:
                    continue
                _closing, target_tcpa, target_dcpa = env._relative_motion(
                    obstacle, target_x, target_z
                )
                if (
                    0.0 <= target_tcpa <= self.config.critical_tcpa_seconds
                    and target_dcpa
                    < colreg_clearance
                    + self.config.colreg_trigger_buffer_meters
                ):
                    dynamic_conflict = True
                    break
        if dynamic_conflict:
            return True, "closing_traffic_conflict"
        near_term_conflict = self._near_term_operational_conflict(env, proposed)
        if near_term_conflict is not None:
            return True, near_term_conflict

        nearest = env.avoidance_context()
        clearance = float(nearest.get("clearance", math.inf))
        closing = float(nearest.get("closing_speed", 0.0))
        bearing_degrees = abs(math.degrees(float(nearest.get("bearing", 0.0))))
        relevant_static_hazard = bool(
            not bool(nearest.get("dynamic", False))
            and clearance <= self._stopping_trigger(env)
            and bearing_degrees <= self.config.forward_hazard_bearing_degrees
            and closing > self.config.closing_speed_threshold_mps
        )
        if relevant_static_hazard:
            return True, "closing_static_hazard"

        proposed_pair = tuple(float(value) for value in proposed)
        if proposed_pair[0] > 0.85 and abs(proposed_pair[1]) > 0.92:
            return True, "aggressive_command"
        return False, "pass_through"

    def _guardian_action(self, env: Any) -> tuple[float, float]:
        navigation = env._navigation_context()
        speed_limit = float(navigation.get("speed_limit_knots", 0.0) or 0.0)
        limit_mps = speed_limit * 0.514444 if speed_limit > 0.0 else math.inf
        target_speed = min(
            float(env.performance.max_forward_speed)
            * self.config.preferred_speed_ratio,
            limit_mps,
        )
        speed = max(float(env.state[3]), 0.0)
        speed_error = target_speed - speed
        throttle = float(
            np.clip(
                speed_error / max(float(env.performance.max_forward_speed), 0.1)
                + 0.42,
                -0.35,
                0.72,
            )
        )
        route_rudder = float(
            np.clip(
                self.config.guardian_route_gain * float(env._heading_error()),
                -1.0,
                1.0,
            )
        )
        nearest = env.avoidance_context()
        clearance = float(nearest.get("clearance", math.inf))
        bearing = float(nearest.get("bearing", 0.0))
        trigger = max(self._stopping_trigger(env), self.config.hard_clearance_meters)
        if clearance < trigger:
            urgency = float(np.clip(1.0 - clearance / trigger, 0.0, 1.0))
            away = -1.0 if bearing >= 0.0 else 1.0
            route_rudder = float(
                np.clip(
                    (1.0 - urgency) * route_rudder
                    + urgency * away * self.config.guardian_avoidance_gain,
                    -1.0,
                    1.0,
                )
            )
            throttle = min(throttle, 0.32 - 0.52 * urgency)

        encounter = env._encounter_context()
        colreg_clearance = max(
            self.config.target_clearance_meters,
            float(env.reward_config.get("safe_distance", 0.0)),
        )
        if (
            encounter.get("obstacle") is not None
            and float(encounter.get("tcpa", math.inf))
            <= self.config.critical_tcpa_seconds
            and float(encounter.get("dcpa", math.inf))
            < colreg_clearance + self.config.colreg_trigger_buffer_meters
        ):
            name = str(encounter.get("encounter", "none"))
            if name in {"head_on", "crossing_starboard"}:
                route_rudder = max(route_rudder, 0.42)
            throttle = min(throttle, 0.12)
        return throttle, route_rudder

    def _candidate_actions(
        self,
        env: Any,
        proposed: Sequence[float],
    ) -> list[tuple[float, float]]:
        proposed_pair = tuple(float(value) for value in proposed)
        guardian = self._guardian_action(env)
        blended = tuple(
            0.55 * proposed_pair[index] + 0.45 * guardian[index]
            for index in range(2)
        )
        reduced = min(proposed_pair[0], 0.25)
        values: list[Sequence[float]] = [
            proposed_pair,
            blended,
            guardian,
            (reduced, float(np.clip(proposed_pair[1] + 0.35, -1.0, 1.0))),
            (reduced, float(np.clip(proposed_pair[1] - 0.35, -1.0, 1.0))),
            (0.05, 0.65),
            (0.05, -0.65),
            (-0.35, 0.0),
            (-0.35, 0.55),
            (-0.35, -0.55),
        ]
        return self._unique_actions(values)

    def _simulate_action_sequence(
        self,
        env: Any,
        actions: Sequence[Sequence[float]],
    ) -> dict[str, Any]:
        simulated = copy.copy(env)
        simulated.state = env.state.copy()
        simulated.previous_action = env.previous_action.copy()
        simulated.obstacles = [copy.copy(obstacle) for obstacle in env.obstacles]
        simulated._obstacle_bbox_by_name = {
            obstacle.name: simulated._obstacle_bbox(obstacle)
            for obstacle in simulated.obstacles
        }
        simulated.last_collision = dict(env.last_collision)
        simulated.trajectory = []
        simulated._state_cache_key = None
        simulated._state_cache = {}
        simulated.rng = np.random.default_rng()
        simulated.rng.bit_generator.state = copy.deepcopy(
            env.rng.bit_generator.state
        )
        initial_collision_count = int(simulated.collision_count)
        initial_grounding_count = int(simulated.grounding_count)
        initial_channel_count = int(simulated.channel_departure_count)
        initial_colreg_count = int(simulated.colreg_violation_count)
        initial_speed_count = int(simulated.speed_violation_count)
        minimum_clearance = float(
            simulated._nearest_obstacle(False).get("clearance", 0.0)
        )
        minimum_dcpa = float(
            simulated._encounter_context().get("dcpa", 0.0)
        )
        info: dict[str, Any] = {}
        for action in actions:
            environment_action = self._environment_action(simulated, action)
            _observation, _reward, terminated, truncated, info = simulated.step(
                environment_action
            )
            minimum_clearance = min(
                minimum_clearance,
                float(
                    simulated._nearest_obstacle(False).get(
                        "clearance", 0.0
                    )
                ),
            )
            minimum_dcpa = min(
                minimum_dcpa,
                float(simulated._encounter_context().get("dcpa", 0.0)),
            )
            if terminated or truncated:
                break
        collision = int(simulated.collision_count) > initial_collision_count
        grounding = int(simulated.grounding_count) > initial_grounding_count
        channel_violation = (
            int(simulated.channel_departure_count) > initial_channel_count
        )
        colreg_violation = (
            int(simulated.colreg_violation_count) > initial_colreg_count
        )
        speed_violation = int(simulated.speed_violation_count) > initial_speed_count
        return {
            "actions": [tuple(float(value) for value in action) for action in actions],
            "feasible": bool(
                not collision
                and not grounding
                and not channel_violation
                and not colreg_violation
                and not speed_violation
                and minimum_clearance >= self.config.hard_clearance_meters
            ),
            "collision": collision,
            "grounding": grounding,
            "channel_violation": channel_violation,
            "colreg_violation": colreg_violation,
            "speed_violation": speed_violation,
            "minimum_clearance": minimum_clearance,
            "minimum_dcpa": minimum_dcpa,
            "final_distance": float(simulated._distance_to_target()),
            "steps_simulated": len(simulated.trajectory),
        }

    def _build_escape_plan(
        self,
        env: Any,
        proposed: Sequence[float],
    ) -> tuple[dict[str, Any] | None, int]:
        encounter = env._encounter_context()
        obstacle_name = str(
            getattr(encounter.get("obstacle"), "name", "")
        )
        if (
            int(env.steps) < self._next_escape_search_step
            or (
                bool(obstacle_name)
                and obstacle_name == self._escape_search_obstacle_name
            )
            or float(encounter.get("dcpa", math.inf))
            > self.config.hard_clearance_meters
            or float(encounter.get("tcpa", math.inf))
            > self.config.critical_tcpa_seconds
        ):
            return None, 0
        self._escape_search_obstacle_name = obstacle_name or None
        horizon = max(1, self.config.escape_sequence_horizon_steps)
        switch = min(
            max(1, self.config.escape_sequence_switch_steps),
            horizon,
        )
        evaluated = 0
        sequences: list[list[tuple[float, float]]] = []
        for direction in (-1.0, 1.0):
            sequences.append(
                [(0.10, direction)] * switch
                + [(0.60, direction)] * (horizon - switch)
            )
            sequences.append(
                [(-0.20, direction)] * switch
                + [(0.40, -direction)] * (horizon - switch)
            )
        candidates = [
            self._simulate_action_sequence(env, sequence)
            for sequence in sequences
        ]
        evaluated += len(candidates)
        self.escape_sequence_evaluations += evaluated
        feasible = [candidate for candidate in candidates if candidate["feasible"]]
        if not feasible:
            self._next_escape_search_step = int(env.steps) + max(
                1, self.config.escape_search_retry_steps
            )
            return None, evaluated
        selected = min(
            feasible,
            key=lambda candidate: (
                -float(candidate["minimum_clearance"]),
                float(candidate["final_distance"]),
            ),
        )
        self._escape_plan = list(selected["actions"])
        self._escape_prediction = selected
        self.escape_plans_activated += 1
        return selected, evaluated

    def _planned_escape_decision(
        self,
        env: Any,
        proposed: tuple[float, float],
        candidates_evaluated: int,
    ) -> SafetyDecision:
        applied = self._escape_plan.pop(0)
        prediction = self._escape_prediction
        intervened = bool(
            np.max(np.abs(np.asarray(applied) - np.asarray(proposed))) > 1e-5
        )
        if intervened:
            self.interventions += 1
            self.intervention_steps += 1
        self.escape_plan_steps += 1
        reason = "planned_dynamic_escape_sequence"
        self.reason_counts[reason] = self.reason_counts.get(reason, 0) + 1
        return SafetyDecision(
            proposed_action=proposed,
            applied_action=applied,
            intervened=intervened,
            feasible=True,
            fail_closed=False,
            reason=reason,
            candidates_evaluated=candidates_evaluated,
            predicted_minimum_clearance_meters=float(
                prediction.get("minimum_clearance", 0.0)
            ),
            predicted_minimum_dcpa_meters=float(
                prediction.get("minimum_dcpa", 0.0)
            ),
            predicted_collision=False,
            predicted_grounding=False,
            predicted_channel_violation=False,
            predicted_colreg_violation=False,
            predicted_speed_violation=False,
            risk_score=0.0,
        )

    @staticmethod
    def _hard_safe(item: dict[str, Any]) -> bool:
        return bool(
            item["feasible"]
            and not item["collision"]
            and not item["grounding"]
        )

    def _selection_key(
        self,
        item: dict[str, Any],
        proposed: Sequence[float],
        trigger_reason: str,
    ) -> tuple[float, ...]:
        deviation = float(
            np.sum(
                (np.asarray(item["action"]) - np.asarray(proposed)) ** 2
            )
        )
        common = (
            float(item["colreg_violation"]),
            float(item["channel_violation"]),
            float(item["speed_violation"]),
        )
        if trigger_reason in {
            "closing_traffic_conflict",
            "near_term_colreg_conflict",
        }:
            return common + (
                -float(item["minimum_dcpa"]),
                -float(item["minimum_clearance"]),
                float(item["score"]),
                deviation,
            )
        if trigger_reason == "closing_static_hazard":
            return common + (
                -float(item["minimum_clearance"]),
                float(item["score"]),
                deviation,
                -float(item["minimum_dcpa"]),
            )
        if trigger_reason == "speed_margin":
            return common + (
                float(item["action"][0]),
                float(item["score"]),
                deviation,
                -float(item["minimum_clearance"]),
            )
        return common + (
            float(item["score"]),
            deviation,
            -float(item["minimum_clearance"]),
            -float(item["minimum_dcpa"]),
        )

    def project(self, env: Any, action: Any) -> SafetyDecision:
        proposed = self._continuous_action(env, action)
        if self._escape_plan:
            review, active_reason = self._requires_review(env, proposed)
            if review and active_reason in {
                "closing_traffic_conflict",
                "near_term_colreg_conflict",
            }:
                return self._planned_escape_decision(env, proposed, 0)
            self._escape_plan = []
            self._escape_prediction = {}
            self._escape_search_obstacle_name = None
        review, trigger_reason = self._requires_review(env, proposed)
        if trigger_reason not in {
            "closing_traffic_conflict",
            "near_term_colreg_conflict",
        }:
            self._escape_search_obstacle_name = None
        if not review:
            return SafetyDecision(
                proposed_action=proposed,
                applied_action=proposed,
                intervened=False,
                feasible=True,
                fail_closed=False,
                reason=trigger_reason,
                candidates_evaluated=0,
                predicted_minimum_clearance_meters=float(
                    env.avoidance_context().get("clearance", 0.0)
                ),
                predicted_minimum_dcpa_meters=float(
                    env._encounter_context().get("dcpa", 0.0)
                ),
                predicted_collision=False,
                predicted_grounding=False,
                predicted_channel_violation=False,
                predicted_colreg_violation=False,
                predicted_speed_violation=False,
                risk_score=0.0,
            )

        if trigger_reason in {
            "closing_traffic_conflict",
            "near_term_colreg_conflict",
        }:
            escape, escape_evaluations = self._build_escape_plan(
                env, proposed
            )
            self.candidate_evaluations += escape_evaluations
            if escape is not None:
                return self._planned_escape_decision(
                    env,
                    proposed,
                    escape_evaluations,
                )

        candidates = self._candidate_actions(env, proposed)
        evaluated = [
            self._simulate_candidate(env, proposed, candidate)
            for candidate in candidates
        ]
        self.candidate_evaluations += len(evaluated)
        hard_safe = [item for item in evaluated if self._hard_safe(item)]
        fail_closed = not hard_safe
        if hard_safe:
            selected = min(
                hard_safe,
                key=lambda item: self._selection_key(
                    item, proposed, trigger_reason
                ),
            )
            reason = trigger_reason
        else:
            selected = min(
                evaluated,
                key=lambda item: (
                    float(item["collision"]),
                    float(item["grounding"]),
                    -float(item["minimum_clearance"]),
                    float(item["score"]),
                ),
            )
            emergency = (
                self.config.fail_closed_reverse_throttle,
                float(selected["action"][1]),
            )
            selected = self._simulate_candidate(env, proposed, emergency)
            selected["action"] = emergency
            reason = "fail_closed_no_hard_safe_candidate"
            self.fail_closed_events += 1

        applied = tuple(float(value) for value in selected["action"])
        intervened = bool(
            np.max(np.abs(np.asarray(applied) - np.asarray(proposed))) > 1e-5
        )
        if intervened:
            self.interventions += 1
            self.intervention_steps += 1
        self.reason_counts[reason] = self.reason_counts.get(reason, 0) + 1
        return SafetyDecision(
            proposed_action=proposed,
            applied_action=applied,
            intervened=intervened,
            feasible=bool(selected["feasible"]),
            fail_closed=fail_closed,
            reason=reason,
            candidates_evaluated=len(evaluated),
            predicted_minimum_clearance_meters=float(selected["minimum_clearance"]),
            predicted_minimum_dcpa_meters=float(selected["minimum_dcpa"]),
            predicted_collision=bool(selected["collision"]),
            predicted_grounding=bool(selected["grounding"]),
            predicted_channel_violation=bool(selected["channel_violation"]),
            predicted_colreg_violation=bool(selected["colreg_violation"]),
            predicted_speed_violation=bool(selected["speed_violation"]),
            risk_score=float(selected["score"]),
        )

    def summary(self) -> dict[str, Any]:
        value = super().summary()
        value.update(
            {
                "escape_plans_activated": self.escape_plans_activated,
                "escape_plan_steps": self.escape_plan_steps,
                "escape_sequence_evaluations": self.escape_sequence_evaluations,
            }
        )
        return value


__all__ = [
    "UtilityPreservingSafetyConfig",
    "UtilityPreservingSafetySupervisor",
]
