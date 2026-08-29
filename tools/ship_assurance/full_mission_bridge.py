"""Full-mission software bridge assurance and external-evidence gate."""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
from typing import Any, Mapping


REQUIRED_DOMAIN_IDS = (
    "RADAR_ARPA",
    "ECDIS",
    "CONNING",
    "GMDSS_VHF_DSC",
    "AUTOPILOT_STEERING",
    "PROPULSION_TELEGRAPH",
    "MULTI_STATION_BRM",
    "PANORAMIC_VISUAL",
    "INSTRUCTOR_STATION",
    "DEBRIEF",
)

RUNTIME_COMPONENT_FILES = {
    "ShipNavigationEquipmentSuite": "scripts/navigation/ship_navigation_equipment_suite.gd",
    "ShipGmdssCommunicationsSuite": "scripts/navigation/ship_gmdss_communications_suite.gd",
    "ShipExecutionControlSuite": "scripts/navigation/ship_execution_control_suite.gd",
    "ShipBridgeTeamCollaborationController": "scripts/training/ship_bridge_team_collaboration_controller.gd",
    "ShipFullMissionBridgeSuite": "scripts/navigation/ship_full_mission_bridge_suite.gd",
    "ShipInstructorExerciseController": "scripts/training/ship_instructor_exercise_controller.gd",
    "ShipAdvancedMissionRealismController": "scripts/training/ship_advanced_mission_realism_controller.gd",
    "ShipSimulationReviewPanel": "scripts/ui/ship_simulation_review_panel.gd",
}

REQUIRED_EXTERNAL_REFERENCES = (
    ("equipment_acceptance", "type_approval_evidence_file"),
    ("equipment_acceptance", "official_chart_and_update_service_evidence_file"),
    ("equipment_acceptance", "gmdss_hardware_test_evidence_file"),
    ("equipment_acceptance", "steering_and_propulsion_console_test_evidence_file"),
    ("visual_acceptance", "physical_display_layout_evidence_file"),
    ("visual_acceptance", "channel_synchronization_evidence_file"),
    ("multi_student_acceptance", "non_loopback_network_test_evidence_file"),
    ("instructor_acceptance", "qualification_evidence_file"),
    ("course_acceptance", "approval_evidence_file"),
    ("course_acceptance", "independent_acceptance_report_file"),
)


