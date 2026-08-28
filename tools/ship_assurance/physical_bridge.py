"""Physical-bridge HIL evidence contract and fail-closed site readiness gate."""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
from typing import Any, Mapping, Sequence


REQUIRED_HARDWARE_ROLES = (
    "helm_input",
    "engine_telegraph",
    "emergency_stop_channel_a",
    "emergency_stop_channel_b",
    "manual_override",
    "gnss_receiver",
    "heading_sensor",
    "speed_log",
    "rudder_feedback",
    "throttle_feedback",
    "bridge_display",
    "target_controller",
    "real_io_rack",
    "safety_relay",
    "clock_source",
)

REQUIRED_IO_CHANNELS = {
    "heading_deg": "input",
    "position_lat_lon": "input",
    "speed_knots": "input",
    "rudder_command": "output",
    "rudder_feedback": "input",
    "throttle_command": "output",
    "throttle_feedback": "input",
    "emergency_stop_channel_a": "input",
    "emergency_stop_channel_b": "input",
    "manual_reset_key": "input",
    "manual_override": "input",
    "watchdog_heartbeat": "bidirectional",
    "target_controller_health": "input",
    "io_rack_health": "input",
    "clock_sync": "input",
}

REQUIRED_INTERLOCKS = (
    "independent_emergency_stop",
    "manual_control_priority",
    "hardwired_neutral_state",
    "power_loss_neutralization",
    "watchdog_independent_of_application",
    "network_isolation",
    "hazard_analysis",
    "cybersecurity_review",
    "dual_channel_estop_independence",
    "controller_deadline_monitor",
    "feedback_disagreement_trip",
    "recovery_manual_rearm",
)

REQUIRED_TARGET_CONTROLLER_FIELDS = (
    "manufacturer",
    "model",
    "serial_number",
    "hardware_revision",
    "firmware_build_id",
    "io_firmware_id",
    "installation_reference",
)

REQUIRED_RTOS_FIELDS = (
    "vendor",
    "name",
    "version",
    "build_id",
    "scheduler_policy",
    "controller_task_priority",
    "configuration_hash",
    "wcet_measurement_tool",
)

REQUIRED_IO_RACK_FIELDS = (
    "manufacturer",
    "model",
    "serial_number",
    "fieldbus_protocol",
    "signal_mapping_reference",
    "electrical_acceptance_reference",
    "calibration_reference",
)

REQUIRED_CLOCK_FIELDS = (
    "synchronization_protocol",
    "primary_source_model",
    "primary_source_serial_number",
    "synchronization_domain",
    "topology_reference",
    "holdover_test_reference",
)

REQUIRED_RECOVERY_EVIDENCE = (
    "sensor_bus_loss_reference",
    "control_link_loss_reference",
    "io_rack_power_cycle_reference",
    "controller_restart_reference",
    "feedback_disagreement_reference",
    "manual_rearm_reference",
)

REQUIRED_WITNESSED_TEST_CASES = (
    "nominal_closed_loop",
    "clock_offset_fault",
    "execution_deadline_overrun",
    "sensor_link_dropout",
    "command_link_dropout",
    "io_rack_power_loss",
    "controller_restart",
    "manual_takeover",
    "estop_channel_a",
    "estop_channel_b",
    "dual_channel_estop_reset",
    "feedback_disagreement",
)

REQUIRED_SITE_FIELDS = (
    "site_name",
    "location",
    "operator_organization",
    "responsible_engineer",
    "installation_record_reference",
    "network_diagram_reference",
    "power_and_ups_test_reference",
)

REQUIRED_TEST_EVIDENCE = (
    "sensor_calibration_reference",
    "actuator_calibration_reference",
    "physical_hil_raw_log_reference",
    "fault_injection_report_reference",
    "manual_override_test_reference",
    "emergency_stop_test_reference",
    "independent_witness_name",
    "independent_witness_organization",
    "signed_acceptance_record_reference",
)


