from __future__ import annotations

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import unittest

from tools.run_maritime_cybersecurity_assurance import build_payload
from tools.ship_assurance.maritime_cybersecurity import (
    PRODUCTION_CLAIMS,
    REQUIRED_IDS_RULES,
    REQUIRED_ROLES,
    REQUIRED_ZONES,
    build_maritime_cybersecurity_report,
    evaluate_acceptance_manifest,
    evaluate_profile,
    evaluate_runtime_smoke,
    verify_boot_manifest,
    verify_policy_inventory,
    verify_signed_update_fixture,
)


ROOT = Path(__file__).resolve().parents[1]
PROFILE_PATH = ROOT / "data/verification/maritime_cybersecurity_profile_v1.json"
MANIFEST_PATH = ROOT / "data/verification/maritime_cybersecurity_acceptance_manifest.template.json"


def _read(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


class MaritimeCybersecurityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.profile = _read(PROFILE_PATH)
        self.manifest = _read(MANIFEST_PATH)

    def test_profile_covers_segmentation_identity_ids_recovery_and_penetration(self) -> None:
        result = evaluate_profile(self.profile, ROOT)
        self.assertTrue(result["schema_valid"], result)
        self.assertEqual(tuple(result["roles"]), REQUIRED_ROLES)
        self.assertEqual(tuple(result["zone_ids"]), REQUIRED_ZONES)
        self.assertEqual(result["allowed_flow_count"], 8)
        self.assertTrue(result["identity_contract_complete"], result)
        self.assertTrue(result["zone_contract_complete"], result)
        self.assertTrue(result["ids_contract_complete"], result)
        self.assertTrue(result["recovery_contract_complete"], result)
        self.assertTrue(result["penetration_contract_complete"], result)

    def test_training_password_fixtures_match_only_salted_hashes(self) -> None:
        passwords = {
            "bridge_operator": "Bridge-Operator-Training-2026!",
            "instructor": "Instructor-Training-2026!",
            "security_admin": "Cyber-Admin-Training-2026!",
            "auditor": "Audit-Training-2026!",
        }
        for account in self.profile["identity_policy"]["accounts"]:
            presented = hashlib.sha256(
                f"{account['salt']}:{passwords[account['username']]}".encode()
            ).hexdigest()
            self.assertEqual(presented, account["password_sha256"])
            self.assertNotIn("password", account)

    def test_rsa_update_signature_and_private_key_boundary(self) -> None:
        result = verify_signed_update_fixture(self.profile, ROOT)
        self.assertTrue(result["passed"], result)
        self.assertEqual(result["openssl_stdout"], "Verified OK")
        self.assertEqual(result["private_key_candidates"], [])
        self.assertFalse(result["production_signing_key"])
        self.assertFalse(result["hardware_backed_key"])

    def test_software_boot_manifest_hashes_are_current(self) -> None:
        result = verify_boot_manifest(self.profile, ROOT)
        self.assertTrue(result["passed"], result)
        self.assertGreaterEqual(result["file_count"], 7)
        self.assertFalse(result["hardware_root_of_trust_verified"])
        self.assertFalse(result["measured_boot_verified"])

    def test_runtime_smoke_exercises_real_godot_security_controls(self) -> None:
        result = evaluate_runtime_smoke(ROOT)
        self.assertTrue(result["passed"], result)
        self.assertGreaterEqual(result["check_count"], 55)
        self.assertEqual(result["passed_count"], result["check_count"])
        smoke = _read(ROOT / result["file"])
        observed = {
            name.removeprefix("ids_rule_").removesuffix("_observed").upper()
            for name in smoke["checks"]
            if name.startswith("ids_rule_") and name.endswith("_observed")
        }
        self.assertEqual(observed, set(REQUIRED_IDS_RULES))

    def test_existing_policies_remain_hash_verified(self) -> None:
        result = verify_policy_inventory(ROOT)
        self.assertTrue(result["passed"], result)
        self.assertEqual(result["policy_count"], 10)

    def test_empty_external_manifest_and_forged_claims_fail_closed(self) -> None:
        empty = evaluate_acceptance_manifest(self.manifest, ROOT)
        self.assertFalse(empty["evidence_package_complete"], empty)
        self.assertEqual(
            empty["status"],
            "BLOCKED_EXTERNAL_CYBERSECURITY_EVIDENCE_INCOMPLETE",
        )
        forged = deepcopy(self.manifest)
        forged["claims"] = {key: True for key in PRODUCTION_CLAIMS}
        forged["network_segmentation"]["production_network_segmentation_verified"] = True
        forged["platform_integrity"]["hardware_secure_boot_verified"] = True
        forged["monitoring_and_logs"]["production_ids_verified"] = True
        forged["penetration_test"]["independent_penetration_test_completed"] = True
        forged["external_approval"]["class_or_flag_cyber_approval"] = True
        result = evaluate_acceptance_manifest(forged, ROOT)
        self.assertTrue(result["self_asserted_claim_detected"], result)
        self.assertFalse(result["evidence_package_complete"], result)
        self.assertFalse(result["production_authority"])

    def test_runtime_sources_preserve_motion_policy_and_no_actuation_boundary(self) -> None:
        suite = (ROOT / "scripts/security/ship_bridge_cybersecurity_suite.gd").read_text(encoding="utf-8")
        panel = (ROOT / "scripts/ui/ship_bridge_cybersecurity_panel.gd").read_text(encoding="utf-8")
        self.assertIn("func request_network_flow", suite)
        self.assertIn("func verify_signed_update", suite)
        self.assertIn("func run_penetration_campaign", suite)
        self.assertIn("func verify_audit_chain", suite)
        self.assertIn('"mapped_to_actuation": false', suite)
        self.assertNotIn("set_ship_agent_command", suite)
        self.assertNotIn("apply_action", suite)
        self.assertIn('"ship_motion_model_modified": false', panel)
        self.assertIn('"existing_policy_modified": false', panel)

    def test_report_is_functionally_complete_but_external_assurance_is_blocked(self) -> None:
        report = build_maritime_cybersecurity_report(
            ROOT, self.profile, self.manifest
        )
        self.assertTrue(report["functional_cyber_controls_complete"], report)
        self.assertTrue(all(report["checks"].values()), report)
        self.assertEqual(
            report["status"],
            "FUNCTIONAL_CYBER_CONTROLS_COMPLETE_EXTERNAL_SECURITY_ASSURANCE_BLOCKED",
        )
        self.assertFalse(
            report["external_acceptance_gate"]["evidence_package_complete"]
        )
        self.assertTrue(all(value is False for value in report["claims"].values()))
        payload = build_payload()
        self.assertEqual(len(payload["inputs_sha256"]), 10)


if __name__ == "__main__":
    unittest.main()
