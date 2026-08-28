"""Complex COLREG scenario oracle for multi-vessel and constrained-waterway tests.

This extends, but does not replace, the V1 powered-vessel pairwise oracle.  The
result is deterministic simulator evidence, not a legal interpretation.
"""

from __future__ import annotations

import math
from typing import Any, Mapping, Sequence

from tools.ship_assurance.colreg import (
    ControlAction,
    VesselState,
    assess_action,
    assess_encounter,
)


REQUIRED_CAPABILITIES = (
    "multi_ship",
    "narrow_channel",
    "traffic_separation_scheme",
    "restricted_in_ability_to_manoeuvre",
    "not_under_command",
    "fishing_vessel",
    "lights_and_shapes",
    "sound_signals",
    "local_rules",
    "complex_restricted_visibility",
)

STATUS_PRIORITY = {
    "not_under_command": 0,
    "restricted_in_ability_to_manoeuvre": 1,
    "fishing": 2,
    "sailing": 3,
    "under_way_using_engine": 4,
}

STATUS_RULE = {
    "not_under_command": "Rule 27",
    "restricted_in_ability_to_manoeuvre": "Rule 27",
    "fishing": "Rule 26",
    "sailing": "Rule 25",
    "under_way_using_engine": "Rule 23",
}


def _status(value: str) -> str:
    aliases = {
        "nuc": "not_under_command",
        "ram": "restricted_in_ability_to_manoeuvre",
        "fishing_vessel": "fishing",
        "power_driven": "under_way_using_engine",
    }
    normalized = str(value or "under_way_using_engine").strip().lower()
    return aliases.get(normalized, normalized)


