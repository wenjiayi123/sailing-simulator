from __future__ import annotations

from copy import deepcopy
import json
from pathlib import Path
import unittest

from tools.run_mass_safety_case import build_payload
from tools.ship_assurance.safety_case import (
    REQUIRED_DEPLOYMENT_FIELDS,
    REQUIRED_DUTY_HOLDERS,
    REQUIRED_REGULATORY_INSTRUMENTS,
    REQUIRED_REVIEW_FIELDS,
    REQUIRED_SUPPORTING_EVIDENCE,
    assess_safety_case,
    evaluate_runtime_odd,
)


ROOT = Path(__file__).resolve().parents[1]
CASE_PATH = ROOT / "data/verification/mass_safety_case_v1.json"
ACCEPTANCE_PATH = ROOT / "data/verification/mass_safety_case_acceptance_manifest.template.json"


def _read(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _complete_acceptance() -> dict:
    manifest = _read(ACCEPTANCE_PATH)
    manifest["manifest_id"] = "external-safety-case-package-001"
    manifest["deployment"] = {
        key: f"external-reference-{key}" for key in REQUIRED_DEPLOYMENT_FIELDS
    }
    manifest["regulatory_determinations"] = {
        instrument: {
            "authority": f"authority-{instrument}",
            "decision_reference": f"decision-{instrument}",
            "decision_date": "2026-08-28",
        }
        for instrument in REQUIRED_REGULATORY_INSTRUMENTS
    }
    manifest["duty_holder_assignments"] = {
        role: f"assigned-person-{role}" for role in REQUIRED_DUTY_HOLDERS
    }
    manifest["independent_review"] = {
        key: f"external-reference-{key}" for key in REQUIRED_REVIEW_FIELDS
    }
    manifest["supporting_evidence"] = {
        key: f"external-reference-{key}" for key in REQUIRED_SUPPORTING_EVIDENCE
    }
    return manifest


class MassSafetyCaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.case = _read(CASE_PATH)
        self.template = _read(ACCEPTANCE_PATH)

    def test_functional_case_covers_all_required_safety_arguments(self) -> None:
        result = assess_safety_case(self.case, self.template, root=ROOT)
        self.assertTrue(result["functional_safety_case_complete"], result)
        self.assertEqual(len(result["checks"]), 12)
        self.assertTrue(all(result["checks"].values()))
        sections = result["section_results"]
        self.assertEqual(sections["operational_design_domain"]["dimension_count"], 12)
        self.assertEqual(sections["hazard_log"]["hazard_count"], 12)
        self.assertEqual(sections["minimum_risk_conditions"]["mrc_count"], 6)
        self.assertEqual(sections["fault_trees"]["tree_count"], 5)

    def test_checked_in_acceptance_template_fails_closed(self) -> None:
        result = assess_safety_case(self.case, self.template, root=ROOT)
        self.assertEqual(
            result["status"],
            "FUNCTIONAL_SAFETY_CASE_COMPLETE_EXTERNAL_ACCEPTANCE_BLOCKED",
        )
        self.assertFalse(result["acceptance_evidence"]["passed"])
        self.assertFalse(result["independent_review_complete"])
        self.assertFalse(result["class_approval"])
        self.assertFalse(result["mass_safety_certificate"])
        self.assertFalse(result["production_authority"])

    def test_complete_references_only_route_to_independent_decision(self) -> None:
        result = assess_safety_case(
            self.case, _complete_acceptance(), root=ROOT
        )
        self.assertTrue(result["acceptance_evidence"]["passed"], result)
        self.assertEqual(
            result["status"], "READY_FOR_INDEPENDENT_SAFETY_CASE_DECISION"
        )
        self.assertFalse(result["independent_review_complete"])
        self.assertFalse(result["flag_state_approval"])
        self.assertFalse(result["production_authority"])

    def test_missing_odd_dimension_breaks_top_claim(self) -> None:
        case = deepcopy(self.case)
        case["operational_design_domain"]["dimensions"].pop()
        result = assess_safety_case(case, self.template, root=ROOT)
        self.assertFalse(result["functional_safety_case_complete"])
        self.assertFalse(result["checks"]["operational_design_domain_complete"])

    def test_fault_tree_cycle_is_rejected(self) -> None:
        case = deepcopy(self.case)
        tree = case["fault_trees"][0]
        tree["nodes"][1] = {
            "node_id": "COL-PERCEPTION",
            "node_type": "OR",
            "children": ["COL-ROOT"],
        }
        result = assess_safety_case(case, self.template, root=ROOT)
        self.assertFalse(result["checks"]["fault_trees_acyclic_and_cover_all_hazards"])

    def test_raci_requires_accountable_duty_holder(self) -> None:
        case = deepcopy(self.case)
        case["responsibility_model"]["raci"][0]["accountable"] = ""
        result = assess_safety_case(case, self.template, root=ROOT)
        self.assertFalse(result["checks"]["personnel_responsibility_raci_complete"])

    def test_runtime_odd_breach_maps_to_minimum_risk_condition(self) -> None:
        conditions = {
            item["monitor_signal"]: item["threshold"]
            for item in self.case["operational_design_domain"]["dimensions"]
        }
        nominal = evaluate_runtime_odd(self.case, conditions)
        self.assertTrue(nominal["within_odd"])
        conditions["visibility_nm"] = 0.5
        breached = evaluate_runtime_odd(self.case, conditions)
        self.assertFalse(breached["within_odd"])
        self.assertIn("MRC-03", breached["required_mrc_ids"])
        self.assertFalse(breached["production_command_authority"])

    def test_report_hashes_all_registered_evidence(self) -> None:
        payload = build_payload()
        self.assertTrue(payload["functional_safety_case_complete"], payload)
        self.assertEqual(len(payload["evidence_sha256"]), 10)
        self.assertEqual(len(payload["inputs_sha256"]), 4)
        self.assertFalse(payload["training_performed"])
        self.assertFalse(payload["existing_model_modified"])


if __name__ == "__main__":
    unittest.main()
