from __future__ import annotations

import json
import math
import unittest
from pathlib import Path

import numpy as np
from gymnasium.utils.env_checker import check_env

from tools.cargo_rl.environment import CARGO_OBSERVATION_SIZE, CargoCircuitEnv, cargo_experiment_fingerprint
from tools.cargo_rl.trainer import (
    CARGO_RL_ALGORITHMS,
    _build_cargo_model,
    _cargo_sb3_imports,
    _require_manual_feasibility_gate,
)
from tools.ship_rl.environment import dataset_fingerprint, load_experiment
from tools.ship_rl.trainer import TrainRequest


ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "data" / "rl" / "cargo_circuit_experiment_v1.json"
MANUAL_REPORT = ROOT / "reports" / "cargo_circuit_manual_feasibility_v1.json"


class CargoCircuitRLTests(unittest.TestCase):
    def test_seven_continuous_algorithms_have_real_training_entrypoints(self) -> None:
        self.assertEqual(CARGO_RL_ALGORITHMS, ("sac", "ppo", "td3", "a2c", "ddpg", "tqc", "trpo"))
        config, dataset, _ = load_experiment(CONFIG)
        imports = _cargo_sb3_imports()
        expected_classes = {"a2c": "A2C", "ddpg": "DDPG", "tqc": "TQC", "trpo": "TRPO"}
        for algorithm, expected_class in expected_classes.items():
            vector_env = imports["DummyVecEnv"]([
                lambda: imports["Monitor"](
                    CargoCircuitEnv(config, dataset, split="train", max_steps=8, seed=17)
                )
            ])
            request = TrainRequest(
                algorithm=algorithm,
                config_path=CONFIG,
                output_dir=ROOT / "output" / "algorithm_entrypoint_test",
                progress_path=ROOT / "output" / "algorithm_entrypoint_test" / "progress.json",
                checkpoint_path=ROOT / "output" / "algorithm_entrypoint_test" / "checkpoint.json",
                total_timesteps=1,
                max_steps=8,
                rollout_horizon=64,
                batch_size=16,
                minibatch_size=16,
                replay_buffer_size=1_000,
                warmup_steps=1,
            )
            model = _build_cargo_model(algorithm, vector_env, request, imports)
            self.assertEqual(type(model).__name__, expected_class)
            model.learn(total_timesteps=1)
            vector_env.close()

    def test_independent_continuous_contract_and_inertia(self) -> None:
        config, dataset, _ = load_experiment(CONFIG)
        env = CargoCircuitEnv(config, dataset, split="test", max_steps=20, seed=5, task_index=0)
        check_env(env, skip_render_check=True)
        observation, info = env.reset(seed=5, options={"task_index": 0})
        self.assertEqual(observation.shape, (CARGO_OBSERVATION_SIZE,))
        self.assertEqual(env.action_space.shape, (2,))
        self.assertEqual(info["module"], "cargo_circuit_rl")
        self.assertEqual(info["total_checkpoints"], 7)
        self.assertEqual(info["checkpoints_passed"], 0)
        self.assertFalse(any(obstacle.dynamic for obstacle in env.obstacles))
        env.step(np.asarray([1.0, 1.0], dtype=np.float32))
        self.assertAlmostEqual(env.state[4], 0.55 * 0.25, places=6)
        self.assertAlmostEqual(env.state[5], 0.70 * 0.25, places=6)
        self.assertLessEqual(abs(env.trajectory[-1]["yaw_rate_degrees_per_second"]), 20.0)
        self.assertIn("actual_rudder", env.trajectory[-1])
        self.assertIn("actual_throttle", env.trajectory[-1])

    def test_sparse_route_spacing_and_static_cliffs(self) -> None:
        _config, dataset, _ = load_experiment(CONFIG)
        for split in ("train", "validation", "test"):
            for task in dataset["splits"][split]:
                points = [task["start"], *task["route"]]
                spacings = [
                    math.hypot(float(b["x"]) - float(a["x"]), float(b["z"]) - float(a["z"]))
                    for a, b in zip(points, points[1:])
                ]
                self.assertGreaterEqual(min(spacings[:-1]), 140.0)
                self.assertGreaterEqual(spacings[-1], 100.0)
                self.assertEqual(len(task["route"]) - 1, 7)
                self.assertGreaterEqual(len(task.get("terrain", [])), 8)
                self.assertFalse(task.get("dynamic_obstacles", []))
                self.assertTrue(all(item.get("kind") == "cliff" for item in task["terrain"]))

    def test_manual_feasibility_gate_matches_current_contract(self) -> None:
        config, dataset, _ = load_experiment(CONFIG)
        report = json.loads(MANUAL_REPORT.read_text(encoding="utf-8"))
        self.assertTrue(report["acceptance_gate"]["passed"])
        self.assertEqual(report["aggregate"]["episodes"], 5)
        self.assertEqual(report["aggregate"]["success_rate"], 1.0)
        self.assertEqual(report["aggregate"]["total_collisions"], 0)
        self.assertGreater(report["aggregate"]["minimum_safety_envelope_clearance_meters"], 0.0)
        self.assertFalse(report["controller"]["learned"])
        self.assertFalse(report["controller"]["rl_evidence"])
        self.assertFalse(report["dynamic_obstacles"]["included"])
        gate = _require_manual_feasibility_gate(
            config,
            CONFIG,
            dataset_fingerprint(dataset),
            cargo_experiment_fingerprint(config),
        )
        self.assertTrue(gate["passed"])
        self.assertEqual(gate["total_collisions"], 0)

    def test_static_base_and_future_dynamic_goal_are_not_conflated(self) -> None:
        config, dataset, _ = load_experiment(CONFIG)
        self.assertEqual(config["algorithm_decision"]["primary"], "sac")
        self.assertTrue(config["headless"])
        self.assertFalse(config["render"])
        self.assertEqual(config["environment_parameters"]["generated_traffic_count"], 0)
        self.assertTrue(dataset["source"]["simulation_only"])
        self.assertEqual(
            json.loads(MANUAL_REPORT.read_text(encoding="utf-8"))["dynamic_obstacles"]["phase"],
            "future_advanced_goal_after_static_policy_acceptance",
        )


if __name__ == "__main__":
    unittest.main()
