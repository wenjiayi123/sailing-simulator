from __future__ import annotations

import hashlib
import inspect
import json
import re
import unittest
from pathlib import Path

from tools.cargo_rl.dynamic_environment import (
    DYNAMIC_OBSERVATION_SIZE,
    CargoDynamicResidualEnv,
)
from tools.cargo_rl.environment import CARGO_OBSERVATION_SIZE, CargoCircuitEnv


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "reports" / "cargo_circuit_public_evidence_v1.json"
SHA256 = re.compile(r"^[0-9a-f]{64}$")


class CargoCircuitPublicEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.payload = json.loads(MANIFEST.read_text(encoding="utf-8"))

    def test_real_continuous_and_dynamic_residual_source_is_public(self) -> None:
        self.assertEqual(CARGO_OBSERVATION_SIZE, 36)
        self.assertEqual(DYNAMIC_OBSERVATION_SIZE, 44)
        self.assertTrue(issubclass(CargoDynamicResidualEnv, CargoCircuitEnv))
        residual_source = inspect.getsource(CargoDynamicResidualEnv.step)
        self.assertIn("frozen_static_policy.predict", residual_source)
        self.assertIn("residual_throttle_scale", residual_source)
        self.assertIn("residual_rudder_scale", residual_source)

    def test_held_out_metrics_and_honesty_boundary_are_machine_readable(self) -> None:
        static = self.payload["held_out_results"]["static_sac_s1"]
        dynamic = self.payload["held_out_results"]["dynamic_res_sac_d2"]
        for result in (static, dynamic):
            self.assertEqual(result["dataset_split"], "test")
            self.assertTrue(result["accepted"])
            self.assertEqual(result["checkpoints_passed"], result["total_checkpoints"])
            self.assertEqual(result["collisions"], 0)
            self.assertEqual(result["terrain_collisions"], 0)
        self.assertEqual(dynamic["dynamic_traffic_count"], 6)
        self.assertGreater(dynamic["minimum_dynamic_clearance_meters"], 0.0)
        self.assertFalse(dynamic["released_policy_has_manual_bypass_points"])
        self.assertIn("not a sea trial", self.payload["acceptance_boundary"])

    def test_private_assets_are_replaced_by_frozen_hash_commitments(self) -> None:
        serialized = json.dumps(self.payload, ensure_ascii=False)
        self.assertNotIn("/Users/", serialized)
        self.assertNotIn("route_points", serialized)
        self.assertNotIn("samples", self.payload["held_out_results"])
        commitments = self.payload["frozen_artifact_commitments"]
        self.assertEqual(len(commitments), 9)
        self.assertTrue(all(SHA256.fullmatch(value) for value in commitments.values()))
        withheld = self.payload["release_scope"]["withheld_assets"]
        self.assertIn("trained model weights", withheld)
        self.assertIn("full per-step held-out trajectories", withheld)

    def test_public_source_hashes_match_the_reviewed_runtime_files(self) -> None:
        expected = self.payload["release_scope"]["public_source_sha256"]
        self.assertEqual(set(expected), set(self.payload["release_scope"]["public_source_files"]))
        for relative_path, expected_sha256 in expected.items():
            actual = hashlib.sha256((ROOT / relative_path).read_bytes()).hexdigest()
            self.assertEqual(actual, expected_sha256)


if __name__ == "__main__":
    unittest.main()
