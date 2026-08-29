from __future__ import annotations

from copy import deepcopy
import json
from pathlib import Path
import unittest

from tools.run_full_mission_bridge_assurance import build_payload
from tools.ship_assurance.full_mission_bridge import (
    REQUIRED_DOMAIN_IDS,
    build_full_mission_bridge_report,
    evaluate_acceptance_manifest,
    evaluate_profile,
    evaluate_runtime_smoke,
    verify_policy_inventory,
)


ROOT = Path(__file__).resolve().parents[1]
PROFILE_PATH = ROOT / "data/verification/full_mission_bridge_profile_v1.json"
MANIFEST_PATH = ROOT / "data/verification/full_mission_bridge_acceptance_manifest.template.json"


def _read(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


class FullMissionBridgeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.profile = _read(PROFILE_PATH)
        self.manifest = _read(MANIFEST_PATH)

    def test_profile_covers_ten_full_mission_domains(self) -> None:
        result = evaluate_profile(self.profile, ROOT)
        self.assertTrue(result["domain_contract_complete"], result)
        self.assertEqual(tuple(result["domain_ids"]), REQUIRED_DOMAIN_IDS)
        self.assertTrue(result["runtime_components_present"], result)
        self.assertTrue(result["gmdss_contract_complete"], result)
        self.assertTrue(result["visual_contract_complete"], result)
        self.assertTrue(result["multi_student_contract_complete"], result)
        self.assertTrue(result["instructor_gate_complete"], result)

    def test_runtime_smoke_exercises_real_godot_controls(self) -> None:
        result = evaluate_runtime_smoke(ROOT)
        self.assertTrue(result["passed"], result)
        self.assertGreaterEqual(result["check_count"], 38)
        self.assertEqual(result["passed_count"], result["check_count"])

    def test_all_existing_port_policies_remain_hash_verified(self) -> None:
        inventory = verify_policy_inventory(ROOT)
        self.assertTrue(inventory["passed"], inventory)
        self.assertEqual(inventory["policy_count"], 10)
        self.assertEqual(inventory["errors"], [])

    def test_empty_external_manifest_fails_closed(self) -> None:
        gate = evaluate_acceptance_manifest(self.manifest, ROOT)
        self.assertFalse(gate["evidence_package_complete"], gate)
        self.assertEqual(
            gate["status"],
            "BLOCKED_EXTERNAL_FULL_MISSION_EVIDENCE_INCOMPLETE",
        )
        self.assertFalse(gate["physical_full_mission_bridge_verified"])
        self.assertFalse(gate["instructor_qualification_verified"])
        self.assertFalse(gate["course_approval_verified"])
        self.assertFalse(gate["production_authority"])

    def test_claim_booleans_cannot_bypass_external_evidence(self) -> None:
        forged = deepcopy(self.manifest)
        forged["claims"] = {
            "physical_full_mission_bridge_verified": True,
            "instructor_qualification_verified": True,
            "course_approval_verified": True,
            "production_authority": True,
        }
        forged["course_acceptance"]["approved_training_course"] = True
        gate = evaluate_acceptance_manifest(forged, ROOT)
        self.assertTrue(gate["self_asserted_claim_detected"], gate)
        self.assertFalse(gate["evidence_package_complete"], gate)
        self.assertFalse(gate["production_authority"])

    def test_runtime_sources_preserve_motion_policy_and_actuation_boundaries(self) -> None:
        gmdss = (ROOT / "scripts/navigation/ship_gmdss_communications_suite.gd").read_text(encoding="utf-8")
        bridge = (ROOT / "scripts/navigation/ship_full_mission_bridge_suite.gd").read_text(encoding="utf-8")
        self.assertIn("func prepare_distress_alert", gmdss)
        self.assertIn("func transmit_prepared_distress", gmdss)
        self.assertIn("DISTRESS_REQUIRES_GUARDED_TWO_STEP_FLOW", gmdss)
        self.assertIn('"real_radio_transmission": false', gmdss)
        self.assertIn("func sweep_all_visual_sectors", bridge)
        self.assertIn('"visual_action_modified_ship_motion_model": false', bridge)
        self.assertIn('"existing_policy_modified": false', bridge)
        self.assertIn("ShipExecutionControlSuite", bridge)

    def test_report_is_functionally_complete_but_external_acceptance_is_blocked(self) -> None:
        report = build_full_mission_bridge_report(
            ROOT, self.profile, self.manifest
        )
        self.assertTrue(report["functional_software_bridge_complete"], report)
        self.assertTrue(all(report["checks"].values()), report)
        self.assertEqual(
            report["status"],
            "FUNCTIONAL_SOFTWARE_BRIDGE_COMPLETE_EXTERNAL_ACCEPTANCE_BLOCKED",
        )
        self.assertFalse(
            report["external_acceptance_gate"]["evidence_package_complete"]
        )
        self.assertFalse(report["model_boundary"]["base_ship_motion_model_replaced"])
        self.assertTrue(
            report["model_boundary"]["advanced_task_hydrodynamic_extension_enabled"]
        )
        self.assertFalse(
            report["model_boundary"]["named_vessel_dynamics_calibrated"]
        )
        self.assertTrue(all(value is False for value in report["claims"].values()))
        payload = build_payload()
        self.assertEqual(len(payload["inputs_sha256"]), 8)


if __name__ == "__main__":
    unittest.main()
