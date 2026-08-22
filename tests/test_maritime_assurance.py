from __future__ import annotations

import json
import math
import tempfile
import unittest
from pathlib import Path

import numpy as np

from tools.ship_assurance.colreg import run_scenario_catalog
from tools.ship_assurance.dynamics import (
    DynamicsConfig,
    ThreeDofVessel,
    identify_first_order_nomoto,
    run_dynamics_acceptance,
)
from tools.ship_assurance.hil import (
    FrameError,
    UdpHilEndpoint,
    decode_frame,
    encode_frame,
    run_hil_loopback_campaign,
)
from tools.ship_assurance.environment import (
    ASSURED_PORT_OPS_OBSERVATION_SIZE,
    AssuredPortOpsEnv,
)
from tools.ship_assurance.sea_trial import (
    SeaTrialEvidence,
    evaluate_sea_trial_gate,
    load_telemetry_csv,
    run_sea_trial_dry_run,
    sha256_file,
)


ROOT = Path(__file__).resolve().parents[1]
DYNAMICS = ROOT / "data/verification/vessel_dynamics_reference_v1.json"
COLREG = ROOT / "data/verification/colreg_encounter_catalog_v1.json"
HIL = ROOT / "data/verification/hil_loopback_profile_v1.json"
SEA_TRIAL = ROOT / "data/verification/sea_trial_protocol_v1.json"


