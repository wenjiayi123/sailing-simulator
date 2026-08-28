from __future__ import annotations

import json
from pathlib import Path
import unittest
from unittest.mock import patch

import numpy as np

from tools.ship_rl.port_ops_environment import PortOpsNavigationEnv
from tools.ship_rl.sac_champion_environment import SacChampionPortOpsEnv


ROOT = Path(__file__).resolve().parents[1]


class SacChampionRewardTests(unittest.TestCase):
    @staticmethod
    def _shell() -> SacChampionPortOpsEnv:
        env = object.__new__(SacChampionPortOpsEnv)
        env.config = {
            "rl_parameters": {
                "reward_goal_reached": 800.0,
                "reward_port_compliant": 800.0,
                "penalty_incomplete_terminal": 400.0,
            }
        }
        env.total_reward = 10.0
        env.trajectory = [{"reward": 1.0}]
        return env

    def test_compliant_arrival_dominates_partial_progress(self) -> None:
        env = self._shell()
        base = (
            np.zeros(45, dtype=np.float32),
            2.0,
            True,
            False,
            {
                "goal_reached": True,
                "port_compliant_success": True,
                "episode": {"r": 10.0, "l": 1},
            },
        )
        with patch.object(PortOpsNavigationEnv, "step", return_value=base):
            _observation, reward, terminated, truncated, info = env.step(
                np.zeros(2, dtype=np.float32)
            )
        self.assertEqual(reward, 1602.0)
        self.assertEqual(env.total_reward, 1610.0)
        self.assertTrue(terminated)
        self.assertFalse(truncated)
        self.assertEqual(info["episode"]["r"], 1610.0)
        self.assertEqual(
            env.trajectory[-1]["sac_v5_terminal_adjustment"],
            1600.0,
        )

    def test_incomplete_terminal_receives_explicit_penalty(self) -> None:
        env = self._shell()
        base = (
            np.zeros(45, dtype=np.float32),
            5.0,
            False,
            True,
            {
                "goal_reached": False,
                "port_compliant_success": False,
                "episode": {"r": 10.0, "l": 1600},
            },
        )
        with patch.object(PortOpsNavigationEnv, "step", return_value=base):
            _observation, reward, terminated, truncated, info = env.step(
                np.zeros(2, dtype=np.float32)
            )
        self.assertEqual(reward, -395.0)
        self.assertEqual(env.total_reward, -390.0)
        self.assertFalse(terminated)
        self.assertTrue(truncated)
        self.assertEqual(info["episode"]["r"], -390.0)

    def test_v5_changes_reward_only_not_dynamics_or_observation(self) -> None:
        v2 = json.loads(
            (
                ROOT
                / "data/rl/long_beach_ais_port_ops_experiment_v2.json"
            ).read_text(encoding="utf-8")
        )
        v5 = json.loads(
            (
                ROOT
                / "data/rl/long_beach_ais_port_ops_sac_champion_v5.json"
            ).read_text(encoding="utf-8")
        )
        self.assertEqual(v5["dataset"], v2["dataset"])
        self.assertEqual(
            v5["environment_parameters"],
            v2["environment_parameters"],
        )
        self.assertEqual(v5["ships"], v2["ships"])
        self.assertEqual(v5["world"], v2["world"])
        self.assertGreater(
            v5["rl_parameters"]["penalty_collision"],
            v2["rl_parameters"]["penalty_collision"],
        )
        self.assertGreater(
            v5["rl_parameters"]["reward_port_compliant"],
            0.0,
        )


if __name__ == "__main__":
    unittest.main()
