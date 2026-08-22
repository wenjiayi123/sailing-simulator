from __future__ import annotations

import hashlib
import inspect
import json
import re
import sys
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

    def test_public_artifacts_match_frozen_hash_commitments(self) -> None:
        serialized = json.dumps(self.payload, ensure_ascii=False)
        self.assertNotIn("/Users/", serialized)
        self.assertNotIn("route_points", serialized)
        self.assertNotIn("samples", self.payload["held_out_results"])
        commitments = self.payload["frozen_artifact_commitments"]
        self.assertEqual(len(commitments), 9)
        self.assertTrue(all(SHA256.fullmatch(value) for value in commitments.values()))
        public_artifacts = self.payload["release_scope"]["public_artifact_sha256"]
        self.assertEqual(len(public_artifacts), 11)
        for relative_path, expected_sha256 in public_artifacts.items():
            artifact = ROOT / relative_path
            self.assertTrue(artifact.is_file(), relative_path)
            self.assertEqual(
                hashlib.sha256(artifact.read_bytes()).hexdigest(),
                expected_sha256,
                relative_path,
            )
        withheld = self.payload["release_scope"]["withheld_assets"]
        self.assertNotIn("trained model weights", withheld)
        self.assertNotIn("full per-step held-out trajectories", withheld)

    def test_public_models_load_with_declared_space_and_step_contracts(self) -> None:
        tools_path = str(ROOT / "tools")
        if tools_path not in sys.path:
            sys.path.insert(0, tools_path)
        from stable_baselines3 import SAC

        expected = (
            (
                ROOT
                / "reports/artifacts/cargo_circuit_rl_v1/cargo_sac_policy.zip",
                (36,),
                300_000,
            ),
            (
                ROOT
                / "reports/artifacts/cargo_circuit_dynamic_rl_v2/"
                "cargo_dynamic_sac_policy.zip",
                (44,),
                500,
            ),
        )
        for path, observation_shape, timesteps in expected:
            model = SAC.load(path, device="cpu")
            self.assertEqual(model.observation_space.shape, observation_shape)
            self.assertEqual(model.action_space.shape, (2,))
            self.assertEqual(model.num_timesteps, timesteps)

    def test_render_video_is_silent_small_and_hash_bound(self) -> None:
        video = self.payload["render_video"]
        video_path = ROOT / video["path"]
        poster_path = ROOT / video["poster"]
        preview_path = ROOT / video["inline_preview"]
        self.assertEqual(video["policy_id"], "SAC-S1")
        self.assertEqual(video["dataset_split"], "test")
        self.assertEqual(video["audio_tracks"], 0)
        self.assertTrue(video["external_audio_removed"])
        self.assertEqual(video["file_size_bytes"], video_path.stat().st_size)
        self.assertLess(video_path.stat().st_size, 10 * 1024 * 1024)
        self.assertLess(video["duration_seconds"], 30)
        self.assertEqual(video["resolution"], "1600x900")
        self.assertEqual(video_path.read_bytes()[4:8], b"ftyp")
        self.assertEqual(poster_path.read_bytes()[:2], b"\xff\xd8")
        self.assertEqual(video["inline_preview_size_bytes"], preview_path.stat().st_size)
        self.assertLess(preview_path.stat().st_size, 10 * 1024 * 1024)
        self.assertEqual(preview_path.read_bytes()[:6], b"GIF89a")
        self.assertEqual(
            hashlib.sha256(video_path.read_bytes()).hexdigest(),
            video["video_sha256"],
        )
        self.assertEqual(
            hashlib.sha256(poster_path.read_bytes()).hexdigest(),
            video["poster_sha256"],
        )
        self.assertEqual(
            hashlib.sha256(preview_path.read_bytes()).hexdigest(),
            video["inline_preview_sha256"],
        )

    def test_public_source_hashes_match_the_reviewed_runtime_files(self) -> None:
        expected = self.payload["release_scope"]["public_source_sha256"]
        self.assertEqual(set(expected), set(self.payload["release_scope"]["public_source_files"]))
        for relative_path, expected_sha256 in expected.items():
            actual = hashlib.sha256((ROOT / relative_path).read_bytes()).hexdigest()
            self.assertEqual(actual, expected_sha256)


if __name__ == "__main__":
    unittest.main()
