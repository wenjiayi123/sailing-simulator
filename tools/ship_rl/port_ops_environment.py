"""Port-operations environment with AIS, ENC, depth, traffic, and COLREG context."""

from __future__ import annotations

import math
from typing import Any, Dict, List, Mapping, Sequence, Tuple

import numpy as np
from gymnasium import spaces

from .environment import (
    DISCRETE_ACTIONS,
    ObstacleRecord,
    ShipPerformance,
    ShipNavigationEnv,
    _point_in_polygon,
    _polygon_distance,
    _wrap_angle,
)


PORT_OPS_OBSERVATION_SIZE = 45


class PortOpsNavigationEnv(ShipNavigationEnv):
    """Adds fail-closed port constraints while preserving the 28-D v1 environment."""

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        self.grounding_count = 0
        self.speed_violation_count = 0
        self.channel_departure_count = 0
        self.colreg_violation_count = 0
        self._grounding_active = False
        self._speed_violation_active = False
        self._channel_departure_active = False
        self._colreg_violation_active = False
        self._geometry_ready = False
        self._area_cache: dict[str, List[Mapping[str, Any]]] = {}
        self._obstacle_bbox_by_name: dict[str, Tuple[float, float, float, float]] = {}
        self._state_cache_key: tuple[Any, ...] | None = None
        self._state_cache: dict[str, Any] = {}
        super().__init__(*args, **kwargs)
        self.observation_space = spaces.Box(
            low=-1.0,
            high=1.0,
            shape=(PORT_OPS_OBSERVATION_SIZE,),
            dtype=np.float32,
        )

    def reset(
        self,
        *,
        seed: int | None = None,
        options: Dict[str, Any] | None = None,
    ) -> Tuple[np.ndarray, Dict[str, Any]]:
        self._geometry_ready = False
        self._area_cache.clear()
        self._obstacle_bbox_by_name.clear()
        self._clear_state_cache()
        self.grounding_count = 0
        self.speed_violation_count = 0
        self.channel_departure_count = 0
        self.colreg_violation_count = 0
        self._grounding_active = False
        self._speed_violation_active = False
        self._channel_departure_active = False
        self._colreg_violation_active = False
        observation, info = super().reset(seed=seed, options=options)
        self._prepare_area_cache()
        self._clear_state_cache()
        self.performance = self._task_performance()
        return self._observation(), self._info(False, False, False)

    def _clear_state_cache(self) -> None:
        self._state_cache_key = None
        self._state_cache.clear()

    def _refresh_state_cache(self) -> None:
        key = (
            self.steps,
            float(self.state[0]),
            float(self.state[1]),
            float(self.state[2]),
            float(self.state[3]),
            self.waypoint_index,
        )
        if key != self._state_cache_key:
            self._state_cache_key = key
            self._state_cache.clear()

    def _prepare_area_cache(self) -> None:
        margin = float(self.environment_config["sensor_range_m"]) + 500.0
        window = self._task_window(margin)
        shared = self._shared_environment()
        cache: dict[str, List[Mapping[str, Any]]] = {}
        for key in (
            "depth_areas",
            "fairways",
            "restricted_areas",
            "traffic_separation",
        ):
            selected: List[Mapping[str, Any]] = []
            values = shared.get(key, [])
            if isinstance(values, list):
                for value in values:
                    if not isinstance(value, Mapping):
                        continue
                    if not self._record_intersects_window(value, window):
                        continue
                    prepared = dict(value)
                    prepared["_points_cache"] = self._points(value)
                    selected.append(prepared)
            cache[key] = selected
        self._area_cache = cache
        self._geometry_ready = True

    def _shared_environment(self) -> Mapping[str, Any]:
        shared = self.dataset.get("shared_environment", {})
        return shared if isinstance(shared, Mapping) else {}

    def _task_window(self, margin: float = 500.0) -> Tuple[float, float, float, float]:
        points = [self._point_tuple(self.task.get("start", {})), *self.route]
        xs = [point[0] for point in points]
        zs = [point[1] for point in points]
        return (
            min(xs) - margin,
            min(zs) - margin,
            max(xs) + margin,
            max(zs) + margin,
        )

    @staticmethod
    def _record_intersects_window(
        record: Mapping[str, Any],
        window: Tuple[float, float, float, float],
    ) -> bool:
        bbox = record.get("bbox")
        if isinstance(bbox, Sequence) and len(bbox) >= 4:
            left, bottom, right, top = (float(value) for value in bbox[:4])
            return not (
                right < window[0]
                or left > window[2]
                or top < window[1]
                or bottom > window[3]
            )
        position = record.get("position", record)
        if isinstance(position, Mapping):
            x = float(position.get("x", record.get("x", 0.0)))
            z = float(position.get("z", record.get("z", 0.0)))
            return window[0] <= x <= window[2] and window[1] <= z <= window[3]
        return True

    def _build_obstacles(self, randomize: bool) -> List[ObstacleRecord]:
        records = super()._build_obstacles(randomize)
        window = self._task_window(
            float(self.environment_config["sensor_range_m"])
        )
        shared = self._shared_environment()
        index = len(records)
        for key, source in (
            ("terrain", "enc_terrain"),
            ("obstacles", "enc_obstacle"),
        ):
            values = shared.get(key, [])
            if not isinstance(values, list):
                continue
            for value in values:
                if not isinstance(value, Mapping):
                    continue
                if not self._record_intersects_window(value, window):
                    continue
                records.append(self._obstacle_record(value, index, source, False))
                index += 1
        names: set[str] = set()
        unique: List[ObstacleRecord] = []
        for record in records:
            if record.name in names:
                continue
            names.add(record.name)
            unique.append(record)
        self._obstacle_bbox_by_name = {
            record.name: self._obstacle_bbox(record)
            for record in unique
        }
        return unique

    @staticmethod
    def _obstacle_bbox(
        obstacle: ObstacleRecord,
    ) -> Tuple[float, float, float, float]:
        if obstacle.shape == "polygon" and obstacle.points:
            xs = [point[0] for point in obstacle.points]
            zs = [point[1] for point in obstacle.points]
            return min(xs), min(zs), max(xs), max(zs)
        if obstacle.shape == "box":
            return (
                obstacle.x - obstacle.half_x,
                obstacle.z - obstacle.half_z,
                obstacle.x + obstacle.half_x,
                obstacle.z + obstacle.half_z,
            )
        return (
            obstacle.x - obstacle.radius,
            obstacle.z - obstacle.radius,
            obstacle.x + obstacle.radius,
            obstacle.z + obstacle.radius,
        )

    def _bbox_clearance_lower_bound(self, obstacle: ObstacleRecord) -> float:
        bbox = self._obstacle_bbox_by_name.get(obstacle.name)
        if bbox is None:
            return 0.0
        x, z = float(self.state[0]), float(self.state[1])
        dx = max(bbox[0] - x, 0.0, x - bbox[2])
        dz = max(bbox[1] - z, 0.0, z - bbox[3])
        return math.hypot(dx, dz) - self._obstacle_inflation(obstacle)

    def _vessel_profile(self) -> Mapping[str, Any]:
        profile = self.task.get("vessel_profile", {})
        return profile if isinstance(profile, Mapping) else {}

    def _task_performance(self) -> ShipPerformance:
        vessel = self._vessel_profile()
        navigation = self._navigation_context()
        length = max(float(vessel.get("length_meters", 0.0) or 0.0), 20.0)
        reference_knots = max(
            float(navigation.get("speed_limit_knots", 0.0) or 0.0),
            float(vessel.get("max_observed_speed_knots", 0.0) or 0.0),
            4.0,
        )
        maximum_speed = float(np.clip(reference_knots * 0.514444 * 1.15, 3.0, 10.5))
        turn_rate = float(np.clip(900.0 / length, 3.0, 24.0))
        acceleration = float(np.clip(18.0 / length, 0.08, 0.45))
        return ShipPerformance(
            max_forward_speed=maximum_speed,
            max_reverse_speed=max(1.0, maximum_speed * 0.24),
            acceleration=acceleration,
            deceleration=acceleration * 0.75,
            brake_acceleration=acceleration * 1.8,
            throttle_response=0.32,
            rudder_response=0.55,
            max_turn_rate_degrees=turn_rate,
            low_speed_turn_factor=0.12,
            reverse_turn_factor=0.45,
        )

    def _effective_vessel_radius(self) -> float:
        configured = float(self.environment_config["vessel_radius_m"])
        beam = float(self._vessel_profile().get("width_meters", 0.0) or 0.0)
        return max(configured, beam * 0.5)

    def _obstacle_inflation(self, obstacle: ObstacleRecord) -> float:
        value = self._effective_vessel_radius() + float(
            self.environment_config["obstacle_inflation_m"]
        )
        if obstacle.kind in ("cliff", "terrain", "shoreline"):
            value += float(self.environment_config["cliff_inflation_m"])
        return value

    def _boundary_clearance(self) -> float:
        boundary = float(self.task.get("boundary_half_extent", 780.0))
        effective = (
            boundary
            - float(self.environment_config["boundary_margin_m"])
            - self._effective_vessel_radius()
        )
        return min(
            effective - abs(float(self.state[0])),
            effective - abs(float(self.state[1])),
        )

    def _navigation_context(self) -> Mapping[str, Any]:
        context = self.task.get("navigation_context", {})
        return context if isinstance(context, Mapping) else {}

    @staticmethod
    def _points(record: Mapping[str, Any]) -> Tuple[Tuple[float, float], ...]:
        cached = record.get("_points_cache")
        if isinstance(cached, tuple):
            return cached
        raw = record.get("points", [])
        if not isinstance(raw, list):
            return ()
        points: list[Tuple[float, float]] = []
        for point in raw:
            if isinstance(point, Mapping):
                points.append((float(point.get("x", 0.0)), float(point.get("z", 0.0))))
            elif isinstance(point, Sequence) and len(point) >= 2:
                points.append((float(point[0]), float(point[1])))
        return tuple(points)

    def _area_records(self, key: str) -> List[Mapping[str, Any]]:
        if self._geometry_ready:
            return self._area_cache.get(key, [])
        values = self._shared_environment().get(key, [])
        return (
            [value for value in values if isinstance(value, Mapping)]
            if isinstance(values, list)
            else []
        )

    def _depth_at_position(self) -> Tuple[float, bool]:
        self._refresh_state_cache()
        cached = self._state_cache.get("depth")
        if isinstance(cached, tuple):
            return cached
        x, z = float(self.state[0]), float(self.state[1])
        values: list[float] = []
        for record in self._area_records("depth_areas"):
            if not self._record_intersects_window(record, (x, z, x, z)):
                continue
            points = self._points(record)
            if len(points) >= 3 and _point_in_polygon(x, z, points):
                value = float(record.get("minimum_depth_meters", 0.0) or 0.0)
                if value > 0.0:
                    values.append(value)
        if values:
            result = (min(values), True)
            self._state_cache["depth"] = result
            return result
        fallback = float(
            self._navigation_context().get("chart_depth_meters", 0.0) or 0.0
        )
        result = (fallback, fallback > 0.0) if not self._area_records("depth_areas") else (0.0, False)
        self._state_cache["depth"] = result
        return result

    def _fairway_context(self) -> Tuple[bool, float, bool]:
        self._refresh_state_cache()
        cached = self._state_cache.get("fairway")
        if isinstance(cached, tuple):
            return cached
        x, z = float(self.state[0]), float(self.state[1])
        best = float("inf")
        inside = False
        records = self._area_records("fairways")
        for record in records:
            points = self._points(record)
            if len(points) < 3:
                continue
            distance, _tx, _tz = _polygon_distance(x, z, points)
            record_inside = _point_in_polygon(x, z, points)
            if record_inside:
                inside = True
                best = min(best, distance)
            elif not inside:
                best = min(best, distance)
        if not records:
            result = (
                True,
                float(self.environment_config["sensor_range_m"]),
                False,
            )
            self._state_cache["fairway"] = result
            return result
        result = (inside, best if math.isfinite(best) else 0.0, True)
        self._state_cache["fairway"] = result
        return result

    def _under_keel_clearance(self) -> Tuple[float, bool]:
        depth, valid = self._depth_at_position()
        tide = float(self.sea_state.get("tide_meters", 0.0))
        draft = float(self._vessel_profile().get("draft_meters", 0.0) or 0.0)
        return depth + tide - draft, bool(valid and draft > 0.0)

    def _nearest_dynamic(self) -> Dict[str, Any]:
        sensor_range = float(self.environment_config["sensor_range_m"])
        nearest: Dict[str, Any] = {
            "clearance": sensor_range,
            "bearing": 0.0,
            "closing_speed": 0.0,
            "tcpa": float(self.environment_config["tcpa_horizon_seconds"]),
            "dcpa": sensor_range,
            "obstacle": None,
        }
        for obstacle in self.obstacles:
            if not obstacle.dynamic:
                continue
            clearance, bearing, target_x, target_z = self._obstacle_distance(obstacle)
            if clearance >= float(nearest["clearance"]):
                continue
            closing, tcpa, dcpa = self._relative_motion(obstacle, target_x, target_z)
            nearest = {
                "clearance": clearance,
                "bearing": bearing,
                "closing_speed": closing,
                "tcpa": tcpa,
                "dcpa": dcpa,
                "obstacle": obstacle,
            }
        return nearest

    def _encounter_context(self) -> Dict[str, Any]:
        self._refresh_state_cache()
        cached = self._state_cache.get("encounter")
        if isinstance(cached, dict):
            return cached
        nearest = self._nearest_dynamic()
        obstacle = nearest.get("obstacle")
        encounter = "none"
        give_way = False
        if isinstance(obstacle, ObstacleRecord):
            bearing = math.degrees(float(nearest["bearing"]))
            target_course = math.atan2(obstacle.vx, obstacle.vz)
            heading_difference = math.degrees(
                abs(_wrap_angle(target_course - float(self.state[2])))
            )
            closing = float(nearest["closing_speed"])
            if abs(bearing) <= 15.0 and heading_difference >= 150.0:
                encounter = "head_on"
                give_way = True
            elif (
                abs(bearing) <= 22.5
                and heading_difference <= 30.0
                and closing > 0.0
            ):
                encounter = "overtaking"
                give_way = True
            elif 15.0 < bearing <= 112.5:
                encounter = "crossing_starboard"
                give_way = True
            elif -112.5 <= bearing < -15.0:
                encounter = "crossing_port"
        result = {**nearest, "encounter": encounter, "give_way": give_way}
        self._state_cache["encounter"] = result
        return result

    def _traffic_density(self) -> int:
        self._refresh_state_cache()
        cached = self._state_cache.get("traffic_density")
        if isinstance(cached, int):
            return cached
        sensor_range = float(self.environment_config["sensor_range_m"])
        result = sum(
            1
            for obstacle in self.obstacles
            if obstacle.dynamic
            and math.hypot(
                obstacle.x - float(self.state[0]),
                obstacle.z - float(self.state[1]),
            )
            <= sensor_range
        )
        self._state_cache["traffic_density"] = result
        return result

    def _nearest_obstacle(self, sensor_limited: bool) -> Dict[str, Any]:
        self._refresh_state_cache()
        key = "nearest_sensor" if sensor_limited else "nearest_all"
        cached = self._state_cache.get(key)
        if isinstance(cached, dict):
            return cached
        sensor_range = float(self.environment_config["sensor_range_m"])
        result: Dict[str, Any] = {
            "clearance": sensor_range if sensor_limited else float("inf"),
            "bearing": 0.0,
            "name": "none",
            "kind": "none",
            "closing_speed": 0.0,
            "tcpa": float(self.environment_config["tcpa_horizon_seconds"]),
            "dcpa": sensor_range,
            "dynamic": False,
            "obstacle": None,
        }
        for obstacle, clearance, bearing, target_x, target_z in self._obstacle_measurements():
            if sensor_limited and clearance > sensor_range:
                continue
            if clearance >= float(result["clearance"]):
                continue
            closing, tcpa, dcpa = self._relative_motion(
                obstacle,
                target_x,
                target_z,
            )
            result = {
                "clearance": clearance,
                "bearing": bearing,
                "name": obstacle.name,
                "kind": obstacle.kind,
                "closing_speed": closing,
                "tcpa": tcpa,
                "dcpa": dcpa,
                "dynamic": obstacle.dynamic,
                "obstacle": obstacle,
            }
        if not math.isfinite(float(result["clearance"])):
            result["clearance"] = 9999.0
        if sensor_limited:
            result["clearance"] = float(
                np.clip(
                    float(result["clearance"])
                    + float(
                        self.rng.normal(
                            0.0,
                            float(
                                self.environment_config[
                                    "sensor_distance_noise_std_m"
                                ]
                            ),
                        )
                    ),
                    -sensor_range,
                    sensor_range,
                )
            )
            result["bearing"] = _wrap_angle(
                float(result["bearing"])
                + math.radians(
                    float(
                        self.rng.normal(
                            0.0,
                            float(
                                self.environment_config[
                                    "sensor_bearing_noise_degrees"
                                ]
                            ),
                        )
                    )
                )
            )
        self._state_cache[key] = result
        return result

    def _sector_clearances(self, sensor_range: float) -> Dict[str, float]:
        self._refresh_state_cache()
        cached = self._state_cache.get("sector_clearances")
        if isinstance(cached, dict):
            return cached
        result = {
            "front": sensor_range,
            "port": sensor_range,
            "starboard": sensor_range,
        }
        for _obstacle, clearance, bearing, _target_x, _target_z in self._obstacle_measurements():
            if clearance > sensor_range:
                continue
            degrees = math.degrees(bearing)
            if abs(degrees) <= 55.0:
                result["front"] = min(result["front"], clearance)
            elif degrees < 0.0:
                result["port"] = min(result["port"], clearance)
            else:
                result["starboard"] = min(result["starboard"], clearance)
        self._state_cache["sector_clearances"] = result
        return result

    def _obstacle_measurements(
        self,
    ) -> List[Tuple[ObstacleRecord, float, float, float, float]]:
        self._refresh_state_cache()
        cached = self._state_cache.get("obstacle_measurements")
        if isinstance(cached, list):
            return cached
        sensor_range = float(self.environment_config["sensor_range_m"])
        candidates = sorted(
            (
                (self._bbox_clearance_lower_bound(obstacle), obstacle)
                for obstacle in self.obstacles
            ),
            key=lambda item: item[0],
        )
        best = float("inf")
        measurements: List[
            Tuple[ObstacleRecord, float, float, float, float]
        ] = []
        for lower_bound, obstacle in candidates:
            if lower_bound > sensor_range and lower_bound > best:
                continue
            clearance, bearing, target_x, target_z = self._obstacle_distance(
                obstacle
            )
            best = min(best, clearance)
            measurements.append(
                (obstacle, clearance, bearing, target_x, target_z)
            )
        self._state_cache["obstacle_measurements"] = measurements
        return measurements

    def _build_sea_state(self, raw: Any, randomize: bool) -> Dict[str, float]:
        result = super()._build_sea_state(raw, randomize)
        source = raw if isinstance(raw, Mapping) else {}
        result["visibility_km"] = max(0.0, float(source.get("visibility_km", 10.0)))
        result["tide_meters"] = float(source.get("tide_meters", 0.0))
        return result

    def _observation(self) -> np.ndarray:
        base = super()._observation()
        depth, depth_valid = self._depth_at_position()
        ukc, ukc_valid = self._under_keel_clearance()
        fairway_inside, fairway_margin, fairway_valid = self._fairway_context()
        navigation = self._navigation_context()
        speed_limit = max(float(navigation.get("speed_limit_knots", 0.0) or 0.0), 0.1)
        speed_knots = abs(float(self.state[3])) / 0.514444
        vessel = self._vessel_profile()
        encounter = self._encounter_context()
        encounter_name = str(encounter["encounter"])
        bearing = float(encounter["bearing"])
        extension = np.asarray(
            [
                np.clip(float(self.sea_state.get("visibility_km", 0.0)) / 20.0, 0.0, 1.0),
                np.clip(float(self.sea_state.get("tide_meters", 0.0)) / 5.0, -1.0, 1.0),
                np.clip(depth / 30.0, 0.0, 1.0) if depth_valid else -1.0,
                np.clip(ukc / 10.0, -1.0, 1.0) if ukc_valid else -1.0,
                1.0 if fairway_inside else -1.0,
                (
                    np.clip(fairway_margin / float(self.environment_config["sensor_range_m"]), 0.0, 1.0)
                    if fairway_valid
                    else -1.0
                ),
                np.clip((speed_limit - speed_knots) / speed_limit, -1.0, 1.0),
                np.clip(float(vessel.get("length_meters", 0.0) or 0.0) / 400.0, 0.0, 1.0),
                np.clip(float(vessel.get("draft_meters", 0.0) or 0.0) / 25.0, 0.0, 1.0),
                math.sin(bearing),
                math.cos(bearing),
                1.0 if encounter_name == "head_on" else 0.0,
                1.0 if encounter_name == "crossing_starboard" else 0.0,
                1.0 if encounter_name == "crossing_port" else 0.0,
                1.0 if encounter_name == "overtaking" else 0.0,
                1.0 if bool(encounter["give_way"]) else 0.0,
                np.clip(self._traffic_density() / 10.0, 0.0, 1.0),
            ],
            dtype=np.float32,
        )
        observation = np.concatenate((base, extension))
        if observation.shape != (PORT_OPS_OBSERVATION_SIZE,):
            raise RuntimeError(
                f"port observation shape {observation.shape} does not match "
                f"{PORT_OPS_OBSERVATION_SIZE}"
            )
        return observation

    def _collision_status(self) -> Tuple[bool, bool, ObstacleRecord | None]:
        if self._boundary_clearance() <= 0.0:
            boundary = max(
                0.1,
                float(self.task.get("boundary_half_extent", 780.0))
                - float(self.environment_config["boundary_margin_m"])
                - self._effective_vessel_radius(),
            )
            self.state[0] = float(np.clip(self.state[0], -boundary, boundary))
            self.state[1] = float(np.clip(self.state[1], -boundary, boundary))
            return True, True, None
        nearest = self._nearest_obstacle(False)
        obstacle = nearest.get("obstacle")
        if float(nearest["clearance"]) <= 0.0:
            return True, False, obstacle
        ukc, valid = self._under_keel_clearance()
        grounding = not valid or ukc <= 0.0
        if grounding and not self._grounding_active:
            self.grounding_count += 1
        self._grounding_active = grounding
        if grounding:
            return (
                True,
                False,
                ObstacleRecord(
                    name=(
                        "under_keel_clearance"
                        if valid
                        else "unknown_depth_coverage"
                    ),
                    kind="terrain",
                    shape="circle",
                    x=float(self.state[0]),
                    z=float(self.state[1]),
                    radius=0.1,
                    source="enc_depth_area",
                ),
            )
        return False, False, None

    def step(
        self,
        action: Any,
    ) -> Tuple[np.ndarray, float, bool, bool, Dict[str, Any]]:
        command = (
            DISCRETE_ACTIONS[int(action)]
            if self.discrete_actions
            else np.clip(np.asarray(action, dtype=np.float32), -1.0, 1.0)
        )
        observation, reward, terminated, truncated, info = super().step(action)
        raw = self.config.get("rl_parameters", {})
        raw = raw if isinstance(raw, Mapping) else {}
        operational_penalty = 0.0
        ukc, ukc_valid = self._under_keel_clearance()
        minimum_ukc = float(
            self._navigation_context().get(
                "minimum_under_keel_clearance_meters",
                raw.get("minimum_under_keel_clearance_meters", 1.0),
            )
        )
        if ukc_valid and ukc < minimum_ukc:
            operational_penalty += (
                (minimum_ukc - ukc)
                / max(minimum_ukc, 0.1)
                * float(raw.get("penalty_under_keel_clearance", 2.5))
            )
        speed_limit = float(
            self._navigation_context().get("speed_limit_knots", 0.0) or 0.0
        )
        speed_knots = abs(float(self.state[3])) / 0.514444
        speed_violation = speed_limit > 0.0 and speed_knots > speed_limit
        if speed_violation and not self._speed_violation_active:
            self.speed_violation_count += 1
        self._speed_violation_active = speed_violation
        if speed_violation:
            operational_penalty += (
                (speed_knots - speed_limit)
                / max(speed_limit, 0.1)
                * float(raw.get("penalty_speed_limit", 0.8))
            )
        fairway_inside, _margin, fairway_valid = self._fairway_context()
        channel_departure = bool(
            self._navigation_context().get("enforce_fairway", False)
        ) and fairway_valid and not fairway_inside
        if channel_departure and not self._channel_departure_active:
            self.channel_departure_count += 1
        self._channel_departure_active = channel_departure
        if channel_departure:
            operational_penalty += float(raw.get("penalty_channel_departure", 1.2))
        encounter = self._encounter_context()
        predicted_conflict = (
            bool(encounter["give_way"])
            and float(encounter["tcpa"])
            < float(self.environment_config["tcpa_horizon_seconds"])
            and float(encounter["dcpa"]) < float(self.reward_config["safe_distance"])
        )
        encounter_name = str(encounter["encounter"])
        colreg_violation = bool(
            predicted_conflict
            and (
                (
                    encounter_name in ("head_on", "crossing_starboard")
                    and float(command[1]) < 0.1
                    and float(command[0]) > 0.15
                )
                or (
                    encounter_name == "overtaking"
                    and float(command[0]) > 0.35
                )
            )
        )
        if colreg_violation and not self._colreg_violation_active:
            self.colreg_violation_count += 1
        self._colreg_violation_active = colreg_violation
        if colreg_violation:
            operational_penalty += float(raw.get("penalty_colreg_give_way", 1.8))
        reward -= operational_penalty
        self.total_reward -= operational_penalty
        if self.trajectory:
            self.trajectory[-1]["reward"] = round(float(reward), 6)
            self.trajectory[-1]["operational_penalty"] = round(operational_penalty, 6)
            self.trajectory[-1]["under_keel_clearance_meters"] = round(ukc, 4)
            self.trajectory[-1]["encounter"] = encounter_name
            self.trajectory[-1]["give_way"] = bool(encounter["give_way"])
        info = self._info(
            terminated,
            truncated,
            bool(info.get("goal_reached", False)),
        )
        if terminated or truncated:
            info["episode"] = {"r": round(self.total_reward, 6), "l": self.steps}
        return observation, float(reward), terminated, truncated, info

    def _info(
        self,
        terminated: bool,
        truncated: bool,
        goal_reached: bool,
    ) -> Dict[str, Any]:
        info = super()._info(terminated, truncated, goal_reached)
        ukc, ukc_valid = self._under_keel_clearance()
        fairway_inside, fairway_margin, fairway_valid = self._fairway_context()
        encounter = self._encounter_context()
        info.update(
            {
                "observation_size": PORT_OPS_OBSERVATION_SIZE,
                "groundings": self.grounding_count,
                "speed_limit_violations": self.speed_violation_count,
                "channel_departures": self.channel_departure_count,
                "colreg_give_way_violations": self.colreg_violation_count,
                "under_keel_clearance_meters": ukc if ukc_valid else None,
                "fairway_inside": fairway_inside if fairway_valid else None,
                "fairway_margin_meters": fairway_margin if fairway_valid else None,
                "encounter": str(encounter["encounter"]),
                "give_way": bool(encounter["give_way"]),
                "traffic_density": self._traffic_density(),
            }
        )
        info["port_compliant_success"] = bool(
            info["is_success"]
            and self.grounding_count == 0
            and self.speed_violation_count == 0
            and self.channel_departure_count == 0
            and self.colreg_violation_count == 0
        )
        return info