def _read(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


class DynamicsAssuranceTests(unittest.TestCase):
    def test_reference_plant_acceptance_and_determinism(self) -> None:
        config = DynamicsConfig.from_mapping(_read(DYNAMICS))
        report = run_dynamics_acceptance(config)
        self.assertTrue(report["passed"], report)
        self.assertEqual(report["passed_count"], report["check_count"])
        self.assertFalse(report["vessel_specific_calibration_verified"])
        first = ThreeDofVessel(config)
        second = ThreeDofVessel(config)
        for _ in range(100):
            first.step(0.4, 0.2, 0.1)
            second.step(0.4, 0.2, 0.1)
        self.assertEqual(first.state.export(), second.state.export())

    def test_nomoto_identification_recovers_synthetic_stable_plant(self) -> None:
        timestep = 0.2
        time = np.arange(0.0, 80.0, timestep)
        rudder = np.where(time >= 10.0, math.radians(10.0), 0.0)
        gain = 0.35
        time_constant = 12.0
        yaw = np.zeros_like(time)
        for index in range(1, len(time)):
            yaw[index] = yaw[index - 1] + timestep * (
                -yaw[index - 1] / time_constant
                + gain * rudder[index - 1] / time_constant
            )
        result = identify_first_order_nomoto(time, yaw, rudder)
        self.assertAlmostEqual(result["nomoto_gain_radps_per_rad"], gain, delta=0.02)
        self.assertAlmostEqual(result["nomoto_time_constant_s"], time_constant, delta=0.8)
        self.assertGreater(result["r_squared"], 0.98)

    def test_assured_environment_connects_plant_and_rule_trace(self) -> None:
        config = {
            "delta": 0.2,
            "rl_parameters": {
                "safe_distance": 500.0,
                "penalty_colreg_give_way": 2.0,
            },
            "environment_parameters": {
                "domain_randomization": False,
                "randomize_evaluation": False,
                "merge_scene_obstacles": False,
                "generated_traffic_count": 0,
                "sensor_range_m": 1500.0,
                "tcpa_horizon_seconds": 900.0,
                "sensor_distance_noise_std_m": 0.0,
                "sensor_bearing_noise_degrees": 0.0,
            },
            "ships": [{"performance": {}}],
            "assurance_parameters": {
                "dynamics_3dof": _read(DYNAMICS),
                "colreg_safe_dcpa_m": 500.0,
                "vessels_in_sight": True,
            },
        }
        task = {
            "id": "assured-crossing",
            "start": {"x": 0.0, "z": 0.0, "heading_degrees": 0.0},
            "route": [{"x": 0.0, "z": 1500.0}],
            "arrival_radius": 20.0,
            "boundary_half_extent": 2000.0,
            "sea_state": {"visibility_km": 10.0},
            "vessel_profile": {
                "length_meters": 150.0,
                "width_meters": 24.0,
                "draft_meters": 6.0,
                "max_observed_speed_knots": 12.0,
            },
            "navigation_context": {
                "chart_depth_meters": 20.0,
                "minimum_under_keel_clearance_meters": 1.0,
                "speed_limit_knots": 12.0,
                "enforce_fairway": False,
            },
            "dynamic_obstacles": [
                {
                    "name": "crossing-target",
                    "kind": "traffic",
                    "shape": "circle",
                    "dynamic": True,
                    "x": 500.0,
                    "z": 500.0,
                    "radius": 8.0,
                    "course_degrees": 270.0,
                    "speed_knots": 9.72,
                }
            ],
        }
        dataset = {
            "shared_environment": {},
            "splits": {"train": [task], "validation": [task], "test": [task]},
        }
        env = AssuredPortOpsEnv(config, dataset, split="test", max_steps=20, seed=3)
        observation, info = env.reset(options={"task_index": 0})
        self.assertEqual(observation.shape, (ASSURED_PORT_OPS_OBSERVATION_SIZE,))
        self.assertEqual(info["module"], "assured_port_ops_v4")
        self.assertFalse(info["named_vessel_dynamics_calibrated"])
        for _ in range(5):
            observation, _reward, _terminated, _truncated, info = env.step(
                np.asarray([0.6, 0.3], dtype=np.float32)
            )
        self.assertTrue(env.observation_space.contains(observation))
        self.assertGreater(env.plant.state.throttle, 0.0)
        self.assertGreater(env.plant.state.rudder_angle_rad, 0.0)
        self.assertIn("dynamics_model_id", env.trajectory[-1])
        self.assertIn("colreg_rules", env.trajectory[-1])


class ColregAssuranceTests(unittest.TestCase):
    def test_catalog_covers_positive_and_negative_rule_actions(self) -> None:
        report = run_scenario_catalog(_read(COLREG))
        self.assertTrue(report["passed"], report)
        self.assertEqual(report["scenario_count"], 6)
        self.assertGreaterEqual(report["action_case_count"], 11)
        self.assertFalse(report["colreg_certified"])
        encounters = {item["assessment"]["encounter"] for item in report["results"]}
        self.assertEqual(
            encounters,
            {
                "head_on",
                "crossing_starboard",
                "crossing_port",
                "overtaking",
                "restricted_visibility",
                "no_risk",
            },
        )


class HilAssuranceTests(unittest.TestCase):
    def test_campaign_rejects_faults_and_neutralizes_watchdog(self) -> None:
        report = run_hil_loopback_campaign(_read(HIL))
        self.assertTrue(report["passed"], report)
        self.assertTrue(report["watchdog_neutralized"])
        self.assertGreater(report["invalid_frames_rejected"], 0)
        self.assertFalse(report["physical_hardware_verified"])
        self.assertFalse(report["production_authority"])

    def test_udp_transport_and_integrity_contract(self) -> None:
        frame = encode_frame(
            frame_type="telemetry",
            session_id="test",
            sequence=1,
            monotonic_ns=10,
            payload={"heading_deg": 12.0},
        )
        self.assertEqual(decode_frame(frame)["payload"]["heading_deg"], 12.0)
        damaged = bytearray(frame)
        damaged[len(damaged) // 2] ^= 1
        with self.assertRaises(FrameError):
            decode_frame(bytes(damaged))
        with UdpHilEndpoint() as sender, UdpHilEndpoint() as receiver:
            sender.send(frame, receiver.address)
            received, source = receiver.receive()
            self.assertEqual(received["sequence"], 1)
            self.assertEqual(source[1], sender.address[1])


class SeaTrialAssuranceTests(unittest.TestCase):
    @staticmethod
    def _csv(duration: int = 300) -> str:
        lines = [
            "timestamp_s,heading_deg,speed_mps,cross_track_error_m,dcpa_m,command_latency_ms,gnss_fix_valid,manual_override_active,emergency_stop_active"
        ]
        for timestamp in range(duration + 1):
            lines.append(
                f"{timestamp},10,3,2,1000,20,true,"
                f"{'true' if timestamp == 120 else 'false'},"
                f"{'true' if timestamp == 180 else 'false'}"
            )
        return "\n".join(lines) + "\n"

    def test_simulation_metrics_cannot_claim_sea_trial(self) -> None:
        result = run_sea_trial_dry_run(_read(SEA_TRIAL))
        self.assertTrue(result["dry_run_metric_gate_passed"])
        self.assertTrue(result["evidence_completeness_refusal_gate_passed"])
        self.assertFalse(result["sea_trial_completed"])

    def test_complete_real_evidence_contract_is_ready_for_external_review(self) -> None:
        protocol = _read(SEA_TRIAL)
        with tempfile.TemporaryDirectory() as temporary:
            telemetry = Path(temporary) / "trial.csv"
            telemetry.write_text(self._csv(), encoding="utf-8")
            rows = load_telemetry_csv(telemetry)
            evidence = SeaTrialEvidence(
                execution_context="real_vessel",
                raw_log_path=str(telemetry),
                raw_log_sha256=sha256_file(telemetry),
                vessel_identifier="test-vessel-identifier",
                trial_area="authorized-test-area",
                authority_or_port_permission_reference="permit-reference",
                master_or_operator_name="operator-name",
                independent_witness_name="witness-name",
                independent_witness_organization="witness-organization",
                sensor_calibration_report_reference="sensor-calibration-reference",
                actuator_calibration_report_reference="actuator-calibration-reference",
                risk_assessment_reference="risk-assessment-reference",
                signed_trial_record_reference="signed-record-reference",
                physical_hil_report_reference="physical-hil-reference",
                physical_hil_verified=True,
            )
            result = evaluate_sea_trial_gate(evidence, protocol, rows)
            self.assertTrue(result["evidence_package_complete"], result)
            self.assertFalse(result["sea_trial_completed"])
            self.assertTrue(result["external_authentication_required"])
            self.assertEqual(result["status"], "READY_FOR_EXTERNAL_REVIEW")


if __name__ == "__main__":
    unittest.main()
