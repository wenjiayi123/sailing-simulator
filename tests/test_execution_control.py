from __future__ import annotations

import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
PROFILE_PATH = ROOT / "data/verification/execution_control_profile_v1.json"
SUITE_PATH = ROOT / "scripts/navigation/ship_execution_control_suite.gd"
PANEL_PATH = ROOT / "scripts/ui/ship_execution_control_panel.gd"
MAIN_PATH = ROOT / "main.tscn"


class ExecutionControlContractTests(unittest.TestCase):
    def test_profile_declares_limits_authority_and_fail_closed_hardware(self) -> None:
        profile = json.loads(PROFILE_PATH.read_text(encoding="utf-8"))
        self.assertEqual(profile["schema_version"], "ship_execution_control_profile_v1")
        self.assertEqual(profile["authority_priority"][:2], ["EMERGENCY_STOP", "MANUAL"])
        limits = profile["command_limits"]
        self.assertLessEqual(limits["maximum_ahead_throttle"], 1.0)
        self.assertLessEqual(limits["maximum_rudder_normalized"], 1.0)
        self.assertGreater(profile["watchdog_timeout_seconds"], 0.0)
        self.assertFalse(profile["external_actuator_adapter"]["enabled"])
        self.assertFalse(profile["physical_emergency_stop_verified"])
        self.assertFalse(profile["physical_actuator_feedback_verified"])
        self.assertFalse(profile["production_authority"])

    def test_runtime_has_closed_loop_and_arbitration_contracts(self) -> None:
        source = SUITE_PATH.read_text(encoding="utf-8")
        for token in (
            "func arm_simulation_execution",
            "func request_control",
            "func submit_rl_action",
            "func engage_autopilot",
            "func manual_immediate_takeover",
            "func trigger_emergency_stop",
            "func release_emergency_stop",
            '"FAIL_SAFE_WATCHDOG_NEUTRAL"',
            '"FAIL_SAFE_FEEDBACK_LOSS"',
            '"DEGRADED_ACTUATOR_JAM"',
            '"command_acknowledged"',
        ):
            self.assertIn(token, source)

    def test_layer_uses_public_api_without_modifying_plant_or_policy(self) -> None:
        source = SUITE_PATH.read_text(encoding="utf-8")
        self.assertIn('has_method("set_ship_agent_command")', source)
        self.assertIn('has_method("clear_ship_agent_command")', source)
        self.assertNotIn("apply_ship_performance_config", source)
        self.assertNotIn("ship_three_dof_enabled =", source)
        self.assertNotIn("FileAccess.WRITE", source)
        profile = json.loads(PROFILE_PATH.read_text(encoding="utf-8"))
        self.assertFalse(profile["existing_policy_adapter"]["wired"])

    def test_scene_panel_and_hotkey_are_wired(self) -> None:
        scene = MAIN_PATH.read_text(encoding="utf-8")
        panel = PANEL_PATH.read_text(encoding="utf-8")
        self.assertIn('node name="ShipExecutionControlSuite"', scene)
        self.assertIn('node name="ShipExecutionControlPanel"', scene)
        self.assertIn("ship_execution_control_suite.gd", scene)
        self.assertIn("ship_execution_control_panel.gd", scene)
        self.assertIn("const TOGGLE_PANEL_KEY := KEY_L", panel)


if __name__ == "__main__":
    unittest.main()
