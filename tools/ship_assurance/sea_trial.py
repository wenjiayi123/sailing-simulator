"""Sea-trial protocol evaluation with an explicit anti-fabrication evidence gate."""

from __future__ import annotations

import csv
from dataclasses import dataclass
import hashlib
import io
import math
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


REQUIRED_COLUMNS = (
    "timestamp_s",
    "heading_deg",
    "speed_mps",
    "cross_track_error_m",
    "dcpa_m",
    "command_latency_ms",
    "gnss_fix_valid",
    "manual_override_active",
    "emergency_stop_active",
)


def sha256_file(path: str | Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def parse_telemetry_csv(content: str) -> list[dict[str, Any]]:
    reader = csv.DictReader(io.StringIO(content))
    missing = [column for column in REQUIRED_COLUMNS if column not in (reader.fieldnames or [])]
    if missing:
        raise ValueError(f"sea-trial telemetry is missing columns: {missing}")
    rows: list[dict[str, Any]] = []
    previous = -math.inf
    for index, raw in enumerate(reader):
        timestamp = float(raw["timestamp_s"])
        if timestamp <= previous:
            raise ValueError(f"telemetry timestamp is not strictly increasing at row {index + 2}")
        previous = timestamp
        rows.append(
            {
                "timestamp_s": timestamp,
                "heading_deg": float(raw["heading_deg"]),
                "speed_mps": float(raw["speed_mps"]),
                "cross_track_error_m": float(raw["cross_track_error_m"]),
                "dcpa_m": float(raw["dcpa_m"]),
                "command_latency_ms": float(raw["command_latency_ms"]),
                "gnss_fix_valid": str(raw["gnss_fix_valid"]).strip().lower() in ("1", "true", "yes"),
                "manual_override_active": str(raw["manual_override_active"]).strip().lower() in ("1", "true", "yes"),
                "emergency_stop_active": str(raw["emergency_stop_active"]).strip().lower() in ("1", "true", "yes"),
            }
        )
    if len(rows) < 2:
        raise ValueError("sea-trial telemetry must contain at least two rows")
    return rows


def load_telemetry_csv(path: str | Path) -> list[dict[str, Any]]:
    return parse_telemetry_csv(Path(path).read_text(encoding="utf-8"))


def _percentile(values: Sequence[float], percentile: float) -> float:
    if not values:
        return float("nan")
    ordered = sorted(float(value) for value in values)
    position = (len(ordered) - 1) * percentile
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return ordered[lower] * (1.0 - fraction) + ordered[upper] * fraction


def evaluate_telemetry(rows: Sequence[Mapping[str, Any]], protocol: Mapping[str, Any]) -> dict[str, Any]:
    limits = protocol.get("acceptance_limits", {})
    timestamps = [float(row["timestamp_s"]) for row in rows]
    xte = [abs(float(row["cross_track_error_m"])) for row in rows]
    dcpa = [float(row["dcpa_m"]) for row in rows]
    latency = [float(row["command_latency_ms"]) for row in rows]
    metrics = {
        "duration_s": timestamps[-1] - timestamps[0],
        "sample_count": len(rows),
        "gnss_valid_ratio": sum(int(bool(row["gnss_fix_valid"])) for row in rows) / len(rows),
        "p95_cross_track_error_m": _percentile(xte, 0.95),
        "minimum_dcpa_m": min(dcpa),
        "p95_command_latency_ms": _percentile(latency, 0.95),
        "manual_override_observed": any(bool(row["manual_override_active"]) for row in rows),
        "emergency_stop_observed": any(bool(row["emergency_stop_active"]) for row in rows),
    }
    checks = {
        "minimum_duration": metrics["duration_s"] >= float(limits.get("minimum_duration_s", 300.0)),
        "gnss_availability": metrics["gnss_valid_ratio"] >= float(limits.get("minimum_gnss_valid_ratio", 0.995)),
        "cross_track_error": metrics["p95_cross_track_error_m"] <= float(limits.get("maximum_p95_cross_track_error_m", 15.0)),
        "closest_point_of_approach": metrics["minimum_dcpa_m"] >= float(limits.get("minimum_dcpa_m", 100.0)),
        "command_latency": metrics["p95_command_latency_ms"] <= float(limits.get("maximum_p95_command_latency_ms", 100.0)),
        "manual_override_demonstrated": bool(metrics["manual_override_observed"]),
        "emergency_stop_demonstrated": bool(metrics["emergency_stop_observed"]),
    }
    return {"metrics": metrics, "checks": checks, "metric_gate_passed": all(checks.values())}


@dataclass(frozen=True)
class SeaTrialEvidence:
    execution_context: str
    raw_log_path: str
    raw_log_sha256: str
    vessel_identifier: str
    trial_area: str
    authority_or_port_permission_reference: str
    master_or_operator_name: str
    independent_witness_name: str
    independent_witness_organization: str
    sensor_calibration_report_reference: str
    actuator_calibration_report_reference: str
    risk_assessment_reference: str
    signed_trial_record_reference: str
    physical_hil_report_reference: str
    physical_hil_verified: bool

    @classmethod
    def from_mapping(cls, value: Mapping[str, Any]) -> "SeaTrialEvidence":
        return cls(**{name: value.get(name, "") for name in cls.__dataclass_fields__})


def evaluate_sea_trial_gate(
    evidence: SeaTrialEvidence,
    protocol: Mapping[str, Any],
    rows: Sequence[Mapping[str, Any]] | None,
) -> dict[str, Any]:
    """Return PASS only for real-vessel evidence with provenance and metrics."""

    provenance_checks = {
        "real_vessel_context": evidence.execution_context == "real_vessel",
        "named_vessel": bool(evidence.vessel_identifier.strip()),
        "trial_area_recorded": bool(evidence.trial_area.strip()),
        "authority_permission": bool(evidence.authority_or_port_permission_reference.strip()),
        "master_or_operator": bool(evidence.master_or_operator_name.strip()),
        "independent_witness": bool(
            evidence.independent_witness_name.strip()
            and evidence.independent_witness_organization.strip()
        ),
        "sensor_calibration": bool(evidence.sensor_calibration_report_reference.strip()),
        "actuator_calibration": bool(evidence.actuator_calibration_report_reference.strip()),
        "risk_assessment": bool(evidence.risk_assessment_reference.strip()),
        "signed_trial_record": bool(evidence.signed_trial_record_reference.strip()),
        "physical_hil_prerequisite": bool(
            evidence.physical_hil_verified
            and evidence.physical_hil_report_reference.strip()
        ),
    }
    path = Path(evidence.raw_log_path).expanduser() if evidence.raw_log_path else None
    raw_log_exists = bool(path and path.is_file())
    raw_log_hash_matches = bool(
        raw_log_exists
        and evidence.raw_log_sha256
        and sha256_file(path) == evidence.raw_log_sha256
    )
    provenance_checks["raw_log_exists"] = raw_log_exists
    provenance_checks["raw_log_hash_matches"] = raw_log_hash_matches
    metric_result = evaluate_telemetry(rows, protocol) if rows else {
        "metrics": {},
        "checks": {},
        "metric_gate_passed": False,
    }
    package_complete = all(provenance_checks.values()) and bool(metric_result["metric_gate_passed"])
    return {
        "status": "READY_FOR_EXTERNAL_REVIEW" if package_complete else "BLOCKED_NO_REAL_VESSEL_EVIDENCE",
        "evidence_package_complete": package_complete,
        "sea_trial_completed": False,
        "external_authentication_required": True,
        "provenance_checks": provenance_checks,
        "telemetry_evaluation": metric_result,
        "protocol_id": str(protocol.get("protocol_id", "sea_trial_protocol_v1")),
        "boundary": "Software checks declared completeness, raw-log integrity and metrics only. It cannot authenticate a vessel, permit, person, witness, signature or calibration record, so it never declares the sea trial completed.",
    }


def run_sea_trial_dry_run(protocol: Mapping[str, Any]) -> dict[str, Any]:
    """Prove that good simulated metrics still cannot be labelled a sea trial."""

    duration = int(max(float(protocol.get("acceptance_limits", {}).get("minimum_duration_s", 300.0)), 300.0))
    rows: list[dict[str, Any]] = []
    for timestamp in range(duration + 1):
        rows.append(
            {
                "timestamp_s": float(timestamp),
                "heading_deg": 10.0,
                "speed_mps": 3.0,
                "cross_track_error_m": 2.0 + 0.5 * math.sin(timestamp / 10.0),
                "dcpa_m": 1000.0,
                "command_latency_ms": 20.0,
                "gnss_fix_valid": True,
                "manual_override_active": timestamp == duration // 2,
                "emergency_stop_active": timestamp == duration // 2 + 20,
            }
        )
    evidence = SeaTrialEvidence(
        execution_context="simulation",
        raw_log_path="",
        raw_log_sha256="",
        vessel_identifier="",
        trial_area="",
        authority_or_port_permission_reference="",
        master_or_operator_name="",
        independent_witness_name="",
        independent_witness_organization="",
        sensor_calibration_report_reference="",
        actuator_calibration_report_reference="",
        risk_assessment_reference="",
        signed_trial_record_reference="",
        physical_hil_report_reference="",
        physical_hil_verified=False,
    )
    result = evaluate_sea_trial_gate(evidence, protocol, rows)
    result["dry_run_metric_gate_passed"] = result["telemetry_evaluation"]["metric_gate_passed"]
    result["evidence_completeness_refusal_gate_passed"] = (
        result["dry_run_metric_gate_passed"]
        and not result["evidence_package_complete"]
        and not result["sea_trial_completed"]
        and result["status"] == "BLOCKED_NO_REAL_VESSEL_EVIDENCE"
    )
    return result
