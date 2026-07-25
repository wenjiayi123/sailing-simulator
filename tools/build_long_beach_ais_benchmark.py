#!/usr/bin/env python3
"""Build the Long Beach AIS + ENC port-operations benchmark.

The checked-in derivative is compact. Nationwide daily AIS archives stay outside
Git; their official URLs and SHA-256 values remain in provenance metadata.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
from concurrent.futures import ProcessPoolExecutor
import csv
from datetime import date, datetime, timedelta, timezone
import hashlib
import io
import json
import math
from pathlib import Path
import statistics
from typing import Any, Iterable, Iterator, Mapping, Sequence
import urllib.parse
import urllib.request

import zstandard

from ship_rl.port_contract import validate_port_dataset


ROOT = Path(__file__).resolve().parents[1]
START_DATE = date(2025, 1, 1)
END_DATE = date(2025, 1, 7)
TRAIN_END = date(2025, 1, 4)
VALIDATION_END = date(2025, 1, 5)
ORIGIN_LATITUDE = 33.735
ORIGIN_LONGITUDE = -118.25
BBOX = (-118.35, 33.65, -118.15, 33.82)
AIS_BASE_URL = "https://coast.noaa.gov/htdata/CMSP/AISDataHandler/2025"
ENC_BASE_URL = (
    "https://gis.charttools.noaa.gov/arcgis/rest/services/"
    "encdirect/enc_approach/MapServer"
)
WEATHER_ENDPOINT = "https://historical-forecast-api.open-meteo.com/v1/forecast"
MARINE_ENDPOINT = "https://marine-api.open-meteo.com/v1/marine"
DEFAULT_RAW_DIR = ROOT / "data/raw_cache/long_beach_ais_2025_w01"
DEFAULT_DATASET = ROOT / "data/rl/long_beach_ais_port_ops_benchmark_v2.json"
DEFAULT_EXPERIMENT = ROOT / "data/rl/long_beach_ais_port_ops_experiment_v2.json"
DEFAULT_PROVENANCE = ROOT / "data/public/long_beach_ais_2025_w01.provenance.json"
DEFAULT_ENVIRONMENT = ROOT / "data/public/long_beach_noaa_enc_harbour_v1.json"
DEFAULT_WEATHER = ROOT / "data/public/long_beach_open_meteo_2025_w01_hourly.csv"
DEFAULT_REPORT = ROOT / "reports/port_dataset_contract_v2.json"

ENC_LAYERS = (
    (238, "terrain", "shoreline", "NOAA ENC Approach Land Area"),
    (143, "terrain", "shoreline", "NOAA ENC Approach Shoreline Construction"),
    (161, "obstacles", "obstruction", "NOAA ENC Approach Obstruction Area"),
    (163, "obstacles", "wreck", "NOAA ENC Approach Wreck Area"),
    (36, "obstacles", "obstruction", "NOAA ENC Approach Obstruction Point"),
    (39, "obstacles", "wreck", "NOAA ENC Approach Wreck Point"),
    (213, "fairways", "fairway", "NOAA ENC Approach Fairway"),
    (202, "restricted_areas", "restricted", "NOAA ENC Approach Restricted Area"),
    (216, "restricted_areas", "precautionary", "NOAA ENC Approach Precautionary Area"),
    (220, "traffic_separation", "traffic_lane", "NOAA ENC Approach TSS Lane"),
    (232, "depth_areas", "depth_area", "NOAA ENC Approach Depth Area"),
)


def _write_json(path: Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _dates() -> list[date]:
    result: list[date] = []
    current = START_DATE
    while current <= END_DATE:
        result.append(current)
        current += timedelta(days=1)
    return result


def _download(url: str, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".part")
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "sailing-simulator-port-benchmark/2.0"},
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        with temporary.open("wb") as handle:
            while True:
                block = response.read(1024 * 1024)
                if not block:
                    break
                handle.write(block)
    temporary.replace(path)


def _field(row: Mapping[str, str], *names: str) -> str:
    normalized = {
        key.lower().replace("_", ""): value
        for key, value in row.items()
        if key
    }
    for name in names:
        value = normalized.get(name.lower().replace("_", ""), "")
        if value not in (None, ""):
            return str(value)
    return ""


def _float(row: Mapping[str, str], *names: str) -> float:
    value = _field(row, *names)
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def _parse_time(value: str) -> datetime | None:
    text = value.strip().replace("Z", "+00:00")
    if not text:
        return None
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _project(latitude: float, longitude: float) -> tuple[float, float]:
    earth_radius = 6_371_000.0
    x = (
        math.radians(longitude - ORIGIN_LONGITUDE)
        * earth_radius
        * math.cos(math.radians(ORIGIN_LATITUDE))
    )
    z = math.radians(latitude - ORIGIN_LATITUDE) * earth_radius
    return x, z


def _distance(a: Mapping[str, Any], b: Mapping[str, Any]) -> float:
    return math.hypot(float(b["x"]) - float(a["x"]), float(b["z"]) - float(a["z"]))


def _open_zstd_csv(path: Path) -> Iterator[Mapping[str, str]]:
    with path.open("rb") as compressed:
        decompressor = zstandard.ZstdDecompressor()
        with decompressor.stream_reader(compressed) as binary:
            with io.TextIOWrapper(
                binary,
                encoding="utf-8-sig",
                errors="replace",
                newline="",
            ) as text:
                yield from csv.DictReader(text)


def _read_one_ais(
    path: Path,
) -> tuple[list[dict[str, Any]], dict[str, int]]:
    points: list[dict[str, Any]] = []
    raw_rows = 0
    rejected_position = 0
    rejected_motion = 0
    for row in _open_zstd_csv(path):
        raw_rows += 1
        latitude = _float(row, "LAT", "Latitude")
        longitude = _float(row, "LON", "Longitude")
        if not (
            BBOX[1] <= latitude <= BBOX[3]
            and BBOX[0] <= longitude <= BBOX[2]
        ):
            continue
        mmsi = _field(row, "MMSI")
        timestamp = _parse_time(
            _field(row, "BaseDateTime", "Timestamp", "DateTime")
        )
        if not mmsi or timestamp is None:
            rejected_position += 1
            continue
        speed = _float(row, "SOG", "SpeedOverGround")
        course = _float(row, "COG", "CourseOverGround")
        if speed < 0.3 or speed > 35.0 or course < 0.0 or course >= 360.0:
            rejected_motion += 1
            continue
        x, z = _project(latitude, longitude)
        points.append(
            {
                "mmsi": mmsi,
                "timestamp": timestamp.isoformat().replace("+00:00", "Z"),
                "epoch": timestamp.timestamp(),
                "source_date": timestamp.date().isoformat(),
                "latitude": round(latitude, 7),
                "longitude": round(longitude, 7),
                "x": round(x, 3),
                "z": round(z, 3),
                "speed_knots": round(speed, 3),
                "heading_degrees": round(course, 3),
                "vessel_name": _field(row, "VesselName", "Name"),
                "vessel_type": _field(row, "VesselType"),
                "length_meters": round(_float(row, "Length"), 2),
                "width_meters": round(_float(row, "Width"), 2),
                "draft_meters": round(_float(row, "Draft", "Draught"), 2),
            }
        )
    return points, {
        "raw_rows": raw_rows,
        "filtered_rows": len(points),
        "rejected_position": rejected_position,
        "rejected_motion": rejected_motion,
    }


def _read_ais(
    raw_files: Sequence[Path],
) -> tuple[
    dict[str, dict[str, list[dict[str, Any]]]],
    dict[tuple[str, int], list[dict[str, Any]]],
    dict[str, Any],
]:
    tracks: dict[str, dict[str, list[dict[str, Any]]]] = defaultdict(
        lambda: defaultdict(list)
    )
    time_index: dict[tuple[str, int], list[dict[str, Any]]] = defaultdict(list)
    raw_rows = 0
    filtered_rows = 0
    rejected_position = 0
    rejected_motion = 0
    workers = min(4, len(raw_files))
    print(
        "scan AIS in parallel: "
        + ", ".join(path.name for path in raw_files),
        flush=True,
    )
    with ProcessPoolExecutor(max_workers=workers) as executor:
        results = executor.map(_read_one_ais, raw_files)
        for path, (points, counters) in zip(raw_files, results):
            print(
                f"scanned {path.name}: {len(points)} in-port motion rows",
                flush=True,
            )
            raw_rows += counters["raw_rows"]
            filtered_rows += counters["filtered_rows"]
            rejected_position += counters["rejected_position"]
            rejected_motion += counters["rejected_motion"]
            for point in points:
                day = str(point["source_date"])
                mmsi = str(point["mmsi"])
                tracks[day][mmsi].append(point)
                time_index[
                    (day, int(float(point["epoch"])) // 120)
                ].append(point)
    summary = {
        "raw_ais_rows_scanned": raw_rows,
        "filtered_ais_rows": filtered_rows,
        "rejected_missing_position_or_time": rejected_position,
        "rejected_motion_outlier": rejected_motion,
        "distinct_mmsi": len(
            {mmsi for per_day in tracks.values() for mmsi in per_day}
        ),
    }
    return tracks, time_index, summary


def _deduplicate(points: Sequence[dict[str, Any]]) -> list[dict[str, Any]]:
    selected: dict[float, dict[str, Any]] = {}
    for point in points:
        selected[float(point["epoch"])] = point
    return [selected[key] for key in sorted(selected)]


def _segments(points: Sequence[dict[str, Any]]) -> Iterator[list[dict[str, Any]]]:
    current: list[dict[str, Any]] = []
    for point in _deduplicate(points):
        if current:
            gap = float(point["epoch"]) - float(current[-1]["epoch"])
            jump = _distance(current[-1], point)
            if gap > 12 * 60 or jump > 3_000.0:
                if len(current) >= 6:
                    yield current
                current = []
        current.append(point)
    if len(current) >= 6:
        yield current


def _chunks(points: Sequence[dict[str, Any]]) -> Iterator[list[dict[str, Any]]]:
    current = [points[0]]
    length = 0.0
    for point in points[1:]:
        length += _distance(current[-1], point)
        current.append(point)
        elapsed = float(current[-1]["epoch"]) - float(current[0]["epoch"])
        if length >= 1_400.0 or elapsed >= 15 * 60 or len(current) >= 24:
            if length >= 450.0 and len(current) >= 5:
                yield current
            current = [current[-1]]
            length = 0.0
    if len(current) >= 5 and length >= 450.0:
        yield current


def _downsample(
    points: Sequence[dict[str, Any]],
    maximum: int = 18,
) -> list[dict[str, Any]]:
    if len(points) <= maximum:
        return list(points)
    indices = sorted(
        {
            round(index * (len(points) - 1) / (maximum - 1))
            for index in range(maximum)
        }
    )
    return [points[index] for index in indices]


def _dynamic_traffic(
    start: Mapping[str, Any],
    time_index: Mapping[tuple[str, int], Sequence[dict[str, Any]]],
    maximum: int = 6,
) -> list[dict[str, Any]]:
    day = str(start["source_date"])
    bucket = int(float(start["epoch"])) // 120
    own_mmsi = str(start["mmsi"])
    candidates: dict[str, tuple[float, dict[str, Any]]] = {}
    for offset in (-1, 0, 1):
        for point in time_index.get((day, bucket + offset), []):
            mmsi = str(point["mmsi"])
            if mmsi == own_mmsi:
                continue
            time_gap = abs(float(point["epoch"]) - float(start["epoch"]))
            if time_gap > 150.0:
                continue
            distance = _distance(start, point)
            if distance < 35.0 or distance > 1_500.0:
                continue
            previous = candidates.get(mmsi)
            score = time_gap + distance / 100.0
            if previous is None or score < previous[0]:
                candidates[mmsi] = (score, point)
    selected = sorted(
        (value[1] for value in candidates.values()),
        key=lambda point: _distance(start, point),
    )[:maximum]
    return [
        {
            "name": f"ais_traffic_{point['mmsi']}",
            "kind": "traffic",
            "shape": "circle",
            "x": point["x"],
            "z": point["z"],
            "radius": round(
                max(4.0, min(float(point["width_meters"]) * 0.5, 24.0)),
                2,
            ),
            "course_degrees": point["heading_degrees"],
            "speed_knots": point["speed_knots"],
            "source_timestamp": point["timestamp"],
            "source_track": {
                "mmsi": point["mmsi"],
                "vessel_type": point["vessel_type"],
                "length_meters": point["length_meters"],
                "width_meters": point["width_meters"],
                "draft_meters": point["draft_meters"],
            },
        }
        for point in selected
    ]


def _split_name(day: date) -> str:
    if day <= TRAIN_END:
        return "train"
    if day <= VALIDATION_END:
        return "validation"
    return "test"


def _stable_select(
    values: Sequence[dict[str, Any]],
    maximum: int,
) -> list[dict[str, Any]]:
    ordered = sorted(
        values,
        key=lambda value: hashlib.sha256(
            str(value["id"]).encode("utf-8")
        ).hexdigest(),
    )
    return sorted(ordered[:maximum], key=lambda value: str(value["id"]))


def _request_json(
    endpoint: str,
    parameters: Mapping[str, Any],
) -> tuple[dict[str, Any], str]:
    url = f"{endpoint}?{urllib.parse.urlencode(parameters)}"
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "sailing-simulator-port-benchmark/2.0"},
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.load(response), url


def _hourly_series(payload: Mapping[str, Any], key: str) -> list[Any]:
    values = payload.get("hourly", {}).get(key)
    if not isinstance(values, list):
        raise ValueError(f"missing hourly series {key!r}")
    return values


def _fetch_weather() -> tuple[list[dict[str, Any]], dict[str, Any]]:
    common = {
        "latitude": ORIGIN_LATITUDE,
        "longitude": ORIGIN_LONGITUDE,
        "start_date": START_DATE.isoformat(),
        "end_date": END_DATE.isoformat(),
        "timezone": "UTC",
    }
    atmosphere, atmosphere_url = _request_json(
        WEATHER_ENDPOINT,
        {
            **common,
            "hourly": "wind_speed_10m,wind_direction_10m,visibility",
            "wind_speed_unit": "kn",
        },
    )
    marine, marine_url = _request_json(
        MARINE_ENDPOINT,
        {
            **common,
            "hourly": (
                "wave_height,wave_direction,wave_period,"
                "ocean_current_velocity,ocean_current_direction,"
                "sea_level_height_msl"
            ),
            "wind_speed_unit": "kn",
        },
    )
    timestamps = _hourly_series(atmosphere, "time")
    if timestamps != _hourly_series(marine, "time") or len(timestamps) != 168:
        raise ValueError("weather and marine hourly timelines must align for 168 hours")
    series = {
        "wind_speed_knots": _hourly_series(atmosphere, "wind_speed_10m"),
        "wind_direction_degrees": _hourly_series(
            atmosphere,
            "wind_direction_10m",
        ),
        "visibility_meters": _hourly_series(atmosphere, "visibility"),
        "wave_height_meters": _hourly_series(marine, "wave_height"),
        "wave_direction_degrees": _hourly_series(marine, "wave_direction"),
        "wave_period_seconds": _hourly_series(marine, "wave_period"),
        "current_speed_knots": _hourly_series(
            marine,
            "ocean_current_velocity",
        ),
        "current_direction_degrees": _hourly_series(
            marine,
            "ocean_current_direction",
        ),
        "sea_level_height_msl_meters": _hourly_series(
            marine,
            "sea_level_height_msl",
        ),
    }
    records: list[dict[str, Any]] = []
    for index, timestamp in enumerate(timestamps):
        record = {"timestamp": f"{timestamp}:00Z"}
        for key, values in series.items():
            value = values[index]
            if value is None:
                raise ValueError(f"{key} is missing at {timestamp}")
            record[key] = round(float(value), 6)
        records.append(record)
    provenance = {
        "provider": "Open-Meteo",
        "license": "CC BY 4.0; attribution required",
        "request_urls": [atmosphere_url, marine_url],
        "period": {
            "start": START_DATE.isoformat(),
            "end": END_DATE.isoformat(),
            "hours": len(records),
        },
        "evidence_level": "public_model_archive",
        "navigation_suitability": (
            "offline forcing only; coastal tide and current model resolution "
            "is not suitable for navigation"
        ),
    }
    return records, provenance


def _write_weather(path: Path, records: Sequence[Mapping[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(records[0]))
        writer.writeheader()
        writer.writerows(records)
    temporary.replace(path)


def _read_weather(path: Path) -> list[dict[str, Any]]:
    with path.open("r", newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    return [
        {
            "timestamp": row["timestamp"],
            **{
                key: float(value)
                for key, value in row.items()
                if key != "timestamp"
            },
        }
        for row in rows
    ]


def _weather_index(
    records: Sequence[Mapping[str, Any]],
) -> dict[str, Mapping[str, Any]]:
    return {
        str(record["timestamp"])[:13]: record
        for record in records
    }


def _point_in_polygon(
    x: float,
    z: float,
    points: Sequence[Mapping[str, Any]],
) -> bool:
    if len(points) < 3:
        return False
    inside = False
    previous = points[-1]
    for current in points:
        ax, az = float(previous["x"]), float(previous["z"])
        bx, bz = float(current["x"]), float(current["z"])
        if (az > z) != (bz > z):
            crossing_x = (bx - ax) * (z - az) / (bz - az) + ax
            if x < crossing_x:
                inside = not inside
        previous = current
    return inside


def _chart_depth_at(
    x: float,
    z: float,
    shared: Mapping[str, Sequence[Mapping[str, Any]]],
) -> float:
    depths: list[float] = []
    for record in shared.get("depth_areas", []):
        bbox = record.get("bbox", [])
        if (
            isinstance(bbox, list)
            and len(bbox) >= 4
            and not (
                float(bbox[0]) <= x <= float(bbox[2])
                and float(bbox[1]) <= z <= float(bbox[3])
            )
        ):
            continue
        points = record.get("points", [])
        if isinstance(points, list) and _point_in_polygon(x, z, points):
            value = float(record.get("minimum_depth_meters", 0.0) or 0.0)
            if value > 0.0:
                depths.append(value)
    return min(depths) if depths else 0.0


def _inside_feature_group(
    x: float,
    z: float,
    shared: Mapping[str, Sequence[Mapping[str, Any]]],
    group: str,
) -> bool:
    for record in shared.get(group, []):
        bbox = record.get("bbox", [])
        if (
            isinstance(bbox, list)
            and len(bbox) >= 4
            and not (
                float(bbox[0]) <= x <= float(bbox[2])
                and float(bbox[1]) <= z <= float(bbox[3])
            )
        ):
            continue
        points = record.get("points", [])
        if isinstance(points, list) and _point_in_polygon(x, z, points):
            return True
    return False


def _rdp(points: Sequence[tuple[float, float]], epsilon: float) -> list[tuple[float, float]]:
    if len(points) <= 2:
        return list(points)
    ax, az = points[0]
    bx, bz = points[-1]
    dx, dz = bx - ax, bz - az
    length_squared = dx * dx + dz * dz
    best_distance = 0.0
    best_index = 0
    for index, (x, z) in enumerate(points[1:-1], start=1):
        if length_squared <= 1e-12:
            distance = math.hypot(x - ax, z - az)
        else:
            ratio = max(
                0.0,
                min(1.0, ((x - ax) * dx + (z - az) * dz) / length_squared),
            )
            cx, cz = ax + ratio * dx, az + ratio * dz
            distance = math.hypot(x - cx, z - cz)
        if distance > best_distance:
            best_distance = distance
            best_index = index
    if best_distance <= epsilon:
        return [points[0], points[-1]]
    left = _rdp(points[: best_index + 1], epsilon)
    right = _rdp(points[best_index:], epsilon)
    return [*left[:-1], *right]


def _bbox(points: Sequence[tuple[float, float]]) -> list[float]:
    return [
        round(min(point[0] for point in points), 3),
        round(min(point[1] for point in points), 3),
        round(max(point[0] for point in points), 3),
        round(max(point[1] for point in points), 3),
    ]


def _polygon_records(
    feature: Mapping[str, Any],
    kind: str,
    name: str,
    source_layer: int,
) -> list[dict[str, Any]]:
    geometry = feature.get("geometry", {})
    if not isinstance(geometry, Mapping):
        return []
    geometry_type = str(geometry.get("type", ""))
    coordinates = geometry.get("coordinates", [])
    polygons: list[Sequence[Sequence[Sequence[float]]]] = []
    if geometry_type == "Polygon" and isinstance(coordinates, list):
        polygons = [coordinates]
    elif geometry_type == "MultiPolygon" and isinstance(coordinates, list):
        polygons = coordinates
    records: list[dict[str, Any]] = []
    properties = feature.get("properties", {})
    properties = properties if isinstance(properties, Mapping) else {}
    for index, polygon in enumerate(polygons):
        if not polygon:
            continue
        ring = polygon[0]
        projected = [
            _project(float(latitude), float(longitude))
            for longitude, latitude, *_rest in ring
        ]
        if len(projected) > 1 and projected[0] == projected[-1]:
            projected.pop()
        simplified = _rdp(projected, 6.0)
        if len(simplified) < 3:
            continue
        record: dict[str, Any] = {
            "name": f"enc_{source_layer}_{feature.get('id', 'feature')}_{index}",
            "kind": kind,
            "shape": "polygon",
            "points": [
                {"x": round(x, 3), "z": round(z, 3)}
                for x, z in simplified
            ],
            "bbox": _bbox(simplified),
            "source": {
                "provider": "NOAA ENC Direct to GIS",
                "layer_id": source_layer,
                "layer_name": name,
                "object_id": feature.get("id"),
                "dataset_name": properties.get("DSNM"),
                "source_date": properties.get("SORDAT"),
            },
        }
        depth = float(properties.get("DRVAL1", 0.0) or 0.0)
        if kind == "depth_area" and depth > 0.0:
            record["minimum_depth_meters"] = round(depth, 3)
            maximum = float(properties.get("DRVAL2", 0.0) or 0.0)
            if maximum > 0.0:
                record["maximum_depth_meters"] = round(maximum, 3)
        records.append(record)
    return records


def _point_record(
    feature: Mapping[str, Any],
    kind: str,
    name: str,
    source_layer: int,
) -> dict[str, Any] | None:
    geometry = feature.get("geometry", {})
    if not isinstance(geometry, Mapping) or geometry.get("type") != "Point":
        return None
    coordinates = geometry.get("coordinates", [])
    if not isinstance(coordinates, list) or len(coordinates) < 2:
        return None
    x, z = _project(float(coordinates[1]), float(coordinates[0]))
    properties = feature.get("properties", {})
    properties = properties if isinstance(properties, Mapping) else {}
    radius = 12.0 if kind == "wreck" else 8.0
    return {
        "name": f"enc_{source_layer}_{feature.get('id', 'feature')}",
        "kind": kind,
        "shape": "circle",
        "x": round(x, 3),
        "z": round(z, 3),
        "radius": radius,
        "bbox": [
            round(x - radius, 3),
            round(z - radius, 3),
            round(x + radius, 3),
            round(z + radius, 3),
        ],
        "source": {
            "provider": "NOAA ENC Direct to GIS",
            "layer_id": source_layer,
            "layer_name": name,
            "object_id": feature.get("id"),
            "dataset_name": properties.get("DSNM"),
            "source_date": properties.get("SORDAT"),
        },
    }


def _fetch_enc() -> tuple[dict[str, list[dict[str, Any]]], dict[str, Any]]:
    shared: dict[str, list[dict[str, Any]]] = {
        "terrain": [],
        "obstacles": [],
        "depth_areas": [],
        "fairways": [],
        "restricted_areas": [],
        "traffic_separation": [],
    }
    requests: list[dict[str, Any]] = []
    geometry = ",".join(str(value) for value in BBOX)
    for layer_id, target, kind, layer_name in ENC_LAYERS:
        payload, url = _request_json(
            f"{ENC_BASE_URL}/{layer_id}/query",
            {
                "where": "1=1",
                "geometry": geometry,
                "geometryType": "esriGeometryEnvelope",
                "inSR": 4326,
                "outSR": 4326,
                "outFields": "*",
                "returnGeometry": "true",
                "f": "geojson",
            },
        )
        features = payload.get("features", [])
        if not isinstance(features, list):
            raise ValueError(f"NOAA ENC layer {layer_id} did not return features")
        before = len(shared[target])
        for feature in features:
            if not isinstance(feature, Mapping):
                continue
            geometry_type = str((feature.get("geometry", {}) or {}).get("type", ""))
            if geometry_type in ("Polygon", "MultiPolygon"):
                shared[target].extend(
                    _polygon_records(feature, kind, layer_name, layer_id)
                )
            elif geometry_type == "Point":
                record = _point_record(feature, kind, layer_name, layer_id)
                if record is not None:
                    shared[target].append(record)
        requests.append(
            {
                "layer_id": layer_id,
                "layer_name": layer_name,
                "url": url,
                "source_feature_count": len(features),
                "normalized_feature_count": len(shared[target]) - before,
            }
        )
    provenance = {
        "provider": "NOAA Office of Coast Survey ENC Direct to GIS",
        "service": "Harbor-scale S-57 derived GIS",
        "documentation": "https://nauticalcharts.noaa.gov/learn/encdirect/",
        "bbox_wgs84": list(BBOX),
        "retrieved_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "requests": requests,
        "navigation_suitability": (
            "ENC Direct to GIS is not certified for navigation; official "
            "NOAA ENC and local notices are required for operational use"
        ),
    }
    return shared, provenance


def _environment_from_cache(path: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    shared = payload.get("shared_environment", {})
    provenance = payload.get("provenance", {})
    if not isinstance(shared, dict) or not isinstance(provenance, dict):
        raise ValueError("cached ENC environment is invalid")
    return shared, provenance


def _build_tasks(
    tracks: Mapping[str, Mapping[str, Sequence[dict[str, Any]]]],
    time_index: Mapping[tuple[str, int], Sequence[dict[str, Any]]],
    hourly: Mapping[str, Mapping[str, Any]],
    shared: Mapping[str, Sequence[Mapping[str, Any]]],
    maximum_per_day: int,
) -> tuple[dict[str, list[dict[str, Any]]], dict[str, Any]]:
    by_split: dict[str, list[dict[str, Any]]] = {
        "train": [],
        "validation": [],
        "test": [],
    }
    candidate_counts: dict[str, int] = {}
    for raw_day in sorted(tracks):
        day = date.fromisoformat(raw_day)
        candidates: list[dict[str, Any]] = []
        for mmsi, points in sorted(tracks[raw_day].items()):
            for segment_index, segment in enumerate(_segments(points)):
                for chunk_index, chunk in enumerate(_chunks(segment)):
                    sampled = _downsample(chunk)
                    start = sampled[0]
                    length = float(start.get("length_meters", 0.0))
                    width = float(start.get("width_meters", 0.0))
                    draft = float(start.get("draft_meters", 0.0))
                    if length <= 0.0 or width <= 0.0 or draft <= 0.0:
                        continue
                    traffic = _dynamic_traffic(start, time_index)
                    if not traffic:
                        continue
                    weather = hourly.get(str(start["timestamp"])[:13])
                    if weather is None:
                        continue
                    route_depths = [
                        _chart_depth_at(
                            float(point["x"]),
                            float(point["z"]),
                            shared,
                        )
                        for point in sampled
                    ]
                    if any(depth <= 0.0 for depth in route_depths):
                        continue
                    chart_depth = route_depths[0]
                    route = [
                        {
                            "x": point["x"],
                            "z": point["z"],
                            "timestamp": point["timestamp"],
                            "observed_speed_knots": point["speed_knots"],
                            "observed_course_degrees": point[
                                "heading_degrees"
                            ],
                            "chart_depth_meters": round(
                                route_depths[index],
                                3,
                            ),
                        }
                        for index, point in enumerate(sampled[1:], start=1)
                    ]
                    route_length = sum(
                        _distance(a, b)
                        for a, b in zip(sampled, sampled[1:])
                    )
                    speeds = [
                        float(point["speed_knots"])
                        for point in sampled
                    ]
                    empirical_cap = min(
                        14.0,
                        max(4.0, statistics.quantiles(speeds, n=20)[-1] + 1.0)
                        if len(speeds) >= 2
                        else speeds[0] + 1.0,
                    )
                    enforce_fairway = all(
                        _inside_feature_group(
                            float(point["x"]),
                            float(point["z"]),
                            shared,
                            "fairways",
                        )
                        for point in sampled
                    )
                    extent = max(
                        max(abs(float(point["x"])), abs(float(point["z"])))
                        for point in sampled
                    ) + 800.0
                    identifier = (
                        f"ais_{raw_day}_{mmsi}_{segment_index:02d}_"
                        f"{chunk_index:02d}_{str(start['timestamp'])[11:16].replace(':', '')}"
                    )
                    candidates.append(
                        {
                            "id": identifier,
                            "start_timestamp": start["timestamp"],
                            "end_timestamp": sampled[-1]["timestamp"],
                            "source_track": {
                                "provider": "NOAA/BOEM/USCG historical AIS",
                                "mmsi": mmsi,
                                "start_time": start["timestamp"],
                                "end_time": sampled[-1]["timestamp"],
                                "raw_point_count": len(chunk),
                                "retained_route_point_count": len(sampled),
                                "observed_route_length_meters": round(
                                    route_length,
                                    3,
                                ),
                            },
                            "vessel_profile": {
                                "name": start["vessel_name"],
                                "vessel_type": start["vessel_type"],
                                "length_meters": length,
                                "width_meters": width,
                                "draft_meters": draft,
                                "max_observed_speed_knots": round(
                                    max(speeds),
                                    3,
                                ),
                            },
                            "start": {
                                "x": start["x"],
                                "z": start["z"],
                                "heading_degrees": start["heading_degrees"],
                            },
                            "route": route,
                            "arrival_radius": max(35.0, min(length * 0.35, 70.0)),
                            "boundary_half_extent": round(extent, 1),
                            "obstacles": [],
                            "terrain": [],
                            "dynamic_obstacles": traffic,
                            "navigation_context": {
                                "chart_depth_meters": round(chart_depth, 3),
                                "chart_depth_source": (
                                    "NOAA ENC Direct to GIS Approach Depth Area "
                                    "DRVAL1; research GIS, not navigation-certified"
                                ),
                                "minimum_route_chart_depth_meters": round(
                                    min(route_depths),
                                    3,
                                ),
                                "speed_limit_knots": round(empirical_cap, 3),
                                "speed_limit_source": (
                                    "AIS segment p95 plus 1 knot research cap; "
                                    "not a regulatory speed limit"
                                ),
                                "enforce_fairway": enforce_fairway,
                                "minimum_under_keel_clearance_meters": 1.0,
                                "under_keel_clearance_source": (
                                    "research threshold; replace with port and "
                                    "vessel-class rule before operational use"
                                ),
                            },
                            "sea_state": {
                                "source_timestamp": weather["timestamp"],
                                "wind_speed_knots": weather["wind_speed_knots"],
                                "wind_direction_degrees": weather[
                                    "wind_direction_degrees"
                                ],
                                "visibility_km": round(
                                    weather["visibility_meters"] / 1000.0,
                                    3,
                                ),
                                "wave_height_meters": weather[
                                    "wave_height_meters"
                                ],
                                "wave_direction_degrees": weather[
                                    "wave_direction_degrees"
                                ],
                                "wave_period_seconds": weather[
                                    "wave_period_seconds"
                                ],
                                "current_speed_knots": weather[
                                    "current_speed_knots"
                                ],
                                "current_direction_degrees": weather[
                                    "current_direction_degrees"
                                ],
                                "tide_meters": weather[
                                    "sea_level_height_msl_meters"
                                ],
                                "tide_datum_note": (
                                    "model sea level above global mean sea level, "
                                    "not ENC chart datum; datum alignment is required "
                                    "before operational UKC use"
                                ),
                            },
                        }
                    )
        candidate_counts[raw_day] = len(candidates)
        split = _split_name(day)
        by_split[split].extend(_stable_select(candidates, maximum_per_day))
    return by_split, {"candidate_task_counts_by_day": candidate_counts}


def _experiment(dataset_path: Path) -> dict[str, Any]:
    return {
        "schema_version": "ship_training_experiment_v3",
        "headless": True,
        "render": False,
        "delta": 0.5,
        "dataset": {
            "path": f"res://{dataset_path.relative_to(ROOT)}",
            "training_split": "train",
            "validation_split": "validation",
            "evaluation_split": "test",
            "observation_profile": "port_ops_45",
        },
        "rl_parameters": {
            "reward_progress": 2.8,
            "reward_heading": 1.4,
            "reward_speed": 0.5,
            "penalty_collision": 72.0,
            "penalty_terrain_collision": 96.0,
            "penalty_boundary": 64.0,
            "penalty_rudder": 0.35,
            "penalty_proximity": 1.6,
            "penalty_predicted_collision": 2.4,
            "penalty_cross_track": 0.08,
            "penalty_action_slew": 0.06,
            "penalty_step": 0.002,
            "penalty_under_keel_clearance": 3.0,
            "penalty_speed_limit": 1.0,
            "penalty_channel_departure": 1.8,
            "penalty_colreg_give_way": 2.2,
            "minimum_under_keel_clearance_meters": 1.0,
            "safe_distance": 80.0,
        },
        "environment_parameters": {
            "vessel_radius_m": 4.0,
            "obstacle_inflation_m": 2.0,
            "cliff_inflation_m": 8.0,
            "boundary_margin_m": 20.0,
            "sensor_range_m": 1_500.0,
            "tcpa_horizon_seconds": 900.0,
            "terminate_on_collision": True,
            "merge_scene_obstacles": False,
            "domain_randomization": True,
            "randomize_evaluation": False,
            "start_position_jitter_m": 4.0,
            "start_heading_jitter_degrees": 3.0,
            "obstacle_position_jitter_m": 0.0,
            "obstacle_size_jitter_m": 0.0,
            "current_speed_jitter_knots": 0.08,
            "current_direction_jitter_degrees": 3.0,
            "wind_speed_jitter_knots": 0.5,
            "wind_direction_jitter_degrees": 3.0,
            "wave_height_jitter_m": 0.05,
            "wave_direction_jitter_degrees": 3.0,
            "wind_leeway_factor": 0.008,
            "wave_drift_mps_per_meter": 0.05,
            "sensor_distance_noise_std_m": 1.5,
            "sensor_bearing_noise_degrees": 0.8,
            "generated_traffic_count": 0,
            "generated_traffic_speed_knots": 0.0,
            "generated_traffic_radius_m": 5.0,
        },
        "ships": [
            {
                "performance": {
                    "max_forward_speed": 8.0,
                    "max_reverse_speed": 2.0,
                    "acceleration": 0.2,
                    "deceleration": 0.15,
                    "brake_acceleration": 0.35,
                    "throttle_response": 0.32,
                    "rudder_response": 0.55,
                    "max_turn_rate_degrees": 8.0,
                    "low_speed_turn_factor": 0.12,
                    "reverse_turn_factor": 0.45,
                }
            }
        ],
        "world": {"obstacles": {"boundary_half_extent": 15_000.0, "rocks": [], "boxes": []}},
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fetch", action="store_true")
    parser.add_argument("--raw-dir", type=Path, default=DEFAULT_RAW_DIR)
    parser.add_argument("--dataset-output", type=Path, default=DEFAULT_DATASET)
    parser.add_argument("--experiment-output", type=Path, default=DEFAULT_EXPERIMENT)
    parser.add_argument("--provenance-output", type=Path, default=DEFAULT_PROVENANCE)
    parser.add_argument("--environment-output", type=Path, default=DEFAULT_ENVIRONMENT)
    parser.add_argument("--weather-output", type=Path, default=DEFAULT_WEATHER)
    parser.add_argument("--report-output", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--max-tasks-per-day", type=int, default=72)
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    raw_dir = arguments.raw_dir.expanduser().resolve()
    raw_files: list[Path] = []
    source_files: list[dict[str, Any]] = []
    for day in _dates():
        name = f"ais-{day.isoformat()}.csv.zst"
        url = f"{AIS_BASE_URL}/{name}"
        path = raw_dir / name
        if arguments.fetch and not path.exists():
            print(f"download {url}", flush=True)
            _download(url, path)
        if not path.exists():
            raise FileNotFoundError(
                f"missing {path}; rerun with --fetch or provide the official archive"
            )
        raw_files.append(path)
        source_files.append(
            {
                "file": name,
                "url": url,
                "bytes": path.stat().st_size,
                "sha256": _sha256(path),
            }
        )
    weather_path = arguments.weather_output.expanduser().resolve()
    if arguments.fetch or not weather_path.exists():
        weather_records, weather_provenance = _fetch_weather()
        _write_weather(weather_path, weather_records)
    else:
        weather_records = _read_weather(weather_path)
        weather_provenance = {
            "provider": "Open-Meteo",
            "license": "CC BY 4.0; attribution required",
            "cached": True,
        }
    weather_provenance["hourly_file"] = weather_path.name
    weather_provenance["hourly_sha256"] = _sha256(weather_path)
    environment_path = arguments.environment_output.expanduser().resolve()
    if arguments.fetch or not environment_path.exists():
        shared, enc_provenance = _fetch_enc()
        _write_json(
            environment_path,
            {
                "schema_version": "ship_noaa_enc_environment_v1",
                "shared_environment": shared,
                "provenance": enc_provenance,
            },
        )
    else:
        shared, enc_provenance = _environment_from_cache(environment_path)
    enc_provenance["normalized_file"] = environment_path.name
    enc_provenance["normalized_sha256"] = _sha256(environment_path)
    tracks, time_index, ais_summary = _read_ais(raw_files)
    tasks, task_summary = _build_tasks(
        tracks,
        time_index,
        _weather_index(weather_records),
        shared,
        max(1, arguments.max_tasks_per_day),
    )
    dataset = {
        "schema_version": "ship_port_dataset_v3",
        "dataset_id": "long_beach_ais_enc_port_ops_benchmark_v2",
        "name": "Long Beach historical AIS + NOAA ENC port-operations benchmark",
        "description": (
            "Historical AIS route segments and traffic snapshots aligned with "
            "public model forcing and current NOAA ENC-derived research geometry."
        ),
        "port": {
            "id": "us_lgb_long_beach",
            "name": "Port of Long Beach research area",
            "country": "United States",
            "timezone": "America/Los_Angeles",
            "jurisdiction": [
                "United States Coast Guard",
                "Port of Long Beach",
                "Los Angeles-Long Beach Vessel Traffic Service",
            ],
        },
        "coordinate_system": {
            "type": "local_cartesian_meters",
            "axes": "x_east_z_north",
            "origin_wgs84": {
                "latitude": ORIGIN_LATITUDE,
                "longitude": ORIGIN_LONGITUDE,
            },
            "source_crs": "EPSG:4326",
        },
        "source": {
            "provider": "NOAA OCM / BOEM / U.S. Coast Guard Marine Cadastre",
            "catalog": "https://coast.noaa.gov/digitalcoast/data/vesseltraffic.html",
            "bulk_index": f"{AIS_BASE_URL}/index.html",
            "observed_ais": True,
            "live_data_verified": False,
            "coverage_bbox_wgs84": list(BBOX),
            "period": {
                "start": START_DATE.isoformat(),
                "end": END_DATE.isoformat(),
            },
            "raw_files": source_files,
            **ais_summary,
            "license_note": (
                "Historical NAIS-derived public data for coastal/ocean planning; "
                "cite Marine Cadastre. The checked-in derivative is not a live feed."
            ),
            "weather": weather_provenance,
            "enc": enc_provenance,
            "temporal_alignment_note": (
                "AIS and weather use 2025-01-01..07; ENC Direct to GIS reflects "
                "the retrieval-date chart derivative and may not match 2025 notices."
            ),
        },
        "split_policy": {
            "method": "chronological_source_date_no_shuffle",
            "train": f"{START_DATE.isoformat()}..{TRAIN_END.isoformat()}",
            "validation": f"{(TRAIN_END + timedelta(days=1)).isoformat()}..{VALIDATION_END.isoformat()}",
            "test": f"{(VALIDATION_END + timedelta(days=1)).isoformat()}..{END_DATE.isoformat()}",
            "identity_note": (
                "MMSI is excluded from observations. The same vessel may recur "
                "on later dates; temporal isolation measures future-day generalization."
            ),
        },
        "shared_environment": shared,
        "operational_rules": {
            "authority_status": "reference_only_not_machine_authoritative",
            "sources": [
                {
                    "name": "IMO COLREG collision regulations",
                    "url": "https://www.imo.org/en/ourwork/safety/pages/preventing-collisions.aspx",
                },
                {
                    "name": "2026 Port of Los Angeles Mariners Guide for the San Pedro Bay complex",
                    "url": "https://kentico.portoflosangeles.org/getmedia/032862cd-8f0b-4167-8c50-9aa149c34e1f/2026-pola-mariners-guide",
                },
                {
                    "name": "Jacobsen Pilot Service, Port of Long Beach",
                    "url": "https://www.jacobsenpilot.com/pilotage/",
                },
            ],
            "modelled": {
                "colreg_encounter_context": (
                    "conservative give-way proxy; not a COLREG compliance engine"
                ),
                "historical_traffic_replay": True,
                "fairway_and_precautionary_geometry": True,
            },
            "not_machine_enforced": {
                "vts_reporting_and_clearance": True,
                "pilotage_and_tug_requirements": True,
                "berth_and_terminal_constraints": True,
                "notices_to_mariners": True,
                "local_regulatory_speed_zones": True,
                "aids_to_navigation_and_radio_procedures": True,
            },
            "reference_examples": {
                "covered_vts_participant_length_meters": 40.0,
                "precautionary_area_reference_speed_knots": 12.0,
                "long_beach_pilot_vhf_channel": "12",
            },
        },
        "splits": tasks,
        "live_integration": {
            "telemetry_verified": False,
            "chart_update_verified": False,
            "vessel_model_calibrated": False,
            "control_interface_certified": False,
            "human_authority_configured": False,
            "hydrographic_datum_verified": False,
            "regulatory_rules_verified": False,
            "pilotage_and_tug_rules_verified": False,
            "berth_geometry_verified": False,
            "notices_to_mariners_current": False,
            "sensor_latency_validated": False,
            "communications_verified": False,
            "failsafe_redundancy_verified": False,
        },
    }
    dataset_path = arguments.dataset_output.expanduser().resolve()
    _write_json(dataset_path, dataset)
    experiment_path = arguments.experiment_output.expanduser().resolve()
    _write_json(experiment_path, _experiment(dataset_path))
    report = validate_port_dataset(dataset)
    report.update(task_summary)
    report["generated_at"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    report["dataset_path"] = str(dataset_path.relative_to(ROOT))
    report["dataset_file_sha256"] = _sha256(dataset_path)
    report["experiment_path"] = str(experiment_path.relative_to(ROOT))
    report["experiment_file_sha256"] = _sha256(experiment_path)
    report_path = arguments.report_output.expanduser().resolve()
    _write_json(report_path, report)
    provenance = {
        "schema_version": "ship_public_ais_provenance_v1",
        "dataset_id": dataset["dataset_id"],
        "provider": dataset["source"]["provider"],
        "catalog": dataset["source"]["catalog"],
        "period": dataset["source"]["period"],
        "coverage_bbox_wgs84": list(BBOX),
        "raw_files": source_files,
        **ais_summary,
        "derived_dataset": str(dataset_path.relative_to(ROOT)),
        "derived_dataset_sha256": _sha256(dataset_path),
        "contract_report": str(report_path.relative_to(ROOT)),
        "contract_report_sha256": _sha256(report_path),
        "generated_at": report["generated_at"],
        "redistribution_boundary": (
            "Git contains the normalized derivative and hashes, not the nationwide "
            "daily archives. Rebuild from the official URLs."
        ),
    }
    _write_json(arguments.provenance_output.expanduser().resolve(), provenance)
    print(
        json.dumps(
            {
                "dataset": str(dataset_path),
                "split_sizes": report["split_sizes"],
                "filtered_ais_rows": report["filtered_ais_rows"],
                "distinct_mmsi": report["distinct_mmsi"],
                "route_point_count": report["route_point_count"],
                "dynamic_target_instances": report["dynamic_target_instances"],
                "research_training_ready": report["research_training_ready"],
                "live_control_ready": report["live_control_ready"],
                "errors": report["errors"],
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0 if report["research_training_ready"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
