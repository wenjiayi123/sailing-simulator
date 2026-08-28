from __future__ import annotations

import json
from pathlib import Path
import unittest

from tools.run_colreg_complex_assurance import build_payload
from tools.ship_assurance.colreg import run_scenario_catalog
from tools.ship_assurance.colreg_complex import REQUIRED_CAPABILITIES, run_complex_colreg_catalog


ROOT = Path(__file__).resolve().parents[1]
LEGACY = ROOT / "data/verification/colreg_encounter_catalog_v1.json"
CATALOG = ROOT / "data/verification/colreg_complex_scenario_catalog_v2.json"
LOCAL_RULES = ROOT / "data/verification/local_navigation_rules_template_v1.json"


def _read(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


class ComplexColregTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.local_rules = _read(LOCAL_RULES)
        cls.result = run_complex_colreg_catalog(_read(CATALOG), cls.local_rules)

    def test_all_complex_scenarios_and_cases_match(self) -> None:
        self.assertTrue(self.result["passed"], self.result)
        self.assertEqual(self.result["scenario_count"], 16)
        self.assertEqual(self.result["scenario_passed_count"], 16)
        self.assertEqual(self.result["case_count"], 45)
        self.assertEqual(self.result["case_matched_count"], 45)
        self.assertEqual(self.result["missing_capabilities"], [])
        self.assertTrue(set(REQUIRED_CAPABILITIES) <= set(self.result["covered_capabilities"]))

    def test_multi_ship_duty_graph_preserves_each_target(self) -> None:
        item = next(value for value in self.result["results"] if value["scenario_id"] == "multi_ship_mixed_duties")
        assessment = item["assessment"]
        self.assertEqual(assessment["target_count"], 3)
        self.assertEqual(len(assessment["multi_ship_duty_graph"]), 3)
        self.assertEqual(assessment["priority_target_id"], "NUC-A")
        self.assertEqual(assessment["primary_duty"], "give_way_to_privileged_vessel")

    def test_special_status_and_signal_traces_are_explicit(self) -> None:
        by_id = {item["scenario_id"]: item for item in self.result["results"]}
        self.assertEqual(
            by_id["give_way_to_ram_and_verify_signals"]["assessment"]["expected_visual_signal"]["lights"],
            ["all_round_red_upper", "all_round_white", "all_round_red_lower"],
        )
        self.assertEqual(
            by_id["restricted_visibility_nuc_sound"]["assessment"]["expected_sound_signal"],
            "one_prolonged_two_short",
        )
        self.assertIn("Rule 35", by_id["restricted_visibility_power_sound"]["assessment"]["rules"])

    def test_local_rules_fail_closed_as_exercise_data(self) -> None:
        self.assertEqual(self.local_rules["source_class"], "SIMULATOR_AUTHORED_EXERCISE_RULES")
        self.assertFalse(self.local_rules["official_authorization_verified"])
        item = next(value for value in self.result["results"] if value["scenario_id"] == "simulated_local_port_rules")
        cases = {case["case_id"]: case for case in item["cases"]}
        self.assertTrue(cases["local_all_requirements"]["passed"])
        self.assertFalse(cases["local_speed_limit_rejected"]["passed"])
        self.assertFalse(cases["local_overtaking_rejected"]["passed"])
        self.assertFalse(cases["local_reporting_missing"]["passed"])

    def test_legacy_v1_remains_a_separate_passing_baseline(self) -> None:
        legacy = run_scenario_catalog(_read(LEGACY))
        self.assertTrue(legacy["passed"], legacy)
        self.assertEqual(legacy["scenario_count"], 6)
        self.assertGreaterEqual(legacy["action_case_count"], 11)
        self.assertFalse(self.result["legacy_v1_replaced"])

    def test_assurance_payload_keeps_external_claims_blocked(self) -> None:
        payload = build_payload()
        self.assertTrue(payload["functional_assurance_passed"], payload)
        self.assertFalse(payload["source_boundary"]["training_performed"])
        self.assertFalse(payload["source_boundary"]["existing_policy_modified"])
        self.assertFalse(payload["source_boundary"]["ship_motion_model_modified"])
        self.assertFalse(payload["claim_matrix"]["official_local_rules_connected"])
        self.assertFalse(payload["claim_matrix"]["colreg_certified"])
        self.assertFalse(payload["claim_matrix"]["production_authority"])


if __name__ == "__main__":
    unittest.main()
