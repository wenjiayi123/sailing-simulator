"""Traceable COLREG encounter classification and action-assessment primitives.

The engine records applicable rule references and observable reasons. It is a
deterministic verification oracle for scenario testing, not a legal judgment or
an alternative to a competent watchkeeper.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
import math
from typing import Any, Mapping, Sequence


def _wrap_degrees(value: float) -> float:
    return (float(value) + 180.0) % 360.0 - 180.0


def _velocity(heading_deg: float, speed_mps: float) -> tuple[float, float]:
    heading = math.radians(heading_deg)
    return math.sin(heading) * speed_mps, math.cos(heading) * speed_mps


def _relative_bearing(own: "VesselState", target: "VesselState") -> float:
    absolute = math.degrees(math.atan2(target.east_m - own.east_m, target.north_m - own.north_m))
    return _wrap_degrees(absolute - own.heading_deg)


@dataclass(frozen=True)
class VesselState:
    vessel_id: str
    east_m: float
    north_m: float
    heading_deg: float
    speed_mps: float
    navigation_status: str = "under_way_using_engine"

    @classmethod
    def from_mapping(cls, value: Mapping[str, Any]) -> "VesselState":
        return cls(
            vessel_id=str(value["vessel_id"]),
            east_m=float(value["east_m"]),
            north_m=float(value["north_m"]),
            heading_deg=float(value["heading_deg"]),
            speed_mps=float(value["speed_mps"]),
            navigation_status=str(value.get("navigation_status", "under_way_using_engine")),
        )


@dataclass(frozen=True)
class ControlAction:
    course_change_deg: float
    speed_ratio: float

    @classmethod
    def from_mapping(cls, value: Mapping[str, Any]) -> "ControlAction":
        return cls(
            course_change_deg=float(value.get("course_change_deg", 0.0)),
            speed_ratio=float(value.get("speed_ratio", 1.0)),
        )


@dataclass(frozen=True)
class ColregAssessment:
    encounter: str
    role: str
    risk_of_collision: bool
    relative_bearing_deg: float
    target_aspect_deg: float
    tcpa_s: float | None
    dcpa_m: float
    range_m: float
    rules: tuple[str, ...]
    reasons: tuple[str, ...]

    def export(self) -> dict[str, Any]:
        payload = asdict(self)
        payload["rules"] = list(self.rules)
        payload["reasons"] = list(self.reasons)
        return payload


def closest_point_of_approach(own: VesselState, target: VesselState) -> tuple[float | None, float]:
    relative_east = target.east_m - own.east_m
    relative_north = target.north_m - own.north_m
    own_velocity = _velocity(own.heading_deg, own.speed_mps)
    target_velocity = _velocity(target.heading_deg, target.speed_mps)
    relative_velocity = (
        target_velocity[0] - own_velocity[0],
        target_velocity[1] - own_velocity[1],
    )
    speed_squared = relative_velocity[0] ** 2 + relative_velocity[1] ** 2
    if speed_squared <= 1e-12:
        return None, math.hypot(relative_east, relative_north)
    tcpa = -(
        relative_east * relative_velocity[0]
        + relative_north * relative_velocity[1]
    ) / speed_squared
    if tcpa < 0.0:
        return tcpa, math.hypot(relative_east, relative_north)
    dcpa = math.hypot(
        relative_east + relative_velocity[0] * tcpa,
        relative_north + relative_velocity[1] * tcpa,
    )
    return tcpa, dcpa


def assess_encounter(
    own: VesselState,
    target: VesselState,
    *,
    visibility_nm: float = 10.0,
    vessels_in_sight: bool = True,
    safe_dcpa_m: float = 500.0,
    tcpa_horizon_s: float = 900.0,
) -> ColregAssessment:
    """Classify a powered-vessel encounter and retain the rule trace."""

    bearing = _relative_bearing(own, target)
    target_aspect = _relative_bearing(target, own)
    range_m = math.hypot(target.east_m - own.east_m, target.north_m - own.north_m)
    tcpa, dcpa = closest_point_of_approach(own, target)
    risk = bool(tcpa is not None and 0.0 <= tcpa <= tcpa_horizon_s and dcpa < safe_dcpa_m)
    rules = ["Rule 5", "Rule 6", "Rule 7", "Rule 8"]
    reasons = [
        f"relative bearing {bearing:.2f} deg",
        f"DCPA {dcpa:.1f} m",
        "TCPA unavailable" if tcpa is None else f"TCPA {tcpa:.1f} s",
    ]

    if visibility_nm < 2.0 or not vessels_in_sight:
        rules.append("Rule 19")
        encounter = "restricted_visibility"
        role = "safe_speed_and_avoidance"
        reasons.append("restricted visibility or vessels not in sight")
    elif abs(target_aspect) > 112.5 and own.speed_mps > target.speed_mps and risk:
        rules.append("Rule 13")
        encounter = "overtaking"
        role = "give_way"
        reasons.append("own vessel approaches from more than 22.5 deg abaft target beam")
    else:
        reciprocal_error = abs(abs(_wrap_degrees(target.heading_deg - own.heading_deg)) - 180.0)
        if abs(bearing) <= 10.0 and reciprocal_error <= 15.0 and risk:
            rules.append("Rule 14")
            encounter = "head_on"
            role = "both_give_way"
            reasons.append("nearly reciprocal courses with target nearly ahead")
        elif 0.0 < bearing <= 112.5 and risk:
            rules.extend(("Rule 15", "Rule 16"))
            encounter = "crossing_starboard"
            role = "give_way"
            reasons.append("target is on own starboard side")
        elif -112.5 <= bearing < 0.0 and risk:
            rules.extend(("Rule 15", "Rule 17"))
            encounter = "crossing_port"
            role = "stand_on"
            reasons.append("target is on own port side")
        elif risk:
            encounter = "risk_unclassified"
            role = "early_substantial_action"
            reasons.append("risk exists outside the canonical powered-vessel sectors")
        else:
            encounter = "no_risk"
            role = "monitor"
            reasons.append("CPA thresholds do not establish current collision risk")
    return ColregAssessment(
        encounter=encounter,
        role=role,
        risk_of_collision=risk,
        relative_bearing_deg=bearing,
        target_aspect_deg=target_aspect,
        tcpa_s=tcpa,
        dcpa_m=dcpa,
        range_m=range_m,
        rules=tuple(rules),
        reasons=tuple(reasons),
    )


def assess_action(assessment: ColregAssessment, action: ControlAction) -> dict[str, Any]:
    """Evaluate a proposed course/speed change against the classified duty."""

    turn = float(action.course_change_deg)
    speed_ratio = float(action.speed_ratio)
    substantial = abs(turn) >= 10.0 or speed_ratio <= 0.70
    passed = True
    reason = "continued monitoring is consistent with the current no-risk assessment"
    if not 0.0 <= speed_ratio <= 1.25:
        passed = False
        reason = "speed ratio lies outside the verifier contract"
    elif assessment.encounter in ("head_on", "crossing_starboard"):
        passed = (turn >= 10.0 or speed_ratio <= 0.70) and not (turn < -5.0)
        reason = (
            "substantial starboard alteration or marked speed reduction"
            if passed
            else "give-way action is not early/substantial or alters to port"
        )
    elif assessment.encounter == "overtaking":
        passed = substantial
        reason = "overtaking vessel takes substantial action to keep clear" if passed else "overtaking vessel has not taken substantial action"
    elif assessment.encounter == "crossing_port":
        immediate_danger = assessment.tcpa_s is not None and assessment.tcpa_s < 60.0
        passed = immediate_danger or (abs(turn) <= 5.0 and 0.90 <= speed_ratio <= 1.10)
        reason = (
            "stand-on course and speed maintained"
            if passed and not immediate_danger
            else "immediate danger permits avoidance action"
            if passed
            else "stand-on vessel changes course/speed without the verifier's immediate-danger trigger"
        )
    elif assessment.encounter == "restricted_visibility":
        target_forward = abs(assessment.relative_bearing_deg) <= 112.5
        passed = not (target_forward and turn < -5.0) and (substantial or speed_ratio <= 0.85)
        reason = (
            "safe-speed/avoidance action avoids a port alteration for a vessel forward of the beam"
            if passed
            else "restricted-visibility action is insufficient or alters to port for a vessel forward of the beam"
        )
    elif assessment.risk_of_collision:
        passed = substantial
        reason = "early substantial action" if passed else "risk exists but action is not substantial"
    return {
        "passed": passed,
        "encounter": assessment.encounter,
        "role": assessment.role,
        "rules": list(assessment.rules),
        "action": asdict(action),
        "reason": reason,
    }


def run_scenario_catalog(catalog: Mapping[str, Any]) -> dict[str, Any]:
    results: list[dict[str, Any]] = []
    for scenario in catalog.get("scenarios", []):
        own = VesselState.from_mapping(scenario["own"])
        target = VesselState.from_mapping(scenario["target"])
        assessment = assess_encounter(
            own,
            target,
            visibility_nm=float(scenario.get("visibility_nm", 10.0)),
            vessels_in_sight=bool(scenario.get("vessels_in_sight", True)),
            safe_dcpa_m=float(catalog.get("safe_dcpa_m", 500.0)),
            tcpa_horizon_s=float(catalog.get("tcpa_horizon_s", 900.0)),
        )
        classification_passed = assessment.encounter == scenario["expected_encounter"] and assessment.role == scenario["expected_role"]
        action_results: list[dict[str, Any]] = []
        for case in scenario.get("actions", []):
            verdict = assess_action(assessment, ControlAction.from_mapping(case))
            verdict["id"] = str(case["id"])
            verdict["expected_passed"] = bool(case["expected_passed"])
            verdict["matched"] = verdict["passed"] is verdict["expected_passed"]
            action_results.append(verdict)
        results.append(
            {
                "id": str(scenario["id"]),
                "classification_passed": classification_passed,
                "assessment": assessment.export(),
                "actions": action_results,
                "passed": classification_passed and all(item["matched"] for item in action_results),
            }
        )
    action_count = sum(len(item["actions"]) for item in results)
    action_passed = sum(sum(int(action["matched"]) for action in item["actions"]) for item in results)
    return {
        "scenario_count": len(results),
        "scenario_passed_count": sum(int(item["passed"]) for item in results),
        "action_case_count": action_count,
        "action_case_passed_count": action_passed,
        "passed": bool(results) and all(item["passed"] for item in results),
        "results": results,
        "colreg_certified": False,
        "boundary": "Deterministic rule-trace regression for powered-vessel encounters; not flag-state, class, or legal COLREG certification.",
    }
