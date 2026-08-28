"""Executable maritime-autonomy safety-case consistency and refusal gates."""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
from typing import Any, Mapping, Sequence


REQUIRED_ODD_CATEGORIES = (
    "geographical_authorization",
    "under_keel_clearance",
    "wind",
    "wave",
    "visibility",
    "traffic_complexity",
    "positioning_integrity",
    "navigation_fusion_quality",
    "actuator_feedback",
    "remote_control_centre_link",
    "cyber_integrity",
    "speed_envelope",
)
REQUIRED_HAZARD_CATEGORIES = (
    "collision",
    "grounding",
    "loss_of_navigation_integrity",
    "steering_failure",
    "propulsion_failure",
    "power_failure",
    "communication_loss",
    "sensor_deception",
    "cyber_compromise",
    "fire_or_flooding",
    "human_factor",
    "unsafe_learning_output",
)
REQUIRED_ROLES = (
    "MASTER",
    "ONBOARD_OPERATOR",
    "RCC_OPERATOR",
    "RCC_SUPERVISOR",
    "SAFETY_MANAGER",
    "TECHNICAL_AUTHORITY",
    "RL_MODEL_OWNER",
    "CYBERSECURITY_OFFICER",
    "INDEPENDENT_ASSESSOR",
)
REQUIRED_DUTY_HOLDERS = REQUIRED_ROLES[:-1]
REQUIRED_REGULATORY_INSTRUMENTS = (
    "COLREG",
    "SOLAS",
    "STCW",
    "FLAG_AND_COASTAL_STATE",
    "CLASS_AND_ASSURANCE",
)
REQUIRED_DEPLOYMENT_FIELDS = (
    "vessel_name",
    "official_number_or_mmsi",
    "flag_state",
    "operating_area",
    "operator_organization",
    "rcc_site",
    "approved_odd_reference",
    "configuration_baseline_reference",
    "change_control_record_reference",
)
REQUIRED_REVIEW_FIELDS = (
    "reviewer_name",
    "organization",
    "competence_reference",
    "independence_declaration_reference",
    "review_scope_reference",
    "review_report_reference",
    "open_findings_register_reference",
    "finding_closure_reference",
    "residual_risk_acceptance_reference",
    "signed_decision_reference",
)
REQUIRED_SUPPORTING_EVIDENCE = (
    "hazard_workshop_reference",
    "fault_tree_review_reference",
    "mrc_demonstration_reference",
    "rcc_human_factors_reference",
    "physical_hil_reference",
    "named_vessel_calibration_reference",
    "sea_trial_reference",
    "cybersecurity_assessment_reference",
)
ALLOWED_RISK_LEVELS = {"INTOLERABLE", "ALARP_HIGH", "ALARP", "TOLERABLE_WITH_MONITORING"}


def load_json(path: str | Path) -> dict[str, Any]:
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"JSON root must be an object: {path}")
    return value


