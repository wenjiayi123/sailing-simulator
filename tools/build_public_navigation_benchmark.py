#!/usr/bin/env python3
"""Build the fixed Long Beach public-weather navigation benchmark.

The public inputs are model/reanalysis products, not port telemetry or measured
ship-control outcomes. They supply environmental forcing only. Routes, hazards,
vessel dynamics, and counterfactual actions remain explicit simulator fixtures.
"""

from __future__ import annotations

import argparse
import csv
from datetime import date, datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import urllib.parse
import urllib.request
from typing import Any, Iterable, Mapping


ROOT = Path(__file__).resolve().parents[1]
START_DATE = date(2024, 1, 1)
END_DATE = date(2024, 4, 30)
LATITUDE = 33.73
LONGITUDE = -118.27
MARINE_ENDPOINT = "https://marine-api.open-meteo.com/v1/marine"
WEATHER_ENDPOINT = "https://archive-api.open-meteo.com/v1/archive"
DEFAULT_HOURLY = ROOT / "data/public/long_beach_open_meteo_2024_01_04_hourly.csv"
DEFAULT_PROVENANCE = ROOT / "data/public/long_beach_open_meteo_2024_01_04.provenance.json"
DEFAULT_DATASET = ROOT / "data/rl/long_beach_public_weather_benchmark_v1.json"


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _write_text_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(text, encoding="utf-8")
    temporary.replace(path)


def _write_json(path: Path, payload: Mapping[str, Any]) -> None:
    _write_text_atomic(path, json.dumps(payload, ensure_ascii=False, indent=2) + "\n")


def _request_json(endpoint: str, parameters: Mapping[str, Any]) -> tuple[dict[str, Any], str]:
    url = f"{endpoint}?{urllib.parse.urlencode(parameters)}"
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "sailing-simulator-public-benchmark/1.0"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response), url


def _series(payload: Mapping[str, Any], name: str) -> list[Any]:
    values = payload.get("hourly", {}).get(name)
    if not isinstance(values, list):
        raise ValueError(f"missing hourly series: {name}")
    return values


def _finite(value: Any, field: str, timestamp: str) -> float:
    if value is None:
        raise ValueError(f"{field} is missing at {timestamp}")
    result = float(value)
    if not math.isfinite(result):
        raise ValueError(f"{field} is not finite at {timestamp}")
    return result


