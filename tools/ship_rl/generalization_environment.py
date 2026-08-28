"""Additive interactive-traffic environment for generalization evaluation.

The own-ship transition, observation contract, action contract and reward logic
remain inherited from ``PortOpsNavigationEnv``.  Only simulator-authored traffic
agents with an explicit ``interaction`` record may adapt their velocity.
"""

from __future__ import annotations

import hashlib
import json
import math
from typing import Any, Mapping

import numpy as np

from .environment import ObstacleRecord
from .port_ops_environment import PortOpsNavigationEnv


INTERACTIVE_BEHAVIORS = {
    "cooperative_yield",
    "delayed_yield",
    "adversarial_closing",
    "speed_matching",
}


def _wrap(value: float) -> float:
    return (float(value) + math.pi) % (2.0 * math.pi) - math.pi


class GeneralizationEvaluationEnv(PortOpsNavigationEnv):
    """Port environment with bounded, auditable responsive traffic agents."""

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        self._interaction_by_name: dict[str, dict[str, Any]] = {}
        self._interaction_receipts: list[dict[str, Any]] = []
        self._receipt_head = "0" * 64
        super().__init__(*args, **kwargs)

    def reset(self, *args: Any, **kwargs: Any):
        self._interaction_receipts = []
        self._receipt_head = "0" * 64
        return super().reset(*args, **kwargs)

    def _build_obstacles(self, randomize: bool) -> list[ObstacleRecord]:
        records = super()._build_obstacles(randomize)
        specifications: dict[str, dict[str, Any]] = {}
        for raw in self.task.get("dynamic_obstacles", []):
            if not isinstance(raw, Mapping):
                continue
            interaction = raw.get("interaction")
            if not isinstance(interaction, Mapping):
                continue
            behavior = str(interaction.get("behavior", ""))
            if behavior not in INTERACTIVE_BEHAVIORS:
                continue
            specifications[str(raw.get("name", ""))] = dict(interaction)
        self._interaction_by_name = specifications
        return records

    @staticmethod
    def _bounded_velocity(
        obstacle: ObstacleRecord,
        desired_course: float,
        desired_speed: float,
        specification: Mapping[str, Any],
    ) -> tuple[float, float]:
        current_speed = math.hypot(obstacle.vx, obstacle.vz)
        current_course = math.atan2(obstacle.vx, obstacle.vz)
        max_turn = math.radians(
            max(0.0, float(specification.get("maximum_course_change_deg_per_step", 5.0)))
        )
        max_speed_change = max(
            0.0,
            float(specification.get("maximum_speed_change_mps_per_step", 0.2)),
        )
        course = current_course + float(np.clip(_wrap(desired_course - current_course), -max_turn, max_turn))
        speed = current_speed + float(np.clip(desired_speed - current_speed, -max_speed_change, max_speed_change))
        speed = max(0.0, speed)
        return math.sin(course) * speed, math.cos(course) * speed

    def _desired_response(
        self,
        obstacle: ObstacleRecord,
        specification: Mapping[str, Any],
    ) -> tuple[float, float] | None:
        dx = float(self.state[0]) - obstacle.x
        dz = float(self.state[1]) - obstacle.z
        distance = math.hypot(dx, dz)
        if distance > float(specification.get("trigger_range_m", 300.0)):
            return None
        behavior = str(specification.get("behavior", ""))
        if behavior == "delayed_yield" and self.steps < int(specification.get("response_delay_steps", 2)):
            return None
        current_speed = math.hypot(obstacle.vx, obstacle.vz)
        bearing_to_own = math.atan2(dx, dz)
        if behavior in {"cooperative_yield", "delayed_yield"}:
            desired_course = bearing_to_own + math.pi / 2.0
            return self._bounded_velocity(
                obstacle,
                desired_course,
                max(0.4, current_speed * 0.75),
                specification,
            )
        if behavior == "adversarial_closing":
            projected_x = float(self.state[0]) + math.sin(float(self.state[2])) * float(self.state[3]) * 4.0
            projected_z = float(self.state[1]) + math.cos(float(self.state[2])) * float(self.state[3]) * 4.0
            desired_course = math.atan2(projected_x - obstacle.x, projected_z - obstacle.z)
            return self._bounded_velocity(
                obstacle,
                desired_course,
                max(current_speed, 2.0),
                specification,
            )
        if behavior == "speed_matching":
            desired_course = float(self.state[2])
            desired_speed = max(0.5, abs(float(self.state[3])))
            return self._bounded_velocity(
                obstacle,
                desired_course,
                desired_speed,
                specification,
            )
        return None

    def _append_receipt(
        self,
        obstacle: ObstacleRecord,
        specification: Mapping[str, Any],
        before: tuple[float, float],
    ) -> None:
        payload = {
            "sequence": len(self._interaction_receipts) + 1,
            "step": self.steps,
            "target_id": obstacle.name,
            "behavior": specification.get("behavior"),
            "before_velocity_mps": [round(before[0], 9), round(before[1], 9)],
            "after_velocity_mps": [round(obstacle.vx, 9), round(obstacle.vz, 9)],
            "own_state": [round(float(value), 9) for value in self.state[:4]],
            "previous_receipt_sha256": self._receipt_head,
        }
        canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
        receipt_hash = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
        payload["receipt_sha256"] = receipt_hash
        self._receipt_head = receipt_hash
        self._interaction_receipts.append(payload)

    def _advance_dynamic_obstacles(self) -> None:
        for obstacle in self.obstacles:
            if not obstacle.dynamic:
                continue
            specification = self._interaction_by_name.get(obstacle.name)
            if specification is None:
                continue
            before = (obstacle.vx, obstacle.vz)
            desired = self._desired_response(obstacle, specification)
            if desired is None:
                continue
            obstacle.vx, obstacle.vz = desired
            if not (
                math.isclose(before[0], obstacle.vx, abs_tol=1e-12)
                and math.isclose(before[1], obstacle.vz, abs_tol=1e-12)
            ):
                self._append_receipt(obstacle, specification, before)
        super()._advance_dynamic_obstacles()

    def _info(self, terminated: bool, truncated: bool, goal_reached: bool) -> dict[str, Any]:
        info = super()._info(terminated, truncated, goal_reached)
        info.update(
            {
                "generalization_evaluation_layer": True,
                "interactive_traffic_agent_count": len(self._interaction_by_name),
                "interactive_traffic_receipt_count": len(self._interaction_receipts),
                "interactive_traffic_receipt_head_sha256": self._receipt_head,
                "own_ship_motion_model_modified": False,
                "observation_contract_modified": False,
                "action_contract_modified": False,
                "policy_modified": False,
            }
        )
        return info

    def interaction_receipts(self) -> list[dict[str, Any]]:
        return json.loads(json.dumps(self._interaction_receipts))
