#!/usr/bin/env python3
"""Normalize public marine data into the simulator's open schemas.

No third-party Python package is required. NOAA/BOEM AccessAIS CSV files may be
large, so rows are streamed and only retained for selected vessels.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import math
import os
import sys
import urllib.parse
import urllib.request
import zipfile
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, Iterator, List, Mapping, Sequence, TextIO, Tuple


OPEN_METEO_FORECAST = "https://api.open-meteo.com/v1/forecast"
OPEN_METEO_MARINE = "https://marine-api.open-meteo.com/v1/marine"
NOAA_AIS_SOURCE = "https://coast.noaa.gov/digitalcoast/data/vesseltraffic.html"


def write_json_atomic(path: Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(path)


def fetch_json(base_url: str, parameters: Mapping[str, Any]) -> Tuple[Dict[str, Any], str]:
    query = urllib.parse.urlencode(parameters, doseq=True)
    url = f"{base_url}?{query}"
    request = urllib.request.Request(url, headers={"User-Agent": "ship-simulator-open-data/1.0"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response), url


def _first_hour(payload: Mapping[str, Any], key: str, default: float = 0.0) -> float:
    current = payload.get("current", {})
    if isinstance(current, Mapping) and current.get(key) is not None:
        return float(current[key])
    hourly = payload.get("hourly", {})
    values = hourly.get(key, []) if isinstance(hourly, Mapping) else []
    return float(values[0]) if values else default


def sync_weather(latitude: float, longitude: float, output: Path) -> Dict[str, Any]:
    atmosphere, atmosphere_url = fetch_json(
        OPEN_METEO_FORECAST,
        {
            "latitude": latitude,
            "longitude": longitude,
            "current": "wind_speed_10m,wind_direction_10m,visibility",
            "wind_speed_unit": "kn",
            "timezone": "UTC",
            "forecast_days": 1,
        },
    )
    marine, marine_url = fetch_json(
        OPEN_METEO_MARINE,
        {
            "latitude": latitude,
            "longitude": longitude,
            "hourly": "wave_height,wave_direction,wave_period,ocean_current_velocity,ocean_current_direction,sea_surface_temperature",
            "wind_speed_unit": "kn",
            "timezone": "UTC",
            "forecast_days": 1,
        },
    )
    observed_at = str((atmosphere.get("current", {}) or {}).get("time", ""))
    if not observed_at:
        observed_at = str((marine.get("hourly", {}) or {}).get("time", [""])[0])
    payload = {
        "format": "ship_marine_weather_v1",
        "source": {
            "provider": "Open-Meteo",
            "upstream_models": "national weather services including DWD/NOAA/ECMWF as selected by Open-Meteo",
            "license": "CC BY 4.0; attribution required",
            "documentation": "https://open-meteo.com/en/docs/marine-weather-api",
            "attribution": "Weather data by Open-Meteo.com; wave data includes DWD model products",
            "request_urls": [atmosphere_url, marine_url],
        },
        "fetched_at": datetime.now(timezone.utc).isoformat(),
        "observed_at": observed_at,
        "location": {"latitude": latitude, "longitude": longitude, "crs": "WGS84"},
        "sea_state": {
            "wind_speed_knots": _first_hour(atmosphere, "wind_speed_10m"),
            "wind_direction_degrees": _first_hour(atmosphere, "wind_direction_10m"),
            "wave_height_meters": _first_hour(marine, "wave_height"),
            "wave_direction_degrees": _first_hour(marine, "wave_direction"),
            "wave_period_seconds": _first_hour(marine, "wave_period"),
            "visibility_km": _first_hour(atmosphere, "visibility") / 1000.0,
            "current_speed_knots": _first_hour(marine, "ocean_current_velocity"),
            "current_direction_degrees": _first_hour(marine, "ocean_current_direction"),
            "sea_surface_temperature_celsius": _first_hour(marine, "sea_surface_temperature"),
            "tide_meters": 0.0,
            "time_scale": 1.0,
        },
    }
    write_json_atomic(output, payload)
    return payload


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _csv_handles(path: Path) -> Iterator[Tuple[str, TextIO]]:
    if path.suffix.lower() == ".zip":
        archive = zipfile.ZipFile(path)
        try:
            for name in archive.namelist():
                if not name.lower().endswith(".csv"):
                    continue
                binary = archive.open(name)
                text = io.TextIOWrapper(binary, encoding="utf-8-sig", errors="replace", newline="")
                try:
                    yield name, text
                finally:
                    text.close()
        finally:
            archive.close()
    else:
        with path.open("r", encoding="utf-8-sig", errors="replace", newline="") as handle:
            yield path.name, handle


def _field(row: Mapping[str, str], *names: str) -> str:
    normalized = {key.lower().replace("_", ""): value for key, value in row.items() if key}
    for name in names:
        value = normalized.get(name.lower().replace("_", ""), "")
        if value not in (None, ""):
            return str(value)
    return ""


def _project(latitude: float, longitude: float, origin_lat: float, origin_lon: float) -> Tuple[float, float]:
    earth_radius = 6_371_000.0
    x = math.radians(longitude - origin_lon) * earth_radius * math.cos(math.radians(origin_lat))
    z = math.radians(latitude - origin_lat) * earth_radius
    return x, z


def _downsample(points: Sequence[Dict[str, Any]], maximum: int = 96) -> List[Dict[str, Any]]:
    if len(points) <= maximum:
        return list(points)
    indices = sorted({round(index * (len(points) - 1) / (maximum - 1)) for index in range(maximum)})
    return [points[index] for index in indices]


def _split_name(identifier: str) -> str:
    bucket = int(hashlib.sha256(identifier.encode("utf-8")).hexdigest()[:8], 16) % 100
    if bucket < 70:
        return "train"
    return "validation" if bucket < 85 else "test"


def normalize_environment_geojson(
    input_path: Path,
    origin_lat: float,
    origin_lon: float,
) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
    """Convert WGS84 GeoJSON points/polygons into terrain-aware local records."""

    payload = json.loads(input_path.read_text(encoding="utf-8"))
    features = payload.get("features", []) if isinstance(payload, Mapping) else []
    if not isinstance(features, list):
        raise ValueError("environment GeoJSON must contain a FeatureCollection.features array")
    terrain: List[Dict[str, Any]] = []
    obstacles: List[Dict[str, Any]] = []
    terrain_kinds = {"cliff", "terrain", "shoreline", "land", "reef", "shoal"}

    def destination(properties: Mapping[str, Any]) -> List[Dict[str, Any]]:
        category = str(properties.get("category", "")).lower()
        kind = str(properties.get("kind", category or "obstacle")).lower()
        return terrain if category == "terrain" or kind in terrain_kinds else obstacles

    def point_record(coordinates: Sequence[Any], properties: Mapping[str, Any], name: str) -> Dict[str, Any]:
        longitude, latitude = float(coordinates[0]), float(coordinates[1])
        x, z = _project(latitude, longitude, origin_lat, origin_lon)
        shape = str(properties.get("shape", "circle")).lower()
        record: Dict[str, Any] = {
            "name": name,
            "kind": str(properties.get("kind", properties.get("category", "obstacle"))).lower(),
            "shape": shape,
            "position": {"x": round(x, 3), "z": round(z, 3)},
        }
        if shape == "box":
            record["size"] = {
                "x": float(properties.get("width_m", properties.get("size_x_m", 10.0))),
                "z": float(properties.get("length_m", properties.get("size_z_m", 10.0))),
            }
        else:
            record["radius"] = float(properties.get("radius_m", 8.0))
        return record

    def polygon_record(ring: Sequence[Sequence[Any]], properties: Mapping[str, Any], name: str) -> Dict[str, Any]:
        points = []
        for coordinates in ring:
            longitude, latitude = float(coordinates[0]), float(coordinates[1])
            x, z = _project(latitude, longitude, origin_lat, origin_lon)
            points.append({"x": round(x, 3), "z": round(z, 3)})
        if len(points) > 1 and points[0] == points[-1]:
            points.pop()
        if len(points) < 3:
            raise ValueError(f"GeoJSON polygon {name!r} has fewer than three unique points")
        return {
            "name": name,
            "kind": str(properties.get("kind", properties.get("category", "terrain"))).lower(),
            "shape": "polygon",
            "points": points,
        }

    for feature_index, feature in enumerate(features):
        if not isinstance(feature, Mapping):
            continue
        properties = feature.get("properties", {})
        properties = properties if isinstance(properties, Mapping) else {}
        geometry = feature.get("geometry", {})
        geometry = geometry if isinstance(geometry, Mapping) else {}
        geometry_type = str(geometry.get("type", ""))
        coordinates = geometry.get("coordinates", [])
        base_name = str(properties.get("name", properties.get("id", f"environment_{feature_index + 1:03d}")))
        target = destination(properties)
        if geometry_type == "Point" and isinstance(coordinates, Sequence):
            target.append(point_record(coordinates, properties, base_name))
        elif geometry_type == "MultiPoint" and isinstance(coordinates, Sequence):
            for point_index, point in enumerate(coordinates):
                target.append(point_record(point, properties, f"{base_name}_{point_index + 1:02d}"))
        elif geometry_type == "Polygon" and isinstance(coordinates, Sequence) and coordinates:
            target.append(polygon_record(coordinates[0], properties, base_name))
        elif geometry_type == "MultiPolygon" and isinstance(coordinates, Sequence):
            for polygon_index, polygon in enumerate(coordinates):
                if polygon:
                    target.append(polygon_record(polygon[0], properties, f"{base_name}_{polygon_index + 1:02d}"))
    return terrain, obstacles


def normalize_ais(
    input_path: Path,
    dataset_output: Path,
    targets_output: Path,
    origin_lat: float,
    origin_lon: float,
    minimum_points: int,
    maximum_vessels: int,
    bbox: Sequence[float] | None,
    environment_geojson: Path | None = None,
) -> Dict[str, Any]:
    tracks: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    vessel_meta: Dict[str, Dict[str, Any]] = {}
    for _name, handle in _csv_handles(input_path):
        for row in csv.DictReader(handle):
            mmsi = _field(row, "MMSI")
            latitude_text = _field(row, "LAT", "Latitude")
            longitude_text = _field(row, "LON", "Longitude")
            if not mmsi or not latitude_text or not longitude_text:
                continue
            try:
                latitude, longitude = float(latitude_text), float(longitude_text)
            except ValueError:
                continue
            if bbox and not (bbox[1] <= latitude <= bbox[3] and bbox[0] <= longitude <= bbox[2]):
                continue
            if mmsi not in tracks and len(tracks) >= maximum_vessels:
                continue
            x, z = _project(latitude, longitude, origin_lat, origin_lon)
            point = {
                "timestamp": _field(row, "BaseDateTime", "Timestamp", "DateTime"),
                "latitude": latitude,
                "longitude": longitude,
                "x": round(x, 3),
                "z": round(z, 3),
                "speed_knots": float(_field(row, "SOG", "SpeedOverGround") or 0.0),
                "heading_degrees": float(_field(row, "COG", "Heading") or 0.0),
            }
            tracks[mmsi].append(point)
            vessel_meta[mmsi] = {
                "mmsi": mmsi,
                "name": _field(row, "VesselName", "Name") or f"MMSI {mmsi}",
                "vessel_type": _field(row, "VesselType"),
                "length_meters": float(_field(row, "Length") or 0.0),
                "width_meters": float(_field(row, "Width") or 0.0),
            }
    qualified = [(mmsi, sorted(points, key=lambda item: item["timestamp"])) for mmsi, points in tracks.items() if len(points) >= minimum_points]
    if len(qualified) < 3:
        raise ValueError(f"need at least 3 vessels with {minimum_points}+ points; found {len(qualified)}")
    static_terrain: List[Dict[str, Any]] = []
    static_obstacles: List[Dict[str, Any]] = []
    if environment_geojson is not None:
        static_terrain, static_obstacles = normalize_environment_geojson(environment_geojson, origin_lat, origin_lon)
    splits: Dict[str, List[Dict[str, Any]]] = {"train": [], "validation": [], "test": []}
    targets: List[Dict[str, Any]] = []
    for mmsi, raw_points in qualified:
        points = _downsample(raw_points)
        start = points[0]
        route = [{"x": point["x"], "z": point["z"], "timestamp": point["timestamp"]} for point in points[1:]]
        maximum_extent = max(max(abs(point["x"]), abs(point["z"])) for point in points) + 500.0
        task = {
            "id": f"ais_{mmsi}_{start['timestamp']}",
            "source_track": {"mmsi": mmsi, **vessel_meta[mmsi]},
            "start": {"x": start["x"], "z": start["z"], "heading_degrees": start["heading_degrees"]},
            "route": route,
            "arrival_radius": 40.0,
            "boundary_half_extent": round(maximum_extent, 1),
            "obstacles": json.loads(json.dumps(static_obstacles)),
            "terrain": json.loads(json.dumps(static_terrain)),
            "dynamic_obstacles": [],
            "sea_state": {},
        }
        splits[_split_name(mmsi)].append(task)
        latest = points[-1]
        targets.append({**vessel_meta[mmsi], **latest, "source": "NOAA/BOEM AccessAIS historical observation"})
    # Small filtered downloads can hash unevenly. Move tasks deterministically so
    # every required split exists without duplicating observations across splits.
    for split in ("validation", "test"):
        if not splits[split]:
            donor = max(splits, key=lambda name: len(splits[name]))
            splits[split].append(splits[donor].pop())
    if not splits["train"]:
        donor = max(("validation", "test"), key=lambda name: len(splits[name]))
        splits["train"].append(splits[donor].pop())
    source = {
        "provider": "NOAA Office for Coastal Management / BOEM / U.S. Coast Guard",
        "catalog": NOAA_AIS_SOURCE,
        "input_file": input_path.name,
        "input_sha256": _sha256(input_path),
        "license_note": "Review the metadata and terms supplied with the selected AccessAIS export before redistribution.",
        "observed_ais": True,
    }
    if environment_geojson is not None:
        source["environment_geojson"] = {
            "input_file": environment_geojson.name,
            "input_sha256": _sha256(environment_geojson),
            "feature_count": len(static_terrain) + len(static_obstacles),
        }
    dataset = {
        "schema_version": "ship_port_dataset_v2",
        "name": f"AccessAIS normalized dataset around {origin_lat:.5f},{origin_lon:.5f}",
        "coordinate_system": {
            "type": "local_cartesian_meters",
            "axes": "x_east_z_north",
            "origin_wgs84": {"latitude": origin_lat, "longitude": origin_lon},
        },
        "source": source,
        "splits": splits,
    }
    snapshot = {
        "format": "ship_ais_targets_v1",
        "source": source,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "coordinate_system": dataset["coordinate_system"],
        "targets": targets,
    }
    write_json_atomic(dataset_output, dataset)
    write_json_atomic(targets_output, snapshot)
    return {"dataset": os.fspath(dataset_output), "targets": os.fspath(targets_output), "split_sizes": {key: len(value) for key, value in splits.items()}}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Prepare public marine data for the simulator.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    weather = subparsers.add_parser("weather", help="fetch attributed Open-Meteo marine and atmospheric data")
    weather.add_argument("--latitude", type=float, required=True)
    weather.add_argument("--longitude", type=float, required=True)
    weather.add_argument("--output", type=Path, required=True)
    ais = subparsers.add_parser("ais", help="normalize NOAA/BOEM AccessAIS CSV or ZIP")
    ais.add_argument("--input", type=Path, required=True)
    ais.add_argument("--dataset-output", type=Path, required=True)
    ais.add_argument("--targets-output", type=Path, required=True)
    ais.add_argument("--origin-lat", type=float, required=True)
    ais.add_argument("--origin-lon", type=float, required=True)
    ais.add_argument("--min-points", type=int, default=12)
    ais.add_argument("--max-vessels", type=int, default=500)
    ais.add_argument("--bbox", type=float, nargs=4, metavar=("MIN_LON", "MIN_LAT", "MAX_LON", "MAX_LAT"))
    ais.add_argument("--environment-geojson", type=Path, help="WGS84 terrain, cliff, reef, pier, and breakwater features")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.command == "weather":
        result = sync_weather(args.latitude, args.longitude, args.output)
        print(json.dumps({"ok": True, "output": os.fspath(args.output), "observed_at": result["observed_at"]}, ensure_ascii=False))
    else:
        result = normalize_ais(
            args.input,
            args.dataset_output,
            args.targets_output,
            args.origin_lat,
            args.origin_lon,
            args.min_points,
            args.max_vessels,
            args.bbox,
            args.environment_geojson,
        )
        print(json.dumps({"ok": True, **result}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
