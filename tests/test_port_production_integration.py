from __future__ import annotations

from copy import deepcopy
import json
from pathlib import Path
import unittest

from tools.run_port_production_integration_assurance import build_payload
from tools.ship_assurance.port_production_integration import (
    REQUIRED_ADAPTER_IDS,
    SITE_CLAIMS,
    build_port_production_integration_report,
    evaluate_profile,
    evaluate_runtime_smoke,
    evaluate_site_manifest,
    verify_policy_inventory,
)


ROOT = Path(__file__).resolve().parents[1]
PROFILE_PATH = ROOT / "data/verification/port_production_integration_profile_v1.json"
MANIFEST_PATH = ROOT / "data/verification/port_production_site_acceptance_manifest.template.json"


def _read(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


class PortProductionIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.profile = _read(PROFILE_PATH)
        self.manifest = _read(MANIFEST_PATH)

    def test_profile_declares_six_authority_bounded_connectors(self) -> None:
        result = evaluate_profile(self.profile, ROOT)
        self.assertTrue(result["schema_valid"], result)
        self.assertEqual(tuple(result["adapter_ids"]), REQUIRED_ADAPTER_IDS)
        self.assertEqual(result["adapter_count"], 6)
        self.assertTrue(result["adapter_contract_complete"], result)
        self.assertTrue(result["unique_training_keys"], result)
        self.assertTrue(result["hmac_fixture_available"], result)

    def test_coordination_degraded_and_audit_contracts_fail_closed(self) -> None:
        result = evaluate_profile(self.profile, ROOT)
        self.assertTrue(result["coordination_contract_complete"], result)
        self.assertTrue(result["degraded_mode_complete"], result)
        self.assertTrue(result["audit_contract_complete"], result)
        self.assertTrue(result["preservation_boundary_complete"], result)
        self.assertTrue(result["site_claims_fail_closed"], result)

    def test_runtime_smoke_exercises_signed_real_godot_gateway(self) -> None:
        result = evaluate_runtime_smoke(ROOT)
        self.assertTrue(result["passed"], result)
        self.assertGreaterEqual(result["check_count"], 50)
        self.assertEqual(result["passed_count"], result["check_count"])

    def test_existing_policies_remain_hash_verified(self) -> None:
        result = verify_policy_inventory(ROOT)
        self.assertTrue(result["passed"], result)
        self.assertEqual(result["policy_count"], 10)

    def test_empty_site_manifest_and_forged_claims_fail_closed(self) -> None:
        empty = evaluate_site_manifest(self.manifest, ROOT)
        self.assertFalse(empty["evidence_package_complete"], empty)
        self.assertEqual(
            empty["status"], "BLOCKED_EXTERNAL_PORT_SITE_EVIDENCE_INCOMPLETE"
        )
        forged = deepcopy(self.manifest)
        forged["claims"] = {key: True for key in SITE_CLAIMS}
        forged["connector_authorization"]["all_six_authorized"] = True
        forged["mapping_and_semantics"]["all_mappings_accepted"] = True
        forged["service_level"]["sla_verified"] = True
        forged["security_and_audit"]["security_accepted"] = True
        forged["shadow_operation"]["shadow_operation_completed"] = True
        forged["external_approval"]["all_required_approvals_obtained"] = True
        result = evaluate_site_manifest(forged, ROOT)
        self.assertTrue(result["self_asserted_claim_detected"], result)
        self.assertFalse(result["evidence_package_complete"], result)
        self.assertFalse(result["production_authority"])

    def test_runtime_source_has_no_transport_or_actuation_side_effect(self) -> None:
        gateway = (ROOT / "scripts/integration/ship_port_production_gateway.gd").read_text(encoding="utf-8")
        panel = (ROOT / "scripts/ui/ship_port_integration_panel.gd").read_text(encoding="utf-8")
        self.assertIn("func ingest_snapshot", gateway)
        self.assertIn("func run_freshness_watchdog", gateway)
        self.assertIn("func create_coordination_request", gateway)
        self.assertIn("func receive_coordination_ack", gateway)
        self.assertIn('"external_dispatch_performed": false', gateway)
        self.assertIn('"mapped_to_vessel_actuation": false', gateway)
        self.assertNotIn("HTTPClient", gateway)
        self.assertNotIn("PacketPeerUDP", gateway)
        self.assertNotIn("set_ship_agent_command", gateway)
        self.assertIn('"ship_motion_model_modified": false', panel)
        self.assertIn('"existing_policy_modified": false', panel)

    def test_report_is_functionally_complete_but_site_acceptance_is_blocked(self) -> None:
        report = build_port_production_integration_report(
            ROOT, self.profile, self.manifest
        )
        self.assertTrue(report["functional_port_integration_complete"], report)
        self.assertTrue(all(report["checks"].values()), report)
        self.assertEqual(
            report["status"],
            "FUNCTIONAL_PORT_INTEGRATION_COMPLETE_EXTERNAL_SITE_ACCEPTANCE_BLOCKED",
        )
        self.assertFalse(report["site_acceptance_gate"]["evidence_package_complete"])
        self.assertTrue(all(value is False for value in report["claims"].values()))
        payload = build_payload()
        self.assertEqual(len(payload["inputs_sha256"]), 6)


if __name__ == "__main__":
    unittest.main()
