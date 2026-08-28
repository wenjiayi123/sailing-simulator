"""Named-vessel trial ingestion, identification and error-envelope gates.

The module never edits the checked-in plant. It compares a frozen candidate
model with timestamped manoeuvring trials and emits a candidate calibration
package for independent review. Simulation data can exercise the functions but
cannot establish named-vessel calibration.
"""

from __future__ import annotations

import csv
import hashlib
import json
import math
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

import numpy as np

from tools.cargo_rl.catamaran_physics import TwinWaterjetCatamaran
from tools.ship_assurance.dynamics import identify_first_order_nomoto


SCHEMA = "named_vessel_twin_manifest_v1"
REQUIRED_MANEUVERS = (
    "turning_circle_port",
    "turning_circle_starboard",
    "zigzag_10_10",
    "zigzag_20_20",
    "stopping_full_ahead_to_stop",
    "acceleration",
    "deceleration",
)
REQUIRED_LOADING_CONDITIONS = ("lightship", "design_payload", "maximum_operating")
REQUIRED_COLUMNS = (
    "timestamp_s",
    "east_m",
    "north_m",
    "heading_deg",
    "surge_mps",
    "sway_mps",
    "yaw_rate_deg_s",
    "throttle_command",
    "steering_command",
    "steering_angle_deg",
)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _nonempty(value: Any) -> bool:
    return value is not None and str(value).strip() != ""


def _finite(value: Any) -> bool:
    try:
        return math.isfinite(float(value))
    except (TypeError, ValueError):
        return False


def _percentile(values: Sequence[float], percentile: float) -> float:
    return float(np.percentile(np.asarray(values, dtype=np.float64), percentile))


def _angle_error_degrees(actual: float, predicted: float) -> float:
    return (float(predicted) - float(actual) + 180.0) % 360.0 - 180.0