def fetch_hourly_records() -> tuple[list[dict[str, Any]], dict[str, Any]]:
    common = {
        "latitude": LATITUDE,
        "longitude": LONGITUDE,
        "start_date": START_DATE.isoformat(),
        "end_date": END_DATE.isoformat(),
        "timezone": "UTC",
        "cell_selection": "sea",
    }
    marine, marine_url = _request_json(
        MARINE_ENDPOINT,
        {
            **common,
            "hourly": (
                "wave_height,wave_direction,wave_period,"
                "ocean_current_velocity,ocean_current_direction"
            ),
            "wind_speed_unit": "kn",
        },
    )
    weather, weather_url = _request_json(
        WEATHER_ENDPOINT,
        {
            **common,
            "hourly": "wind_speed_10m,wind_direction_10m",
            "wind_speed_unit": "kn",
        },
    )
    timestamps = _series(marine, "time")
    if timestamps != _series(weather, "time"):
        raise ValueError("marine and weather hourly timestamps do not align")
    expected_hours = 121 * 24
    if len(timestamps) != expected_hours:
        raise ValueError(f"expected {expected_hours} hourly rows, found {len(timestamps)}")
    columns = {
        "wind_speed_knots": _series(weather, "wind_speed_10m"),
        "wind_direction_degrees": _series(weather, "wind_direction_10m"),
        "wave_height_meters": _series(marine, "wave_height"),
        "wave_direction_degrees": _series(marine, "wave_direction"),
        "wave_period_seconds": _series(marine, "wave_period"),
        "current_speed_knots": _series(marine, "ocean_current_velocity"),
        "current_direction_degrees": _series(marine, "ocean_current_direction"),
    }
    records: list[dict[str, Any]] = []
    for index, raw_timestamp in enumerate(timestamps):
        timestamp = f"{raw_timestamp}:00Z"
        row = {"timestamp": timestamp}
        for field, values in columns.items():
            row[field] = round(_finite(values[index], field, timestamp), 6)
        records.append(row)
    provenance = {
        "schema_version": "ship_public_environment_provenance_v1",
        "dataset_id": "open_meteo_long_beach_2024_01_04_hourly",
        "provider": "Open-Meteo",
        "upstream": (
            "ERA5/ECMWF historical weather reanalysis and archived marine "
            "forecast/model products selected by Open-Meteo"
        ),
        "license": "CC BY 4.0; attribution required",
        "documentation": [
            "https://open-meteo.com/en/docs/historical-weather-api",
            "https://open-meteo.com/en/docs/marine-weather-api",
            "https://open-meteo.com/en/license",
        ],
        "request_urls": [weather_url, marine_url],
        "location": {
            "name": "Long Beach adjacent waters",
            "latitude": LATITUDE,
            "longitude": LONGITUDE,
            "crs": "WGS84",
        },
        "period": {
            "start": START_DATE.isoformat(),
            "end": END_DATE.isoformat(),
            "hours": len(records),
        },
        "evidence_level": "public_model_reanalysis_and_archive",
        "live_data_verified": False,
        "navigation_suitability": (
            "not suitable for coastal navigation; used only as offline "
            "environmental forcing for a simulator benchmark"
        ),
        "retrieved_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
    }
    return records, provenance


