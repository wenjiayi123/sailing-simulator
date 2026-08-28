from __future__ import annotations

from copy import deepcopy
import json
from pathlib import Path
import unittest

from tools.run_physical_bridge_readiness import build_payload
from tools.ship_assurance.physical_bridge import (
    REQUIRED_CLOCK_FIELDS,
    REQUIRED_HARDWARE_ROLES,
    REQUIRED_IO_CHANNELS,
    REQUIRED_IO_RACK_FIELDS,
    REQUIRED_INTERLOCKS,
    REQUIRED_RECOVERY_EVIDENCE,
    REQUIRED_RTOS_FIELDS,
    REQUIRED_TARGET_CONTROLLER_FIELDS,
    REQUIRED_WITNESSED_TEST_CASES,
    build_physical_bridge_report,
    evaluate_physical_bridge_manifest,
    evaluate_standards_mapping,
)


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "data/verification/physical_bridge_hil_manifest.template.json"
MAPPING_PATH = ROOT / "data/verification/simulator_standards_mapping_v1.json"


def _read(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _complete_manifest() -> dict:
    manifest = _read(MANIFEST_PATH)
    manifest["manifest_id"] = "physical-hil-evidence-package-001"
    manifest["execution_context"] = "physical_hil"
    manifest["site"] = {
        "site_name": "witnessed test site",
        "location": "authorized lab",
        "operator_organization": "operator organization",
        "responsible_engineer": "responsible engineer",
        "installation_record_reference": "installation-record",
        "network_diagram_reference": "network-diagram",
        "power_and_ups_test_reference": "power-ups-test",
    }
    manifest["hardware_inventory"] = [
        {
            "role": role,
            "manufacturer": "manufacturer",
            "model": "model",
            "serial_number": f"serial-{index}",
            "installation_reference": f"install-{index}",
        }
        for index, role in enumerate(REQUIRED_HARDWARE_ROLES)
    ]
    manifest["io_channels"] = [
        {
            "signal": signal,
            "direction": direction,
            "protocol": "witnessed-protocol",
            "unit": "contract-unit",
            "update_rate_hz": 20.0,
            "calibration_reference": f"cal-{signal}",
            "verified": True,
        }
        for signal, direction in REQUIRED_IO_CHANNELS.items()
    ]
    manifest["safety_interlocks"] = {
        key: {"verified": True, "evidence_reference": f"evidence-{key}"}
        for key in REQUIRED_INTERLOCKS
    }
    for section, fields in (
        ("target_controller", REQUIRED_TARGET_CONTROLLER_FIELDS),
        ("real_time_operating_system", REQUIRED_RTOS_FIELDS),
        ("real_io_rack", REQUIRED_IO_RACK_FIELDS),
        ("clock_synchronization", REQUIRED_CLOCK_FIELDS),
        ("dropout_recovery_evidence", REQUIRED_RECOVERY_EVIDENCE),
    ):
        manifest[section] = {field: f"evidence-{field}" for field in fields}
    manifest["dual_channel_emergency_stop"] = {
        "channel_a_wiring_reference": "estop-a-wiring",
        "channel_b_wiring_reference": "estop-b-wiring",
        "safety_relay_reference": "safety-relay",
        "independent_power_reference": "independent-power",
        "manual_reset_key_reference": "manual-reset-key",
        "channel_independence_test_reference": "estop-independence-test",
        "one_out_of_two_trip_verified": True,
        "automatic_reset_disabled": True,
    }
    manifest["witnessed_test_cases"] = {
        test_case: {
            "passed": True,
            "evidence_reference": f"evidence-{test_case}",
            "witness_signature_reference": f"signature-{test_case}",
        }
        for test_case in REQUIRED_WITNESSED_TEST_CASES
    }
    manifest["timing_evidence"].update(
        {
            "clock_synchronization_reference": "clock-sync",
            "worst_case_execution_time_reference": "wcet",
            "latency_log_reference": "latency-log",
            "sample_count": 2000,
            "p95_sensor_latency_ms": 20.0,
            "p95_command_latency_ms": 25.0,
            "maximum_jitter_ms": 4.0,
            "watchdog_trip_ms": 120.0,
        }
    )
    evidence = manifest["calibration_and_test_evidence"]
    for key in tuple(evidence):
        evidence[key] = "a" * 64 if key == "physical_hil_raw_log_sha256" else f"reference-{key}"
    manifest["standards_review"] = {
        "mapping_id": "simulator_standards_mapping_v1",
        "qualified_assessor_name": "qualified assessor",
        "assessor_organization": "external organization",
        "review_record_reference": "review-record",
        "administration_or_class_reference": "external-authority-reference",
    }
    return manifest


class PhysicalBridgeReadinessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.template = _read(MANIFEST_PATH)
        self.mapping = _read(MAPPING_PATH)

    def test_checked_in_template_is_fail_closed(self) -> None:
        report = build_physical_bridge_report(self.template, self.mapping)
        self.assertTrue(report["software_readiness_gate_passed"], report)
        self.assertTrue(report["refusal_gate_passed"])
        evaluation = report["evaluation"]
        self.assertEqual(
            evaluation["status"],
            "BLOCKED_PHYSICAL_BRIDGE_EVIDENCE_INCOMPLETE",
        )
        self.assertFalse(evaluation["physical_hil_verified"])
        self.assertFalse(evaluation["site_delivery_ready"])
        self.assertFalse(evaluation["certified"])
        self.assertFalse(evaluation["production_authority"])

    def test_complete_references_only_route_to_external_assessment(self) -> None:
        evaluation = evaluate_physical_bridge_manifest(
            _complete_manifest(), self.mapping
        )
        self.assertTrue(evaluation["evidence_package_complete"], evaluation)
        self.assertEqual(
            evaluation["status"], "READY_FOR_WITNESSED_EXTERNAL_ASSESSMENT"
        )
        self.assertFalse(evaluation["physical_hil_verified"])
        self.assertFalse(evaluation["site_delivery_ready"])
        self.assertFalse(evaluation["certified"])
        self.assertTrue(evaluation["external_authentication_required"])

    def test_missing_io_channel_is_reported_by_name(self) -> None:
        manifest = _complete_manifest()
        manifest["io_channels"] = [
            item
            for item in manifest["io_channels"]
            if item["signal"] != "emergency_stop_channel_a"
        ]
        evaluation = evaluate_physical_bridge_manifest(manifest, self.mapping)
        self.assertFalse(evaluation["evidence_package_complete"])
        self.assertIn(
            "emergency_stop_channel_a",
            evaluation["io_contract"]["missing_channels"],
        )

    def test_missing_target_runtime_evidence_blocks_external_routing(self) -> None:
        manifest = _complete_manifest()
        manifest["target_controller"]["firmware_build_id"] = ""
        evaluation = evaluate_physical_bridge_manifest(manifest, self.mapping)
        runtime = evaluation["target_runtime_and_witnessed_tests"]
        self.assertFalse(runtime["passed"])
        self.assertFalse(
            runtime["section_checks"]["target_controller"]["firmware_build_id"]
        )
        self.assertFalse(evaluation["evidence_package_complete"])

    def test_self_asserted_authority_blocks_package(self) -> None:
        manifest = _complete_manifest()
        manifest["authority"]["production_control_authorized"] = True
        evaluation = evaluate_physical_bridge_manifest(manifest, self.mapping)
        self.assertTrue(evaluation["authority_request_detected"])
        self.assertFalse(evaluation["evidence_package_complete"])
        self.assertFalse(evaluation["production_authority"])

    def test_standards_mapping_is_traceable_but_not_certification(self) -> None:
        result = evaluate_standards_mapping(self.mapping)
        self.assertTrue(result["schema_valid"], result)
        self.assertGreaterEqual(result["requirement_count"], 13)
        self.assertGreater(result["open_or_partial_count"], 0)
        self.assertFalse(result["certification_claim_allowed"])
        self.assertTrue(result["external_assessor_required"])

    def test_report_builder_includes_current_input_hashes(self) -> None:
        payload = build_payload()
        self.assertTrue(payload["software_readiness_gate_passed"], payload)
        self.assertEqual(len(payload["inputs_sha256"]), 4)
        self.assertFalse(payload["claims"]["physical_hil_verified"])
        self.assertFalse(payload["claims"]["dnv_certified"])


if __name__ == "__main__":
    unittest.main()