def _present(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _finite_number(value: Any) -> bool:
    return not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(float(value))


def sha256_path(path: str | Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def evaluate_standards_mapping(mapping: Mapping[str, Any]) -> dict[str, Any]:
    requirements = mapping.get("requirements", [])
    valid_records = isinstance(requirements, list) and all(
        isinstance(item, Mapping)
        and _present(item.get("requirement_id"))
        and _present(item.get("topic"))
        and _present(item.get("status"))
        and isinstance(item.get("evidence"), list)
        and _present(item.get("gap"))
        for item in requirements
    )
    counts: dict[str, int] = {}
    for raw in requirements if isinstance(requirements, list) else []:
        if isinstance(raw, Mapping):
            status = str(raw.get("status", "MISSING"))
            counts[status] = counts.get(status, 0) + 1
    blocked_count = sum(
        count
        for status, count in counts.items()
        if status not in {"COMPLETE", "VERIFIED_BY_EXTERNAL_ASSESSOR"}
    )
    return {
        "mapping_id": str(mapping.get("mapping_id", "")),
        "schema_valid": mapping.get("schema_version") == "simulator_standards_mapping_v1" and valid_records,
        "requirement_count": len(requirements) if isinstance(requirements, list) else 0,
        "status_counts": dict(sorted(counts.items())),
        "open_or_partial_count": blocked_count,
        "certification_claim_allowed": mapping.get("certification_claim_allowed") is True,
        "external_assessor_required": mapping.get("external_assessor_required") is True,
        "boundary": str(mapping.get("boundary", "")),
    }


def _hardware_checks(inventory: Any) -> dict[str, Any]:
    records = inventory if isinstance(inventory, list) else []
    roles: dict[str, Mapping[str, Any]] = {}
    invalid_records: list[int] = []
    for index, raw in enumerate(records):
        if not isinstance(raw, Mapping):
            invalid_records.append(index)
            continue
        role = str(raw.get("role", ""))
        complete = all(
            _present(raw.get(field))
            for field in ("role", "manufacturer", "model", "serial_number", "installation_reference")
        )
        if not complete:
            invalid_records.append(index)
        if role:
            roles[role] = raw
    missing = [role for role in REQUIRED_HARDWARE_ROLES if role not in roles]
    return {
        "passed": not missing and not invalid_records,
        "required_roles": list(REQUIRED_HARDWARE_ROLES),
        "record_count": len(records),
        "missing_roles": missing,
        "invalid_record_indexes": invalid_records,
    }


def _io_checks(channels: Any) -> dict[str, Any]:
    records = channels if isinstance(channels, list) else []
    by_signal: dict[str, Mapping[str, Any]] = {}
    invalid: list[str] = []
    for raw in records:
        if not isinstance(raw, Mapping):
            invalid.append("NON_OBJECT")
            continue
        signal = str(raw.get("signal", ""))
        if signal:
            by_signal[signal] = raw
    missing = [signal for signal in REQUIRED_IO_CHANNELS if signal not in by_signal]
    for signal, expected_direction in REQUIRED_IO_CHANNELS.items():
        if signal not in by_signal:
            continue
        record = by_signal[signal]
        if (
            str(record.get("direction", "")) != expected_direction
            or not _present(record.get("protocol"))
            or not _present(record.get("unit"))
            or not _finite_number(record.get("update_rate_hz"))
            or float(record.get("update_rate_hz", 0.0)) <= 0.0
            or not _present(record.get("calibration_reference"))
            or record.get("verified") is not True
        ):
            invalid.append(signal)
    return {
        "passed": not missing and not invalid,
        "required_channels": dict(REQUIRED_IO_CHANNELS),
        "record_count": len(records),
        "missing_channels": missing,
        "invalid_channels": sorted(set(invalid)),
    }


def _interlock_checks(interlocks: Any) -> dict[str, Any]:
    records = interlocks if isinstance(interlocks, Mapping) else {}
    failed: list[str] = []
    for key in REQUIRED_INTERLOCKS:
        record = records.get(key, {})
        if not isinstance(record, Mapping) or record.get("verified") is not True or not _present(record.get("evidence_reference")):
            failed.append(key)
    return {
        "passed": not failed,
        "required": list(REQUIRED_INTERLOCKS),
        "failed_or_missing": failed,
    }


def _timing_checks(timing: Any) -> dict[str, Any]:
    record = timing if isinstance(timing, Mapping) else {}
    limits = record.get("limits", {}) if isinstance(record.get("limits"), Mapping) else {}
    references = {
        key: _present(record.get(key))
        for key in (
            "clock_synchronization_reference",
            "worst_case_execution_time_reference",
            "latency_log_reference",
        )
    }
    metrics: dict[str, bool] = {
        "minimum_sample_count": _finite_number(record.get("sample_count"))
        and int(record.get("sample_count", 0)) >= int(limits.get("minimum_sample_count", 1000)),
        "sensor_latency": _finite_number(record.get("p95_sensor_latency_ms"))
        and float(record.get("p95_sensor_latency_ms")) <= float(limits.get("maximum_p95_sensor_latency_ms", 100.0)),
        "command_latency": _finite_number(record.get("p95_command_latency_ms"))
        and float(record.get("p95_command_latency_ms")) <= float(limits.get("maximum_p95_command_latency_ms", 100.0)),
        "jitter": _finite_number(record.get("maximum_jitter_ms"))
        and float(record.get("maximum_jitter_ms")) <= float(limits.get("maximum_jitter_ms", 25.0)),
        "watchdog_trip": _finite_number(record.get("watchdog_trip_ms"))
        and float(record.get("watchdog_trip_ms")) <= float(limits.get("maximum_watchdog_trip_ms", 200.0)),
    }
    return {
        "passed": all(references.values()) and all(metrics.values()),
        "reference_checks": references,
        "metric_checks": metrics,
        "limits": dict(limits),
    }


def _target_runtime_checks(manifest: Mapping[str, Any]) -> dict[str, Any]:
    """Check evidence needed to identify and witness the physical target runtime."""

    sections = {
        "target_controller": (manifest.get("target_controller"), REQUIRED_TARGET_CONTROLLER_FIELDS),
        "real_time_operating_system": (
            manifest.get("real_time_operating_system"),
            REQUIRED_RTOS_FIELDS,
        ),
        "real_io_rack": (manifest.get("real_io_rack"), REQUIRED_IO_RACK_FIELDS),
        "clock_synchronization": (
            manifest.get("clock_synchronization"),
            REQUIRED_CLOCK_FIELDS,
        ),
        "dropout_recovery_evidence": (
            manifest.get("dropout_recovery_evidence"),
            REQUIRED_RECOVERY_EVIDENCE,
        ),
    }
    section_checks: dict[str, dict[str, bool]] = {}
    for section_name, (raw, required_fields) in sections.items():
        record = raw if isinstance(raw, Mapping) else {}
        section_checks[section_name] = {
            field: _present(record.get(field)) for field in required_fields
        }
    dual = (
        manifest.get("dual_channel_emergency_stop")
        if isinstance(manifest.get("dual_channel_emergency_stop"), Mapping)
        else {}
    )
    dual_checks = {
        field: _present(dual.get(field))
        for field in (
            "channel_a_wiring_reference",
            "channel_b_wiring_reference",
            "safety_relay_reference",
            "independent_power_reference",
            "manual_reset_key_reference",
            "channel_independence_test_reference",
        )
    }
    dual_checks["one_out_of_two_trip_verified"] = dual.get("one_out_of_two_trip_verified") is True
    dual_checks["automatic_reset_disabled"] = dual.get("automatic_reset_disabled") is True
    raw_tests = manifest.get("witnessed_test_cases")
    tests = raw_tests if isinstance(raw_tests, Mapping) else {}
    witnessed_checks: dict[str, bool] = {}
    for test_case in REQUIRED_WITNESSED_TEST_CASES:
        record = tests.get(test_case, {})
        witnessed_checks[test_case] = (
            isinstance(record, Mapping)
            and record.get("passed") is True
            and _present(record.get("evidence_reference"))
            and _present(record.get("witness_signature_reference"))
        )
    passed = (
        all(all(fields.values()) for fields in section_checks.values())
        and all(dual_checks.values())
        and all(witnessed_checks.values())
    )
    return {
        "passed": passed,
        "section_checks": section_checks,
        "dual_channel_emergency_stop_checks": dual_checks,
        "required_witnessed_test_cases": list(REQUIRED_WITNESSED_TEST_CASES),
        "witnessed_test_case_checks": witnessed_checks,
    }


def _site_and_evidence_checks(manifest: Mapping[str, Any]) -> dict[str, Any]:
    site = manifest.get("site", {}) if isinstance(manifest.get("site"), Mapping) else {}
    evidence = (
        manifest.get("calibration_and_test_evidence", {})
        if isinstance(manifest.get("calibration_and_test_evidence"), Mapping)
        else {}
    )
    standards = manifest.get("standards_review", {}) if isinstance(manifest.get("standards_review"), Mapping) else {}
    site_checks = {field: _present(site.get(field)) for field in REQUIRED_SITE_FIELDS}
    evidence_checks = {field: _present(evidence.get(field)) for field in REQUIRED_TEST_EVIDENCE}
    raw_hash = str(evidence.get("physical_hil_raw_log_sha256", ""))
    evidence_checks["physical_hil_raw_log_sha256"] = len(raw_hash) == 64 and all(
        char in "0123456789abcdefABCDEF" for char in raw_hash
    )
    standards_checks = {
        field: _present(standards.get(field))
        for field in (
            "mapping_id",
            "qualified_assessor_name",
            "assessor_organization",
            "review_record_reference",
            "administration_or_class_reference",
        )
    }
    return {
        "passed": all(site_checks.values()) and all(evidence_checks.values()) and all(standards_checks.values()),
        "site_checks": site_checks,
        "evidence_checks": evidence_checks,
        "standards_review_checks": standards_checks,
    }


def evaluate_physical_bridge_manifest(
    manifest: Mapping[str, Any],
    standards_mapping: Mapping[str, Any],
) -> dict[str, Any]:
    """Evaluate package completeness without authenticating external evidence."""

    hardware = _hardware_checks(manifest.get("hardware_inventory"))
    io = _io_checks(manifest.get("io_channels"))
    interlocks = _interlock_checks(manifest.get("safety_interlocks"))
    timing = _timing_checks(manifest.get("timing_evidence"))
    target_runtime = _target_runtime_checks(manifest)
    site_evidence = _site_and_evidence_checks(manifest)
    mapping = evaluate_standards_mapping(standards_mapping)
    schema_valid = manifest.get("schema_version") == "physical_bridge_hil_manifest_v1"
    real_context = manifest.get("execution_context") == "physical_hil"
    authority = manifest.get("authority", {}) if isinstance(manifest.get("authority"), Mapping) else {}
    authority_requested = any(value is True for value in authority.values())
    package_complete = all(
        (
            schema_valid,
            real_context,
            hardware["passed"],
            io["passed"],
            interlocks["passed"],
            timing["passed"],
            target_runtime["passed"],
            site_evidence["passed"],
            mapping["schema_valid"],
            not authority_requested,
        )
    )
    status = (
        "READY_FOR_WITNESSED_EXTERNAL_ASSESSMENT"
        if package_complete
        else "BLOCKED_PHYSICAL_BRIDGE_EVIDENCE_INCOMPLETE"
    )
    return {
        "status": status,
        "manifest_id": str(manifest.get("manifest_id", "")),
        "schema_valid": schema_valid,
        "physical_execution_context_declared": real_context,
        "evidence_package_complete": package_complete,
        "hardware_inventory": hardware,
        "io_contract": io,
        "safety_interlocks": interlocks,
        "timing": timing,
        "target_runtime_and_witnessed_tests": target_runtime,
        "site_and_test_evidence": site_evidence,
        "standards_mapping": mapping,
        "authority_request_detected": authority_requested,
        "physical_hil_verified": False,
        "site_delivery_ready": False,
        "certified": False,
        "production_authority": False,
        "external_authentication_required": True,
        "boundary": (
            "The evaluator checks completeness, ranges and references only. It cannot authenticate hardware, "
            "calibration, witnesses, signatures, an Administration/class decision or a physical test, so it never "
            "declares physical HIL verified, site delivery ready, certified or production-authorized."
        ),
    }


def build_physical_bridge_report(
    manifest: Mapping[str, Any],
    standards_mapping: Mapping[str, Any],
) -> dict[str, Any]:
    evaluation = evaluate_physical_bridge_manifest(manifest, standards_mapping)
    expected_template_block = manifest.get("execution_context") != "physical_hil"
    refusal_gate_passed = (
        not expected_template_block
        or (
            evaluation["status"] == "BLOCKED_PHYSICAL_BRIDGE_EVIDENCE_INCOMPLETE"
            and evaluation["physical_hil_verified"] is False
            and evaluation["site_delivery_ready"] is False
            and evaluation["certified"] is False
            and evaluation["production_authority"] is False
        )
    )
    return {
        "schema_version": "physical_bridge_readiness_report_v1",
        "software_readiness_gate_passed": bool(
            evaluation["standards_mapping"]["schema_valid"] and refusal_gate_passed
        ),
        "evaluation": evaluation,
        "refusal_gate_passed": refusal_gate_passed,
        "claims": {
            "software_hil_loopback_verified": True,
            "physical_hil_verified": False,
            "site_delivery_ready": False,
            "stcw_approved": False,
            "dnv_certified": False,
            "production_authority": False,
        },
        "boundary": "Readiness routing and anti-overclaim evidence only; physical installation and external assessment remain blocked.",
    }


def load_json(path: str | Path) -> dict[str, Any]:
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"JSON root must be an object: {path}")
    return value
