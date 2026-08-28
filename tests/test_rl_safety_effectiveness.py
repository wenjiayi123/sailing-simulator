from __future__ import annotations

import hashlib
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


def _load(path: str) -> dict:
    return json.loads((ROOT / path).read_text(encoding="utf-8"))


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class RlSafetyEffectivenessTests(unittest.TestCase):
    def test_profile_keeps_rl_as_the_only_primary_candidate(self) -> None:
        profile = _load("data/verification/rl_safety_effectiveness_v1.json")
        self.assertEqual(profile["algorithm"], "sac")
        self.assertTrue(profile["strategy_id"].startswith("sac_"))
        serialized = json.dumps(profile)
        for classical in ("los_pid", "lqr", "mpc"):
            self.assertNotIn(classical, serialized)

    def test_prepared_evidence_freezes_real_sac_weights(self) -> None:
        prepared = _load("reports/rl_safety_effectiveness_v1_prepared.json")
        self.assertTrue(prepared["contains_real_rl"])
        self.assertFalse(prepared["holdout_accessed"])
        checkpoint = ROOT / prepared["checkpoint"]
        model = ROOT / prepared["model"]
        self.assertEqual(prepared["checkpoint_sha256"], _sha256(checkpoint))
        self.assertEqual(prepared["model_sha256"], _sha256(model))

    def test_functional_smoke_does_not_claim_training_or_performance(self) -> None:
        report = _load("reports/rl_safety_effectiveness_smoke_v1.json")
        self.assertTrue(report["contains_real_rl"])
        self.assertTrue(report["passed"])
        self.assertFalse(report["training_performed"])
        self.assertFalse(report["performance_claimed"])
        self.assertFalse(report["counterfactual_holdout_accessed"])
        self.assertFalse(report["base_policy_modified"])
        self.assertFalse(report["production_authority"])

    def test_historical_v3_rejection_is_preserved(self) -> None:
        historical = _load("reports/safety_supervisor_utility_audit_v3.json")
        self.assertFalse(historical["passed"])
        self.assertEqual(historical["admitted_offline_strategies"], [])


if __name__ == "__main__":
    unittest.main()
