"""Reward-aligned training environment for the additive SAC V5 champion.

The dynamics, observations, actions, data splits, and operational checks are
unchanged from :class:`PortOpsNavigationEnv`.  V5 only makes the training
objective match the declared admission objective: completing the route and
doing so without port-rule violations must dominate partial-route reward.

This module is training-only.  Validation and test still use the frozen base
environment dynamics so a reward-only wrapper cannot improve evaluation by
changing the simulated vessel or the success definition.
"""

from __future__ import annotations

from typing import Any, Dict, Tuple

import numpy as np

from .port_ops_environment import PortOpsNavigationEnv


class SacChampionPortOpsEnv(PortOpsNavigationEnv):
    """Port environment with terminal utility aligned to the admission gate."""

    def step(
        self,
        action: Any,
    ) -> Tuple[np.ndarray, float, bool, bool, Dict[str, Any]]:
        observation, reward, terminated, truncated, info = super().step(action)
        raw = self.config.get("rl_parameters", {})
        terminal_adjustment = 0.0
        goal_reached = bool(info.get("goal_reached", False))
        if goal_reached:
            terminal_adjustment += float(raw.get("reward_goal_reached", 0.0))
            if bool(info.get("port_compliant_success", False)):
                terminal_adjustment += float(
                    raw.get("reward_port_compliant", 0.0)
                )
        elif terminated or truncated:
            terminal_adjustment -= float(
                raw.get("penalty_incomplete_terminal", 0.0)
            )

        if terminal_adjustment:
            reward += terminal_adjustment
            self.total_reward += terminal_adjustment
            if self.trajectory:
                self.trajectory[-1]["reward"] = round(float(reward), 6)
                self.trajectory[-1]["sac_v5_terminal_adjustment"] = round(
                    terminal_adjustment,
                    6,
                )
            episode = info.get("episode")
            if isinstance(episode, dict):
                episode["r"] = round(self.total_reward, 6)
        return observation, float(reward), terminated, truncated, info


__all__ = ["SacChampionPortOpsEnv"]