def _present(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _records(value: Any) -> list[Mapping[str, Any]]:
    return [item for item in value if isinstance(item, Mapping)] if isinstance(value, list) else []


def expected_visual_signal(status: str, *, trawling: bool = False) -> dict[str, list[str]]:
    normalized = _status(status)
    if normalized == "not_under_command":
        return {
            "lights": ["all_round_red_upper", "all_round_red_lower"],
            "shapes": ["ball_upper", "ball_lower"],
        }
    if normalized == "restricted_in_ability_to_manoeuvre":
        return {
            "lights": ["all_round_red_upper", "all_round_white", "all_round_red_lower"],
            "shapes": ["ball_upper", "diamond", "ball_lower"],
        }
    if normalized == "fishing":
        return {
            "lights": (
                ["all_round_green_upper", "all_round_white_lower"]
                if trawling
                else ["all_round_red_upper", "all_round_white_lower"]
            ),
            "shapes": ["cone_apex_upper", "cone_apex_lower"],
        }
    if normalized == "sailing":
        return {
            "lights": ["sidelight_red", "sidelight_green", "stern_white"],
            "shapes": [],
        }
    return {
        "lights": ["masthead_white", "sidelight_red", "sidelight_green", "stern_white"],
        "shapes": [],
    }


def expected_restricted_visibility_sound(status: str, *, making_way: bool) -> str:
    normalized = _status(status)
    if normalized in {
        "not_under_command",
        "restricted_in_ability_to_manoeuvre",
        "fishing",
        "sailing",
    }:
        return "one_prolonged_two_short"
    return "one_prolonged" if making_way else "two_prolonged"


def _set_equal(left: Any, right: Sequence[str]) -> bool:
    return isinstance(left, list) and set(str(value) for value in left) == set(right)


def _local_area(local_rules: Mapping[str, Any], area_id: str) -> Mapping[str, Any] | None:
    for record in _records(local_rules.get("areas")):
        if str(record.get("area_id", "")) == area_id:
            return record
    return None


def _local_rule_context(
    own: VesselState,
    context: Mapping[str, Any],
    local_rules: Mapping[str, Any],
) -> dict[str, Any]:
    area_id = str(context.get("local_rule_area_id", ""))
    area = _local_area(local_rules, area_id)
    if area is None:
        return {
            "applicable": bool(area_id),
            "compliant": not area_id,
            "rule_ids": [],
            "violations": ["local rule area is unavailable"] if area_id else [],
            "area_id": area_id,
        }
    rules = area.get("rules", {}) if isinstance(area.get("rules"), Mapping) else {}
    violations: list[str] = []
    maximum_speed = float(rules.get("maximum_speed_knots", math.inf))
    speed_knots = own.speed_mps * 1.9438444924406
    if speed_knots > maximum_speed + 1e-9:
        violations.append("local speed limit exceeded")
    if rules.get("overtaking_prohibited") is True and context.get("overtaking") is True:
        violations.append("local overtaking prohibition")
    if rules.get("reporting_required") is True and context.get("report_completed") is not True:
        violations.append("mandatory reporting not completed")
    rule_ids = [f"LOCAL:{value}" for value in rules.get("rule_ids", [])]
    return {
        "applicable": True,
        "compliant": not violations,
        "rule_ids": rule_ids,
        "violations": violations,
        "area_id": area_id,
        "source_class": local_rules.get("source_class", "UNKNOWN"),
        "official_authorization_verified": local_rules.get("official_authorization_verified") is True,
    }


def _pairwise_assessment(
    own: VesselState,
    target: VesselState,
    *,
    visibility_nm: float,
    vessels_in_sight: bool,
    safe_dcpa_m: float,
    tcpa_horizon_s: float,
) -> dict[str, Any]:
    base = assess_encounter(
        own,
        target,
        visibility_nm=visibility_nm,
        vessels_in_sight=vessels_in_sight,
        safe_dcpa_m=safe_dcpa_m,
        tcpa_horizon_s=tcpa_horizon_s,
    )
    result = base.export()
    own_status = _status(own.navigation_status)
    target_status = _status(target.navigation_status)
    rules = list(result["rules"])
    if STATUS_RULE.get(own_status) not in rules:
        rules.append(STATUS_RULE.get(own_status, "Rule 18"))
    if STATUS_RULE.get(target_status) not in rules:
        rules.append(STATUS_RULE.get(target_status, "Rule 18"))
    if visibility_nm >= 2.0 and vessels_in_sight and base.risk_of_collision:
        own_rank = STATUS_PRIORITY.get(own_status, 4)
        target_rank = STATUS_PRIORITY.get(target_status, 4)
        if own_rank > target_rank:
            result["encounter"] = f"give_way_to_{target_status}"
            result["role"] = "give_way_to_privileged_vessel"
            rules.append("Rule 18")
            result["reasons"].append(
                f"target status {target_status} has priority over {own_status} in the verifier hierarchy"
            )
        elif own_rank < target_rank:
            result["encounter"] = f"stand_on_as_{own_status}"
            result["role"] = "stand_on_special_status"
            rules.append("Rule 18")
            result["reasons"].append(
                f"own status {own_status} has priority over target status {target_status} in the verifier hierarchy"
            )
    result["rules"] = list(dict.fromkeys(rules))
    result["own_status"] = own_status
    result["target_status"] = target_status
    result["target_id"] = target.vessel_id
    return result


def assess_complex_scenario(
    scenario: Mapping[str, Any],
    *,
    local_rules: Mapping[str, Any],
    safe_dcpa_m: float,
    tcpa_horizon_s: float,
) -> dict[str, Any]:
    own = VesselState.from_mapping(scenario["own"])
    targets = [VesselState.from_mapping(value) for value in scenario.get("targets", [])]
    visibility_nm = float(scenario.get("visibility_nm", 10.0))
    vessels_in_sight = bool(scenario.get("vessels_in_sight", True))
    pairwise = [
        _pairwise_assessment(
            own,
            target,
            visibility_nm=visibility_nm,
            vessels_in_sight=vessels_in_sight,
            safe_dcpa_m=safe_dcpa_m,
            tcpa_horizon_s=tcpa_horizon_s,
        )
        for target in targets
    ]
    risky = [item for item in pairwise if item.get("risk_of_collision")]
    priority_target = None
    if risky:
        priority = min(
            risky,
            key=lambda item: (
                STATUS_PRIORITY.get(str(item.get("target_status")), 4),
                float(item.get("tcpa_s")) if item.get("tcpa_s") is not None else math.inf,
            ),
        )
        priority_target = str(priority.get("target_id"))
    roles = [str(item.get("role")) for item in risky]
    if visibility_nm < 2.0 or not vessels_in_sight:
        primary_duty = "safe_speed_and_avoidance"
    elif "give_way_to_privileged_vessel" in roles:
        primary_duty = "give_way_to_privileged_vessel"
    elif any(role in {"give_way", "both_give_way"} for role in roles):
        primary_duty = "give_way"
    elif "stand_on_special_status" in roles:
        primary_duty = "stand_on_special_status"
    elif "stand_on" in roles:
        primary_duty = "stand_on"
    else:
        primary_duty = "monitor"
    context = scenario.get("context", {}) if isinstance(scenario.get("context"), Mapping) else {}
    waterway = str(context.get("waterway", "open_water"))
    context_rules: list[str] = []
    context_violations: list[str] = []
    if waterway == "narrow_channel":
        context_rules.append("Rule 9")
        if float(context.get("starboard_side_fraction", 0.0)) < 0.5:
            context_violations.append("not keeping near the starboard outer limit")
        if context.get("crossing_impedes_channel_vessel") is True:
            context_violations.append("crossing impedes a vessel constrained to the channel")
        if context.get("overtaking") is True and context.get("overtaking_agreement") is not True:
            context_violations.append("narrow-channel overtaking lacks explicit agreement")
    elif waterway == "traffic_separation_scheme":
        context_rules.append("Rule 10")
        if context.get("inside_separation_zone") is True:
            context_violations.append("vessel is inside the separation zone")
        mode = str(context.get("tss_mode", "lane_following"))
        if mode == "lane_following" and abs(float(context.get("lane_alignment_error_deg", 999.0))) > 10.0:
            context_violations.append("course is not aligned with traffic-flow direction")
        if mode == "crossing" and not 80.0 <= abs(float(context.get("crossing_angle_deg", 0.0))) <= 100.0:
            context_violations.append("traffic lane is not crossed near a right angle")
    local = _local_rule_context(own, context, local_rules)
    context_rules.extend(local["rule_ids"])
    context_violations.extend(local["violations"])
    rules: list[str] = []
    for item in pairwise:
        for rule in item.get("rules", []):
            if rule not in rules:
                rules.append(str(rule))
    for rule in context_rules:
        if rule not in rules:
            rules.append(rule)
    subject = scenario.get("signal_subject", scenario.get("own", {}))
    subject_status = _status(str(subject.get("navigation_status", "under_way_using_engine"))) if isinstance(subject, Mapping) else "under_way_using_engine"
    status_rule = STATUS_RULE.get(subject_status)
    if status_rule and status_rule not in rules:
        rules.append(status_rule)
    if bool(scenario.get("sound_signal_required", False)) and "Rule 35" not in rules:
        rules.append("Rule 35")
    return {
        "scenario_id": str(scenario.get("id", "")),
        "target_count": len(targets),
        "pairwise": pairwise,
        "risk_target_count": len(risky),
        "priority_target_id": priority_target,
        "primary_duty": primary_duty,
        "rules": rules,
        "waterway": waterway,
        "context_compliant": not context_violations,
        "context_violations": context_violations,
        "local_rules": local,
        "signal_subject_status": subject_status,
        "expected_visual_signal": expected_visual_signal(
            subject_status, trawling=bool(scenario.get("trawling", False))
        ),
        "expected_sound_signal": (
            expected_restricted_visibility_sound(
                subject_status,
                making_way=bool(scenario.get("making_way", True)),
            )
            if bool(scenario.get("sound_signal_required", False))
            else None
        ),
        "multi_ship_duty_graph": [
            {
                "target_id": item.get("target_id"),
                "role": item.get("role"),
                "encounter": item.get("encounter"),
                "tcpa_s": item.get("tcpa_s"),
                "dcpa_m": item.get("dcpa_m"),
                "rules": item.get("rules"),
            }
            for item in pairwise
        ],
    }


def _navigation_action_passed(
    assessment: Mapping[str, Any],
    action: Mapping[str, Any],
    scenario: Mapping[str, Any],
    local_rules: Mapping[str, Any],
) -> tuple[bool, list[str]]:
    reasons: list[str] = []
    turn = float(action.get("course_change_deg", 0.0))
    speed_ratio = float(action.get("speed_ratio", 1.0))
    if not 0.0 <= speed_ratio <= 1.25:
        return False, ["speed ratio outside verifier contract"]
    substantial = abs(turn) >= 10.0 or speed_ratio <= 0.70
    risky = [item for item in assessment.get("pairwise", []) if item.get("risk_of_collision")]
    give_way = [
        item
        for item in risky
        if item.get("role") in {"give_way", "both_give_way", "give_way_to_privileged_vessel"}
    ]
    if give_way:
        for item in give_way:
            role = str(item.get("role"))
            if role == "give_way_to_privileged_vessel":
                passed = substantial and turn >= -5.0
            else:
                passed = bool(
                    assess_action(
                        _assessment_adapter(item),
                        ControlAction(course_change_deg=turn, speed_ratio=speed_ratio),
                    )["passed"]
                )
            if not passed:
                reasons.append(f"duty to {item.get('target_id')} is not satisfied")
    elif assessment.get("primary_duty") in {"stand_on", "stand_on_special_status"}:
        immediate = any(item.get("tcpa_s") is not None and float(item["tcpa_s"]) < 60.0 for item in risky)
        if not immediate and not (abs(turn) <= 5.0 and 0.90 <= speed_ratio <= 1.10):
            reasons.append("stand-on course and speed are not maintained")
    elif assessment.get("primary_duty") == "safe_speed_and_avoidance":
        target_forward = any(abs(float(item.get("relative_bearing_deg", 180.0))) <= 112.5 for item in risky)
        if target_forward and turn < -5.0:
            reasons.append("port alteration for a vessel forward of the beam")
        if not substantial and speed_ratio > 0.85:
            reasons.append("restricted-visibility action is not substantial")
    context = scenario.get("context", {}) if isinstance(scenario.get("context"), Mapping) else {}
    waterway = str(context.get("waterway", "open_water"))
    if waterway == "narrow_channel":
        if float(action.get("starboard_side_fraction_after", context.get("starboard_side_fraction", 0.0))) < 0.5:
            reasons.append("action leaves the starboard side of the narrow channel")
        if action.get("crossing_impedes_after", context.get("crossing_impedes_channel_vessel")) is True:
            reasons.append("action impedes a channel vessel")
        overtaking = action.get("overtaking_after", context.get("overtaking")) is True
        agreement = action.get("overtaking_agreement", context.get("overtaking_agreement")) is True
        if overtaking and not agreement:
            reasons.append("overtaking agreement is missing")
    elif waterway == "traffic_separation_scheme":
        if action.get("inside_separation_zone_after", context.get("inside_separation_zone")) is True:
            reasons.append("action enters the separation zone")
        mode = str(context.get("tss_mode", "lane_following"))
        if mode == "lane_following" and abs(float(action.get("lane_alignment_error_after_deg", context.get("lane_alignment_error_deg", 999.0)))) > 10.0:
            reasons.append("action is not aligned with traffic flow")
        if mode == "crossing" and not 80.0 <= abs(float(action.get("crossing_angle_after_deg", context.get("crossing_angle_deg", 0.0)))) <= 100.0:
            reasons.append("action does not cross near a right angle")
    local_context = dict(context)
    local_context["overtaking"] = action.get("overtaking_after", context.get("overtaking"))
    local_context["report_completed"] = action.get("report_completed", context.get("report_completed"))
    own_raw = dict(scenario["own"])
    own_raw["speed_mps"] = float(own_raw["speed_mps"]) * speed_ratio
    local = _local_rule_context(VesselState.from_mapping(own_raw), local_context, local_rules)
    reasons.extend(str(value) for value in local["violations"])
    return not reasons, reasons


def _assessment_adapter(value: Mapping[str, Any]):
    """Rebuild the V1 immutable assessment for its tested action oracle."""

    from tools.ship_assurance.colreg import ColregAssessment

    return ColregAssessment(
        encounter=str(value.get("encounter", "")),
        role=str(value.get("role", "")),
        risk_of_collision=bool(value.get("risk_of_collision", False)),
        relative_bearing_deg=float(value.get("relative_bearing_deg", 0.0)),
        target_aspect_deg=float(value.get("target_aspect_deg", 0.0)),
        tcpa_s=float(value["tcpa_s"]) if value.get("tcpa_s") is not None else None,
        dcpa_m=float(value.get("dcpa_m", 0.0)),
        range_m=float(value.get("range_m", 0.0)),
        rules=tuple(str(item) for item in value.get("rules", [])),
        reasons=tuple(str(item) for item in value.get("reasons", [])),
    )


def assess_complex_case(
    assessment: Mapping[str, Any],
    case: Mapping[str, Any],
    scenario: Mapping[str, Any],
    *,
    local_rules: Mapping[str, Any],
) -> dict[str, Any]:
    kind = str(case.get("kind", "navigation"))
    reasons: list[str] = []
    if kind == "visual_signal":
        expected = assessment.get("expected_visual_signal", {})
        passed = _set_equal(case.get("lights"), expected.get("lights", [])) and _set_equal(
            case.get("shapes"), expected.get("shapes", [])
        )
        if not passed:
            reasons.append("observed lights or shapes do not match the status signature")
    elif kind == "sound_signal":
        expected_sound = assessment.get("expected_sound_signal")
        interval = float(case.get("interval_s", math.inf))
        passed = case.get("signal") == expected_sound and interval <= 120.0
        if not passed:
            reasons.append("restricted-visibility sound pattern or interval is incorrect")
    else:
        passed, reasons = _navigation_action_passed(
            assessment, case, scenario, local_rules
        )
    return {
        "case_id": str(case.get("id", "")),
        "kind": kind,
        "passed": passed,
        "expected_passed": case.get("expected_passed") is True,
        "matched": passed is (case.get("expected_passed") is True),
        "reasons": reasons or ["case satisfies the deterministic verifier contract"],
    }


def run_complex_colreg_catalog(
    catalog: Mapping[str, Any], local_rules: Mapping[str, Any]
) -> dict[str, Any]:
    results: list[dict[str, Any]] = []
    covered: set[str] = set()
    rules_seen: set[str] = set()
    safe_dcpa_m = float(catalog.get("safe_dcpa_m", 500.0))
    tcpa_horizon_s = float(catalog.get("tcpa_horizon_s", 900.0))
    for scenario in _records(catalog.get("scenarios")):
        covered.update(str(value) for value in scenario.get("capabilities", []))
        assessment = assess_complex_scenario(
            scenario,
            local_rules=local_rules,
            safe_dcpa_m=safe_dcpa_m,
            tcpa_horizon_s=tcpa_horizon_s,
        )
        rules_seen.update(str(value) for value in assessment["rules"])
        expected = scenario.get("expected", {}) if isinstance(scenario.get("expected"), Mapping) else {}
        expected_rules = set(str(value) for value in expected.get("rule_ids", []))
        classification_passed = (
            assessment.get("primary_duty") == expected.get("primary_duty")
            and assessment.get("priority_target_id") == expected.get("priority_target_id")
            and assessment.get("context_compliant") is (expected.get("context_compliant") is True)
            and expected_rules <= set(assessment.get("rules", []))
        )
        case_results = [
            assess_complex_case(
                assessment, case, scenario, local_rules=local_rules
            )
            for case in _records(scenario.get("cases"))
        ]
        results.append(
            {
                "scenario_id": scenario.get("id", ""),
                "capabilities": list(scenario.get("capabilities", [])),
                "classification_passed": classification_passed,
                "assessment": assessment,
                "cases": case_results,
                "passed": classification_passed and bool(case_results) and all(item["matched"] for item in case_results),
            }
        )
    case_count = sum(len(item["cases"]) for item in results)
    matched_count = sum(sum(int(case["matched"]) for case in item["cases"]) for item in results)
    coverage_complete = set(REQUIRED_CAPABILITIES) <= covered
    return {
        "schema_version": "colreg_complex_assessment_v2",
        "scenario_count": len(results),
        "scenario_passed_count": sum(int(item["passed"]) for item in results),
        "case_count": case_count,
        "case_matched_count": matched_count,
        "required_capabilities": list(REQUIRED_CAPABILITIES),
        "covered_capabilities": sorted(covered),
        "missing_capabilities": sorted(set(REQUIRED_CAPABILITIES) - covered),
        "coverage_complete": coverage_complete,
        "rules_seen": sorted(rules_seen),
        "results": results,
        "passed": bool(results) and coverage_complete and all(item["passed"] for item in results),
        "legacy_v1_replaced": False,
        "authorized_local_rules_connected": local_rules.get("official_authorization_verified") is True,
        "official_local_rule_compliance_verified": False,
        "colreg_certified": False,
        "legal_interpretation_complete": False,
        "production_authority": False,
        "training_performed": False,
        "existing_model_modified": False,
        "boundary": "V2 deterministic complex-scenario regression layered over the preserved V1 oracle. It is not legal advice, an official local-rule service, flag/class acceptance or COLREG certification.",
    }
