from __future__ import annotations

import hashlib
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class AdditiveSafetyReleaseTests(unittest.TestCase):
    def test_deep_verify_targets_do_not_write_into_frozen_artifacts(self) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        verifier = (ROOT / "tools/run_nonmutating_deep_verify.py").read_text(
            encoding="utf-8"
        )
        self.assertIn("run_nonmutating_deep_verify.py navigation-v1", makefile)
        self.assertIn("run_nonmutating_deep_verify.py port-v2", makefile)
        self.assertIn("run_nonmutating_deep_verify.py safety-v3", makefile)
        self.assertIn("TemporaryDirectory", verifier)
        self.assertIn("benchmark.ARTIFACT_ROOT = Path(temporary_root)", verifier)

    def test_all_frozen_v2_policies_and_models_are_preserved(self) -> None:
        prepared = json.loads(
            (ROOT / "reports/port_ops_benchmark_v2_prepared.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(len(prepared["artifacts"]), 10)
        self.assertEqual(
            [item["algorithm"] for item in prepared["artifacts"]],
            [
                "ppo",
                "sac",
                "td3",
                "dqn",
                "a2c",
                "ddpg",
                "trpo",
                "los_pid",
                "lqr",
                "mpc",
            ],
        )
        trained_models = 0
        for artifact in prepared["artifacts"]:
            checkpoint = ROOT / artifact["checkpoint"]
            self.assertTrue(checkpoint.is_file())
            self.assertEqual(_sha256(checkpoint), artifact["checkpoint_sha256"])
            if artifact["model"]:
                trained_models += 1
                model = ROOT / artifact["model"]
                self.assertTrue(model.is_file())
                self.assertEqual(_sha256(model), artifact["model_sha256"])
        self.assertEqual(trained_models, 7)

    def test_godot_strategy_dropdown_is_additive(self) -> None:
        source = (ROOT / "scripts/ui/ship_rl_control_panel.gd").read_text(
            encoding="utf-8"
        )
        for algorithm in (
            "ppo",
            "sac",
            "td3",
            "dqn",
            "a2c",
            "ddpg",
            "trpo",
            "los_pid",
            "lqr",
            "mpc",
        ):
            self.assertIn(f'"{algorithm}"', source)
        self.assertIn("+SAFETY-V3｜新增组合策略｜基础产物不覆盖", source)
        self.assertIn("PERSONAL-LATEST｜本次新增训练产物", source)

    def test_safety_profile_remains_offline_and_test_is_post_freeze(self) -> None:
        profile = json.loads(
            (ROOT / "data/rl/port_ops_safety_supervisor_v3.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(profile["selection_split"], "validation")
        self.assertEqual(profile["final_evaluation_split"], "test")
        self.assertIn("not COLREGs certification", profile["boundary"])

    def test_recorded_replay_distinguishes_single_task_from_aggregate(self) -> None:
        source = (
            ROOT / "scripts/rl/ship_policy_replay_controller.gd"
        ).read_text(encoding="utf-8")
        self.assertIn('mode == "recorded_safety_supervised_test_rollout"', source)
        self.assertIn("RecordedTestIncidentMarker", source)
        self.assertIn("总体%d场不由本画面代替", source)
        self.assertIn("本场证据 碰撞%d · 搁浅%d", source)

    def test_utility_aware_audit_preserves_fail_closed_rejection(self) -> None:
        audit = json.loads(
            (ROOT / "reports/safety_supervisor_utility_audit_v3.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertFalse(audit["passed"])
        self.assertEqual(audit["deployment_decision"], "rejected_fail_closed")
        self.assertFalse(audit["live_control_authorized"])
        self.assertEqual(audit["admitted_offline_strategies"], [])
        self.assertFalse(audit["portfolio_checks"]["grounding_not_worse"])
        self.assertFalse(audit["portfolio_checks"]["intervention_budget"])


if __name__ == "__main__":
    unittest.main()
