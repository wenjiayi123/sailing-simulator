import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class CargoRuntimeCollisionRegressionTests(unittest.TestCase):
    def test_crossing_rocks_remain_at_reviewed_safe_positions(self) -> None:
        scene = (ROOT / "scenes/worlds/taoyuan_valley_terrain_skeleton.tscn").read_text(
            encoding="utf-8"
        )
        for position in (
            "-460, -24.71473, 280",
            "-520, -35.739677, -200",
            "620, -24.94445, 450",
            "-120, -39.053867, 520",
        ):
            self.assertIn(position, scene)

    def test_runtime_guard_and_replay_collision_layer_remain_wired(self) -> None:
        main_scene = (ROOT / "main.tscn").read_text(encoding="utf-8")
        self.assertIn('path="res://scripts/world/large_rock_collision_guard.gd"', main_scene)
        self.assertIn('[node name="LargeRockCollisionGuard"', main_scene)
        for relative in (
            "scripts/world/floating_rock_demo_builder.gd",
            "scripts/world/grounded_rock_plate_builder.gd",
        ):
            source = (ROOT / relative).read_text(encoding="utf-8")
            self.assertIn("body.collision_layer |= 2", source)
            self.assertIn('body.add_to_group(&"ship_navigation_obstacle")', source)
            self.assertIn('body.add_to_group(&"large_rock_exact_collision")', source)

    def test_all_large_rocks_are_locked_and_exported_to_training(self) -> None:
        contract = json.loads(
            (ROOT / "reports/large_rock_training_contract_v1.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertTrue(contract["passed"], contract["errors"])
        self.assertEqual(contract["canonical_rock_count"], 32)
        self.assertEqual(contract["transform_match_count"], 32)
        self.assertEqual(contract["radar_large_rock_count"], 32)
        self.assertEqual(contract["training_snapshot_large_rock_count"], 32)
        self.assertEqual(contract["collision_shape_count"], 64)
        self.assertTrue(contract["transform_restore_probe_passed"])

    def test_frozen_replays_remain_clear_of_current_rocks(self) -> None:
        geometry = json.loads(
            (ROOT / "reports/large_rock_collision_audit_v1.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertTrue(geometry["passed"], geometry["errors"])
        self.assertEqual(geometry["large_rock_count"], 32)
        self.assertEqual(geometry["trajectory_conflict_count"], 0)
        self.assertEqual(geometry["waterline_guard_status"]["guard_count"], 3)
        self.assertEqual(geometry["released_trajectory_replay_sweep_block_count"], 0)

        replay = json.loads(
            (ROOT / "reports/cargo_circuit_full_replay_smoke_v1.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertTrue(replay["passed"], replay["errors"])
        self.assertEqual([item["name"] for item in replay["results"]], ["SAC-S1", "RES-SAC-D2"])
        for result in replay["results"]:
            self.assertTrue(result["passed"])
            self.assertEqual(result["large_rock_replay_guard_blocks"], 0)
            self.assertTrue(result["last_result"]["success"])
            self.assertIn("播放完成", result["last_result"]["message"])

    def test_catamaran_three_dof_runtime_is_verified_but_not_calibrated(self) -> None:
        report = json.loads(
            (ROOT / "reports/catamaran_hydrodynamics_smoke_v2.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertTrue(report["passed"], report["errors"])
        self.assertEqual(
            report["model_id"],
            "taoyuan_catamaran_usv_3dof_twin_waterjet_v2",
        )
        self.assertEqual(len(report["software_factors"]), 16)
        self.assertFalse(report["named_vessel_calibrated"])


if __name__ == "__main__":
    unittest.main()
