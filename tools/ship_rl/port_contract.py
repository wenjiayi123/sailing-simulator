"""Validation and evidence summaries for replaceable real-port datasets."""

from __future__ import annotations

from datetime import datetime
import hashlib
import json
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


PORT_DATA_FACTORS = (
    "historical_ais",
    "shoreline_and_fixed_hazards",
    "bathymetry_or_depth_areas",
    "fairways_and_restricted_areas",
    "wind_wave_current",
    "visibility_and_tide",
    "vessel_dimensions_and_draft",
    "dynamic_traffic",
    "speed_limits",
    "colreg_encounter_context",
)

DEPLOYMENT_FACTORS = (
    "hydrographic_datum_and_ukc",
    "current_official_charts_and_notices",
    "local_vts_and_regulatory_rules",
    "pilotage_tug_and_berth_constraints",
    "live_traffic_weather_and_sensor_latency",
    "calibrated_vessel_manoeuvring",
    "certified_control_and_communications",
    "failsafe_redundancy_and_human_authority",
)


def _canonical_sha256(payload: Mapping[str, Any]) -> str:
    canonical = json.dumps(
        payload,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _timestamp(value: Any) -> datetime | None:
    text = str(value or "").strip().replace("Z", "+00:00")
    if not text:
        return None
    try:
        return datetime.fromisoformat(text)
    except ValueError:
        return None


def _features(shared: Mapping[str, Any], key: str) -> list[Mapping[str, Any]]:
    values = shared.get(key, [])
    if not isinstance(values, list):
        return []
    return [value for value in values if isinstance(value, Mapping)]


def _tasks(dataset: Mapping[str, Any]) -> Iterable[tuple[str, Mapping[str, Any]]]:
    splits = dataset.get("splits", {})
    if not isinstance(splits, Mapping):
        return
    for split in ("train", "validation", "test"):
        values = splits.get(split, [])
        if not isinstance(values, list):
            continue
        for task in values:
            if isinstance(task, Mapping):
                yield split, task


def validate_port_dataset(dataset: Mapping[str, Any]) -> dict[str, Any]:
    """Return a fail-closed readiness report without changing the dataset."""

    errors: list[str] = []
    warnings: list[str] = []
    schema = str(dataset.get("schema_version", ""))
    if schema != "ship_port_dataset_v3":
        errors.append("schema_version must be ship_port_dataset_v3")
    port = dataset.get("port", {})
    if not isinstance(port, Mapping) or not all(
        str(port.get(field, "")).strip()
        for field in ("id", "name", "country", "timezone")
    ):
        errors.append("port.id/name/country/timezone are required")
    coordinate_system = dataset.get("coordinate_system", {})
    if not isinstance(coordinate_system, Mapping):
        errors.append("coordinate_system is required")
    elif (
        coordinate_system.get("type") != "local_cartesian_meters"
        or coordinate_system.get("axes") != "x_east_z_north"
        or not isinstance(coordinate_system.get("origin_wgs84"), Mapping)
    ):
        errors.append("coordinate_system must define local x-east/z-north metres and WGS84 origin")

    splits = dataset.get("splits", {})
    if not isinstance(splits, Mapping):
        errors.append("splits must be an object")
        splits = {}
    split_sizes: dict[str, int] = {}
    split_times: dict[str, list[datetime]] = {}
    ids: set[str] = set()
    duplicate_ids: set[str] = set()
    route_points = 0
    dynamic_targets = 0
    mmsi_values: set[str] = set()
    tasks_with_vessel_dimensions = 0
    tasks_with_draft = 0
    tasks_with_weather = 0
    tasks_with_visibility = 0
    tasks_with_tide = 0
    tasks_with_speed_limit = 0
    task_count = 0
    for split in ("train", "validation", "test"):
        values = splits.get(split, [])
        if not isinstance(values, list) or not values:
            errors.append(f"split {split!r} must be a non-empty list")
            values = []
        split_sizes[split] = len(values)
        split_times[split] = []
        for task in values:
            if not isinstance(task, Mapping):
                errors.append(f"split {split!r} contains a non-object task")
                continue
            task_count += 1
            task_id = str(task.get("id", "")).strip()
            if not task_id:
                errors.append(f"split {split!r} contains a task without id")
            elif task_id in ids:
                duplicate_ids.add(task_id)
            else:
                ids.add(task_id)
            route = task.get("route", [])
            if not isinstance(route, list) or len(route) < 2:
                errors.append(f"task {task_id or '<unknown>'!r} needs at least two route points")
            else:
                route_points += len(route)
            start_time = _timestamp(
                task.get("start_timestamp")
                or (task.get("source_track", {}) or {}).get("start_time")
            )
            if start_time is None:
                errors.append(f"task {task_id or '<unknown>'!r} has no valid source start time")
            else:
                split_times[split].append(start_time)
            source_track = task.get("source_track", {})
            if isinstance(source_track, Mapping):
                mmsi = str(source_track.get("mmsi", "")).strip()
                if mmsi:
                    mmsi_values.add(mmsi)
            vessel = task.get("vessel_profile", {})
            if isinstance(vessel, Mapping):
                if float(vessel.get("length_meters", 0.0) or 0.0) > 0.0 and float(
                    vessel.get("width_meters", 0.0) or 0.0
                ) > 0.0:
                    tasks_with_vessel_dimensions += 1
                if float(vessel.get("draft_meters", 0.0) or 0.0) > 0.0:
                    tasks_with_draft += 1
            traffic = task.get("dynamic_obstacles", [])
            if isinstance(traffic, list):
                dynamic_targets += len(traffic)
            sea_state = task.get("sea_state", {})
            if isinstance(sea_state, Mapping):
                if all(
                    sea_state.get(field) is not None
                    for field in (
                        "wind_speed_knots",
                        "wave_height_meters",
                        "current_speed_knots",
                    )
                ):
                    tasks_with_weather += 1
                if sea_state.get("visibility_km") is not None:
                    tasks_with_visibility += 1
                if sea_state.get("tide_meters") is not None:
                    tasks_with_tide += 1
            navigation = task.get("navigation_context", {})
            if isinstance(navigation, Mapping) and float(
                navigation.get("speed_limit_knots", 0.0) or 0.0
            ) > 0.0:
                tasks_with_speed_limit += 1
    if duplicate_ids:
        errors.append(f"duplicate task ids: {sorted(duplicate_ids)[:5]}")

    for earlier, later in (("train", "validation"), ("validation", "test")):
        if split_times[earlier] and split_times[later]:
            if max(split_times[earlier]) >= min(split_times[later]):
                errors.append(
                    f"chronological isolation failed: {earlier} overlaps {later}"
                )

    shared = dataset.get("shared_environment", {})
    if not isinstance(shared, Mapping):
        shared = {}
        errors.append("shared_environment must be an object")
    terrain_count = len(_features(shared, "terrain"))
    obstacle_count = len(_features(shared, "obstacles"))
    depth_area_count = len(_features(shared, "depth_areas"))
    fairway_count = len(_features(shared, "fairways"))
    restricted_count = len(_features(shared, "restricted_areas"))
    traffic_scheme_count = len(_features(shared, "traffic_separation"))
    if terrain_count + obstacle_count == 0:
        errors.append("shared environment has no shoreline or fixed hazards")
    if depth_area_count == 0:
        errors.append("shared environment has no depth areas")
    if fairway_count == 0:
        warnings.append("no fairway polygons were supplied")
    if traffic_scheme_count == 0:
        warnings.append("no traffic-separation geometry was supplied")

    source = dataset.get("source", {})
    observed_ais = bool(
        isinstance(source, Mapping) and source.get("observed_ais") is True
    )
    if not observed_ais:
        errors.append("source.observed_ais must be true for the real-port contract")
    source_rows = int(source.get("filtered_ais_rows", 0) or 0) if isinstance(source, Mapping) else 0
    raw_files = source.get("raw_files", []) if isinstance(source, Mapping) else []
    if not isinstance(raw_files, list) or not raw_files:
        errors.append("source.raw_files must preserve original URLs and SHA-256 values")
    elif any(
        not isinstance(item, Mapping)
        or not str(item.get("url", "")).startswith("https://")
        or len(str(item.get("sha256", ""))) != 64
        for item in raw_files
    ):
        errors.append("every source.raw_files entry needs an HTTPS URL and SHA-256")

    denominator = max(task_count, 1)
    factor_coverage = {
        "historical_ais": observed_ais and source_rows > 0 and bool(raw_files),
        "shoreline_and_fixed_hazards": terrain_count + obstacle_count > 0,
        "bathymetry_or_depth_areas": depth_area_count > 0,
        "fairways_and_restricted_areas": fairway_count + restricted_count > 0,
        "wind_wave_current": tasks_with_weather == task_count and task_count > 0,
        "visibility_and_tide": (
            tasks_with_visibility == task_count
            and tasks_with_tide == task_count
            and task_count > 0
        ),
        "vessel_dimensions_and_draft": (
            tasks_with_vessel_dimensions == task_count
            and tasks_with_draft == task_count
            and task_count > 0
        ),
        "dynamic_traffic": dynamic_targets > 0,
        "speed_limits": tasks_with_speed_limit == task_count and task_count > 0,
        "colreg_encounter_context": dynamic_targets > 0,
    }
    research_required = (
        "historical_ais",
        "shoreline_and_fixed_hazards",
        "bathymetry_or_depth_areas",
        "wind_wave_current",
        "vessel_dimensions_and_draft",
        "dynamic_traffic",
        "speed_limits",
        "colreg_encounter_context",
    )
    research_ready = not errors and all(
        factor_coverage[name] for name in research_required
    )
    live = dataset.get("live_integration", {})
    deployment_factor_coverage = {
        "hydrographic_datum_and_ukc": bool(
            isinstance(live, Mapping)
            and live.get("hydrographic_datum_verified") is True
        ),
        "current_official_charts_and_notices": bool(
            isinstance(live, Mapping)
            and live.get("chart_update_verified") is True
            and live.get("notices_to_mariners_current") is True
        ),
        "local_vts_and_regulatory_rules": bool(
            isinstance(live, Mapping)
            and live.get("regulatory_rules_verified") is True
        ),
        "pilotage_tug_and_berth_constraints": bool(
            isinstance(live, Mapping)
            and live.get("pilotage_and_tug_rules_verified") is True
            and live.get("berth_geometry_verified") is True
        ),
        "live_traffic_weather_and_sensor_latency": bool(
            isinstance(live, Mapping)
            and live.get("telemetry_verified") is True
            and live.get("sensor_latency_validated") is True
        ),
        "calibrated_vessel_manoeuvring": bool(
            isinstance(live, Mapping)
            and live.get("vessel_model_calibrated") is True
        ),
        "certified_control_and_communications": bool(
            isinstance(live, Mapping)
            and live.get("control_interface_certified") is True
            and live.get("communications_verified") is True
        ),
        "failsafe_redundancy_and_human_authority": bool(
            isinstance(live, Mapping)
            and live.get("failsafe_redundancy_verified") is True
            and live.get("human_authority_configured") is True
        ),
    }
    live_control_ready = bool(
        research_ready
        and all(deployment_factor_coverage.values())
    )
    if not live_control_ready:
        warnings.append(
            "live control remains fail-closed until telemetry, chart updates, "
            "vessel calibration, control certification, and human authority are verified"
        )

    return {
        "schema_version": "ship_port_contract_report_v1",
        "dataset_sha256": _canonical_sha256(dataset),
        "port": dict(port) if isinstance(port, Mapping) else {},
        "split_sizes": split_sizes,
        "task_count": task_count,
        "route_point_count": route_points,
        "filtered_ais_rows": source_rows,
        "distinct_mmsi": len(mmsi_values),
        "dynamic_target_instances": dynamic_targets,
        "shared_feature_counts": {
            "terrain": terrain_count,
            "obstacles": obstacle_count,
            "depth_areas": depth_area_count,
            "fairways": fairway_count,
            "restricted_areas": restricted_count,
            "traffic_separation": traffic_scheme_count,
        },
        "task_field_coverage": {
            "vessel_dimensions": tasks_with_vessel_dimensions / denominator,
            "draft": tasks_with_draft / denominator,
            "wind_wave_current": tasks_with_weather / denominator,
            "visibility": tasks_with_visibility / denominator,
            "tide": tasks_with_tide / denominator,
            "speed_limit": tasks_with_speed_limit / denominator,
        },
        "factor_coverage": factor_coverage,
        "deployment_factor_coverage": deployment_factor_coverage,
        "research_training_ready": research_ready,
        "live_control_ready": live_control_ready,
        "errors": errors,
        "warnings": warnings,
    }


def validate_port_dataset_path(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, Mapping):
        raise ValueError("port dataset root must be an object")
    return validate_port_dataset(payload)
