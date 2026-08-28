"""Port production-integration functional assurance and site evidence gate."""

from __future__ import annotations

import hashlib
import hmac
import json
import math
from pathlib import Path
from typing import Any, Mapping

from tools.ship_assurance.full_mission_bridge import verify_policy_inventory


REQUIRED_ADAPTER_IDS = (
    "VTS_TRAFFIC",
    "TOS_BERTH_PLAN",
    "PILOTAGE_ORDER",
    "TUG_ORDER",
    "BERTH_RESOURCE",
    "OFFICIAL_NOTICES",
)
SITE_CLAIMS = (
    "live_vts_connected",
    "live_tos_connected",
    "authorized_pilotage_connected",
    "authorized_tug_dispatch_connected",
    "official_berth_service_connected",
    "official_notices_connected",
    "sla_verified",
    "site_shadow_operation_completed",
    "dispatch_allowed",
    "production_authority",
)
REQUIRED_EXTERNAL_REFERENCES = (
    ("connector_authorization", "vts_endpoint_and_authorization_file"),
    ("connector_authorization", "tos_endpoint_and_authorization_file"),
    ("connector_authorization", "pilotage_endpoint_and_authorization_file"),
    ("connector_authorization", "tug_dispatch_endpoint_and_authorization_file"),
    ("connector_authorization", "berth_resource_endpoint_and_authorization_file"),
    ("connector_authorization", "official_notices_endpoint_and_authorization_file"),
    ("mapping_and_semantics", "vts_mapping_file"),
    ("mapping_and_semantics", "tos_mapping_file"),
    ("mapping_and_semantics", "pilotage_mapping_file"),
    ("mapping_and_semantics", "tug_mapping_file"),
    ("mapping_and_semantics", "berth_mapping_file"),
    ("mapping_and_semantics", "notices_mapping_file"),
    ("mapping_and_semantics", "units_and_time_reference_file"),
    ("mapping_and_semantics", "authority_precedence_file"),
    ("service_level", "signed_sla_file"),
    ("service_level", "freshness_and_latency_test_file"),
    ("service_level", "clock_synchronization_test_file"),
    ("service_level", "disconnect_and_recovery_test_file"),
    ("security_and_audit", "identity_and_certificate_file"),
    ("security_and_audit", "network_zone_and_firewall_file"),
    ("security_and_audit", "key_rotation_test_file"),
    ("security_and_audit", "immutable_audit_store_test_file"),
    ("shadow_operation", "frozen_shadow_plan_file"),
    ("shadow_operation", "signed_shadow_results_file"),
    ("shadow_operation", "operator_acceptance_file"),
    ("shadow_operation", "rollback_drill_file"),
    ("external_approval", "port_authority_acceptance_file"),
    ("external_approval", "vts_acceptance_file"),
    ("external_approval", "terminal_operator_acceptance_file"),
    ("external_approval", "pilotage_provider_acceptance_file"),
    ("external_approval", "tug_provider_acceptance_file"),
    ("external_approval", "flag_or_class_decision_file"),
    ("external_approval", "legal_and_raci_file"),
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
    return (
        not isinstance(value, bool)
        and isinstance(value, (int, float))
        and math.isfinite(float(value))
    )


def evaluate_profile(profile: Mapping[str, Any], root: Path) -> dict[str, Any]:
    adapter_value = profile.get("adapters", [])
    adapters = adapter_value if isinstance(adapter_value, list) else []
    adapter_ids = tuple(
        str(item.get("adapter_id", ""))
        for item in adapters
        if isinstance(item, Mapping)
    )
    contract_complete = (
        adapter_ids == REQUIRED_ADAPTER_IDS
        and len(adapters) == 6
        and all(
            isinstance(item, Mapping)
            and _present(item.get("system_type"))
            and item.get("direction") in {"READ_ONLY", "READ_AND_RECEIPT_REHEARSAL"}
            and int(item.get("freshness_seconds", 0)) > 0
            and int(item.get("disconnect_grace_seconds", 0)) > 0
            and len(item.get("required_fields", [])) >= 5
            and isinstance(item.get("required_units"), Mapping)
            and bool(item.get("required_units"))
            and len(item.get("authoritative_for", [])) >= 2
            and _present(item.get("training_hmac_key"))
            and item.get("production_credentials_configured") is False
            for item in adapters
        )
    )
    unique_keys = len(
        {str(item.get("training_hmac_key", "")) for item in adapters if isinstance(item, Mapping)}
    ) == 6
    hmac_fixture = False
    if adapters and isinstance(adapters[0], Mapping):
        item = adapters[0]
        key = str(item.get("training_hmac_key", "")).encode()
        message = b"VTS_TRAFFIC|FIXTURE|1|1700000000|payload-sha"
        hmac_fixture = len(hmac.new(key, message, hashlib.sha256).hexdigest()) == 64
    coordination = profile.get("coordination", {})
    coordination_complete = (
        isinstance(coordination, Mapping)
        and coordination.get("human_confirmation_required") is True
        and coordination.get("allowed_terminal_statuses")
        == ["ACKNOWLEDGED", "REJECTED", "CANCELLED"]
        and coordination.get("external_dispatch_enabled") is False
        and coordination.get("vessel_actuation_mapping_enabled") is False
    )
    degraded = profile.get("degraded_mode", {})
    degraded_complete = (
        isinstance(degraded, Mapping)
        and degraded.get("never_auto_dispatch") is True
        and degraded.get("never_map_to_actuation") is True
        and _present(degraded.get("stale_action"))
        and _present(degraded.get("disconnect_action"))
    )
    audit = profile.get("audit", {})
    audit_complete = (
        isinstance(audit, Mapping)
        and audit.get("hash_algorithm") == "SHA256"
        and int(audit.get("maximum_records", 0)) >= 1024
        and audit.get("persist_payload_body") is False
        and audit.get("persist_summary_and_lineage_only") is True
    )
    preservation = profile.get("preservation_boundary", {})
    preservation_complete = isinstance(preservation, Mapping) and all(
        preservation.get(key) is False
        for key in (
            "ship_motion_model_modified",
            "observation_space_modified",
            "action_space_modified",
            "reward_function_modified",
            "existing_policy_modified",
            "training_performed",
        )
    )
    claims = profile.get("claims", {})
    claims_fail_closed = isinstance(claims, Mapping) and all(
        claims.get(key) is False for key in SITE_CLAIMS
    )
    runtime_files = {
        relative: (root / relative).is_file()
        for relative in (
            "scripts/integration/ship_port_production_gateway.gd",
            "scripts/ui/ship_port_integration_panel.gd",
            "tools/godot_port_production_integration_smoke.gd",
        )
    }
    return {
        "schema_valid": profile.get("schema_version")
        == "port_production_integration_profile_v1",
        "adapter_contract_complete": contract_complete,
        "adapter_ids": list(adapter_ids),
        "adapter_count": len(adapters),
        "unique_training_keys": unique_keys,
        "hmac_fixture_available": hmac_fixture,
        "coordination_contract_complete": coordination_complete,
        "degraded_mode_complete": degraded_complete,
        "audit_contract_complete": audit_complete,
        "preservation_boundary_complete": preservation_complete,
        "site_claims_fail_closed": claims_fail_closed,
        "runtime_files": runtime_files,
        "runtime_files_present": all(runtime_files.values()),
    }


def evaluate_runtime_smoke(root: Path) -> dict[str, Any]:
    path = root / "reports/godot_port_production_integration_smoke_v1.json"
    if not path.is_file():
        return {"passed": False, "reason": "RUNTIME_SMOKE_MISSING"}
    payload = load_json(path)
    false_boundaries = (
        "training_performed",
        "ship_motion_model_modified",
        "observation_space_modified",
        "action_space_modified",
        "reward_function_modified",
        "existing_policy_modified",
        "live_vts_connected",
        "live_tos_connected",
        "authorized_pilotage_connected",
        "authorized_tug_dispatch_connected",
        "official_berth_service_connected",
        "official_notices_connected",
        "sla_verified",
        "site_shadow_operation_completed",
        "external_dispatch_performed",
        "mapped_to_vessel_actuation",
        "dispatch_allowed",
        "production_authority",
    )
    passed = (
        payload.get("schema_version")
        == "godot_port_production_integration_smoke_v1"
        and payload.get("passed") is True
        and payload.get("passed_count") == payload.get("check_count")
        and int(payload.get("check_count", 0)) >= 50
        and all(payload.get(key) is False for key in false_boundaries)
    )
    return {
        "passed": passed,
        "passed_count": int(payload.get("passed_count", 0)),
        "check_count": int(payload.get("check_count", 0)),
        "errors": payload.get("errors", []),
        "file": str(path.relative_to(root)),
        "file_sha256": sha256_path(path),
    }


def evaluate_site_manifest(manifest: Mapping[str, Any], root: Path) -> dict[str, Any]:
    inventory_value = manifest.get("evidence_files", {})
    inventory = inventory_value if isinstance(inventory_value, Mapping) else {}
    reference_checks: dict[str, bool] = {}
    for section, field in REQUIRED_EXTERNAL_REFERENCES:
        section_value = manifest.get(section, {})
        reference = (
            str(section_value.get(field, ""))
            if isinstance(section_value, Mapping)
            else ""
        )
        path = root / reference if reference else root / "__MISSING__"
        expected = str(inventory.get(reference, ""))
        reference_checks[f"{section}.{field}"] = (
            bool(reference)
            and path.is_file()
            and len(expected) == 64
            and sha256_path(path) == expected
        )
    claims = manifest.get("claims", {})
    self_asserted_claim_detected = isinstance(claims, Mapping) and any(
        claims.get(key) is True for key in SITE_CLAIMS
    )
    authorization = manifest.get("connector_authorization", {})
    mapping = manifest.get("mapping_and_semantics", {})
    service = manifest.get("service_level", {})
    security = manifest.get("security_and_audit", {})
    shadow = manifest.get("shadow_operation", {})
    approval = manifest.get("external_approval", {})
    measurements_complete = (
        _present(manifest.get("site_id"))
        and _present(manifest.get("port_authority"))
        and isinstance(authorization, Mapping)
        and authorization.get("all_six_authorized") is True
        and isinstance(mapping, Mapping)
        and mapping.get("all_mappings_accepted") is True
        and isinstance(service, Mapping)
        and service.get("sla_verified") is True
        and _finite(service.get("measured_availability_percent"))
        and float(service.get("measured_availability_percent", 0.0)) >= 99.0
        and _finite(service.get("worst_freshness_seconds"))
        and float(service.get("worst_freshness_seconds", -1.0)) >= 0.0
        and isinstance(security, Mapping)
        and security.get("security_accepted") is True
        and isinstance(shadow, Mapping)
        and shadow.get("shadow_operation_completed") is True
        and int(shadow.get("duration_days", 0)) >= 30
        and int(shadow.get("scenario_count", 0)) >= 1000
        and shadow.get("critical_mismatch_count") == 0
        and isinstance(approval, Mapping)
        and approval.get("all_required_approvals_obtained") is True
    )
    package_complete = (
        manifest.get("schema_version")
        == "port_production_site_acceptance_manifest_v1"
        and all(reference_checks.values())
        and measurements_complete
        and not self_asserted_claim_detected
    )
    return {
        "schema_valid": manifest.get("schema_version")
        == "port_production_site_acceptance_manifest_v1",
        "reference_checks": reference_checks,
        "measurements_complete": measurements_complete,
        "self_asserted_claim_detected": self_asserted_claim_detected,
        "evidence_package_complete": package_complete,
        "status": (
            "READY_FOR_INDEPENDENT_PORT_SITE_DECISION"
            if package_complete
            else "BLOCKED_EXTERNAL_PORT_SITE_EVIDENCE_INCOMPLETE"
        ),
        **{key: False for key in SITE_CLAIMS},
        "external_decision_required": True,
    }


def build_port_production_integration_report(
    root: Path, profile: Mapping[str, Any], manifest: Mapping[str, Any]
) -> dict[str, Any]:
    profile_result = evaluate_profile(profile, root)
    runtime = evaluate_runtime_smoke(root)
    policies = verify_policy_inventory(root)
    external = evaluate_site_manifest(manifest, root)
    checks = {
        "profile_schema": profile_result["schema_valid"],
        "six_adapter_contracts": profile_result["adapter_contract_complete"],
        "unique_training_credentials": profile_result["unique_training_keys"],
        "hmac_fixture": profile_result["hmac_fixture_available"],
        "coordination_contract": profile_result["coordination_contract_complete"],
        "degraded_mode": profile_result["degraded_mode_complete"],
        "summary_only_audit": profile_result["audit_contract_complete"],
        "runtime_components_present": profile_result["runtime_files_present"],
        "preservation_boundary": profile_result["preservation_boundary_complete"],
        "site_claims_fail_closed": profile_result["site_claims_fail_closed"],
        "godot_runtime_acceptance": runtime["passed"],
        "existing_policy_hashes": policies["passed"],
        "site_manifest_fail_closed": not external["evidence_package_complete"],
        "no_self_asserted_site_claim": not external["self_asserted_claim_detected"],
    }
    complete = all(checks.values())
    claims = {
        "training_performed": False,
        "ship_motion_model_modified": False,
        "observation_space_modified": False,
        "action_space_modified": False,
        "reward_function_modified": False,
        "existing_policy_modified": False,
        "external_dispatch_performed": False,
        "mapped_to_vessel_actuation": False,
        **{key: False for key in SITE_CLAIMS},
    }
    return {
        "schema_version": "port_production_integration_assurance_v1",
        "status": (
            "FUNCTIONAL_PORT_INTEGRATION_COMPLETE_EXTERNAL_SITE_ACCEPTANCE_BLOCKED"
            if complete
            else "FUNCTIONAL_PORT_INTEGRATION_INCOMPLETE"
        ),
        "functional_port_integration_complete": complete,
        "checks": checks,
        "profile_evaluation": profile_result,
        "runtime_acceptance": runtime,
        "preserved_policy_inventory": policies,
        "site_acceptance_gate": external,
        "claims": claims,
    }
