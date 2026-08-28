"""State-augmented environment for the current-map hardest cargo task."""

from __future__ import annotations

from typing import Any, Dict, Tuple

import numpy as np
from gymnasium import spaces

from .dynamic_environment import CargoDynamicEnv


HARDEST_OBSERVATION_SIZE = 47


class CargoHardestV3Env(CargoDynamicEnv):
    """Expose action history and a tracked avoidance direction to SAC.

    The latch is sensor state, not an actuator or fallback controller.  SAC
    remains solely responsible for throttle and rudder outputs.
    """

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        self.dynamic_avoidance_latch = 0.0
        super().__init__(*args, **kwargs)
        self.observation_space = spaces.Box(
            low=-1.0,
            high=1.0,
            shape=(HARDEST_OBSERVATION_SIZE,),
            dtype=np.float32,
        )

    def reset(self, *args: Any, **kwargs: Any) -> Tuple[np.ndarray, Dict[str, Any]]:
        self.dynamic_avoidance_latch = 0.0
        _observation, info = super().reset(*args, **kwargs)
        self._update_dynamic_avoidance_latch()
        return self._observation(), info

    def _update_dynamic_avoidance_latch(self) -> None:
        nearest = self._nearest_dynamic_obstacle(False)
        present = bool(nearest["present"])
        clearance = float(nearest["clearance"])
        tcpa = float(nearest["tcpa"])
        dcpa = float(nearest["dcpa"])
        conflict = bool(
            present and clearance < 95.0 and tcpa < 60.0 and dcpa < 46.0
        )
        if self.dynamic_avoidance_latch == 0.0 and conflict:
            bearing = float(nearest["bearing"])
            bearing_sign = 1.0 if bearing >= 0.0 else -1.0
            self.dynamic_avoidance_latch = -bearing_sign
        elif self.dynamic_avoidance_latch != 0.0 and (
            not present
            or clearance > 115.0
            or (tcpa > 75.0 and dcpa > 55.0)
        ):
            self.dynamic_avoidance_latch = 0.0

    def _observation(self) -> np.ndarray:
        base = super()._observation()
        memory = np.asarray(
            [
                float(self.previous_action[0]),
                float(self.previous_action[1]),
                float(self.dynamic_avoidance_latch),
            ],
            dtype=np.float32,
        )
        return np.concatenate((base, memory), dtype=np.float32)

    def step(self, action: Any):
        self._update_dynamic_avoidance_latch()
        return super().step(action)
