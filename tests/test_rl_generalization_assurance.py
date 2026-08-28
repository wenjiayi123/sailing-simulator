from __future__ import annotations

from copy import deepcopy
import json
from pathlib import Path
import unittest

from tools.run_rl_generalization_assurance import build_payload
from tools.ship_rl.generalization_assurance import (
    assess_generalization_campaign,
    build_evaluation_plan,
    run_functional_smoke,
)


ROOT = Path(__file__).resolve().parents[1]
CAMPAIGN_PATH = ROOT / "data/verification/rl_generalization_campaign_v1.json"
RESULTS_PATH = ROOT / "data/verification/rl_generalization_results_manifest.template.json"


def _read(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


class RlGeneralizationAssuranceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.campaign = _read(CAMPAIGN_PATH)
        self.results = _read(RESULTS_PATH)

    def test_functional_framework_is_complete_but_evidence_is_blocked(self) -> None:
        assessment = assess_generalization_campaign(self.campaign, self.results, root=ROOT)
        self.assertTrue(assessment["functional_framework_complete"], assessment)
        self.assertTrue(all(assessment["checks"].values()))
        self.assertEqual(
            assessment["status"],
            "FUNCTIONAL_FRAMEWORK_COMPLETE_TRAINING_AND_FIELD_EVIDENCE_BLOCKED",
        )
        self.assertFalse(assessment["results_evidence_gate"]["generalization_evidence_complete"])

    def test_plan_freezes_multi_domain_seed_ablation_stress_and_ood_cells(self) -> None:
        plan = build_evaluation_plan(self.campaign)
        self.assertEqual(plan["base_matrix_cell_count"], 320)
        self.assertEqual(plan["ablation_pair_count"], 30)
        self.assertEqual(plan["stress_cell_count"], 40)
        self.assertEqual(plan["ood_cell_count"], 20)
        self.assertEqual(plan["total_planned_cell_count"], 410)
        self.assertEqual(len(plan["cells"]), 410)
        self.assertFalse(plan["test_results_accessed"])
        self.assertFalse(plan["training_performed"])

    def test_interactive_traffic_smoke_preserves_own_ship_contracts(self) -> None:
        smoke = run_functional_smoke(self.campaign)
        self.assertTrue(smoke["passed"], smoke)
        self.assertEqual(smoke["fixture_count"], 4)
        self.assertEqual(smoke["passed_count"], 4)
        self.assertTrue(all(item["observation_size"] == 45 for item in smoke["results"]))
        self.assertTrue(all(item["interaction_receipt_count"] > 0 for item in smoke["results"]))
        self.assertTrue(all(item["receipt_chain_valid"] for item in smoke["results"]))
        self.assertFalse(smoke["training_performed"])
        self.assertFalse(smoke["existing_policy_modified"])
        self.assertFalse(smoke["ship_motion_model_modified"])

    def test_all_existing_policy_artifacts_remain_hash_verified(self) -> None:
        payload = build_payload()
        inventory = payload["preserved_policy_inventory"]
        self.assertTrue(inventory["passed"], inventory)
        self.assertEqual(inventory["policy_count"], 10)
        self.assertEqual(len(inventory["algorithms"]), 10)
        self.assertEqual(inventory["errors"], [])

    def test_ood_domains_are_disjoint_from_training_domains(self) -> None:
        for suite in self.campaign["ood_suites"]:
            self.assertTrue(
                set(suite["training_domain_ids"]).isdisjoint(
                    set(suite["evaluation_domain_ids"])
                ),
                suite,
            )

    def test_empty_results_cannot_claim_convergence_or_generalization(self) -> None:
        assessment = assess_generalization_campaign(self.campaign, self.results, root=ROOT)
        gate = assessment["results_evidence_gate"]
        self.assertTrue(gate["structural_contract_complete"])
        self.assertFalse(gate["training_completed"])
        self.assertFalse(gate["convergence_demonstrated"])
        self.assertFalse(gate["matrix_complete"])
        self.assertFalse(gate["confidence_intervals_complete"])
        self.assertFalse(gate["generalization_evidence_complete"])

    def test_claim_flags_alone_cannot_bypass_evidence_gate(self) -> None:
        forged = deepcopy(self.results)
        forged["status"] = "COMPLETE"
        for key in forged["claims"]:
            forged["claims"][key] = key != "production_authority"
        forged["shadow_operation"].update(
            {"status": "COMPLETE", "days_completed": 30, "scenarios_completed": 1000, "dispatch_count": 0}
        )
        assessment = assess_generalization_campaign(self.campaign, forged, root=ROOT)
        gate = assessment["results_evidence_gate"]
        self.assertFalse(gate["hashes_bound"])
        self.assertFalse(gate["training_runs_complete"])
        self.assertFalse(gate["matrix_complete"])
        self.assertFalse(gate["generalization_evidence_complete"])


if __name__ == "__main__":
    unittest.main()