def _write_hourly_csv(path: Path, records: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = list(records[0])
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        writer.writerows(records)
    temporary.replace(path)


def _read_hourly_csv(path: Path) -> list[dict[str, Any]]:
    with path.open("r", newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    records: list[dict[str, Any]] = []
    for row in rows:
        records.append(
            {
                "timestamp": row["timestamp"],
                **{
                    key: float(value)
                    for key, value in row.items()
                    if key != "timestamp"
                },
            }
        )
    return records


def _percentile(values: Iterable[float], fraction: float) -> float:
    ordered = sorted(float(value) for value in values)
    if not ordered:
        return 0.0
    index = round((len(ordered) - 1) * fraction)
    return ordered[index]


def _direction_at_peak(rows: list[dict[str, Any]], value_key: str, direction_key: str) -> float:
    selected = max(rows, key=lambda row: float(row[value_key]))
    return float(selected[direction_key])


def _route_templates() -> tuple[dict[str, Any], ...]:
    return (
        {
            "name": "harbor_approach",
            "start": {"x": -140.0, "z": -100.0, "heading_degrees": 58.0},
            "route": [
                {"x": -100.0, "z": -75.0},
                {"x": -50.0, "z": -45.0},
                {"x": 0.0, "z": -20.0},
                {"x": 55.0, "z": 10.0},
                {"x": 100.0, "z": 45.0},
            ],
            "obstacles": [
                {
                    "name": "east_breakwater",
                    "kind": "breakwater",
                    "shape": "box",
                    "position": {"x": 12.0, "z": 34.0},
                    "size": {"x": 18.0, "z": 38.0},
                }
            ],
            "terrain": [
                {
                    "name": "west_shoal",
                    "kind": "shoal",
                    "shape": "circle",
                    "x": -62.0,
                    "z": 4.0,
                    "radius": 16.0,
                }
            ],
            "dynamic_obstacles": [
                {
                    "name": "crossing_service_vessel",
                    "kind": "traffic",
                    "shape": "circle",
                    "x": 30.0,
                    "z": 55.0,
                    "radius": 5.0,
                    "course_degrees": 190.0,
                    "speed_knots": 4.0,
                }
            ],
        },
        {
            "name": "channel_turn",
            "start": {"x": -130.0, "z": 85.0, "heading_degrees": 122.0},
            "route": [
                {"x": -92.0, "z": 60.0},
                {"x": -48.0, "z": 28.0},
                {"x": -5.0, "z": -5.0},
                {"x": 48.0, "z": -48.0},
                {"x": 102.0, "z": -88.0},
            ],
            "obstacles": [
                {
                    "name": "north_pier",
                    "kind": "pier",
                    "shape": "box",
                    "position": {"x": -18.0, "z": 52.0},
                    "size": {"x": 38.0, "z": 14.0},
                }
            ],
            "terrain": [
                {
                    "name": "south_reef",
                    "kind": "reef",
                    "shape": "circle",
                    "x": 34.0,
                    "z": -96.0,
                    "radius": 14.0,
                }
            ],
            "dynamic_obstacles": [
                {
                    "name": "outbound_ferry",
                    "kind": "traffic",
                    "shape": "circle",
                    "x": 20.0,
                    "z": -4.0,
                    "radius": 6.0,
                    "course_degrees": 305.0,
                    "speed_knots": 5.0,
                }
            ],
        },
        {
            "name": "s_curve",
            "start": {"x": -125.0, "z": -120.0, "heading_degrees": 68.0},
            "route": [
                {"x": -78.0, "z": -100.0},
                {"x": -32.0, "z": -68.0},
                {"x": 12.0, "z": -22.0},
                {"x": 50.0, "z": 34.0},
                {"x": 92.0, "z": 82.0},
            ],
            "obstacles": [
                {
                    "name": "channel_buoy",
                    "kind": "buoy",
                    "shape": "circle",
                    "x": 12.0,
                    "z": 18.0,
                    "radius": 6.0,
                }
            ],
            "terrain": [
                {
                    "name": "east_cliff",
                    "kind": "cliff",
                    "shape": "circle",
                    "x": 82.0,
                    "z": 20.0,
                    "radius": 15.0,
                }
            ],
            "dynamic_obstacles": [
                {
                    "name": "cross_channel_tug",
                    "kind": "traffic",
                    "shape": "circle",
                    "x": -4.0,
                    "z": 4.0,
                    "radius": 5.0,
                    "course_degrees": 260.0,
                    "speed_knots": 4.5,
                }
            ],
        },
    )


def build_dataset(records: list[dict[str, Any]], hourly_path: Path) -> dict[str, Any]:
    by_day: dict[str, list[dict[str, Any]]] = {}
    for row in records:
        by_day.setdefault(str(row["timestamp"])[:10], []).append(row)
    if len(by_day) != 121 or any(len(rows) != 24 for rows in by_day.values()):
        raise ValueError("expected 121 complete UTC days with 24 rows each")
    splits: dict[str, list[dict[str, Any]]] = {
        "train": [],
        "validation": [],
        "test": [],
    }
    templates = _route_templates()
    for index, (day, rows) in enumerate(sorted(by_day.items())):
        template = json.loads(json.dumps(templates[index % len(templates)]))
        current_speed = _percentile(
            (float(row["current_speed_knots"]) for row in rows),
            0.90,
        )
        forcing = {
            "source_date": day,
            "aggregation": "daily p90 speed/height; direction sampled at daily peak",
            "wind_speed_knots": round(
                _percentile(
                    (float(row["wind_speed_knots"]) for row in rows),
                    0.90,
                ),
                4,
            ),
            "wind_direction_degrees": round(
                _direction_at_peak(
                    rows,
                    "wind_speed_knots",
                    "wind_direction_degrees",
                ),
                4,
            ),
            "wave_height_meters": round(
                _percentile(
                    (float(row["wave_height_meters"]) for row in rows),
                    0.90,
                ),
                4,
            ),
            "wave_direction_degrees": round(
                _direction_at_peak(
                    rows,
                    "wave_height_meters",
                    "wave_direction_degrees",
                ),
                4,
            ),
            "wave_period_seconds": round(
                _percentile(
                    (float(row["wave_period_seconds"]) for row in rows),
                    0.50,
                ),
                4,
            ),
            "current_speed_knots": round(current_speed, 4),
            "current_direction_degrees": round(
                _direction_at_peak(
                    rows,
                    "current_speed_knots",
                    "current_direction_degrees",
                ),
                4,
            ),
        }
        task = {
            "id": f"{day}_{template.pop('name')}",
            **template,
            "arrival_radius": 14.0,
            "boundary_half_extent": 220.0,
            "sea_state": forcing,
            "public_forcing": forcing,
        }
        parsed_day = date.fromisoformat(day)
        if parsed_day <= date(2024, 2, 29):
            split = "train"
        elif parsed_day <= date(2024, 3, 31):
            split = "validation"
        else:
            split = "test"
        splits[split].append(task)
    return {
        "schema_version": "ship_port_dataset_v2",
        "dataset_id": "long_beach_public_weather_navigation_benchmark_v1",
        "name": "Long Beach January-April 2024 public-weather navigation benchmark",
        "description": (
            "Public model/reanalysis forcing with project-authored routes, hazards, "
            "vessel dynamics, and action-response assumptions."
        ),
        "coordinate_system": {
            "type": "local_cartesian_meters",
            "axes": "x_east_z_north",
            "origin_wgs84": {
                "latitude": LATITUDE,
                "longitude": LONGITUDE,
            },
        },
        "source": {
            "type": "public_environment_forcing_plus_simulator_scenarios",
            "provider": "Open-Meteo",
            "hourly_file": hourly_path.name,
            "hourly_sha256": _sha256(hourly_path),
            "hourly_rows": len(records),
            "period": {
                "start": START_DATE.isoformat(),
                "end": END_DATE.isoformat(),
            },
            "license": "CC BY 4.0; attribution required",
            "observed_ais": False,
            "route_geometry": "project_native_synthetic",
            "counterfactual_actions": "simulator_only",
            "live_data_verified": False,
        },
        "split_policy": {
            "method": "chronological_by_source_date_no_shuffle",
            "train": "2024-01-01..2024-02-29",
            "validation": "2024-03-01..2024-03-31",
            "test": "2024-04-01..2024-04-30",
        },
        "splits": splits,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build the fixed public-weather navigation benchmark."
    )
    parser.add_argument("--fetch", action="store_true", help="refresh public inputs")
    parser.add_argument("--hourly-output", type=Path, default=DEFAULT_HOURLY)
    parser.add_argument("--provenance-output", type=Path, default=DEFAULT_PROVENANCE)
    parser.add_argument("--dataset-output", type=Path, default=DEFAULT_DATASET)
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    hourly_path = arguments.hourly_output.expanduser().resolve()
    provenance_path = arguments.provenance_output.expanduser().resolve()
    dataset_path = arguments.dataset_output.expanduser().resolve()
    if arguments.fetch:
        records, provenance = fetch_hourly_records()
        _write_hourly_csv(hourly_path, records)
        provenance["hourly_csv"] = hourly_path.name
        provenance["hourly_sha256"] = _sha256(hourly_path)
        _write_json(provenance_path, provenance)
    else:
        records = _read_hourly_csv(hourly_path)
        if not provenance_path.is_file():
            raise FileNotFoundError(
                f"provenance file is missing: {provenance_path}; use --fetch"
            )
    dataset = build_dataset(records, hourly_path)
    _write_json(dataset_path, dataset)
    print(
        json.dumps(
            {
                "hourly_rows": len(records),
                "daily_scenarios": sum(
                    len(items) for items in dataset["splits"].values()
                ),
                "split_sizes": {
                    name: len(items)
                    for name, items in dataset["splits"].items()
                },
                "hourly_sha256": _sha256(hourly_path),
                "dataset_sha256": _sha256(dataset_path),
                "dataset": str(dataset_path),
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