def sha256_path(path: str | Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _present(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _records(value: Any) -> list[Mapping[str, Any]]:
    return [item for item in value if isinstance(item, Mapping)] if isinstance(value, list) else []


def _unique_nonempty(records: Sequence[Mapping[str, Any]], key: str) -> tuple[set[str], bool]:
    values = [str(record.get(key, "")).strip() for record in records]
    return set(values), all(values) and len(values) == len(set(values))


def _acyclic(nodes: Mapping[str, Sequence[str]], root: str) -> bool:
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(node: str) -> bool:
        if node in visiting:
            return False
        if node in visited:
            return True
        if node not in nodes:
            return False
        visiting.add(node)
        if not all(visit(child) for child in nodes[node]):
            return False
        visiting.remove(node)
        visited.add(node)
        return True

    return bool(root) and visit(root)


def _check_odd(case: Mapping[str, Any], mrc_ids: set[str]) -> dict[str, Any]:
    odd = case.get("operational_design_domain", {})
    records = _records(odd.get("dimensions") if isinstance(odd, Mapping) else None)
    ids, unique = _unique_nonempty(records, "dimension_id")
    categories = {str(item.get("category", "")) for item in records}
    invalid: list[str] = []
    for item in records:
        dimension_id = str(item.get("dimension_id", "MISSING"))
        comparator = item.get("comparator")
        threshold = item.get("threshold")
        valid_threshold = (
            isinstance(threshold, bool)
            if comparator == "eq"
            else not isinstance(threshold, bool)
            and isinstance(threshold, (int, float))
            and math.isfinite(float(threshold))
        )
        breach_mrc = item.get("breach_mrc_ids", [])
        if not (
            _present(item.get("limit_statement"))
            and _present(item.get("monitor_signal"))
            and comparator in {"eq", "lte", "gte"}
            and valid_threshold
            and _present(item.get("exit_criteria"))
            and isinstance(breach_mrc, list)
            and bool(breach_mrc)
            and all(str(value) in mrc_ids for value in breach_mrc)
        ):
            invalid.append(dimension_id)
    return {
        "passed": unique and categories == set(REQUIRED_ODD_CATEGORIES) and not invalid,
        "dimension_count": len(ids),
        "covered_categories": sorted(categories),
        "missing_categories": sorted(set(REQUIRED_ODD_CATEGORIES) - categories),
        "invalid_dimensions": invalid,
    }


def _check_mrc(case: Mapping[str, Any], evidence_ids: set[str]) -> tuple[dict[str, Any], set[str]]:
    records = _records(case.get("minimum_risk_conditions"))
    ids, unique = _unique_nonempty(records, "mrc_id")
    invalid: list[str] = []
    for item in records:
        mrc_id = str(item.get("mrc_id", "MISSING"))
        if not (
            _present(item.get("name"))
            and isinstance(item.get("trigger_categories"), list)
            and bool(item.get("trigger_categories"))
            and isinstance(item.get("preconditions"), list)
            and bool(item.get("preconditions"))
            and isinstance(item.get("actions"), list)
            and bool(item.get("actions"))
            and isinstance(item.get("success_criteria"), list)
            and bool(item.get("success_criteria"))
            and isinstance(item.get("timeout_s"), (int, float))
            and not isinstance(item.get("timeout_s"), bool)
            and float(item.get("timeout_s", 0.0)) > 0.0
            and str(item.get("fallback_mrc_id", "")) in ids
            and _present(item.get("command_authority"))
            and isinstance(item.get("evidence_ids"), list)
            and bool(item.get("evidence_ids"))
            and all(str(value) in evidence_ids for value in item.get("evidence_ids", []))
        ):
            invalid.append(mrc_id)
    return {
        "passed": unique and len(ids) >= 6 and not invalid,
        "mrc_count": len(ids),
        "invalid_mrc_ids": invalid,
    }, ids


def _check_hazards(
    case: Mapping[str, Any], evidence_ids: set[str], mrc_ids: set[str]
) -> tuple[dict[str, Any], set[str], set[str]]:
    records = _records(case.get("hazard_log"))
    hazard_ids, unique = _unique_nonempty(records, "hazard_id")
    categories = {str(item.get("category", "")) for item in records}
    control_ids: set[str] = set()
    duplicate_controls: set[str] = set()
    invalid: list[str] = []
    for item in records:
        hazard_id = str(item.get("hazard_id", "MISSING"))
        controls = _records(item.get("controls"))
        controls_valid = len(controls) >= 2
        for control in controls:
            control_id = str(control.get("control_id", ""))
            if control_id in control_ids:
                duplicate_controls.add(control_id)
            control_ids.add(control_id)
            controls_valid = controls_valid and (
                _present(control_id)
                and control.get("type") in {"preventive", "detective", "mitigative"}
                and _present(control.get("description"))
                and isinstance(control.get("evidence_ids"), list)
                and bool(control.get("evidence_ids"))
                and all(str(value) in evidence_ids for value in control.get("evidence_ids", []))
            )
        if not (
            _present(item.get("description"))
            and isinstance(item.get("causes"), list)
            and bool(item.get("causes"))
            and isinstance(item.get("consequences"), list)
            and bool(item.get("consequences"))
            and item.get("initial_risk") in ALLOWED_RISK_LEVELS
            and item.get("residual_risk") in ALLOWED_RISK_LEVELS
            and controls_valid
            and isinstance(item.get("mrc_ids"), list)
            and bool(item.get("mrc_ids"))
            and all(str(value) in mrc_ids for value in item.get("mrc_ids", []))
            and str(item.get("risk_owner_role", "")) in REQUIRED_ROLES
            and item.get("acceptance_status") == "REQUIRES_EXTERNAL_ACCEPTANCE"
        ):
            invalid.append(hazard_id)
    return {
        "passed": (
            unique
            and categories == set(REQUIRED_HAZARD_CATEGORIES)
            and not invalid
            and not duplicate_controls
        ),
        "hazard_count": len(hazard_ids),
        "control_count": len(control_ids),
        "covered_categories": sorted(categories),
        "missing_categories": sorted(set(REQUIRED_HAZARD_CATEGORIES) - categories),
        "invalid_hazard_ids": invalid,
        "duplicate_control_ids": sorted(duplicate_controls),
    }, hazard_ids, control_ids


def _check_fault_trees(
    case: Mapping[str, Any], hazard_ids: set[str], control_ids: set[str]
) -> dict[str, Any]:
    trees = _records(case.get("fault_trees"))
    tree_ids, unique = _unique_nonempty(trees, "tree_id")
    invalid: list[str] = []
    covered_hazards: set[str] = set()
    for tree in trees:
        tree_id = str(tree.get("tree_id", "MISSING"))
        nodes = _records(tree.get("nodes"))
        node_ids, nodes_unique = _unique_nonempty(nodes, "node_id")
        graph: dict[str, list[str]] = {}
        nodes_valid = nodes_unique
        for node in nodes:
            node_id = str(node.get("node_id", ""))
            node_type = node.get("node_type")
            children = [str(value) for value in node.get("children", [])] if isinstance(node.get("children"), list) else []
            graph[node_id] = children
            if node_type in {"AND", "OR"}:
                nodes_valid = nodes_valid and bool(children)
            elif node_type == "BASIC_EVENT":
                controls = node.get("control_ids", [])
                nodes_valid = nodes_valid and (
                    not children
                    and _present(node.get("description"))
                    and isinstance(controls, list)
                    and bool(controls)
                    and all(str(value) in control_ids for value in controls)
                )
            else:
                nodes_valid = False
        tree_hazards = {str(value) for value in tree.get("hazard_ids", [])} if isinstance(tree.get("hazard_ids"), list) else set()
        covered_hazards.update(tree_hazards)
        root = str(tree.get("root_node_id", ""))
        if not (
            _present(tree.get("top_event"))
            and tree_hazards
            and tree_hazards <= hazard_ids
            and root in node_ids
            and nodes_valid
            and all(child in node_ids for children in graph.values() for child in children)
            and _acyclic(graph, root)
        ):
            invalid.append(tree_id)
    return {
        "passed": unique and len(tree_ids) >= 5 and not invalid and covered_hazards == hazard_ids,
        "tree_count": len(tree_ids),
        "covered_hazard_ids": sorted(covered_hazards),
        "uncovered_hazard_ids": sorted(hazard_ids - covered_hazards),
        "invalid_tree_ids": invalid,
    }


def _check_rcc(case: Mapping[str, Any]) -> dict[str, Any]:
    rcc = case.get("remote_control_centre", {})
    record = rcc if isinstance(rcc, Mapping) else {}
    required_text = (
        "rcc_id",
        "status",
        "primary_link_requirement",
        "backup_link_requirement",
        "handover_protocol",
        "watchkeeping_requirement",
        "loss_of_link_response",
        "recording_requirement",
    )
    passed = (
        all(_present(record.get(key)) for key in required_text)
        and isinstance(record.get("operating_modes"), list)
        and set(record.get("operating_modes", [])) == {"monitor_only", "advisory", "bounded_remote_control"}
        and isinstance(record.get("required_roles"), list)
        and set(record.get("required_roles", [])) == {"RCC_OPERATOR", "RCC_SUPERVISOR", "TECHNICAL_SUPPORT"}
        and isinstance(record.get("minimum_staffing"), Mapping)
        and all(int(value) >= 1 for value in record.get("minimum_staffing", {}).values())
        and record.get("site_authorized") is False
    )
    return {"passed": passed, "site_authorized": record.get("site_authorized", False)}


def _check_responsibility(case: Mapping[str, Any]) -> dict[str, Any]:
    model = case.get("responsibility_model", {})
    record = model if isinstance(model, Mapping) else {}
    roles = set(record.get("roles", [])) if isinstance(record.get("roles"), list) else set()
    raci = _records(record.get("raci"))
    activities, unique = _unique_nonempty(raci, "activity")
    invalid: list[str] = []
    for item in raci:
        activity = str(item.get("activity", "MISSING"))
        responsible = item.get("responsible", [])
        accountable = str(item.get("accountable", ""))
        consulted = item.get("consulted", [])
        informed = item.get("informed", [])
        if not (
            isinstance(responsible, list)
            and bool(responsible)
            and all(str(value) in roles for value in responsible)
            and accountable in roles
            and isinstance(consulted, list)
            and all(str(value) in roles for value in consulted)
            and isinstance(informed, list)
            and all(str(value) in roles for value in informed)
        ):
            invalid.append(activity)
    return {
        "passed": set(REQUIRED_ROLES) <= roles and unique and len(activities) >= 7 and not invalid,
        "role_count": len(roles),
        "activity_count": len(activities),
        "invalid_activities": invalid,
    }


def _check_regulatory(case: Mapping[str, Any]) -> dict[str, Any]:
    records = _records(case.get("regulatory_applicability_register"))
    ids, unique = _unique_nonempty(records, "instrument_id")
    invalid = [
        str(item.get("instrument_id", "MISSING"))
        for item in records
        if not (
            _present(item.get("scope_question"))
            and _present(item.get("project_route"))
            and item.get("applicability_status") == "EXTERNAL_LEGAL_DETERMINATION_REQUIRED"
            and _present(item.get("decision_authority"))
        )
    ]
    return {
        "passed": unique and ids == set(REQUIRED_REGULATORY_INSTRUMENTS) and not invalid,
        "instrument_count": len(ids),
        "invalid_instruments": invalid,
        "all_external_determination_required": not invalid,
    }


def _check_evidence(case: Mapping[str, Any], root: Path) -> tuple[dict[str, Any], set[str], dict[str, str]]:
    records = _records(case.get("evidence_registry"))
    ids, unique = _unique_nonempty(records, "evidence_id")
    invalid: list[str] = []
    hashes: dict[str, str] = {}
    for item in records:
        evidence_id = str(item.get("evidence_id", "MISSING"))
        relative = str(item.get("path", ""))
        path = root / relative
        if not (_present(item.get("kind")) and _present(relative) and path.is_file()):
            invalid.append(evidence_id)
            continue
        hashes[evidence_id] = sha256_path(path)
    return {
        "passed": unique and len(ids) >= 10 and not invalid,
        "evidence_count": len(ids),
        "missing_or_invalid_evidence_ids": invalid,
    }, ids, hashes


def _check_claim_graph(case: Mapping[str, Any], evidence_ids: set[str]) -> dict[str, Any]:
    claims = _records(case.get("claim_graph"))
    ids, unique = _unique_nonempty(claims, "claim_id")
    graph: dict[str, list[str]] = {}
    invalid: list[str] = []
    for claim in claims:
        claim_id = str(claim.get("claim_id", "MISSING"))
        children = [str(value) for value in claim.get("children", [])] if isinstance(claim.get("children"), list) else []
        evidence = claim.get("evidence_ids", [])
        graph[claim_id] = children
        if not (
            _present(claim.get("statement"))
            and _present(claim.get("status"))
            and isinstance(evidence, list)
            and all(str(value) in evidence_ids for value in evidence)
        ):
            invalid.append(claim_id)
    root = str(case.get("top_claim", {}).get("claim_id", "")) if isinstance(case.get("top_claim"), Mapping) else ""
    return {
        "passed": (
            unique
            and root in ids
            and all(child in ids for children in graph.values() for child in children)
            and _acyclic(graph, root)
            and not invalid
            and all(graph[claim_id] or any(str(value) in evidence_ids for value in next(item for item in claims if str(item.get("claim_id")) == claim_id).get("evidence_ids", [])) for claim_id in ids)
        ),
        "claim_count": len(ids),
        "root_claim_id": root,
        "invalid_claim_ids": invalid,
    }


def evaluate_runtime_odd(case: Mapping[str, Any], conditions: Mapping[str, Any]) -> dict[str, Any]:
    dimensions = _records(case.get("operational_design_domain", {}).get("dimensions") if isinstance(case.get("operational_design_domain"), Mapping) else None)
    breached: list[dict[str, Any]] = []
    required_mrc: list[str] = []
    for item in dimensions:
        signal = str(item.get("monitor_signal", ""))
        comparator = item.get("comparator")
        threshold = item.get("threshold")
        value = conditions.get(signal)
        passed = False
        if comparator == "eq":
            passed = value == threshold
        elif not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(float(value)):
            passed = float(value) <= float(threshold) if comparator == "lte" else float(value) >= float(threshold)
        if not passed:
            mrc_ids = [str(raw) for raw in item.get("breach_mrc_ids", [])]
            breached.append({
                "dimension_id": item.get("dimension_id"),
                "signal": signal,
                "observed": value,
                "comparator": comparator,
                "threshold": threshold,
                "mrc_ids": mrc_ids,
            })
            for mrc_id in mrc_ids:
                if mrc_id not in required_mrc:
                    required_mrc.append(mrc_id)
    return {
        "within_odd": not breached,
        "breached_dimensions": breached,
        "required_mrc_ids": required_mrc,
        "production_command_authority": False,
    }


def run_odd_monitor_smoke(case: Mapping[str, Any]) -> dict[str, Any]:
    dimensions = _records(case.get("operational_design_domain", {}).get("dimensions") if isinstance(case.get("operational_design_domain"), Mapping) else None)
    nominal: dict[str, Any] = {
        str(item.get("monitor_signal")): item.get("threshold") for item in dimensions
    }
    nominal_result = evaluate_runtime_odd(case, nominal)
    cases: dict[str, Any] = {}
    all_detected = True
    for item in dimensions:
        signal = str(item.get("monitor_signal"))
        comparator = item.get("comparator")
        threshold = item.get("threshold")
        conditions = dict(nominal)
        if comparator == "eq":
            conditions[signal] = not bool(threshold)
        elif comparator == "lte":
            conditions[signal] = float(threshold) + 1.0
        else:
            conditions[signal] = float(threshold) - 1.0
        result = evaluate_runtime_odd(case, conditions)
        dimension_id = str(item.get("dimension_id"))
        detected_ids = {str(value.get("dimension_id")) for value in result["breached_dimensions"]}
        mapped = bool(result["required_mrc_ids"])
        passed = dimension_id in detected_ids and mapped and result["production_command_authority"] is False
        all_detected = all_detected and passed
        cases[dimension_id] = {"passed": passed, "required_mrc_ids": result["required_mrc_ids"]}
    return {
        "passed": nominal_result["within_odd"] and all_detected and len(cases) == len(REQUIRED_ODD_CATEGORIES),
        "nominal_within_odd": nominal_result["within_odd"],
        "breach_case_count": len(cases),
        "breach_cases": cases,
        "production_command_authority": False,
    }


def _check_acceptance(manifest: Mapping[str, Any], safety_case_id: str) -> dict[str, Any]:
    deployment = manifest.get("deployment", {}) if isinstance(manifest.get("deployment"), Mapping) else {}
    regulatory = manifest.get("regulatory_determinations", {}) if isinstance(manifest.get("regulatory_determinations"), Mapping) else {}
    duties = manifest.get("duty_holder_assignments", {}) if isinstance(manifest.get("duty_holder_assignments"), Mapping) else {}
    review = manifest.get("independent_review", {}) if isinstance(manifest.get("independent_review"), Mapping) else {}
    evidence = manifest.get("supporting_evidence", {}) if isinstance(manifest.get("supporting_evidence"), Mapping) else {}
    claims = manifest.get("claims", {}) if isinstance(manifest.get("claims"), Mapping) else {}
    deployment_checks = {key: _present(deployment.get(key)) for key in REQUIRED_DEPLOYMENT_FIELDS}
    regulatory_checks = {
        instrument: (
            isinstance(regulatory.get(instrument), Mapping)
            and all(_present(regulatory[instrument].get(key)) for key in ("authority", "decision_reference", "decision_date"))
        )
        for instrument in REQUIRED_REGULATORY_INSTRUMENTS
    }
    duty_checks = {role: _present(duties.get(role)) for role in REQUIRED_DUTY_HOLDERS}
    review_checks = {key: _present(review.get(key)) for key in REQUIRED_REVIEW_FIELDS}
    evidence_checks = {key: _present(evidence.get(key)) for key in REQUIRED_SUPPORTING_EVIDENCE}
    authority_request_detected = any(value is True for value in claims.values())
    schema_valid = (
        manifest.get("schema_version") == "mass_safety_case_acceptance_manifest_v1"
        and manifest.get("safety_case_id") == safety_case_id
    )
    complete = (
        schema_valid
        and all(deployment_checks.values())
        and all(regulatory_checks.values())
        and all(duty_checks.values())
        and all(review_checks.values())
        and all(evidence_checks.values())
        and not authority_request_detected
    )
    missing = [f"deployment.{key}" for key, passed in deployment_checks.items() if not passed]
    missing += [f"regulatory_determinations.{key}" for key, passed in regulatory_checks.items() if not passed]
    missing += [f"duty_holder_assignments.{key}" for key, passed in duty_checks.items() if not passed]
    missing += [f"independent_review.{key}" for key, passed in review_checks.items() if not passed]
    missing += [f"supporting_evidence.{key}" for key, passed in evidence_checks.items() if not passed]
    if authority_request_detected:
        missing.append("claims must remain false until competent external decisions are authenticated")
    return {
        "passed": complete,
        "schema_valid": schema_valid,
        "deployment_checks": deployment_checks,
        "regulatory_determination_checks": regulatory_checks,
        "duty_holder_checks": duty_checks,
        "independent_review_checks": review_checks,
        "supporting_evidence_checks": evidence_checks,
        "authority_request_detected": authority_request_detected,
        "missing_or_invalid": missing,
    }


def assess_safety_case(
    case: Mapping[str, Any],
    acceptance_manifest: Mapping[str, Any],
    *,
    root: Path,
) -> dict[str, Any]:
    evidence_result, evidence_ids, evidence_hashes = _check_evidence(case, root)
    mrc_result, mrc_ids = _check_mrc(case, evidence_ids)
    odd_result = _check_odd(case, mrc_ids)
    hazard_result, hazard_ids, control_ids = _check_hazards(case, evidence_ids, mrc_ids)
    fault_tree_result = _check_fault_trees(case, hazard_ids, control_ids)
    rcc_result = _check_rcc(case)
    responsibility_result = _check_responsibility(case)
    regulatory_result = _check_regulatory(case)
    claim_graph_result = _check_claim_graph(case, evidence_ids)
    odd_monitor = run_odd_monitor_smoke(case)
    scope = case.get("scope", {}) if isinstance(case.get("scope"), Mapping) else {}
    top_claim = case.get("top_claim", {}) if isinstance(case.get("top_claim"), Mapping) else {}
    schema_and_scope = (
        case.get("schema_version") == "mass_safety_case_v1"
        and _present(case.get("safety_case_id"))
        and _present(scope.get("system"))
        and _present(scope.get("intended_use"))
        and isinstance(scope.get("excluded_uses"), list)
        and len(scope.get("excluded_uses", [])) >= 4
        and top_claim.get("status") == "SUPPORTED_FOR_SIMULATOR_RESEARCH_ONLY"
    )
    claims = case.get("claims", {}) if isinstance(case.get("claims"), Mapping) else {}
    claims_fail_closed = bool(claims) and all(value is False for value in claims.values())
    checks = {
        "schema_scope_and_top_claim": schema_and_scope,
        "operational_design_domain_complete": odd_result["passed"],
        "hazard_log_and_controls_complete": hazard_result["passed"],
        "minimum_risk_conditions_complete": mrc_result["passed"],
        "fault_trees_acyclic_and_cover_all_hazards": fault_tree_result["passed"],
        "remote_control_centre_contract_complete": rcc_result["passed"],
        "personnel_responsibility_raci_complete": responsibility_result["passed"],
        "regulatory_register_routes_external_decisions": regulatory_result["passed"],
        "evidence_registry_files_exist_and_are_hash_bound": evidence_result["passed"],
        "claim_graph_is_traceable_and_acyclic": claim_graph_result["passed"],
        "runtime_odd_monitor_maps_every_breach_to_mrc": odd_monitor["passed"],
        "approval_and_production_claims_fail_closed": claims_fail_closed,
    }
    functional_complete = all(checks.values())
    acceptance = _check_acceptance(acceptance_manifest, str(case.get("safety_case_id", "")))
    status = (
        "READY_FOR_INDEPENDENT_SAFETY_CASE_DECISION"
        if functional_complete and acceptance["passed"]
        else "FUNCTIONAL_SAFETY_CASE_COMPLETE_EXTERNAL_ACCEPTANCE_BLOCKED"
        if functional_complete
        else "BLOCKED_SAFETY_CASE_DEFINITION_INCOMPLETE"
    )
    return {
        "schema_version": "mass_safety_case_assessment_v1",
        "safety_case_id": case.get("safety_case_id", ""),
        "status": status,
        "functional_safety_case_complete": functional_complete,
        "checks": checks,
        "section_results": {
            "operational_design_domain": odd_result,
            "hazard_log": hazard_result,
            "minimum_risk_conditions": mrc_result,
            "fault_trees": fault_tree_result,
            "remote_control_centre": rcc_result,
            "responsibility_model": responsibility_result,
            "regulatory_applicability": regulatory_result,
            "evidence_registry": evidence_result,
            "claim_graph": claim_graph_result,
        },
        "runtime_odd_monitor_smoke": odd_monitor,
        "acceptance_evidence": acceptance,
        "evidence_sha256": evidence_hashes,
        "external_authentication_required": True,
        "independent_review_complete": False,
        "flag_state_approval": False,
        "coastal_state_approval": False,
        "class_approval": False,
        "type_approval": False,
        "mass_safety_certificate": False,
        "sea_trial_completed": False,
        "production_authority": False,
        "training_performed": False,
        "existing_model_modified": False,
        "boundary": "Functional safety-case consistency and ODD-to-MRC routing only. External legal determinations, residual-risk acceptance, independent review, vessel/site approval, certification and production authority remain blocked.",
    }
