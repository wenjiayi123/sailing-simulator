from __future__ import annotations

import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
PROFILE_PATH = ROOT / "data/verification/multisensor_fusion_profile_v1.json"
SUITE_PATH = ROOT / "scripts/navigation/ship_multisensor_fusion_suite.gd"
EQUIPMENT_PATH = ROOT / "scripts/navigation/ship_navigation_equipment_suite.gd"
PANEL_PATH = ROOT / "scripts/ui/ship_multisensor_fusion_panel.gd"
MAIN_PATH = ROOT / "main.tscn"


class MultisensorFusionContractTests(unittest.TestCase):
    def test_profile_declares_six_fail_closed_channels(self) -> None:
        profile = json.loads(PROFILE_PATH.read_text(encoding="utf-8"))
        self.assertEqual(profile["schema_version"], "ship_multisensor_fusion_profile_v1")
        self.assertEqual(
            set(profile["sensor_channels"]),
            {"RADAR", "AIS", "EO", "IR", "GNSS", "INS"},
        )
        self.assertTrue(
            all(
                channel["hardware_verified"] is False
                for channel in profile["sensor_channels"].values()
            )
        )
        self.assertFalse(profile["external_ingest"]["enabled"])
        self.assertFalse(profile["real_sensor_data_verified"])
        self.assertFalse(profile["production_authority"])

    def test_rl_gateway_is_additive_and_does_not_rewire_policy(self) -> None:
        profile = json.loads(PROFILE_PATH.read_text(encoding="utf-8"))
        gateway = profile["rl_observation_gateway"]
        self.assertTrue(gateway["available"])
        self.assertFalse(gateway["wired_to_existing_policy"])
        self.assertTrue(gateway["requires_versioned_observation_adapter_and_retraining"])
        runtime = SUITE_PATH.read_text(encoding="utf-8")
        for forbidden in (
            "set_ship_agent_command",
            "set_external_agent_control",
            "apply_rudder",
            "apply_throttle",
            "policy.zip\", FileAccess.WRITE",
        ):
            self.assertNotIn(forbidden, runtime)

    def test_runtime_models_faults_provenance_and_integrity(self) -> None:
        runtime = SUITE_PATH.read_text(encoding="utf-8")
        for token in (
            'const PACKET_SCHEMA := "ship_sensor_packet_v1"',
            '"measurement_time_seconds"',
            '"source_identity"',
            '"calibration_reference"',
            '"quality"',
            '"integrity"',
            '"radar_dropout"',
            '"ais_latency_ms"',
            '"eo_occlusion_ratio"',
            '"ir_false_alarm_count"',
            '"gnss_spoof_offset_m"',
            '"ins_heading_bias_deg"',
            '"DEAD_RECKONING_DEGRADED"',
            '"FAIL_CLOSED"',
        ):
            self.assertIn(token, runtime)

    def test_scene_and_panel_are_wired(self) -> None:
        scene = MAIN_PATH.read_text(encoding="utf-8")
        panel = PANEL_PATH.read_text(encoding="utf-8")
        self.assertIn('node name="ShipMultisensorFusionSuite"', scene)
        self.assertIn('node name="ShipMultisensorFusionPanel"', scene)
        self.assertIn("ship_multisensor_fusion_suite.gd", scene)
        self.assertIn("ship_multisensor_fusion_panel.gd", scene)
        self.assertIn("const TOGGLE_PANEL_KEY := KEY_K", panel)

    def test_scene_truth_adapter_is_explicitly_not_hardware(self) -> None:
        equipment = EQUIPMENT_PATH.read_text(encoding="utf-8")
        self.assertIn("func get_simulator_sensor_truth_frame()", equipment)
        self.assertIn('"source_mode": "SIMULATOR_TRUTH_INTERNAL"', equipment)
        self.assertIn('"hardware_verified": false', equipment)
        self.assertIn("_collect_truth_contacts(ownship, true)", equipment)


if __name__ == "__main__":
    unittest.main()
