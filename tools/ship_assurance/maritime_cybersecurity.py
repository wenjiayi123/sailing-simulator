"""Maritime cybersecurity functional assurance and external evidence gate."""

from __future__ import annotations

import base64
import hashlib
import json
import math
from pathlib import Path
import subprocess
import tempfile
from typing import Any, Mapping

from tools.ship_assurance.full_mission_bridge import verify_policy_inventory


REQUIRED_ROLES = ("OPERATOR", "INSTRUCTOR", "SECURITY_ADMIN", "AUDITOR")
REQUIRED_ZONES = (
    "SAFETY_CONTROL",
    "NAVIGATION_SENSOR",
    "BRIDGE_OPERATIONS",
    "INSTRUCTOR_TRAINING",
    "ENGINEERING_MAINTENANCE",
    "AUDIT_MONITORING",
    "EXTERNAL_EXCHANGE",
)
REQUIRED_IDS_RULES = (
    "AUTHENTICATION_BRUTE_FORCE",
    "NONCE_REPLAY",
    "RBAC_DENIAL",
    "PROHIBITED_ZONE_FLOW",
    "INVALID_UPDATE_SIGNATURE",
    "BOOT_INTEGRITY_FAILURE",
    "AUDIT_CHAIN_TAMPER",
    "RECOVERY_WITHOUT_CONFIRMATION",
)
REQUIRED_EXTERNAL_REFERENCES = (
    ("network_segmentation", "as_built_network_diagram_file"),
    ("network_segmentation", "firewall_export_file"),
    ("network_segmentation", "vlan_and_data_diode_test_file"),
    ("identity_and_access", "identity_provider_configuration_file"),
    ("identity_and_access", "multi_factor_authentication_test_file"),
    ("identity_and_access", "privileged_access_review_file"),
    ("platform_integrity", "hardware_root_of_trust_evidence_file"),
    ("platform_integrity", "measured_boot_log_file"),
    ("platform_integrity", "production_signing_key_ceremony_file"),
    ("platform_integrity", "signed_update_install_and_rollback_test_file"),
    ("monitoring_and_logs", "ids_sensor_deployment_file"),
    ("monitoring_and_logs", "soc_forwarding_test_file"),
    ("monitoring_and_logs", "hardware_log_immutability_test_file"),
    ("monitoring_and_logs", "incident_response_drill_file"),
    ("disaster_recovery", "offline_backup_inventory_file"),
    ("disaster_recovery", "bare_metal_restore_test_file"),
    ("penetration_test", "scope_file"),
    ("penetration_test", "independent_tester_identity_file"),
    ("penetration_test", "signed_report_file"),
    ("penetration_test", "remediation_retest_file"),
    ("external_approval", "flag_or_class_decision_file"),
    ("external_approval", "qualified_assessor_identity_file"),
    ("external_approval", "signed_acceptance_file"),
)
PRODUCTION_CLAIMS = (
    "production_network_segmentation_verified",
    "hardware_secure_boot_verified",
    "production_signed_update_verified",
    "tamper_proof_hardware_log_verified",
    "production_ids_verified",
    "disaster_recovery_field_verified",
    "independent_penetration_test_completed",
    "class_or_flag_cyber_approval",
    "production_authority",
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


def _root_path(root: Path, value: str) -> Path:
    relative = value.removeprefix("res://")
    return root / relative


def verify_signed_update_fixture(profile: Mapping[str, Any], root: Path) -> dict[str, Any]:
    config = profile.get("secure_boot_and_update", {})
    if not isinstance(config, Mapping):
        return {"passed": False, "reason": "CONFIG_MISSING"}
    payload_path = _root_path(root, str(config.get("update_payload_path", "")))
    signature_path = _root_path(root, str(config.get("update_signature_path", "")))
    public_key_path = _root_path(root, str(config.get("public_key_path", "")))
    if not all(path.is_file() for path in (payload_path, signature_path, public_key_path)):
        return {"passed": False, "reason": "SIGNED_UPDATE_FIXTURE_MISSING"}
    signature_record = load_json(signature_path)
    try:
        signature = base64.b64decode(
            str(signature_record.get("signature_base64", "")), validate=True
        )
    except (ValueError, TypeError):
        return {"passed": False, "reason": "SIGNATURE_BASE64_INVALID"}
    with tempfile.NamedTemporaryFile(suffix=".sig") as handle:
        handle.write(signature)
        handle.flush()
        result = subprocess.run(
            [
                "openssl",
                "dgst",
                "-sha256",
                "-verify",
                str(public_key_path),
                "-signature",
                handle.name,
                str(payload_path),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
    private_key_candidates = [
        path
        for path in (root / "data/verification").rglob("*")
        if path.is_file()
        and (
            "private" in path.name.lower()
            or path.suffix.lower() in {".key", ".p12", ".pfx"}
        )
    ]
    passed = (
        result.returncode == 0
        and "Verified OK" in result.stdout
        and signature_record.get("signature_algorithm")
        == "RSA_PKCS1_V1_5_SHA256"
        and signature_record.get("private_key_present_in_repository") is False
        and not private_key_candidates
    )
    return {
        "passed": passed,
        "openssl_returncode": result.returncode,
        "openssl_stdout": result.stdout.strip(),
        "algorithm": signature_record.get("signature_algorithm"),
        "payload_sha256": sha256_path(payload_path),
        "signature_sha256": sha256_path(signature_path),
        "public_key_sha256": sha256_path(public_key_path),
        "private_key_candidates": [
            str(path.relative_to(root)) for path in private_key_candidates
        ],
        "production_signing_key": False,
        "hardware_backed_key": False,
    }


def verify_boot_manifest(profile: Mapping[str, Any], root: Path) -> dict[str, Any]:
    config = profile.get("secure_boot_and_update", {})
    manifest_path = _root_path(
        root,
        str(config.get("boot_manifest_path", ""))
        if isinstance(config, Mapping)
        else "",
    )
    if not manifest_path.is_file():
        return {"passed": False, "reason": "BOOT_MANIFEST_MISSING", "file_count": 0}
    manifest = load_json(manifest_path)
    errors: list[str] = []
    records = manifest.get("files", [])
    files = records if isinstance(records, list) else []
    for raw in files:
        if not isinstance(raw, Mapping):
            errors.append("INVALID_FILE_RECORD")
            continue
        path = _root_path(root, str(raw.get("path", "")))
        expected = str(raw.get("sha256", ""))
        if not path.is_file():
            errors.append(f"MISSING:{path.relative_to(root)}")
        elif len(expected) != 64 or sha256_path(path) != expected:
            errors.append(f"HASH_MISMATCH:{path.relative_to(root)}")
    boundary_valid = (
        manifest.get("schema_version") == "bridge_secure_boot_manifest_v1"
        and manifest.get("mode") == "SOFTWARE_HASH_ALLOWLIST_TRAINING"
        and len(files) >= 7
        and manifest.get("hardware_root_of_trust_verified") is False
        and manifest.get("measured_boot_verified") is False
        and manifest.get("secure_boot_key_enrolled") is False
        and manifest.get("production_boot_authority") is False
    )
    return {
        "passed": boundary_valid and not errors,
        "file": str(manifest_path.relative_to(root)),
        "file_count": len(files),
        "errors": errors,
        "software_allowlist_only": True,
        "hardware_root_of_trust_verified": False,
        "measured_boot_verified": False,
    }


def evaluate_profile(profile: Mapping[str, Any], root: Path) -> dict[str, Any]:
    identity = profile.get("identity_policy", {})
    accounts_value = identity.get("accounts", []) if isinstance(identity, Mapping) else []
    accounts = accounts_value if isinstance(accounts_value, list) else []
    roles = tuple(str(item.get("role", "")) for item in accounts if isinstance(item, Mapping))
    usernames = [str(item.get("username", "")) for item in accounts if isinstance(item, Mapping)]
    permissions = {
        str(permission)
        for item in accounts
        if isinstance(item, Mapping)
        for permission in item.get("permissions", [])
    }
    identity_complete = (
        tuple(roles) == REQUIRED_ROLES
        and len(set(usernames)) == 4
        and all(
            isinstance(item, Mapping)
            and _present(item.get("salt"))
            and len(str(item.get("password_sha256", ""))) == 64
            and isinstance(item.get("permissions"), list)
            and bool(item.get("permissions"))
            for item in accounts
        )
        and identity.get("maximum_failed_attempts") == 3
        and int(identity.get("session_ttl_seconds", 0)) > 0
        and int(identity.get("nonce_replay_window", 0)) >= 1024
        and identity.get("production_password_storage_approved") is False
    )
    zones_value = profile.get("network_zones", [])
    zones = zones_value if isinstance(zones_value, list) else []
    zone_ids = tuple(str(item.get("zone_id", "")) for item in zones if isinstance(item, Mapping))
    flows_value = profile.get("allowed_flows", [])
    flows = flows_value if isinstance(flows_value, list) else []
    segmentation_complete = (
        zone_ids == REQUIRED_ZONES
        and len(flows) == 8
        and len(
            {
                (str(item.get("source", "")), str(item.get("target", "")), str(item.get("service", "")))
                for item in flows
                if isinstance(item, Mapping)
            }
        )
        == 8
        and all(
            isinstance(item, Mapping)
            and str(item.get("source", "")) in zone_ids
            and str(item.get("target", "")) in zone_ids
            and str(item.get("required_permission", "")) in permissions
            for item in flows
        )
        and not any(
            isinstance(item, Mapping)
            and item.get("source") == "EXTERNAL_EXCHANGE"
            and item.get("target") == "SAFETY_CONTROL"
            and item.get("service") == "DIRECT_CONTROL"
            for item in flows
        )
    )
    ids = profile.get("intrusion_detection", {})
    ids_complete = (
        isinstance(ids, Mapping)
        and tuple(ids.get("rules", [])) == REQUIRED_IDS_RULES
        and int(ids.get("alert_retention", 0)) >= 512
        and ids.get("production_sensor_connected") is False
        and ids.get("soc_forwarding_connected") is False
    )
    recovery = profile.get("disaster_recovery", {})
    recovery_complete = (
        isinstance(recovery, Mapping)
        and recovery.get("recovery_point_type") == "IN_MEMORY_TRAINING_SNAPSHOT"
        and recovery.get("manual_confirmation_required") is True
        and recovery.get("restore_reauth_required") is True
        and recovery.get("offline_backup_verified") is False
        and recovery.get("bare_metal_restore_verified") is False
        and recovery.get("rto_rpo_field_tested") is False
    )
    campaign = profile.get("penetration_campaign", {})
    campaign_complete = (
        isinstance(campaign, Mapping)
        and len(campaign.get("required_cases", [])) == 8
        and campaign.get("real_external_penetration_test_completed") is False
        and campaign.get("independent_tester_verified") is False
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
            "network_messages_mapped_to_actuation",
            "training_performed",
        )
    )
    claims = profile.get("claims", {})
    claims_fail_closed = isinstance(claims, Mapping) and all(
        claims.get(key) is False for key in PRODUCTION_CLAIMS
    )
    runtime_files = {
        relative: (root / relative).is_file()
        for relative in (
            "scripts/security/ship_bridge_cybersecurity_suite.gd",
            "scripts/ui/ship_bridge_cybersecurity_panel.gd",
            "tools/godot_bridge_cybersecurity_smoke.gd",
        )
    }
    return {
        "schema_valid": profile.get("schema_version") == "maritime_cybersecurity_profile_v1",
        "identity_contract_complete": identity_complete,
        "roles": list(roles),
        "zone_contract_complete": segmentation_complete,
        "zone_ids": list(zone_ids),
        "allowed_flow_count": len(flows),
        "ids_contract_complete": ids_complete,
        "recovery_contract_complete": recovery_complete,
        "penetration_contract_complete": campaign_complete,
        "preservation_boundary_complete": preservation_complete,
        "production_claims_fail_closed": claims_fail_closed,
        "runtime_files": runtime_files,
        "runtime_files_present": all(runtime_files.values()),
    }


def evaluate_runtime_smoke(root: Path) -> dict[str, Any]:
    path = root / "reports/godot_bridge_cybersecurity_smoke_v1.json"
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
        "network_messages_mapped_to_actuation",
        "production_network_segmentation_verified",
        "hardware_secure_boot_verified",
        "production_ids_verified",
        "disaster_recovery_field_verified",
        "independent_penetration_test_completed",
        "class_or_flag_cyber_approval",
        "production_authority",
    )
    passed = (
        payload.get("schema_version") == "godot_bridge_cybersecurity_smoke_v1"
        and payload.get("passed") is True
        and payload.get("passed_count") == payload.get("check_count")
        and int(payload.get("check_count", 0)) >= 55
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


def evaluate_acceptance_manifest(manifest: Mapping[str, Any], root: Path) -> dict[str, Any]:
    evidence_files = manifest.get("evidence_files", {})
    inventory = evidence_files if isinstance(evidence_files, Mapping) else {}
    reference_checks: dict[str, bool] = {}
    for section, field in REQUIRED_EXTERNAL_REFERENCES:
        section_value = manifest.get(section, {})
        reference = str(section_value.get(field, "")) if isinstance(section_value, Mapping) else ""
        path = root / reference if reference else root / "__MISSING__"
        expected = str(inventory.get(reference, ""))
        reference_checks[f"{section}.{field}"] = (
            bool(reference)
            and path.is_file()
            and len(expected) == 64
            and sha256_path(path) == expected
        )
    requested_claims = manifest.get("claims", {})
    self_asserted_claim_detected = isinstance(requested_claims, Mapping) and any(
        requested_claims.get(key) is True for key in PRODUCTION_CLAIMS
    )
    segmentation = manifest.get("network_segmentation", {})
    identity = manifest.get("identity_and_access", {})
    platform = manifest.get("platform_integrity", {})
    monitoring = manifest.get("monitoring_and_logs", {})
    recovery = manifest.get("disaster_recovery", {})
    penetration = manifest.get("penetration_test", {})
    approval = manifest.get("external_approval", {})
    measurements_complete = (
        isinstance(segmentation, Mapping)
        and segmentation.get("production_network_segmentation_verified") is True
        and isinstance(identity, Mapping)
        and identity.get("least_privilege_verified") is True
        and isinstance(platform, Mapping)
        and platform.get("hardware_secure_boot_verified") is True
        and isinstance(monitoring, Mapping)
        and monitoring.get("production_ids_verified") is True
        and isinstance(recovery, Mapping)
        and recovery.get("field_restore_verified") is True
        and _finite(recovery.get("measured_rto_minutes"))
        and float(recovery.get("measured_rto_minutes", -1)) >= 0
        and _finite(recovery.get("measured_rpo_minutes"))
        and float(recovery.get("measured_rpo_minutes", -1)) >= 0
        and isinstance(penetration, Mapping)
        and penetration.get("independent_penetration_test_completed") is True
        and penetration.get("critical_findings_open") == 0
        and penetration.get("high_findings_open") == 0
        and isinstance(approval, Mapping)
        and approval.get("class_or_flag_cyber_approval") is True
    )
    evidence_package_complete = (
        manifest.get("schema_version") == "maritime_cybersecurity_acceptance_manifest_v1"
        and all(reference_checks.values())
        and measurements_complete
        and not self_asserted_claim_detected
    )
    return {
        "schema_valid": manifest.get("schema_version") == "maritime_cybersecurity_acceptance_manifest_v1",
        "reference_checks": reference_checks,
        "measurements_complete": measurements_complete,
        "self_asserted_claim_detected": self_asserted_claim_detected,
        "evidence_package_complete": evidence_package_complete,
        "status": (
            "READY_FOR_INDEPENDENT_CYBERSECURITY_ASSESSMENT"
            if evidence_package_complete
            else "BLOCKED_EXTERNAL_CYBERSECURITY_EVIDENCE_INCOMPLETE"
        ),
        "production_network_segmentation_verified": False,
        "hardware_secure_boot_verified": False,
        "production_ids_verified": False,
        "disaster_recovery_field_verified": False,
        "independent_penetration_test_completed": False,
        "class_or_flag_cyber_approval": False,
        "production_authority": False,
        "external_decision_required": True,
    }


def build_maritime_cybersecurity_report(
    root: Path, profile: Mapping[str, Any], manifest: Mapping[str, Any]
) -> dict[str, Any]:
    profile_result = evaluate_profile(profile, root)
    signature = verify_signed_update_fixture(profile, root)
    boot = verify_boot_manifest(profile, root)
    runtime = evaluate_runtime_smoke(root)
    policies = verify_policy_inventory(root)
    external = evaluate_acceptance_manifest(manifest, root)
    checks = {
        "profile_schema": profile_result["schema_valid"],
        "identity_and_least_privilege_contract": profile_result["identity_contract_complete"],
        "seven_zone_default_deny_contract": profile_result["zone_contract_complete"],
        "eight_rule_ids_contract": profile_result["ids_contract_complete"],
        "disaster_recovery_contract": profile_result["recovery_contract_complete"],
        "penetration_campaign_contract": profile_result["penetration_contract_complete"],
        "runtime_components_present": profile_result["runtime_files_present"],
        "preservation_boundary": profile_result["preservation_boundary_complete"],
        "production_claims_fail_closed": profile_result["production_claims_fail_closed"],
        "rsa_signed_update_fixture": signature["passed"],
        "software_boot_allowlist": boot["passed"],
        "godot_runtime_acceptance": runtime["passed"],
        "existing_policy_hashes": policies["passed"],
        "external_manifest_fail_closed": not external["evidence_package_complete"],
        "no_self_asserted_external_claim": not external["self_asserted_claim_detected"],
    }
    functional_complete = all(checks.values())
    claims = {
        "training_performed": False,
        "ship_motion_model_modified": False,
        "observation_space_modified": False,
        "action_space_modified": False,
        "reward_function_modified": False,
        "existing_policy_modified": False,
        "network_messages_mapped_to_actuation": False,
        **{key: False for key in PRODUCTION_CLAIMS},
    }
    return {
        "schema_version": "maritime_cybersecurity_assurance_v1",
        "status": (
            "FUNCTIONAL_CYBER_CONTROLS_COMPLETE_EXTERNAL_SECURITY_ASSURANCE_BLOCKED"
            if functional_complete
            else "FUNCTIONAL_CYBER_CONTROLS_INCOMPLETE"
        ),
        "functional_cyber_controls_complete": functional_complete,
        "checks": checks,
        "profile_evaluation": profile_result,
        "signed_update_evaluation": signature,
        "software_boot_integrity": boot,
        "runtime_acceptance": runtime,
        "preserved_policy_inventory": policies,
        "external_acceptance_gate": external,
        "claims": claims,
    }
