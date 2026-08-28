import copy
import hashlib
import json
import math
from pathlib import Path
from types import SimpleNamespace
import unittest

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
import sys

if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

from cargo_rl.catamaran_physics import TwinWaterjetCatamaran
from cargo_rl.convergence_diagnostics import diagnose_nonconvergence
from cargo_rl.physics_contract import validate_physics_training_contract
from cargo_rl.physics_environment import CargoPhysicsV4Env
from ship_rl.environment import load_experiment


class CargoPhysicsV4Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.config_path = ROOT / "data/rl/cargo_circuit_physics_experiment_v4.json"
        cls.config, cls.dataset, _dataset_path = load_experiment(cls.config_path)

    def test_contract_preserves_all_obstacles_and_shared_dynamics(self) -> None:
        contract = validate_physics_training_contract(
            self.config,
            self.dataset,
            self.config_path,
        )
        self.assertTrue(contract["passed"])
        self.assertEqual(contract["observation_dimension"], 47)
        self.assertEqual(contract["large_rock_count"], 32)
        self.assertEqual(contract["dynamic_traffic_count"], 6)
        self.assertTrue(contract["all_curriculum_obstacles_enabled"])
        self.assertEqual(contract["runtime_physics_hz"], 60)

    def test_contract_fails_closed_if_a_curriculum_hides_rocks(self) -> None:
        changed = copy.deepcopy(self.config)
        changed["cargo_parameters"]["curriculum_obstacles_enabled"][0] = False
        with self.assertRaisesRegex(ValueError, "rocks and traffic must remain enabled"):
            validate_physics_training_contract(changed, self.dataset, self.config_path)

    def test_environment_is_47d_and_exhibits_sway_and_yaw(self) -> None:
        env = CargoPhysicsV4Env(
            self.config,
            self.dataset,
            split="train",
            discrete_actions=False,
            max_steps=200,
            seed=291000,
            task_index=0,
            render_mode=None,
            curriculum_route_length=2,
            curriculum_obstacles_enabled=True,
            curriculum_randomization_enabled=False,
            curriculum_random_segment=True,
        )
        observation, info = env.reset(options={"task_index": 0})
        self.assertEqual(observation.shape, (47,))
        self.assertEqual(info["observation_size"], 47)
        self.assertEqual(sum(item.dynamic for item in env.obstacles), 6)
        manifest_rocks = [
            item
            for item in self.config["world"]["obstacles"]["boxes"]
            if item.get("manifest_id") == "taoyuan_large_rocks_reviewed_2026_08_24"
        ]
        self.assertEqual(len(manifest_rocks), 32)
        for _index in range(25):
            _observation, _reward, terminated, truncated, info = env.step(
                np.asarray([0.75, 0.65], dtype=np.float32)
            )
            if terminated or truncated:
                break
        self.assertGreater(abs(float(info["sway_mps"])), 0.01)
        self.assertGreater(abs(float(info["yaw_rate_degrees_per_second"])), 0.01)
        self.assertGreater(
            max(abs(float(sample["drift_angle_degrees"])) for sample in env.trajectory),
            0.01,
        )
        env.close()

    def test_python_plant_matches_godot_reference_rollouts(self) -> None:
        report = json.loads(
            (ROOT / "reports/catamaran_hydrodynamics_smoke_v2.json").read_text(encoding="utf-8")
        )
        config = json.loads(
            (ROOT / "data/verification/catamaran_usv_dynamics_reference_v2.json").read_text(encoding="utf-8")
        )

        def rollout(throttle: float, steering: float, duration: float):
            model = TwinWaterjetCatamaran(config)
            model.reset(0.0)
            status = {}
            for _index in range(round(duration / 0.05)):
                status = model.step(throttle, steering, 0.05)
            return status

        straight = rollout(0.72, 0.0, 40.0)
        starboard = rollout(0.62, 0.45, 35.0)
        drift = math.degrees(
            math.atan2(
                abs(float(starboard["sway_mps"])),
                max(abs(float(starboard["surge_mps"])), 0.001),
            )
        )
        self.assertAlmostEqual(straight["surge_mps"], report["straight_speed_mps"], delta=0.0001)
        self.assertAlmostEqual(starboard["yaw_rate_deg_s"], report["starboard_yaw_rate_deg_s"], delta=0.0001)
        self.assertAlmostEqual(drift, report["turn_drift_degrees"], delta=0.0001)

    def test_receding_traffic_is_not_reported_as_immediate_conflict(self) -> None:
        env = CargoPhysicsV4Env(
            self.config,
            self.dataset,
            split="train",
            discrete_actions=False,
            max_steps=10,
            seed=291111,
            task_index=0,
            render_mode=None,
            curriculum_route_length=1,
            curriculum_obstacles_enabled=True,
            curriculum_randomization_enabled=False,
            curriculum_random_segment=True,
        )
        env.reset(options={"task_index": 0})
        env.state[:4] = (0.0, 0.0, 0.0, 0.0)
        obstacle = SimpleNamespace(
            vx=0.0,
            vz=2.0,
            shape="circle",
            radius=4.0,
            kind="traffic",
        )
        closing, tcpa, _dcpa = env._relative_motion(obstacle, 0.0, 40.0)
        self.assertLess(closing, 0.0)
        self.assertEqual(tcpa, float(env.environment_config["tcpa_horizon_seconds"]))
        env.close()

    def test_existing_successful_policy_files_are_unchanged(self) -> None:
        expected = {
            ROOT / "reports/artifacts/cargo_circuit_rl_v1/cargo_sac_policy.zip":
                "a6ccb46e1d89c3bea61e8ab8cea7b26fa2ef52813a7b77a4f77d4954e08553f5",
            ROOT / "reports/artifacts/cargo_circuit_dynamic_rl_v2/cargo_dynamic_sac_policy.zip":
                "0f19759cc96027673f5c0bfc050ec72d93d247c32cef57adbe9b6e454df53c20",
        }
        for path, expected_sha in expected.items():
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), expected_sha)

    def test_difficulty_ladder_is_monotonic_and_keeps_every_obstacle(self) -> None:
        levels = self.config["cargo_parameters"]["difficulty_ladder"]
        self.assertEqual([item["level"] for item in levels], [1, 2, 3, 4, 5, 6, 7, 8])
        self.assertEqual([item["route_length"] for item in levels], [1, 2, 2, 4, 8, 8, 8, 8])
        self.assertEqual(
            [item["dynamic_traffic_speed_knots"] for item in levels],
            sorted(item["dynamic_traffic_speed_knots"] for item in levels),
        )
        self.assertEqual(self.config["cargo_parameters"]["curriculum_obstacles_enabled"], [True, True, True])
        self.assertEqual(self.config["environment_parameters"]["generated_traffic_count"], 6)

    def test_nonconvergence_diagnosis_covers_all_material_failure_families(self) -> None:
        report = diagnose_nonconvergence(
            level=self.config["cargo_parameters"]["difficulty_ladder"][1],
            physics_contract={
                "passed": True,
                "fail_closed": True,
                "large_rock_count": 32,
                "observation_dimension": 47,
                "dynamics_sha256": "test",
                "runtime_physics_hz": 60,
            },
            manual_gate={"acceptance_gate": {"passed": True}},
            training={
                "actor_updates_after_warmup": 100,
                "expert_success_rate": 1.0,
                "success_rate_20": 0.2,
                "training_timesteps": 1000,
            },
            validation_rows=[
                {
                    "task_id": "held_out_01",
                    "success": False,
                    "collisions": 1,
                    "terrain_collisions": 1,
                    "dynamic_obstacle_count": 6,
                    "reward": -100.0,
                    "minimum_clearance_meters": -0.1,
                    "maximum_sway_mps": 0.5,
                    "maximum_yaw_rate_degrees_per_second": 2.0,
                    "checkpoint_completion_ratio": 0.5,
                    "action_saturation_ratio": 0.8,
                }
            ],
            previous_level_passed=True,
        )
        categories = {item["category"] for item in report["all_material_possibilities"]}
        self.assertEqual(len(categories), 14)
        self.assertIn("task_or_safety_infeasible", categories)
        self.assertIn("sac_hyperparameters_or_capacity", categories)
        self.assertIn("checkpoint_dataset_or_code_fingerprint_drift", categories)
        self.assertIn("episode_horizon_or_termination_contract", categories)
        self.assertIn("evaluation_coverage_or_holdout_leakage", categories)
        self.assertIn("action_authority_or_control_interval", report["ranked_root_cause_candidates"])


if __name__ == "__main__":
    unittest.main()