def load_json(path: str | Path) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def sha256_path(path: str | Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _present(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _finite(value: Any) -> bool:
    return not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(float(value))


def evaluate_profile(profile: Mapping[str, Any], root: Path) -> dict[str, Any]:
    domains = profile.get("equipment_domains", [])
    domain_records = domains if isinstance(domains, list) else []
    ids = [str(item.get("domain_id", "")) for item in domain_records if isinstance(item, Mapping)]
    components = {
        str(item.get("runtime_component", ""))
        for item in domain_records
        if isinstance(item, Mapping)
    }
    domain_contract_complete = (
        profile.get("schema_version") == "full_mission_bridge_profile_v1"
        and len(domain_records) == len(REQUIRED_DOMAIN_IDS)
        and tuple(ids) == REQUIRED_DOMAIN_IDS
        and all(
            isinstance(item, Mapping)
            and _present(item.get("label"))
            and _present(item.get("runtime_component"))
            and isinstance(item.get("required_functions"), list)
            and len(item.get("required_functions", [])) >= 3
            for item in domain_records
        )
    )
    runtime_components = {
        name: (root / relative).is_file()
        for name, relative in RUNTIME_COMPONENT_FILES.items()
    }
    gmdss = profile.get("gmdss_training", {})
    gmdss_complete = (
        isinstance(gmdss, Mapping)
        and gmdss.get("guard_channels") == ["16", "70"]
        and gmdss.get("priorities") == ["DISTRESS", "URGENCY", "SAFETY", "ROUTINE"]
        and _finite(gmdss.get("distress_hold_seconds"))
        and float(gmdss.get("distress_hold_seconds", 0.0)) >= 3.0
        and len(gmdss.get("distress_natures", [])) >= 8
        and gmdss.get("real_radio_transmission_enabled") is False
        and gmdss.get("coast_station_connected") is False
    )
    visual = profile.get("visual_system", {})
    visual_complete = (
        isinstance(visual, Mapping)
        and visual.get("mode") == "SOFTWARE_ORBIT_SECTORS"
        and visual.get("sector_count") == 8
        and visual.get("sector_width_degrees") == 45
        and visual.get("declared_horizontal_coverage_degrees") == 360
        and visual.get("physical_projection_verified") is False
        and visual.get("multi_channel_synchronization_verified") is False
        and visual.get("visual_latency_measured") is False
    )
    network = profile.get("multi_student_network", {})
    network_complete = (
        isinstance(network, Mapping)
        and network.get("functional_transport") == "LOOPBACK_UDP"
        and int(network.get("role_count", 0)) >= 9
        and network.get("authenticated_training_session") is True
        and network.get("encrypted") is False
        and network.get("non_loopback_acceptance_complete") is False
        and network.get("production_network_authorized") is False
    )
    instructor = profile.get("instructor_qualification_gate", {})
    instructor_complete = (
        isinstance(instructor, Mapping)
        and len(instructor.get("required_evidence", [])) >= 6
        and instructor.get("self_assertion_sufficient") is False
        and instructor.get("external_approval_required") is True
    )
    preservation = profile.get("preservation_boundary", {})
    preservation_complete = (
        isinstance(preservation, Mapping)
        and preservation.get("base_ship_motion_model_replaced") is False
        and preservation.get("advanced_task_hydrodynamic_extension_enabled") is True
        and preservation.get("advanced_task_hydrodynamic_extension_scope")
        == "five_advanced_mission_scenarios_only"
        and all(
            preservation.get(key) is False
            for key in (
                "observation_space_modified",
                "action_space_modified",
                "reward_function_modified",
                "existing_policy_modified",
                "training_performed",
            )
        )
    )
    claims = profile.get("claim_boundary", {})
    claims_fail_closed = isinstance(claims, Mapping) and all(
        claims.get(key) is False
        for key in (
            "type_approved_bridge_equipment",
            "official_chart_carriage_compliance",
            "real_gmdss_transmission",
            "physical_360_bridge_verified",
            "certified_instructor_available",
            "approved_training_course",
            "production_authority",
        )
    )
    return {
        "schema_valid": profile.get("schema_version") == "full_mission_bridge_profile_v1",
        "domain_contract_complete": domain_contract_complete,
        "domain_count": len(domain_records),
        "domain_ids": ids,
        "declared_runtime_components": sorted(components),
        "runtime_component_files": runtime_components,
        "runtime_components_present": all(runtime_components.values()),
        "gmdss_contract_complete": gmdss_complete,
        "visual_contract_complete": visual_complete,
        "multi_student_contract_complete": network_complete,
        "instructor_gate_complete": instructor_complete,
        "preservation_boundary_complete": preservation_complete,
        "external_claims_fail_closed": claims_fail_closed,
    }


def evaluate_acceptance_manifest(
    manifest: Mapping[str, Any], root: Path
) -> dict[str, Any]:
    evidence_files = manifest.get("evidence_files", {})
    evidence_inventory = evidence_files if isinstance(evidence_files, Mapping) else {}
    reference_checks: dict[str, bool] = {}
    for section, field in REQUIRED_EXTERNAL_REFERENCES:
        section_value = manifest.get(section, {})
        reference = (
            str(section_value.get(field, ""))
            if isinstance(section_value, Mapping)
            else ""
        )
        path = root / reference if reference else root / "__MISSING__"
        expected_hash = str(evidence_inventory.get(reference, ""))
        reference_checks[f"{section}.{field}"] = (
            bool(reference)
            and path.is_file()
            and len(expected_hash) == 64
            and sha256_path(path) == expected_hash
        )
    visual = manifest.get("visual_acceptance", {})
    visual_metrics = {
        "coverage": isinstance(visual, Mapping)
        and _finite(visual.get("measured_horizontal_coverage_degrees"))
        and float(visual.get("measured_horizontal_coverage_degrees", 0.0)) >= 360.0,
        "vertical_field": isinstance(visual, Mapping)
        and _finite(visual.get("measured_vertical_field_of_view_degrees"))
        and float(visual.get("measured_vertical_field_of_view_degrees", 0.0)) > 0.0,
        "latency": isinstance(visual, Mapping)
        and _finite(visual.get("worst_channel_latency_ms"))
        and float(visual.get("worst_channel_latency_ms", float("inf"))) <= 100.0,
    }
    network = manifest.get("multi_student_acceptance", {})
    network_metrics = {
        "concurrent_stations": isinstance(network, Mapping)
        and int(network.get("concurrent_station_count", 0)) >= 4,
        "encrypted_transport": isinstance(network, Mapping)
        and network.get("encrypted_transport_verified") is True,
        "session_authentication": isinstance(network, Mapping)
        and network.get("session_authentication_verified") is True,
        "disconnect_recovery": isinstance(network, Mapping)
        and network.get("disconnect_recovery_verified") is True,
    }
    instructor = manifest.get("instructor_acceptance", {})
    instructor_metadata = {
        field: isinstance(instructor, Mapping) and _present(instructor.get(field))
        for field in (
            "instructor_identity",
            "course_scope",
            "issuing_authority",
            "expiry_date",
            "witness_signature",
        )
    }
    course = manifest.get("course_acceptance", {})
    course_metadata = (
        isinstance(course, Mapping)
        and course.get("approved_training_course") is True
        and _present(course.get("approval_authority"))
    )
    requested_claims = manifest.get("claims", {})
    self_asserted_claim_detected = isinstance(requested_claims, Mapping) and any(
        requested_claims.get(key) is True
        for key in (
            "physical_full_mission_bridge_verified",
            "instructor_qualification_verified",
            "course_approval_verified",
            "production_authority",
        )
    )
    evidence_package_complete = (
        manifest.get("schema_version") == "full_mission_bridge_acceptance_manifest_v1"
        and all(reference_checks.values())
        and all(visual_metrics.values())
        and all(network_metrics.values())
        and all(instructor_metadata.values())
        and course_metadata
        and not self_asserted_claim_detected
    )
    return {
        "schema_valid": manifest.get("schema_version") == "full_mission_bridge_acceptance_manifest_v1",
        "reference_checks": reference_checks,
        "visual_metrics": visual_metrics,
        "multi_student_metrics": network_metrics,
        "instructor_metadata": instructor_metadata,
        "course_metadata_complete": course_metadata,
        "self_asserted_claim_detected": self_asserted_claim_detected,
        "evidence_package_complete": evidence_package_complete,
        "status": (
            "READY_FOR_INDEPENDENT_FULL_MISSION_ASSESSMENT"
            if evidence_package_complete
            else "BLOCKED_EXTERNAL_FULL_MISSION_EVIDENCE_INCOMPLETE"
        ),
        "physical_full_mission_bridge_verified": False,
        "instructor_qualification_verified": False,
        "course_approval_verified": False,
        "production_authority": False,
        "external_decision_required": True,
    }


def verify_policy_inventory(root: Path) -> dict[str, Any]:
    benchmark_path = root / "reports/port_ops_benchmark_v2.json"
    if not benchmark_path.is_file():
        return {"passed": False, "policy_count": 0, "errors": ["BENCHMARK_REPORT_MISSING"]}
    benchmark = load_json(benchmark_path)
    errors: list[str] = []
    artifacts = benchmark.get("artifacts", [])
    records = artifacts if isinstance(artifacts, list) else []
    for raw in records:
        if not isinstance(raw, Mapping):
            errors.append("INVALID_ARTIFACT_RECORD")
            continue
        algorithm = str(raw.get("algorithm", ""))
        for kind in ("checkpoint", "model"):
            relative_value = raw.get(kind)
            expected_value = raw.get(f"{kind}_sha256")
            if relative_value is None:
                continue
            relative = str(relative_value)
            expected = str(expected_value or "")
            path = root / relative
            if not path.is_file():
                errors.append(f"MISSING:{algorithm}:{kind}:{relative}")
            elif sha256_path(path) != expected:
                errors.append(f"HASH_MISMATCH:{algorithm}:{kind}:{relative}")
    if len(records) != 10:
        errors.append(f"POLICY_COUNT:{len(records)}")
    return {"passed": not errors, "policy_count": len(records), "errors": errors}


def evaluate_runtime_smoke(root: Path) -> dict[str, Any]:
    path = root / "reports/godot_full_mission_bridge_smoke_v1.json"
    if not path.is_file():
        return {"passed": False, "reason": "RUNTIME_SMOKE_MISSING"}
    payload = load_json(path)
    preservation_keys = (
        "training_performed",
        "base_ship_motion_model_replaced",
        "observation_space_modified",
        "action_space_modified",
        "reward_function_modified",
        "existing_policy_modified",
        "real_radio_transmission",
        "physical_360_bridge_verified",
        "certified_instructor_available",
        "approved_training_course",
        "production_authority",
    )
    passed = (
        payload.get("schema_version") == "godot_full_mission_bridge_smoke_v1"
        and payload.get("passed") is True
        and payload.get("passed_count") == payload.get("check_count")
        and int(payload.get("check_count", 0)) >= 38
        and all(payload.get(key) is False for key in preservation_keys)
        and payload.get("advanced_task_hydrodynamic_extension_enabled") is True
    )
    return {
        "passed": passed,
        "passed_count": int(payload.get("passed_count", 0)),
        "check_count": int(payload.get("check_count", 0)),
        "errors": payload.get("errors", []),
        "file": str(path.relative_to(root)),
        "file_sha256": sha256_path(path),
    }


def build_full_mission_bridge_report(
    root: Path, profile: Mapping[str, Any], manifest: Mapping[str, Any]
) -> dict[str, Any]:
    profile_evaluation = evaluate_profile(profile, root)
    acceptance = evaluate_acceptance_manifest(manifest, root)
    policies = verify_policy_inventory(root)
    runtime = evaluate_runtime_smoke(root)
    checks = {
        "profile_schema": profile_evaluation["schema_valid"],
        "ten_equipment_domains": profile_evaluation["domain_contract_complete"],
        "runtime_components_present": profile_evaluation["runtime_components_present"],
        "gmdss_contract": profile_evaluation["gmdss_contract_complete"],
        "visual_contract": profile_evaluation["visual_contract_complete"],
        "multi_student_contract": profile_evaluation["multi_student_contract_complete"],
        "instructor_gate": profile_evaluation["instructor_gate_complete"],
        "preservation_boundary": profile_evaluation["preservation_boundary_complete"],
        "external_claims_fail_closed": profile_evaluation["external_claims_fail_closed"],
        "existing_policy_hashes": policies["passed"],
        "godot_runtime_acceptance": runtime["passed"],
        "external_manifest_fail_closed": not acceptance["evidence_package_complete"],
        "no_self_asserted_external_claim": not acceptance["self_asserted_claim_detected"],
    }
    framework_complete = all(checks.values())
    return {
        "schema_version": "full_mission_bridge_assurance_v1",
        "status": (
            "FUNCTIONAL_SOFTWARE_BRIDGE_COMPLETE_EXTERNAL_ACCEPTANCE_BLOCKED"
            if framework_complete
            else "FUNCTIONAL_SOFTWARE_BRIDGE_INCOMPLETE"
        ),
        "functional_software_bridge_complete": framework_complete,
        "checks": checks,
        "profile_evaluation": profile_evaluation,
        "runtime_acceptance": runtime,
        "preserved_policy_inventory": policies,
        "external_acceptance_gate": acceptance,
        "model_boundary": {
            "base_ship_motion_model_replaced": False,
            "advanced_task_hydrodynamic_extension_enabled": True,
            "advanced_task_hydrodynamic_extension_scope": "five_advanced_mission_scenarios_only",
            "named_vessel_dynamics_calibrated": False,
        },
        "claims": {
            "training_performed": False,
            "observation_space_modified": False,
            "action_space_modified": False,
            "reward_function_modified": False,
            "existing_policy_modified": False,
            "real_radio_transmission": False,
            "physical_full_mission_bridge_verified": False,
            "type_approved_bridge_equipment": False,
            "instructor_qualification_verified": False,
            "approved_training_course": False,
            "production_authority": False,
        },
    }
