from __future__ import annotations

import json
import unittest
from pathlib import Path

import numpy as np
from gymnasium.utils.env_checker import check_env

from tools.cargo_rl.dynamic_environment import DYNAMIC_OBSERVATION_SIZE, CargoDynamicEnv
from tools.cargo_rl.environment import cargo_experiment_fingerprint
from tools.cargo_rl.trainer import _require_manual_feasibility_gate
from tools.ship_rl.environment import dataset_fingerprint, load_experiment


ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "data" / "rl" / "cargo_circuit_dynamic_experiment_v2.json"
REPORT = ROOT / "reports" / "cargo_circuit_dynamic_manual_feasibility_v2.json"


class CargoDynamicRLTests(unittest.TestCase):
    def test_dedicated_relative_motion_observation_and_moving_traffic(self) -> None:
        config, dataset, _ = load_experiment(CONFIG)
        env = CargoDynamicEnv(config, dataset, split="test", task_index=0, max_steps=10, seed=9)
        check_env(env, skip_render_check=True)
        observation, info = env.reset(options={"task_index": 0})
        self.assertEqual(observation.shape, (DYNAMIC_OBSERVATION_SIZE,))
        self.assertEqual(info["module"], "cargo_circuit_dynamic_rl")
        self.assertGreaterEqual(info["dynamic_obstacle_count"], 6)
        before = [(item.name, item.x, item.z) for item in env.obstacles if item.dynamic]
        env.step(np.asarray([0.0, 0.0], dtype=np.float32))
        after = [(item.name, item.x, item.z) for item in env.obstacles if item.dynamic]
        self.assertTrue(any((ax, az) != (bx, bz) for (_an, ax, az), (_bn, bx, bz) in zip(before, after)))

    def test_dynamic_overlays_do_not_mutate_source_dataset(self) -> None:
        config, dataset, _ = load_experiment(CONFIG)
        before = dataset_fingerprint(dataset)
        env = CargoDynamicEnv(config, dataset, split="train", task_index=0, max_steps=2, seed=3)
        env.reset(options={"task_index": 0})
        self.assertEqual(before, dataset_fingerprint(dataset))

    def test_dynamic_manual_gate_matches_current_contract(self) -> None:
        config, dataset, _ = load_experiment(CONFIG)
        report = json.loads(REPORT.read_text(encoding="utf-8"))
        self.assertTrue(report["acceptance_gate"]["passed"])
        self.assertEqual(report["aggregate"]["success_rate"], 1.0)
        self.assertEqual(report["aggregate"]["total_collisions"], 0)
        self.assertGreater(report["aggregate"]["minimum_dynamic_clearance_meters"], 0.0)
        self.assertFalse(report["controller"]["learned"])
        gate = _require_manual_feasibility_gate(
            config,
            CONFIG,
            dataset_fingerprint(dataset),
            cargo_experiment_fingerprint(config),
        )
        self.assertTrue(gate["passed"])


if __name__ == "__main__":
    unittest.main()
