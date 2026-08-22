"""Model-predictive runtime safety supervisor for port-navigation policies.

The supervisor is deliberately separate from every learner/controller.  It
uses only the simulator state that is available at the current decision time,
tests a small, declared action set on copied environment state, and either
passes the proposed command through or projects it to the lowest-risk command.
It is an offline software assurance layer, not a COLREGs certificate or a
replacement for vessel hardware interlocks.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
import copy
import math
from typing import Any, Iterable, Mapping, Sequence

import numpy as np

from .environment import DISCRETE_ACTIONS


@dataclass(frozen=True)
class SafetySupervisorConfig:
    profile_id: str = "port_ops_model_predictive_safety_v3"
    enabled: bool = True
    trigger_clearance_meters: float = 100.0
    target_clearance_meters: float = 80.0
    hard_clearance_meters: float = 8.0
    horizon_steps: int = 12
    decision_interval_steps: int = 20
    intervention_hold_steps: int = 0
    action_deviation_weight: float = 0.18
    route_progress_weight: float = 0.08
    heading_error_weight: float = 0.35
    clearance_weight: float = 7.5
    dcpa_weight: float = 4.0
    channel_violation_weight: float = 24.0
    colreg_violation_weight: float = 30.0
    speed_violation_weight: float = 8.0
    collision_weight: float = 10_000.0
    grounding_weight: float = 12_000.0
    fail_closed_reverse_throttle: float = -1.0

    @classmethod
    def from_mapping(cls, value: Mapping[str, Any]) -> "SafetySupervisorConfig":
        known = {field.name for field in cls.__dataclass_fields__.values()}
        payload = {key: value[key] for key in known if key in value}
        return cls(**payload)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class SafetyDecision:
    proposed_action: tuple[float, float]
    applied_action: tuple[float, float]
    intervened: bool
    feasible: bool
    fail_closed: bool
    reason: str
    candidates_evaluated: int
    predicted_minimum_clearance_meters: float
    predicted_minimum_dcpa_meters: float
    predicted_collision: bool
    predicted_grounding: bool
    predicted_channel_violation: bool
    predicted_colreg_violation: bool
    predicted_speed_violation: bool
    risk_score: float

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


class ModelPredictiveSafetySupervisor:
    """Project arbitrary policy actions through a conservative safety layer."""

    _CONTINUOUS_CANDIDATES: tuple[tuple[float, float], ...] = (
        (-1.0, 0.0),
        (-1.0, 1.0),
        (-1.0, -1.0),
        (-0.20, 1.0),
        (-0.20, -1.0),
        (0.10, 1.0),
        (0.10, -1.0),
    )

    def __init__(self, config: SafetySupervisorConfig | None = None) -> None:
        self.config = config or SafetySupervisorConfig()
        self.interventions = 0
        self.intervention_steps = 0
        self.fail_closed_events = 0
        self.candidate_evaluations = 0
        self.reason_counts: dict[str, int] = {}
        self._held_action: tuple[float, float] | None = None
        self._hold_remaining = 0
        self._cached_decision: SafetyDecision | None = None
        self._next_review_step = 0

    def reset(self) -> None:
        self._held_action = None
        self._hold_remaining = 0
        self._cached_decision = None
        self._next_review_step = 0

    @staticmethod
    def _continuous_action(env: Any, action: Any) -> tuple[float, float]:
        if bool(getattr(env, "discrete_actions", False)):
            value = DISCRETE_ACTIONS[int(np.asarray(action).reshape(-1)[0])]
        else:
            value = np.asarray(action, dtype=np.float64).reshape(-1)
        return (
            float(np.clip(value[0], -1.0, 1.0)),
            float(np.clip(value[1], -1.0, 1.0)),
        )

    @staticmethod
    def _environment_action(env: Any, action: Sequence[float]) -> Any:
        continuous = np.asarray(action, dtype=np.float32)
        if not bool(getattr(env, "discrete_actions", False)):
            return continuous
        distances = [
            float(np.sum((continuous - candidate) ** 2))
            for candidate in DISCRETE_ACTIONS
        ]
        return int(np.argmin(distances))

    def _requires_review(self, env: Any, proposed: Sequence[float]) -> tuple[bool, str]:
        if not self.config.enabled:
            return False, "disabled"
        nearest = env.avoidance_context()
        encounter = env._encounter_context()
        clearance = float(nearest.get("clearance", 0.0))
        predicted_conflict = bool(
            float(encounter.get("tcpa", math.inf))
            < float(env.environment_config["tcpa_horizon_seconds"])
            and float(encounter.get("dcpa", math.inf))
            < self.config.target_clearance_meters
        )
        ukc, ukc_valid = env._under_keel_clearance()
        minimum_ukc = float(
            env._navigation_context().get(
                "minimum_under_keel_clearance_meters",
                env.config.get("rl_parameters", {}).get(
                    "minimum_under_keel_clearance_meters", 1.0
                ),
            )
        )
        fairway_inside, fairway_margin, fairway_valid = env._fairway_context()
        speed_limit = float(
            env._navigation_context().get("speed_limit_knots", 0.0) or 0.0
        )
        speed_knots = abs(float(env.state[3])) / 0.514444
        if ukc_valid and ukc < minimum_ukc + 0.5:
            return True, "under_keel_clearance"
        if fairway_valid and not fairway_inside:
            return True, "outside_fairway"
        fairway_trigger = max(
            self.config.hard_clearance_meters * 2.0,
            float(env.reward_config.get("safe_distance", 42.0)),
        )
        if fairway_valid and fairway_margin < fairway_trigger:
            return True, "fairway_margin"
        if speed_limit > 0.0 and speed_knots > speed_limit * 0.96:
            return True, "speed_margin"
        if predicted_conflict:
            return True, "predicted_traffic_conflict"
        if bool(encounter.get("give_way", False)):
            return True, "give_way_encounter"
        if clearance < self.config.trigger_clearance_meters:
            return True, "clearance_trigger"
        if self._hold_remaining > 0 and self._held_action is not None:
            return True, "intervention_hold"
        proposed_pair = tuple(float(value) for value in proposed)
        if proposed_pair[0] > 0.70 and abs(proposed_pair[1]) > 0.85:
            return True, "aggressive_command"
        return False, "pass_through"

    @staticmethod
    def _unique_actions(values: Iterable[Sequence[float]]) -> list[tuple[float, float]]:
        result: list[tuple[float, float]] = []
        seen: set[tuple[float, float]] = set()
        for value in values:
            action = (
                round(float(np.clip(value[0], -1.0, 1.0)), 4),
                round(float(np.clip(value[1], -1.0, 1.0)), 4),
            )
            if action not in seen:
                seen.add(action)
                result.append(action)
        return result

    def _candidate_actions(
        self,
        env: Any,
        proposed: Sequence[float],
    ) -> list[tuple[float, float]]:
        encounter = env._encounter_context()
        values: list[Sequence[float]] = [proposed]
        if self._hold_remaining > 0 and self._held_action is not None:
            values.append(self._held_action)
        values.extend(self._CONTINUOUS_CANDIDATES)
        if str(encounter.get("encounter", "none")) in {
            "head_on",
            "crossing_starboard",
        }:
            values.insert(1, (-0.20, 1.0))
            values.insert(2, (0.10, 1.0))
        if bool(getattr(env, "discrete_actions", False)):
            values.extend(tuple(float(item) for item in action) for action in DISCRETE_ACTIONS)
        return self._unique_actions(values)

    def _simulate_candidate(
        self,
        env: Any,
        proposed: Sequence[float],
        candidate: Sequence[float],
    ) -> dict[str, Any]:
        # A full deepcopy would copy the complete AIS/ENC dataset for every
        # candidate.  The predictor needs only mutable episode state; immutable
        # task/config/geometry inventories are shared read-only.
        simulated = copy.copy(env)
        simulated.state = env.state.copy()
        simulated.previous_action = env.previous_action.copy()
        prediction_reach = (
            max(
                self.config.trigger_clearance_meters,
                self.config.target_clearance_meters,
            )
            + float(env.performance.max_forward_speed)
            * float(env.delta)
            * max(1, self.config.horizon_steps)
            + 20.0
        )
        relevant_names = {
            item.name
            for item, clearance, _bearing, _x, _z in env._obstacle_measurements()
            if clearance <= prediction_reach or item.dynamic
        }
        simulated.obstacles = [
            copy.copy(item) for item in env.obstacles if item.name in relevant_names
        ]
        simulated.last_collision = dict(env.last_collision)
        simulated.trajectory = []
        simulated._state_cache_key = None
        simulated._state_cache = {}
        simulated.rng = np.random.default_rng()
        simulated.rng.bit_generator.state = copy.deepcopy(
            env.rng.bit_generator.state
        )
        minimum_clearance = float(simulated.avoidance_context().get("clearance", 0.0))
        encounter = simulated._encounter_context()
        minimum_dcpa = float(encounter.get("dcpa", 0.0))
        collision = False
        grounding = False
        channel_violation = False
        colreg_violation = False
        speed_violation = False
        initial_distance = float(simulated._distance_to_target())
        terminated = truncated = False
        for _ in range(max(1, self.config.horizon_steps)):
            step_action = self._environment_action(simulated, candidate)
            command = self._continuous_action(simulated, step_action)
            simulated._advance_dynamic_obstacles()
            simulated._integrate(command[0], command[1])
            simulated.steps += 1
            simulated._obstacle_bbox_by_name = {
                item.name: simulated._obstacle_bbox(item)
                for item in simulated.obstacles
            }
            simulated._clear_state_cache()
            nearest = simulated._nearest_obstacle(False)
            current_clearance = float(nearest.get("clearance", 0.0))
            current_dcpa = float(nearest.get("dcpa", minimum_dcpa))
            boundary_collision = simulated._boundary_clearance() <= 0.0
            current_collision = boundary_collision or current_clearance <= 0.0
            ukc, ukc_valid = simulated._under_keel_clearance()
            current_grounding = not ukc_valid or ukc <= 0.0
            fairway_inside, _fairway_margin, fairway_valid = (
                simulated._fairway_context()
            )
            navigation = simulated._navigation_context()
            current_channel_violation = bool(
                navigation.get("enforce_fairway", False)
                and fairway_valid
                and not fairway_inside
            )
            current_encounter = simulated._encounter_context()
            encounter_name = str(current_encounter.get("encounter", "none"))
            predicted_conflict = bool(
                current_encounter.get("give_way", False)
                and float(current_encounter.get("tcpa", math.inf))
                < float(simulated.environment_config["tcpa_horizon_seconds"])
                and float(current_encounter.get("dcpa", math.inf))
                < float(simulated.reward_config["safe_distance"])
            )
            current_colreg_violation = bool(
                predicted_conflict
                and (
                    (
                        encounter_name in {"head_on", "crossing_starboard"}
                        and command[1] < 0.1
                        and command[0] > 0.15
                    )
                    or (encounter_name == "overtaking" and command[0] > 0.35)
                )
            )
            speed_limit = float(navigation.get("speed_limit_knots", 0.0) or 0.0)
            speed_knots = abs(float(simulated.state[3])) / 0.514444
            current_speed_violation = (
                speed_limit > 0.0 and speed_knots > speed_limit
            )
            target_distance = float(simulated._distance_to_target())
            if target_distance <= float(simulated.task.get("arrival_radius", 12.0)):
                if simulated.waypoint_index >= len(simulated.route) - 1:
                    terminated = True
                else:
                    simulated.waypoint_index += 1
                    simulated._clear_state_cache()
            truncated = simulated.steps >= simulated.max_steps and not terminated
            minimum_clearance = min(
                minimum_clearance,
                current_clearance,
            )
            minimum_dcpa = min(
                minimum_dcpa,
                current_dcpa,
            )
            collision = collision or current_collision
            grounding = grounding or current_grounding
            channel_violation = channel_violation or current_channel_violation
            colreg_violation = colreg_violation or current_colreg_violation
            speed_violation = speed_violation or current_speed_violation
            if collision or grounding or terminated or truncated:
                break
        final_distance = float(simulated._distance_to_target())
        progress = initial_distance - final_distance
        heading_error = abs(float(simulated._heading_error()))
        target_clearance = max(self.config.target_clearance_meters, 1.0)
        target_dcpa = max(self.config.target_clearance_meters, 1.0)
        score = 0.0
        score += self.config.collision_weight if collision else 0.0
        score += self.config.grounding_weight if grounding else 0.0
        score += self.config.channel_violation_weight if channel_violation else 0.0
        score += self.config.colreg_violation_weight if colreg_violation else 0.0
        score += self.config.speed_violation_weight if speed_violation else 0.0
        score += self.config.clearance_weight * max(
            0.0, (target_clearance - minimum_clearance) / target_clearance
        )
        score += self.config.dcpa_weight * max(
            0.0, (target_dcpa - minimum_dcpa) / target_dcpa
        )
        score += self.config.heading_error_weight * heading_error
        score -= self.config.route_progress_weight * progress
        score += self.config.action_deviation_weight * float(
            np.sum((np.asarray(candidate) - np.asarray(proposed)) ** 2)
        )
        encounter_name = str(encounter.get("encounter", "none"))
        if encounter_name in {"head_on", "crossing_starboard"} and candidate[1] < 0.1:
            score += self.config.colreg_violation_weight * 0.5
        feasible = bool(
            not collision
            and not grounding
            and minimum_clearance >= self.config.hard_clearance_meters
        )
        return {
            "action": tuple(float(value) for value in candidate),
            "feasible": feasible,
            "collision": collision,
            "grounding": grounding,
            "channel_violation": channel_violation,
            "colreg_violation": colreg_violation,
            "speed_violation": speed_violation,
            "minimum_clearance": minimum_clearance,
            "minimum_dcpa": minimum_dcpa,
            "score": float(score),
        }

    def project(self, env: Any, action: Any) -> SafetyDecision:
        proposed = self._continuous_action(env, action)
        if (
            self.config.enabled
            and self._cached_decision is not None
            and int(env.steps) < self._next_review_step
        ):
            cached = self._cached_decision
            applied = cached.applied_action
            intervened = bool(
                np.max(np.abs(np.asarray(applied) - np.asarray(proposed))) > 1e-5
            )
            if intervened:
                self.intervention_steps += 1
            return SafetyDecision(
                proposed_action=proposed,
                applied_action=applied,
                intervened=intervened,
                feasible=cached.feasible,
                fail_closed=cached.fail_closed,
                reason="cached_safety_command",
                candidates_evaluated=0,
                predicted_minimum_clearance_meters=(
                    cached.predicted_minimum_clearance_meters
                ),
                predicted_minimum_dcpa_meters=(
                    cached.predicted_minimum_dcpa_meters
                ),
                predicted_collision=cached.predicted_collision,
                predicted_grounding=cached.predicted_grounding,
                predicted_channel_violation=cached.predicted_channel_violation,
                predicted_colreg_violation=cached.predicted_colreg_violation,
                predicted_speed_violation=cached.predicted_speed_violation,
                risk_score=cached.risk_score,
            )
        review, trigger_reason = self._requires_review(env, proposed)
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
        candidates = self._candidate_actions(env, proposed)
        evaluated = [
            self._simulate_candidate(env, proposed, candidate)
            for candidate in candidates
        ]
        self.candidate_evaluations += len(evaluated)
        feasible = [item for item in evaluated if item["feasible"]]
        fail_closed = not feasible
        if feasible:
            proposed_projection = evaluated[0]
            current_encounter = env._encounter_context()
            dynamic_conflict = bool(
                float(current_encounter.get("tcpa", math.inf))
                < float(env.environment_config["tcpa_horizon_seconds"])
                and float(current_encounter.get("dcpa", math.inf))
                < self.config.target_clearance_meters
            )
            static_safety_clearance = max(
                self.config.hard_clearance_meters * 2.0,
                float(env.reward_config.get("safe_distance", 42.0)),
            )
            safety_critical = bool(
                proposed_projection["collision"]
                or proposed_projection["grounding"]
                or proposed_projection["minimum_clearance"]
                < static_safety_clearance
                or dynamic_conflict
            )
            if safety_critical:
                selected = min(
                    feasible,
                    key=lambda item: (
                        item["colreg_violation"],
                        item["channel_violation"],
                        -item["minimum_clearance"],
                        -item["minimum_dcpa"],
                        item["score"],
                    ),
                )
            else:
                selected = min(feasible, key=lambda item: item["score"])
            reason = trigger_reason
        else:
            selected = min(
                evaluated,
                key=lambda item: (
                    item["collision"],
                    item["grounding"],
                    -item["minimum_clearance"],
                    item["score"],
                ),
            )
            emergency = (
                self.config.fail_closed_reverse_throttle,
                float(selected["action"][1]),
            )
            selected = self._simulate_candidate(env, proposed, emergency)
            selected["action"] = emergency
            reason = "fail_closed_no_feasible_candidate"
            self.fail_closed_events += 1
        applied = tuple(float(value) for value in selected["action"])
        intervened = bool(np.max(np.abs(np.asarray(applied) - np.asarray(proposed))) > 1e-5)
        if intervened:
            self.interventions += 1
            self.intervention_steps += 1
            self._held_action = applied
            self._hold_remaining = max(0, self.config.intervention_hold_steps)
        elif self._hold_remaining > 0:
            self._hold_remaining -= 1
        self.reason_counts[reason] = self.reason_counts.get(reason, 0) + 1
        decision = SafetyDecision(
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
        self._cached_decision = decision
        self._next_review_step = int(env.steps) + max(
            1, self.config.decision_interval_steps
        )
        return decision

    def environment_action(self, env: Any, decision: SafetyDecision) -> Any:
        return self._environment_action(env, decision.applied_action)

    def summary(self) -> dict[str, Any]:
        return {
            "profile": self.config.to_dict(),
            "interventions": self.interventions,
            "intervention_steps": self.intervention_steps,
            "fail_closed_events": self.fail_closed_events,
            "candidate_evaluations": self.candidate_evaluations,
            "reason_counts": dict(sorted(self.reason_counts.items())),
        }


__all__ = [
    "ModelPredictiveSafetySupervisor",
    "SafetyDecision",
    "SafetySupervisorConfig",
]