def read_trial_csv(path: Path) -> list[dict[str, float]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        missing = [name for name in REQUIRED_COLUMNS if name not in (reader.fieldnames or [])]
        if missing:
            raise ValueError(f"trial CSV missing columns: {missing}")
        rows: list[dict[str, float]] = []
        for index, raw in enumerate(reader, start=2):
            try:
                row = {
                    key: float(raw.get(key, 0.0) or 0.0)
                    for key in (reader.fieldnames or [])
                }
            except ValueError as error:
                raise ValueError(f"trial CSV row {index} contains non-numeric data") from error
            if not all(_finite(row[name]) for name in REQUIRED_COLUMNS):
                raise ValueError(f"trial CSV row {index} contains non-finite required data")
            rows.append(row)
    validate_trial_samples(rows)
    return rows


def validate_trial_samples(rows: Sequence[Mapping[str, float]], minimum_samples: int = 8) -> None:
    if len(rows) < int(minimum_samples):
        raise ValueError(f"trial requires at least {minimum_samples} samples")
    timestamps = [float(row["timestamp_s"]) for row in rows]
    if not all(right > left for left, right in zip(timestamps, timestamps[1:])):
        raise ValueError("trial timestamps must be strictly increasing")
    if max(np.diff(np.asarray(timestamps))) > 1.0:
        raise ValueError("trial has a timestamp gap greater than one second")


def _forcing(row: Mapping[str, float]) -> dict[str, float]:
    return {
        "current_east_mps": float(row.get("current_east_mps", 0.0)),
        "current_north_mps": float(row.get("current_north_mps", 0.0)),
        "wind_force_body_x_n": float(row.get("wind_force_body_x_n", 0.0)),
        "wind_force_body_y_n": float(row.get("wind_force_body_y_n", 0.0)),
        "wave_force_body_x_n": float(row.get("wave_force_body_x_n", 0.0)),
        "wave_force_body_y_n": float(row.get("wave_force_body_y_n", 0.0)),
        "environment_yaw_moment_nm": float(row.get("environment_yaw_moment_nm", 0.0)),
    }


def replay_frozen_model(
    rows: Sequence[Mapping[str, float]], config: Mapping[str, Any]
) -> list[dict[str, float]]:
    validate_trial_samples(rows)
    model = TwinWaterjetCatamaran(config)
    model.reset(math.radians(float(rows[0]["heading_deg"])), float(rows[0]["surge_mps"]))
    east = float(rows[0]["east_m"])
    north = float(rows[0]["north_m"])
    predictions = [
        {
            "timestamp_s": float(rows[0]["timestamp_s"]),
            "east_m": east,
            "north_m": north,
            "heading_deg": float(rows[0]["heading_deg"]),
            "surge_mps": float(rows[0]["surge_mps"]),
            "sway_mps": 0.0,
            "yaw_rate_deg_s": 0.0,
        }
    ]
    for previous, current in zip(rows, rows[1:]):
        dt = float(current["timestamp_s"]) - float(previous["timestamp_s"])
        status = model.step(
            float(previous["throttle_command"]),
            float(previous["steering_command"]),
            dt,
            _forcing(previous),
        )
        velocity = status["ground_velocity"]
        east += float(velocity[0]) * dt
        north += float(velocity[1]) * dt
        predictions.append(
            {
                "timestamp_s": float(current["timestamp_s"]),
                "east_m": east,
                "north_m": north,
                "heading_deg": math.degrees(float(status["heading_rad"])) % 360.0,
                "surge_mps": float(status["surge_mps"]),
                "sway_mps": float(status["sway_mps"]),
                "yaw_rate_deg_s": float(status["yaw_rate_deg_s"]),
            }
        )
    return predictions


def error_envelope(
    measured: Sequence[Mapping[str, float]], predicted: Sequence[Mapping[str, float]]
) -> dict[str, float]:
    if len(measured) != len(predicted) or not measured:
        raise ValueError("measured and predicted trajectories must align")
    position_errors = [
        math.hypot(float(p["east_m"]) - float(m["east_m"]), float(p["north_m"]) - float(m["north_m"]))
        for m, p in zip(measured, predicted)
    ]
    heading_errors = [abs(_angle_error_degrees(float(m["heading_deg"]), float(p["heading_deg"]))) for m, p in zip(measured, predicted)]
    speed_errors = [float(p["surge_mps"]) - float(m["surge_mps"]) for m, p in zip(measured, predicted)]
    yaw_errors = [float(p["yaw_rate_deg_s"]) - float(m["yaw_rate_deg_s"]) for m, p in zip(measured, predicted)]
    return {
        "position_error_rmse_m": float(np.sqrt(np.mean(np.square(position_errors)))),
        "position_error_p95_m": _percentile(position_errors, 95.0),
        "position_error_max_m": max(position_errors),
        "heading_error_rmse_deg": float(np.sqrt(np.mean(np.square(heading_errors)))),
        "heading_error_p95_deg": _percentile(heading_errors, 95.0),
        "heading_error_max_deg": max(heading_errors),
        "surge_speed_rmse_mps": float(np.sqrt(np.mean(np.square(speed_errors)))),
        "surge_speed_p95_abs_mps": _percentile([abs(value) for value in speed_errors], 95.0),
        "yaw_rate_rmse_deg_s": float(np.sqrt(np.mean(np.square(yaw_errors)))),
        "yaw_rate_p95_abs_deg_s": _percentile([abs(value) for value in yaw_errors], 95.0),
        "sample_count": float(len(measured)),
    }


def _unwrapped_heading(rows: Sequence[Mapping[str, float]]) -> np.ndarray:
    radians = np.radians([float(row["heading_deg"]) for row in rows])
    return np.degrees(np.unwrap(radians))


def manoeuvre_metrics(maneuver: str, rows: Sequence[Mapping[str, float]]) -> dict[str, Any]:
    validate_trial_samples(rows)
    times = np.asarray([float(row["timestamp_s"]) for row in rows])
    east = np.asarray([float(row["east_m"]) for row in rows])
    north = np.asarray([float(row["north_m"]) for row in rows])
    speed = np.asarray([abs(float(row["surge_mps"])) for row in rows])
    headings = _unwrapped_heading(rows)
    heading_delta = headings - headings[0]
    result: dict[str, Any] = {
        "duration_seconds": float(times[-1] - times[0]),
        "path_length_m": float(np.sum(np.hypot(np.diff(east), np.diff(north)))),
        "maximum_speed_mps": float(np.max(speed)),
        "maximum_abs_yaw_rate_deg_s": max(abs(float(row["yaw_rate_deg_s"])) for row in rows),
    }
    if maneuver.startswith("turning_circle"):
        direction = -1.0 if maneuver.endswith("port") else 1.0
        signed = heading_delta * direction
        index_90 = int(np.argmax(signed >= 90.0)) if np.any(signed >= 90.0) else -1
        index_180 = int(np.argmax(signed >= 180.0)) if np.any(signed >= 180.0) else -1
        result.update(
            {
                "advance_at_90_deg_m": None if index_90 < 0 else float(north[index_90] - north[0]),
                "transfer_at_90_deg_m": None if index_90 < 0 else abs(float(east[index_90] - east[0])),
                "tactical_diameter_m": None if index_180 < 0 else abs(float(east[index_180] - east[0])),
                "completed_180_deg": index_180 >= 0,
            }
        )
    elif maneuver.startswith("zigzag"):
        commanded = np.asarray([float(row["steering_command"]) for row in rows])
        reversals = np.where(np.sign(commanded[1:]) != np.sign(commanded[:-1]))[0] + 1
        overshoots: list[float] = []
        for left, right in zip(reversals, list(reversals[1:]) + [len(rows) - 1]):
            segment = heading_delta[left : right + 1]
            if len(segment):
                overshoots.append(float(np.max(np.abs(segment))))
        result.update({"steering_reversal_count": int(len(reversals)), "heading_overshoot_peaks_deg": overshoots[:4]})
    elif maneuver.startswith("stopping"):
        initial = max(float(speed[0]), 0.01)
        stopped = np.where(speed <= max(initial * 0.05, 0.15))[0]
        index = int(stopped[0]) if len(stopped) else len(rows) - 1
        result.update(
            {
                "stopping_time_s": float(times[index] - times[0]),
                "stopping_distance_m": float(np.sum(np.hypot(np.diff(east[: index + 1]), np.diff(north[: index + 1])))),
                "stop_threshold_reached": bool(len(stopped)),
            }
        )
    else:
        low = float(speed[0])
        high = float(np.max(speed))
        target_90 = low + 0.9 * (high - low)
        reached = np.where(speed >= target_90)[0]
        result["time_to_90_percent_s"] = None if not len(reached) else float(times[int(reached[0])] - times[0])
    return result


def identify_response(rows: Sequence[Mapping[str, float]]) -> dict[str, Any]:
    validate_trial_samples(rows)
    time = np.asarray([float(row["timestamp_s"]) for row in rows])
    speed = np.asarray([float(row["surge_mps"]) for row in rows])
    throttle = np.asarray([float(row["throttle_command"]) for row in rows])
    response: dict[str, Any] = {}
    derivative = np.gradient(speed, time)
    design = np.column_stack((speed, throttle, np.ones_like(speed)))
    coefficients, *_ = np.linalg.lstsq(design, derivative, rcond=None)
    a, b, bias = (float(item) for item in coefficients)
    predicted = design @ coefficients
    residual = derivative - predicted
    response["surge_first_order"] = {
        "stable": a < -1e-9,
        "time_constant_s": None if a >= -1e-9 else -1.0 / a,
        "steady_speed_gain_mps_per_throttle": None if a >= -1e-9 else -b / a,
        "bias_mps2": bias,
        "derivative_rmse_mps2": float(np.sqrt(np.mean(np.square(residual)))),
    }
    try:
        response["nomoto_first_order"] = identify_first_order_nomoto(
            time,
            np.radians([float(row["yaw_rate_deg_s"]) for row in rows]),
            np.radians([float(row["steering_angle_deg"]) for row in rows]),
        )
    except ValueError as error:
        response["nomoto_first_order"] = {"identified": False, "reason": str(error)}
    return response


def assess_trial(
    trial_id: str,
    maneuver: str,
    loading_condition: str,
    rows: Sequence[Mapping[str, float]],
    config: Mapping[str, Any],
    thresholds: Mapping[str, Any],
) -> dict[str, Any]:
    predictions = replay_frozen_model(rows, config)
    envelope = error_envelope(rows, predictions)
    passed = (
        envelope["position_error_p95_m"] <= float(thresholds["position_error_p95_m"])
        and envelope["heading_error_p95_deg"] <= float(thresholds["heading_error_p95_deg"])
        and envelope["surge_speed_rmse_mps"] <= float(thresholds["surge_speed_rmse_mps"])
        and envelope["yaw_rate_rmse_deg_s"] <= float(thresholds["yaw_rate_rmse_deg_s"])
    )
    return {
        "trial_id": trial_id,
        "maneuver": maneuver,
        "loading_condition": loading_condition,
        "sample_count": len(rows),
        "maneuver_metrics": manoeuvre_metrics(maneuver, rows),
        "identified_response": identify_response(rows),
        "error_envelope": envelope,
        "thresholds_passed": passed,
    }


def _aggregate_envelopes(results: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    if not results:
        return {}
    fields = (
        "position_error_p95_m",
        "heading_error_p95_deg",
        "surge_speed_rmse_mps",
        "yaw_rate_rmse_deg_s",
    )
    return {
        field: {
            "maximum": max(float(item["error_envelope"][field]) for item in results),
            "median": float(np.median([float(item["error_envelope"][field]) for item in results])),
        }
        for field in fields
    }


def _aggregate_identification(results: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    fields = {
        "surge_time_constant_s": [],
        "surge_speed_gain_mps_per_throttle": [],
        "nomoto_time_constant_s": [],
        "nomoto_gain_radps_per_rad": [],
    }
    for result in results:
        identified = result.get("identified_response", {})
        surge = identified.get("surge_first_order", {})
        nomoto = identified.get("nomoto_first_order", {})
        mappings = (
            ("surge_time_constant_s", surge.get("time_constant_s")),
            ("surge_speed_gain_mps_per_throttle", surge.get("steady_speed_gain_mps_per_throttle")),
            ("nomoto_time_constant_s", nomoto.get("nomoto_time_constant_s")),
            ("nomoto_gain_radps_per_rad", nomoto.get("nomoto_gain_radps_per_rad")),
        )
        for key, value in mappings:
            if _finite(value):
                fields[key].append(float(value))
    summary: dict[str, Any] = {}
    for key, values in fields.items():
        summary[key] = {
            "identified_trial_count": len(values),
            "median": None if not values else float(np.median(values)),
            "p05": None if not values else _percentile(values, 5.0),
            "p95": None if not values else _percentile(values, 95.0),
        }
    return summary


def _envelopes_by_loading_condition(
    results: Sequence[Mapping[str, Any]],
) -> dict[str, Any]:
    return {
        loading: _aggregate_envelopes(
            [item for item in results if item.get("loading_condition") == loading]
        )
        for loading in REQUIRED_LOADING_CONDITIONS
    }


def evaluate_manifest(
    manifest: Mapping[str, Any],
    *,
    manifest_path: Path,
    dynamics_config_path: Path,
) -> dict[str, Any]:
    errors: list[str] = []
    if manifest.get("schema_version") != SCHEMA:
        errors.append(f"schema_version must be {SCHEMA}")
    identity = manifest.get("vessel_identity", {})
    for key in (
        "vessel_name",
        "official_number_or_mmsi",
        "builder_and_hull_number",
        "length_overall_m",
        "beam_m",
        "propulsion_description",
        "steering_description",
    ):
        if not _nonempty(identity.get(key)):
            errors.append(f"vessel_identity.{key} is required")
    instrumentation = manifest.get("instrumentation", {})
    for key in (
        "gnss_ins_model_and_serial",
        "command_logger_model_and_serial",
        "time_synchronization_reference",
        "position_heading_calibration_reference",
        "actuator_feedback_calibration_reference",
        "environment_measurement_reference",
    ):
        if not _nonempty(instrumentation.get(key)):
            errors.append(f"instrumentation.{key} is required")

    load_records = {str(item.get("id", "")): item for item in manifest.get("loading_conditions", [])}
    missing_loads = [name for name in REQUIRED_LOADING_CONDITIONS if name not in load_records]
    errors.extend(f"loading condition {name} is missing" for name in missing_loads)
    for load_id, record in load_records.items():
        for key in (
            "displacement_kg",
            "longitudinal_cg_m",
            "transverse_cg_m",
            "draft_fore_m",
            "draft_aft_m",
            "payload_description",
            "measurement_reference",
        ):
            if not _nonempty(record.get(key)):
                errors.append(f"loading_conditions.{load_id}.{key} is required")

    config = json.loads(dynamics_config_path.read_text(encoding="utf-8"))
    thresholds = manifest.get("acceptance_thresholds", {})
    minimum_samples = int(thresholds.get("minimum_samples_per_trial", 120))
    covered_maneuvers: set[str] = set()
    covered_loads: dict[str, int] = {name: 0 for name in REQUIRED_LOADING_CONDITIONS}
    trial_results: list[dict[str, Any]] = []
    # Evidence hashes are keyed by semantic identifiers rather than host paths so
    # checked-in reports remain portable and do not disclose local directories.
    input_hashes: dict[str, str] = {
        "dynamics_config": _sha256(dynamics_config_path)
    }
    for index, raw_trial in enumerate(manifest.get("trials", [])):
        trial = dict(raw_trial)
        trial_id = str(trial.get("id", f"trial-{index}"))
        maneuver = str(trial.get("maneuver", ""))
        loading = str(trial.get("loading_condition", ""))
        if maneuver not in REQUIRED_MANEUVERS:
            errors.append(f"{trial_id}: unsupported maneuver {maneuver}")
            continue
        if loading not in REQUIRED_LOADING_CONDITIONS:
            errors.append(f"{trial_id}: unsupported loading condition {loading}")
            continue
        for key in ("trial_date_utc", "operator", "witness", "weather_reference", "raw_data_sha256"):
            if not _nonempty(trial.get(key)):
                errors.append(f"{trial_id}: {key} is required")
        raw_path = str(trial.get("data_file", ""))
        if not raw_path:
            errors.append(f"{trial_id}: data_file is required")
            continue
        path = Path(raw_path)
        if not path.is_absolute():
            path = (manifest_path.parent / path).resolve()
        if not path.exists():
            errors.append(f"{trial_id}: data file is missing")
            continue
        actual_hash = _sha256(path)
        input_hashes[f"trial::{trial_id}"] = actual_hash
        if actual_hash != str(trial.get("raw_data_sha256", "")):
            errors.append(f"{trial_id}: raw_data_sha256 mismatch")
            continue
        try:
            rows = read_trial_csv(path)
            validate_trial_samples(rows, minimum_samples)
            result = assess_trial(trial_id, maneuver, loading, rows, config, thresholds)
        except ValueError as error:
            errors.append(f"{trial_id}: {error}")
            continue
        covered_maneuvers.add(maneuver)
        covered_loads[loading] += 1
        trial_results.append(result)

    missing_maneuvers = [name for name in REQUIRED_MANEUVERS if name not in covered_maneuvers]
    minimum_per_load = int(thresholds.get("minimum_trials_per_loading_condition", 2))
    insufficient_loads = [name for name, count in covered_loads.items() if count < minimum_per_load]
    errors.extend(f"required maneuver {name} has no valid trial" for name in missing_maneuvers)
    errors.extend(f"loading condition {name} has fewer than {minimum_per_load} valid trials" for name in insufficient_loads)
    review = manifest.get("independent_review", {})
    review_complete = all(_nonempty(review.get(key)) for key in ("reviewer_name", "organization", "review_record_reference", "witnessed_trial_reference"))
    if not review_complete:
        errors.append("independent review evidence is incomplete")
    thresholds_passed = bool(trial_results) and all(bool(item["thresholds_passed"]) for item in trial_results)
    evidence_complete = not errors and thresholds_passed
    status = "CALIBRATION_CANDIDATE_READY_FOR_INDEPENDENT_ACCEPTANCE" if evidence_complete else "BLOCKED_NAMED_VESSEL_EVIDENCE_INCOMPLETE"
    return {
        "schema_version": "named_vessel_twin_assessment_v1",
        "manifest_id": manifest.get("manifest_id", ""),
        "vessel_identity": identity,
        "status": status,
        "evidence_package_complete": evidence_complete,
        "required_maneuvers": list(REQUIRED_MANEUVERS),
        "covered_maneuvers": sorted(covered_maneuvers),
        "missing_maneuvers": missing_maneuvers,
        "loading_condition_trial_counts": covered_loads,
        "insufficient_loading_conditions": insufficient_loads,
        "trial_results": trial_results,
        "cross_trial_error_envelope": _aggregate_envelopes(trial_results),
        "error_envelope_by_loading_condition": _envelopes_by_loading_condition(trial_results),
        "identified_parameter_summary": _aggregate_identification(trial_results),
        "thresholds_passed": thresholds_passed,
        "independent_review_complete": review_complete,
        "errors": errors,
        "inputs_sha256": input_hashes,
        "candidate_parameters_apply_automatically": False,
        "existing_model_modified": False,
        "named_vessel_dynamics_calibrated": False,
        "production_authority": False,
        "boundary": "A complete package is only a calibration candidate for independent acceptance. This tool never self-asserts named-vessel calibration or edits the frozen model.",
    }


def build_functional_smoke(
    dynamics_config: Mapping[str, Any], *, samples_per_trial: int = 180
) -> dict[str, Any]:
    """Exercise every manoeuvre and loading bucket using simulator-only rows."""

    thresholds = {
        "position_error_p95_m": 5.0,
        "heading_error_p95_deg": 5.0,
        "surge_speed_rmse_mps": 0.5,
        "yaw_rate_rmse_deg_s": 1.5,
    }
    results: list[dict[str, Any]] = []
    for index, maneuver in enumerate(REQUIRED_MANEUVERS):
        loading = REQUIRED_LOADING_CONDITIONS[index % len(REQUIRED_LOADING_CONDITIONS)]
        rows = _synthetic_trial(maneuver, dynamics_config, samples_per_trial)
        results.append(
            assess_trial(
                f"SIM-{index + 1:02d}", maneuver, loading, rows, dynamics_config, thresholds
            )
        )
    return {
        "schema_version": "named_vessel_twin_functional_smoke_v1",
        "passed": all(bool(item["thresholds_passed"]) for item in results),
        "maneuver_count": len(results),
        "loading_conditions_covered": sorted({item["loading_condition"] for item in results}),
        "trial_results": results,
        "cross_trial_error_envelope": _aggregate_envelopes(results),
        "error_envelope_by_loading_condition": _envelopes_by_loading_condition(results),
        "identified_parameter_summary": _aggregate_identification(results),
        "source_class": "SIMULATOR_GENERATED_FUNCTIONAL_SMOKE",
        "training_performed": False,
        "existing_model_modified": False,
        "named_vessel_dynamics_calibrated": False,
        "production_authority": False,
        "boundary": "Algorithm and schema smoke only. Simulator-generated trials cannot validate a named vessel.",
    }


def _synthetic_trial(
    maneuver: str, config: Mapping[str, Any], sample_count: int
) -> list[dict[str, float]]:
    dt = 0.25
    model = TwinWaterjetCatamaran(config)
    initial_speed = 0.0
    if maneuver in ("stopping_full_ahead_to_stop", "deceleration"):
        for _ in range(240):
            status = model.step(0.72, 0.0, dt)
        initial_speed = float(status["surge_mps"])
    model.reset(0.0, initial_speed)
    east = north = 0.0
    rows: list[dict[str, float]] = []
    steering_sign = 1.0
    next_reversal = 10.0 if maneuver == "zigzag_10_10" else 20.0
    for index in range(sample_count):
        time_s = index * dt
        throttle = 0.58
        steering = 0.0
        if maneuver == "turning_circle_port":
            steering = -0.62 if time_s >= 4.0 else 0.0
        elif maneuver == "turning_circle_starboard":
            steering = 0.62 if time_s >= 4.0 else 0.0
        elif maneuver.startswith("zigzag"):
            heading = math.degrees(model.heading_rad)
            if steering_sign > 0.0 and heading >= next_reversal:
                steering_sign = -1.0
            elif steering_sign < 0.0 and heading <= -next_reversal:
                steering_sign = 1.0
            steering = steering_sign * (0.42 if maneuver == "zigzag_10_10" else 0.68)
        elif maneuver == "stopping_full_ahead_to_stop":
            throttle = -0.25 if time_s < 12.0 else 0.0
        elif maneuver == "acceleration":
            throttle = 0.72
        elif maneuver == "deceleration":
            throttle = 0.16
        status = model.status()
        velocity = status["ground_velocity"]
        noise_phase = index * 0.17
        rows.append(
            {
                "timestamp_s": time_s,
                "east_m": east + 0.03 * math.sin(noise_phase),
                "north_m": north + 0.03 * math.cos(noise_phase),
                "heading_deg": (math.degrees(float(status["heading_rad"])) + 0.05 * math.sin(noise_phase)) % 360.0,
                "surge_mps": float(status["surge_mps"]) + 0.01 * math.sin(noise_phase),
                "sway_mps": float(status["sway_mps"]),
                "yaw_rate_deg_s": float(status["yaw_rate_deg_s"]) + 0.01 * math.cos(noise_phase),
                "throttle_command": throttle,
                "steering_command": steering,
                "steering_angle_deg": float(status["steering_angle_deg"]),
                "current_east_mps": 0.0,
                "current_north_mps": 0.0,
                "wind_force_body_x_n": 0.0,
                "wind_force_body_y_n": 0.0,
                "wave_force_body_x_n": 0.0,
                "wave_force_body_y_n": 0.0,
                "environment_yaw_moment_nm": 0.0,
            }
        )
        status = model.step(throttle, steering, dt)
        velocity = status["ground_velocity"]
        east += float(velocity[0]) * dt
        north += float(velocity[1]) * dt
    return rows
