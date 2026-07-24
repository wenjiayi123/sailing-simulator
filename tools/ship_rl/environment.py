"""Dataset-driven Gymnasium environment for terrain-aware ship navigation.

Godot is never imported by the trainer. Static scene geometry is exported as a
numeric snapshot and may be merged into each dataset task explicitly. Training
therefore remains headless while cliffs, rocks, piers, polygons, moving traffic,
the vessel safety envelope, sensing limits, and domain randomization all affect
the actual transition and reward functions.
"""

from __future__ import annotations

import hashlib
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Mapping, Sequence, Tuple

import gymnasium as gym
import numpy as np
from gymnasium import spaces


DISCRETE_ACTIONS = np.asarray(
    [
        (-1.0, -1.0), (-1.0, 0.0), (-1.0, 1.0),
        (0.0, -1.0), (0.0, 0.0), (0.0, 1.0),
        (1.0, -1.0), (1.0, 0.0), (1.0, 1.0),
    ],
    dtype=np.float32,
)

OBSERVATION_SIZE = 28


@dataclass(frozen=True)
class ShipPerformance:
    max_forward_speed: float = 18.0
    max_reverse_speed: float = 5.5
    acceleration: float = 3.6
    deceleration: float = 2.2
    brake_acceleration: float = 6.4
    throttle_response: float = 1.65
    rudder_response: float = 2.45
    max_turn_rate_degrees: float = 82.0
    low_speed_turn_factor: float = 0.18
    reverse_turn_factor: float = 0.58

    @classmethod
    def from_mapping(cls, value: Mapping[str, Any]) -> "ShipPerformance":
        defaults = cls()
        return cls(**{field: float(value.get(field, getattr(defaults, field))) for field in cls.__dataclass_fields__})


@dataclass
class ObstacleRecord:
    name: str
    kind: str
    shape: str
    x: float
    z: float
    radius: float = 0.0
    half_x: float = 0.0
    half_z: float = 0.0
    points: Tuple[Tuple[float, float], ...] = ()
    vx: float = 0.0
    vz: float = 0.0
    dynamic: bool = False
    source: str = "dataset"


def _read_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _resolve_dataset_path(config: Mapping[str, Any], config_path: Path | None) -> Path | None:
    dataset = config.get("dataset", {})
    raw = dataset.get("path", "") if isinstance(dataset, Mapping) else ""
    if not raw:
        return None
    value = str(raw)
    if value.startswith("res://"):
        if config_path is None:
            return None
        project_root = config_path
        while project_root.parent != project_root and not (project_root / "project.godot").exists():
            project_root = project_root.parent
        return project_root / value.removeprefix("res://")
    candidate = Path(value).expanduser()
    if not candidate.is_absolute() and config_path is not None:
        candidate = config_path.parent / candidate
    return candidate.resolve()


def _task_from_world(config: Mapping[str, Any], task_id: str) -> Dict[str, Any]:
    world = config.get("world", {}) if isinstance(config.get("world", {}), Mapping) else {}
    route = world.get("route", {}) if isinstance(world.get("route", {}), Mapping) else {}
    obstacles = world.get("obstacles", {}) if isinstance(world.get("obstacles", {}), Mapping) else {}
    ships = config.get("ships", [])
    first_ship = ships[0] if isinstance(ships, Sequence) and ships else {}
    position = first_ship.get("position", {}) if isinstance(first_ship, Mapping) else {}
    telemetry = first_ship.get("telemetry", {}) if isinstance(first_ship, Mapping) else {}
    return {
        "id": task_id,
        "start": {
            "x": float(position.get("x", 0.0)),
            "z": float(position.get("z", 0.0)),
            "heading_degrees": float(telemetry.get("heading_degrees", 180.0)),
        },
        "route": route.get("waypoints", []),
        "arrival_radius": float(route.get("arrival_radius", 16.0)),
        "boundary_half_extent": float(obstacles.get("boundary_half_extent", 780.0)),
        "obstacles": [*obstacles.get("rocks", []), *obstacles.get("boxes", [])],
        "sea_state": world.get("sea_state", {}),
    }


def load_experiment(config_path: str | Path) -> Tuple[Dict[str, Any], Dict[str, Any], Path | None]:
    """Load a Godot experiment plus immutable train/validation/test tasks."""

    path = Path(config_path).expanduser().resolve()
    config = _read_json(path)
    dataset_path = _resolve_dataset_path(config, path)
    if dataset_path is not None:
        if not dataset_path.exists():
            raise FileNotFoundError(f"configured port dataset does not exist: {dataset_path}")
        dataset = _read_json(dataset_path)
    elif bool(config.get("allow_runtime_snapshot_dataset", False)):
        task = _task_from_world(config, "godot_world_snapshot")
        dataset = {
            "schema_version": "ship_port_dataset_v2",
            "name": "Godot world snapshot fallback",
            "source": {"type": "runtime_snapshot", "license": "project"},
            "splits": {"train": [task], "validation": [task], "test": [task]},
        }
        dataset_path = None
    else:
        raise ValueError("training config must declare dataset.path with train/validation/test splits")
    splits = dataset.get("splits", {})
    for split in ("train", "validation", "test"):
        if not isinstance(splits.get(split), list) or not splits[split]:
            raise ValueError(f"dataset split '{split}' is missing or empty")
    return config, dataset, dataset_path


def dataset_fingerprint(dataset: Mapping[str, Any]) -> str:
    canonical = json.dumps(dataset, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def experiment_fingerprint(config: Mapping[str, Any]) -> str:
    """Fingerprint dynamics, rewards, environment interaction settings, and scene snapshot."""

    relevant = {
        "schema_version": config.get("schema_version"),
        "delta": config.get("delta"),
        "dataset": config.get("dataset"),
        "rl_parameters": config.get("rl_parameters"),
        "environment_parameters": config.get("environment_parameters"),
        "ships": config.get("ships"),
        "world": config.get("world"),
    }
    canonical = json.dumps(relevant, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


class ShipNavigationEnv(gym.Env[np.ndarray, Any]):
    """Kinematic vessel with terrain, traffic, sensing, and safety-envelope interaction."""

    metadata = {"render_modes": ["ansi"], "render_fps": 10}

    def __init__(
        self,
        experiment_config: Mapping[str, Any],
        dataset: Mapping[str, Any],
        split: str = "train",
        discrete_actions: bool = False,
        max_steps: int = 800,
        seed: int = 0,
        render_mode: str | None = None,
        task_index: int | None = None,
    ) -> None:
        super().__init__()
        if render_mode not in (None, "ansi"):
            raise ValueError("training environment has no graphical renderer")
        self.render_mode = render_mode
        self.config = dict(experiment_config)
        self.dataset = dict(dataset)
        self.split = split
        self.tasks: List[Dict[str, Any]] = list(dataset["splits"][split])
        self.discrete_actions = bool(discrete_actions)
        self.max_steps = max(1, int(max_steps))
        self.fixed_task_index = task_index
        self.delta = float(self.config.get("delta", 0.1))
        self.rng = np.random.default_rng(seed)
        self.reward_config = self._reward_config()
        self.environment_config = self._environment_config()
        self.performance = self._performance_config()
        self.action_space = spaces.Discrete(len(DISCRETE_ACTIONS)) if self.discrete_actions else spaces.Box(
            low=-1.0, high=1.0, shape=(2,), dtype=np.float32
        )
        self.observation_space = spaces.Box(low=-1.0, high=1.0, shape=(OBSERVATION_SIZE,), dtype=np.float32)
        self.task: Dict[str, Any] = {}
        self.route: List[Tuple[float, float]] = []
        self.obstacles: List[ObstacleRecord] = []
        self.sea_state: Dict[str, float] = {}
        self.state = np.zeros(6, dtype=np.float64)  # x, z, heading, signed speed, throttle, rudder
        self.waypoint_index = 0
        self.steps = 0
        self.collision_count = 0
        self.terrain_collision_count = 0
        self.near_miss_count = 0
        self.minimum_clearance = float("inf")
        self.minimum_dcpa = float("inf")
        self.max_cross_track_error = 0.0
        self.path_length = 0.0
        self.total_reward = 0.0
        self.previous_action = np.zeros(2, dtype=np.float32)
        self.collision_active = False
        self.near_miss_active = False
        self.last_collision: Dict[str, Any] = {}
        self.trajectory: List[Dict[str, Any]] = []

    def _performance_config(self) -> ShipPerformance:
        ships = self.config.get("ships", [])
        first = ships[0] if isinstance(ships, list) and ships else {}
        raw = first.get("performance", first) if isinstance(first, Mapping) else {}
        return ShipPerformance.from_mapping(raw)

    def _reward_config(self) -> Dict[str, float]:
        raw = self.config.get("rl_parameters", {})
        return {
            "progress": float(raw.get("reward_progress", 2.8)),
            "heading": float(raw.get("reward_heading", 1.6)),
            "speed": float(raw.get("reward_speed", 0.9)),
            "collision": float(raw.get("penalty_collision", 36.0)),
            "terrain_collision": float(raw.get("penalty_terrain_collision", 52.0)),
            "boundary": float(raw.get("penalty_boundary", 22.0)),
            "rudder": float(raw.get("penalty_rudder", 1.2)),
            "proximity": float(raw.get("penalty_proximity", 0.8)),
            "predicted_collision": float(
                raw.get("penalty_predicted_collision", 1.4)
            ),
            "cross_track": float(raw.get("penalty_cross_track", 0.12)),
            "action_slew": float(raw.get("penalty_action_slew", 0.04)),
            "step": float(raw.get("penalty_step", 0.003)),
            "safe_distance": float(raw.get("safe_distance", 42.0)),
        }

    def _environment_config(self) -> Dict[str, float | bool]:
        raw = self.config.get("environment_parameters", self.config.get("rl_parameters", {}))
        return {
            "vessel_radius_m": max(0.1, float(raw.get("vessel_radius_m", 3.2))),
            "obstacle_inflation_m": max(0.0, float(raw.get("obstacle_inflation_m", 1.5))),
            "cliff_inflation_m": max(0.0, float(raw.get("cliff_inflation_m", 8.0))),
            "boundary_margin_m": max(0.0, float(raw.get("boundary_margin_m", 4.0))),
            "sensor_range_m": max(10.0, float(raw.get("sensor_range_m", 220.0))),
            "tcpa_horizon_seconds": max(1.0, float(raw.get("tcpa_horizon_seconds", 180.0))),
            "terminate_on_collision": bool(round(float(raw.get("terminate_on_collision", 1.0)))),
            "merge_scene_obstacles": bool(round(float(raw.get("merge_scene_obstacles", 1.0)))),
            "domain_randomization": bool(round(float(raw.get("domain_randomization", 1.0)))),
            "randomize_evaluation": bool(round(float(raw.get("randomize_evaluation", 0.0)))),
            "start_position_jitter_m": max(0.0, float(raw.get("start_position_jitter_m", 3.0))),
            "start_heading_jitter_degrees": max(0.0, float(raw.get("start_heading_jitter_degrees", 6.0))),
            "obstacle_position_jitter_m": max(0.0, float(raw.get("obstacle_position_jitter_m", 1.5))),
            "obstacle_size_jitter_m": max(0.0, float(raw.get("obstacle_size_jitter_m", 0.8))),
            "current_speed_jitter_knots": max(0.0, float(raw.get("current_speed_jitter_knots", 0.25))),
            "current_direction_jitter_degrees": max(0.0, float(raw.get("current_direction_jitter_degrees", 10.0))),
            "wind_speed_jitter_knots": max(0.0, float(raw.get("wind_speed_jitter_knots", 1.5))),
            "wind_direction_jitter_degrees": max(0.0, float(raw.get("wind_direction_jitter_degrees", 8.0))),
            "wave_height_jitter_m": max(0.0, float(raw.get("wave_height_jitter_m", 0.15))),
            "wave_direction_jitter_degrees": max(0.0, float(raw.get("wave_direction_jitter_degrees", 8.0))),
            "wind_leeway_factor": max(0.0, float(raw.get("wind_leeway_factor", 0.012))),
            "wave_drift_mps_per_meter": max(0.0, float(raw.get("wave_drift_mps_per_meter", 0.08))),
            "sensor_distance_noise_std_m": max(0.0, float(raw.get("sensor_distance_noise_std_m", 0.35))),
            "sensor_bearing_noise_degrees": max(0.0, float(raw.get("sensor_bearing_noise_degrees", 0.6))),
            "generated_traffic_count": max(0, int(round(float(raw.get("generated_traffic_count", 2.0))))),
            "generated_traffic_speed_knots": max(0.0, float(raw.get("generated_traffic_speed_knots", 5.0))),
            "generated_traffic_radius_m": max(1.0, float(raw.get("generated_traffic_radius_m", 6.0))),
        }

    def reset(self, *, seed: int | None = None, options: Dict[str, Any] | None = None) -> Tuple[np.ndarray, Dict[str, Any]]:
        super().reset(seed=seed)
        if seed is not None:
            self.rng = np.random.default_rng(seed)
        requested = (options or {}).get("task_index", self.fixed_task_index)
        task_index = int(requested) % len(self.tasks) if requested is not None else int(self.rng.integers(len(self.tasks)))
        self.task = json.loads(json.dumps(self.tasks[task_index]))
        self.route = [self._point_tuple(point) for point in self.task.get("route", [])]
        if not self.route:
            raise ValueError(f"task {self.task.get('id', task_index)!r} has no route")
        randomize = self._randomization_active()
        self.sea_state = self._build_sea_state(self.task.get("sea_state", {}), randomize)
        self.obstacles = self._build_obstacles(randomize)
        start = self.task.get("start", {})
        jitter = float(self.environment_config["start_position_jitter_m"]) if randomize else 0.0
        heading_jitter = float(self.environment_config["start_heading_jitter_degrees"]) if randomize else 0.0
        self.state[:] = (
            float(start.get("x", 0.0)) + float(self.rng.uniform(-jitter, jitter)),
            float(start.get("z", 0.0)) + float(self.rng.uniform(-jitter, jitter)),
            math.radians(float(start.get("heading_degrees", 180.0)) + float(self.rng.uniform(-heading_jitter, heading_jitter))),
            0.0, 0.0, 0.0,
        )
        self.waypoint_index = 0
        self.steps = 0
        self.collision_count = 0
        self.terrain_collision_count = 0
        self.near_miss_count = 0
        self.minimum_clearance = float("inf")
        self.minimum_dcpa = float("inf")
        self.max_cross_track_error = 0.0
        self.path_length = 0.0
        self.total_reward = 0.0
        self.previous_action[:] = 0.0
        self.collision_active = False
        self.near_miss_active = False
        self.last_collision = {}
        self.trajectory = []
        nearest = self._nearest_obstacle(False)
        self.minimum_clearance = float(nearest["clearance"])
        self._record_sample((0.0, 0.0), 0.0, False)
        return self._observation(), self._info(False, False, False)

    def step(self, action: Any) -> Tuple[np.ndarray, float, bool, bool, Dict[str, Any]]:
        command = DISCRETE_ACTIONS[int(action)] if self.discrete_actions else np.clip(np.asarray(action, dtype=np.float32), -1.0, 1.0)
        action_slew = float(np.sum(np.abs(command - self.previous_action)))
        previous = self.state[:2].copy()
        previous_distance = self._distance_to_target()
        self._advance_dynamic_obstacles()
        self._integrate(float(command[0]), float(command[1]))
        self.steps += 1
        distance = self._distance_to_target()
        collision, boundary, collision_obstacle = self._collision_status()
        collision_event = collision and not self.collision_active
        if collision_event:
            self.collision_count += 1
            if collision_obstacle and collision_obstacle.kind in ("cliff", "terrain", "shoreline"):
                self.terrain_collision_count += 1
            self.last_collision = {
                "name": collision_obstacle.name if collision_obstacle else "navigation_boundary",
                "kind": collision_obstacle.kind if collision_obstacle else "boundary",
                "step": self.steps,
            }
        self.collision_active = collision
        if collision:
            self.state[3] *= 0.25
        nearest = self._nearest_obstacle(False)
        clearance = float(nearest["clearance"])
        self.minimum_clearance = min(self.minimum_clearance, clearance)
        if bool(nearest["dynamic"]):
            self.minimum_dcpa = min(
                self.minimum_dcpa,
                float(nearest["dcpa"]),
            )
        safe_distance = max(self.reward_config["safe_distance"], 1.0)
        predicted_dynamic_conflict = (
            bool(nearest["dynamic"])
            and float(nearest["tcpa"])
            < float(self.environment_config["tcpa_horizon_seconds"])
            and float(nearest["dcpa"]) < safe_distance
        )
        near_miss = 0.0 < clearance < safe_distance or predicted_dynamic_conflict
        if near_miss and not self.near_miss_active:
            self.near_miss_count += 1
        self.near_miss_active = near_miss
        cross_track = self._cross_track_error()
        self.max_cross_track_error = max(self.max_cross_track_error, abs(cross_track))
        self.path_length += float(np.linalg.norm(self.state[:2] - previous))
        reached_waypoint = distance <= float(self.task.get("arrival_radius", 12.0))
        goal_reached = False
        if reached_waypoint:
            if self.waypoint_index >= len(self.route) - 1:
                goal_reached = True
            else:
                self.waypoint_index += 1
        terminated = goal_reached or (collision and bool(self.environment_config["terminate_on_collision"]))
        truncated = self.steps >= self.max_steps and not terminated
        heading_error = abs(self._heading_error())
        speed_ratio = abs(self.state[3]) / max(self.performance.max_forward_speed, 0.1)
        reward = (previous_distance - distance) * self.reward_config["progress"]
        reward += math.cos(heading_error) * self.reward_config["heading"] * 0.02
        reward += min(speed_ratio, 1.0) * self.reward_config["speed"] * 0.01
        reward -= abs(self.state[5]) * self.reward_config["rudder"] * 0.01
        reward -= min(abs(cross_track) / safe_distance, 3.0) * self.reward_config["cross_track"]
        reward -= action_slew * self.reward_config["action_slew"]
        reward -= self.reward_config["step"]
        if clearance < safe_distance:
            reward -= (safe_distance - clearance) / safe_distance * self.reward_config["proximity"]
        if predicted_dynamic_conflict:
            horizon = float(self.environment_config["tcpa_horizon_seconds"])
            dcpa_factor = (safe_distance - float(nearest["dcpa"])) / safe_distance
            urgency = 1.0 - float(nearest["tcpa"]) / horizon
            reward -= (
                max(0.0, dcpa_factor)
                * max(0.0, urgency)
                * self.reward_config["predicted_collision"]
            )
        if collision_event:
            if boundary:
                reward -= self.reward_config["boundary"]
            elif collision_obstacle and collision_obstacle.kind in ("cliff", "terrain", "shoreline"):
                reward -= self.reward_config["terrain_collision"]
            else:
                reward -= self.reward_config["collision"]
        if reached_waypoint:
            reward += 12.0 if goal_reached else 3.0
        self.total_reward += reward
        self.previous_action[:] = command
        self._record_sample(command, reward, collision)
        info = self._info(terminated, truncated, goal_reached)
        if terminated or truncated:
            info["episode"] = {"r": round(self.total_reward, 6), "l": self.steps}
        return self._observation(), float(reward), terminated, truncated, info

    def _randomization_active(self) -> bool:
        return bool(self.environment_config["domain_randomization"]) and (
            self.split == "train" or bool(self.environment_config["randomize_evaluation"])
        )

    def _build_sea_state(self, raw: Any, randomize: bool) -> Dict[str, float]:
        source = raw if isinstance(raw, Mapping) else {}
        result = {
            "wind_speed_knots": float(source.get("wind_speed_knots", 0.0)),
            "wind_direction_degrees": float(
                source.get("wind_direction_degrees", 0.0)
            ),
            "wave_height_meters": max(
                0.0,
                float(source.get("wave_height_meters", 0.0)),
            ),
            "wave_direction_degrees": float(
                source.get("wave_direction_degrees", 0.0)
            ),
            "wave_period_seconds": max(
                0.0,
                float(source.get("wave_period_seconds", 0.0)),
            ),
            "current_speed_knots": float(source.get("current_speed_knots", 0.0)),
            "current_direction_degrees": float(source.get("current_direction_degrees", 0.0)),
        }
        if randomize:
            result["wind_speed_knots"] = max(0.0, result["wind_speed_knots"] + float(self.rng.normal(0.0, float(self.environment_config["wind_speed_jitter_knots"]))))
            result["wind_direction_degrees"] = (
                result["wind_direction_degrees"]
                + float(
                    self.rng.normal(
                        0.0,
                        float(
                            self.environment_config[
                                "wind_direction_jitter_degrees"
                            ]
                        ),
                    )
                )
            ) % 360.0
            result["wave_height_meters"] = max(
                0.0,
                result["wave_height_meters"]
                + float(
                    self.rng.normal(
                        0.0,
                        float(self.environment_config["wave_height_jitter_m"]),
                    )
                ),
            )
            result["wave_direction_degrees"] = (
                result["wave_direction_degrees"]
                + float(
                    self.rng.normal(
                        0.0,
                        float(
                            self.environment_config[
                                "wave_direction_jitter_degrees"
                            ]
                        ),
                    )
                )
            ) % 360.0
            result["current_speed_knots"] = max(0.0, result["current_speed_knots"] + float(self.rng.normal(0.0, float(self.environment_config["current_speed_jitter_knots"]))))
            result["current_direction_degrees"] = (result["current_direction_degrees"] + float(self.rng.normal(0.0, float(self.environment_config["current_direction_jitter_degrees"])))) % 360.0
        return result

    def _build_obstacles(self, randomize: bool) -> List[ObstacleRecord]:
        raw_items: List[Tuple[Mapping[str, Any], str]] = []
        for key, source in (("obstacles", "dataset"), ("terrain", "dataset_terrain"), ("dynamic_obstacles", "dataset_dynamic")):
            for item in self.task.get(key, []):
                if isinstance(item, Mapping):
                    raw_items.append((item, source))
        if bool(self.environment_config["merge_scene_obstacles"]):
            world = self.config.get("world", {})
            scene = world.get("obstacles", {}) if isinstance(world, Mapping) else {}
            if isinstance(scene, Mapping):
                for key in ("rocks", "boxes"):
                    for item in scene.get(key, []):
                        if isinstance(item, Mapping):
                            raw_items.append((item, "godot_scene_snapshot"))
        records: List[ObstacleRecord] = []
        names: set[str] = set()
        for index, (item, source) in enumerate(raw_items):
            record = self._obstacle_record(item, index, source, randomize)
            if record.name in names:
                continue
            names.add(record.name)
            records.append(record)
        if randomize:
            records.extend(self._generated_traffic(records))
        return records

    def _obstacle_record(self, value: Mapping[str, Any], index: int, source: str, randomize: bool) -> ObstacleRecord:
        position = value.get("position", value)
        position = position if isinstance(position, Mapping) else {}
        size = value.get("size", {})
        size = size if isinstance(size, Mapping) else {}
        raw_points = value.get("points", [])
        shape = str(value.get("shape", "polygon" if raw_points else ("box" if size else "circle"))).lower()
        kind = str(value.get("kind", "terrain" if source == "dataset_terrain" else ("traffic" if source == "dataset_dynamic" else "obstacle"))).lower()
        x = float(position.get("x", value.get("x", 0.0)))
        z = float(position.get("z", value.get("z", 0.0)))
        radius = float(value.get("radius", 0.5 * max(float(size.get("x", 2.0)), float(size.get("z", 2.0)))))
        half_x = max(0.1, float(size.get("x", radius * 2.0)) * 0.5)
        half_z = max(0.1, float(size.get("z", radius * 2.0)) * 0.5)
        points = tuple(self._point_tuple(point) for point in raw_points)
        has_explicit_position = isinstance(value.get("position"), Mapping) or "x" in value or "z" in value
        if shape == "polygon" and points and not has_explicit_position:
            x = float(np.mean([point[0] for point in points]))
            z = float(np.mean([point[1] for point in points]))
        if randomize:
            position_jitter = float(self.environment_config["obstacle_position_jitter_m"])
            size_jitter = float(self.environment_config["obstacle_size_jitter_m"])
            dx = float(self.rng.uniform(-position_jitter, position_jitter))
            dz = float(self.rng.uniform(-position_jitter, position_jitter))
            x, z = x + dx, z + dz
            radius = max(0.5, radius + float(self.rng.uniform(-size_jitter, size_jitter)))
            half_x = max(0.5, half_x + float(self.rng.uniform(-size_jitter, size_jitter)))
            half_z = max(0.5, half_z + float(self.rng.uniform(-size_jitter, size_jitter)))
            points = tuple((px + dx, pz + dz) for px, pz in points)
        velocity = value.get("velocity", {})
        velocity = velocity if isinstance(velocity, Mapping) else {}
        speed_mps = float(value.get("speed_knots", 0.0)) * 0.514444
        course = math.radians(float(value.get("course_degrees", 0.0)))
        vx = float(velocity.get("x", math.sin(course) * speed_mps))
        vz = float(velocity.get("z", math.cos(course) * speed_mps))
        dynamic = bool(value.get("dynamic", False) or source == "dataset_dynamic" or abs(vx) + abs(vz) > 1e-6)
        return ObstacleRecord(
            name=str(value.get("name", f"obstacle_{index}")), kind=kind, shape=shape,
            x=x, z=z, radius=max(0.1, radius), half_x=half_x, half_z=half_z,
            points=points, vx=vx, vz=vz, dynamic=dynamic, source=source,
        )

    def _generated_traffic(self, existing: Sequence[ObstacleRecord]) -> List[ObstacleRecord]:
        count = int(self.environment_config["generated_traffic_count"])
        if count <= 0 or not self.route:
            return []
        speed = float(self.environment_config["generated_traffic_speed_knots"]) * 0.514444
        radius = float(self.environment_config["generated_traffic_radius_m"])
        generated: List[ObstacleRecord] = []
        start = self._point_tuple(self.task.get("start", {}))
        path = [start, *self.route]
        for index in range(count):
            segment_index = index % max(len(path) - 1, 1)
            ax, az = path[segment_index]
            bx, bz = path[min(segment_index + 1, len(path) - 1)]
            ratio = (index + 1.0) / (count + 1.0)
            cx, cz = ax + (bx - ax) * ratio, az + (bz - az) * ratio
            length = max(math.hypot(bx - ax, bz - az), 1.0)
            px, pz = -(bz - az) / length, (bx - ax) / length
            side = -1.0 if index % 2 == 0 else 1.0
            offset = 36.0 + 8.0 * (index % 3)
            generated.append(ObstacleRecord(
                name=f"generated_training_traffic_{index + 1:02d}", kind="traffic", shape="circle",
                x=cx + px * offset * side, z=cz + pz * offset * side, radius=radius,
                vx=-px * speed * side, vz=-pz * speed * side, dynamic=True,
                source="generated_domain_randomization",
            ))
        return generated

    def _advance_dynamic_obstacles(self) -> None:
        boundary = max(float(self.task.get("boundary_half_extent", 780.0)), 1.0)
        for obstacle in self.obstacles:
            if not obstacle.dynamic:
                continue
            obstacle.x += obstacle.vx * self.delta
            obstacle.z += obstacle.vz * self.delta
            if abs(obstacle.x) > boundary:
                obstacle.x = float(np.clip(obstacle.x, -boundary, boundary))
                obstacle.vx *= -1.0
            if abs(obstacle.z) > boundary:
                obstacle.z = float(np.clip(obstacle.z, -boundary, boundary))
                obstacle.vz *= -1.0

    def _integrate(self, throttle_command: float, rudder_command: float) -> None:
        perf = self.performance
        x, z, heading, speed, throttle, rudder = self.state
        throttle = _move_toward(throttle, throttle_command, perf.throttle_response * self.delta)
        rudder = _move_toward(rudder, rudder_command, perf.rudder_response * self.delta)
        target_speed = throttle * (perf.max_forward_speed if throttle >= 0.0 else perf.max_reverse_speed)
        rate = perf.acceleration if abs(target_speed) > abs(speed) else perf.deceleration
        if speed * target_speed < -0.05:
            rate = perf.brake_acceleration
        speed = _move_toward(speed, target_speed, rate * self.delta)
        reference = perf.max_forward_speed if speed >= 0.0 else perf.max_reverse_speed
        ratio = float(np.clip(abs(speed) / max(reference, 1e-6), 0.0, 1.0))
        low_turn = perf.low_speed_turn_factor if speed >= -0.05 else perf.reverse_turn_factor
        turn_authority = low_turn + (1.0 - low_turn) * ratio
        reverse = 1.0 if speed >= -0.05 else -1.0
        heading = _wrap_angle(heading + rudder * math.radians(perf.max_turn_rate_degrees) * turn_authority * reverse * self.delta)
        current_speed = float(self.sea_state.get("current_speed_knots", 0.0)) * 0.514444
        current_heading = math.radians(float(self.sea_state.get("current_direction_degrees", 0.0)))
        wind_speed = (
            float(self.sea_state.get("wind_speed_knots", 0.0))
            * 0.514444
            * float(self.environment_config["wind_leeway_factor"])
        )
        wind_heading = math.radians(
            float(self.sea_state.get("wind_direction_degrees", 0.0))
        )
        wave_drift = (
            float(self.sea_state.get("wave_height_meters", 0.0))
            * float(self.environment_config["wave_drift_mps_per_meter"])
        )
        wave_heading = math.radians(
            float(self.sea_state.get("wave_direction_degrees", 0.0))
        )
        x += (
            math.sin(heading) * speed
            + math.sin(current_heading) * current_speed
            + math.sin(wind_heading) * wind_speed
            + math.sin(wave_heading) * wave_drift
        ) * self.delta
        z += (
            math.cos(heading) * speed
            + math.cos(current_heading) * current_speed
            + math.cos(wind_heading) * wind_speed
            + math.cos(wave_heading) * wave_drift
        ) * self.delta
        self.state[:] = (x, z, heading, speed, throttle, rudder)

    def _observation(self) -> np.ndarray:
        _x, _z, heading, speed, throttle, rudder = self.state
        distance = self._distance_to_target()
        heading_error = self._heading_error()
        nearest = self._nearest_obstacle(True)
        clearance = float(nearest["clearance"])
        obstacle_bearing = float(nearest["bearing"])
        cross_track = self._cross_track_error()
        boundary = max(float(self.task.get("boundary_half_extent", 780.0)), 1.0)
        boundary_clearance = self._boundary_clearance()
        current_speed = float(self.sea_state.get("current_speed_knots", 0.0)) * 0.514444
        current_heading = math.radians(float(self.sea_state.get("current_direction_degrees", 0.0))) - heading
        wind_speed = float(self.sea_state.get("wind_speed_knots", 0.0)) / 60.0
        wind_heading = (
            math.radians(
                float(self.sea_state.get("wind_direction_degrees", 0.0))
            )
            - heading
        )
        wave_height = float(
            self.sea_state.get("wave_height_meters", 0.0)
        )
        wave_heading = (
            math.radians(
                float(self.sea_state.get("wave_direction_degrees", 0.0))
            )
            - heading
        )
        waypoint_progress = self.waypoint_index / max(len(self.route) - 1, 1)
        sensor_range = float(self.environment_config["sensor_range_m"])
        sectors = self._sector_clearances(sensor_range)
        return np.asarray(
            [
                np.clip(distance / (boundary * 2.0), 0.0, 1.0),
                math.sin(heading_error), math.cos(heading_error),
                np.clip(speed / max(self.performance.max_forward_speed, 0.1), -1.0, 1.0),
                throttle, rudder,
                np.clip(cross_track / boundary, -1.0, 1.0),
                np.clip(clearance / sensor_range, -1.0, 1.0),
                math.sin(obstacle_bearing), math.cos(obstacle_bearing),
                np.clip(current_speed / 4.2, 0.0, 1.0),
                math.sin(current_heading), math.cos(current_heading),
                np.clip(wind_speed, 0.0, 1.0),
                math.sin(wind_heading), math.cos(wind_heading),
                np.clip(wave_height / 8.0, 0.0, 1.0),
                math.sin(wave_heading), math.cos(wave_heading),
                waypoint_progress,
                np.clip(float(nearest["closing_speed"]) / max(self.performance.max_forward_speed, 0.1), -1.0, 1.0),
                np.clip(float(nearest["tcpa"]) / float(self.environment_config["tcpa_horizon_seconds"]), 0.0, 1.0),
                np.clip(float(nearest["dcpa"]) / sensor_range, 0.0, 1.0),
                1.0 if bool(nearest["dynamic"]) else 0.0,
                np.clip(boundary_clearance / boundary, -1.0, 1.0),
                np.clip(sectors["front"] / sensor_range, -1.0, 1.0),
                np.clip(sectors["port"] / sensor_range, -1.0, 1.0),
                np.clip(sectors["starboard"] / sensor_range, -1.0, 1.0),
            ],
            dtype=np.float32,
        )

    def navigation_error(self) -> Tuple[float, float, float]:
        nearest = self._nearest_obstacle(False)
        return self._distance_to_target(), self._heading_error(), float(nearest["clearance"])

    def avoidance_context(self) -> Dict[str, Any]:
        return self._nearest_obstacle(True)

    def _distance_to_target(self) -> float:
        target = self.route[min(self.waypoint_index, len(self.route) - 1)]
        return math.hypot(target[0] - self.state[0], target[1] - self.state[1])

    def _heading_error(self) -> float:
        target = self.route[min(self.waypoint_index, len(self.route) - 1)]
        desired = math.atan2(target[0] - self.state[0], target[1] - self.state[1])
        return _wrap_angle(desired - self.state[2])

    def _nearest_obstacle(self, sensor_limited: bool) -> Dict[str, Any]:
        sensor_range = float(self.environment_config["sensor_range_m"])
        nearest: Dict[str, Any] = {
            "clearance": float("inf"), "bearing": 0.0, "name": "none", "kind": "none",
            "closing_speed": 0.0,
            "tcpa": float(self.environment_config["tcpa_horizon_seconds"]),
            "dcpa": sensor_range,
            "dynamic": False,
            "obstacle": None,
        }
        for obstacle in self.obstacles:
            clearance, bearing, target_x, target_z = self._obstacle_distance(obstacle)
            if sensor_limited and clearance > sensor_range:
                continue
            if clearance < float(nearest["clearance"]):
                closing_speed, tcpa, dcpa = self._relative_motion(
                    obstacle,
                    target_x,
                    target_z,
                )
                nearest = {
                    "clearance": clearance, "bearing": bearing, "name": obstacle.name, "kind": obstacle.kind,
                    "closing_speed": closing_speed,
                    "tcpa": tcpa,
                    "dcpa": dcpa,
                    "dynamic": obstacle.dynamic,
                    "obstacle": obstacle,
                }
        if not math.isfinite(float(nearest["clearance"])):
            nearest["clearance"] = sensor_range if sensor_limited else 9999.0
        if sensor_limited:
            nearest["clearance"] = float(np.clip(
                float(nearest["clearance"]) + float(self.rng.normal(0.0, float(self.environment_config["sensor_distance_noise_std_m"]))),
                -sensor_range, sensor_range,
            ))
            nearest["bearing"] = _wrap_angle(float(nearest["bearing"]) + math.radians(float(self.rng.normal(0.0, float(self.environment_config["sensor_bearing_noise_degrees"])))))
        return nearest

    def _obstacle_distance(self, obstacle: ObstacleRecord) -> Tuple[float, float, float, float]:
        x, z = float(self.state[0]), float(self.state[1])
        inflation = self._obstacle_inflation(obstacle)
        if obstacle.shape == "box":
            half_x, half_z = obstacle.half_x + inflation, obstacle.half_z + inflation
            dx, dz = abs(x - obstacle.x) - half_x, abs(z - obstacle.z) - half_z
            outside = math.hypot(max(dx, 0.0), max(dz, 0.0))
            inside = min(max(dx, dz), 0.0)
            target_x = float(np.clip(x, obstacle.x - half_x, obstacle.x + half_x))
            target_z = float(np.clip(z, obstacle.z - half_z, obstacle.z + half_z))
            if dx <= 0.0 and dz <= 0.0:
                target_x, target_z = obstacle.x, obstacle.z
            return outside + inside, _wrap_angle(math.atan2(target_x - x, target_z - z) - self.state[2]), target_x, target_z
        if obstacle.shape == "polygon" and len(obstacle.points) >= 3:
            distance, target_x, target_z = _polygon_distance(x, z, obstacle.points)
            signed = -distance if _point_in_polygon(x, z, obstacle.points) else distance
            return signed - inflation, _wrap_angle(math.atan2(target_x - x, target_z - z) - self.state[2]), target_x, target_z
        dx, dz = obstacle.x - x, obstacle.z - z
        return math.hypot(dx, dz) - obstacle.radius - inflation, _wrap_angle(math.atan2(dx, dz) - self.state[2]), obstacle.x, obstacle.z

    def _obstacle_inflation(self, obstacle: ObstacleRecord) -> float:
        value = float(self.environment_config["vessel_radius_m"]) + float(self.environment_config["obstacle_inflation_m"])
        if obstacle.kind in ("cliff", "terrain", "shoreline"):
            value += float(self.environment_config["cliff_inflation_m"])
        return value

    def _relative_motion(
        self,
        obstacle: ObstacleRecord,
        target_x: float,
        target_z: float,
    ) -> Tuple[float, float, float]:
        relative = np.asarray([target_x - self.state[0], target_z - self.state[1]], dtype=np.float64)
        ship_velocity = np.asarray([math.sin(self.state[2]) * self.state[3], math.cos(self.state[2]) * self.state[3]])
        relative_velocity = np.asarray([obstacle.vx, obstacle.vz]) - ship_velocity
        distance = float(np.linalg.norm(relative))
        closing = -float(np.dot(relative / max(distance, 1e-6), relative_velocity))
        speed_squared = float(np.dot(relative_velocity, relative_velocity))
        horizon = float(self.environment_config["tcpa_horizon_seconds"])
        tcpa = float(np.clip(-np.dot(relative, relative_velocity) / speed_squared, 0.0, horizon)) if speed_squared > 1e-8 else horizon
        closest_relative = relative + relative_velocity * tcpa
        dcpa = float(np.linalg.norm(closest_relative))
        if obstacle.shape == "circle":
            dcpa -= obstacle.radius + self._obstacle_inflation(obstacle)
        return closing, tcpa, max(0.0, dcpa)

    def _sector_clearances(self, sensor_range: float) -> Dict[str, float]:
        values = {"front": sensor_range, "port": sensor_range, "starboard": sensor_range}
        for obstacle in self.obstacles:
            clearance, bearing, _tx, _tz = self._obstacle_distance(obstacle)
            if clearance > sensor_range:
                continue
            degrees = math.degrees(bearing)
            if abs(degrees) <= 55.0:
                values["front"] = min(values["front"], clearance)
            elif degrees < 0.0:
                values["port"] = min(values["port"], clearance)
            else:
                values["starboard"] = min(values["starboard"], clearance)
        return values

    def _boundary_clearance(self) -> float:
        boundary = float(self.task.get("boundary_half_extent", 780.0))
        effective = boundary - float(self.environment_config["boundary_margin_m"]) - float(self.environment_config["vessel_radius_m"])
        return min(effective - abs(float(self.state[0])), effective - abs(float(self.state[1])))

    def _collision_status(self) -> Tuple[bool, bool, ObstacleRecord | None]:
        if self._boundary_clearance() <= 0.0:
            boundary = max(
                0.1,
                float(self.task.get("boundary_half_extent", 780.0))
                - float(self.environment_config["boundary_margin_m"])
                - float(self.environment_config["vessel_radius_m"]),
            )
            self.state[0] = float(np.clip(self.state[0], -boundary, boundary))
            self.state[1] = float(np.clip(self.state[1], -boundary, boundary))
            return True, True, None
        nearest = self._nearest_obstacle(False)
        return float(nearest["clearance"]) <= 0.0, False, nearest.get("obstacle")

    def _cross_track_error(self) -> float:
        end = self.route[min(self.waypoint_index, len(self.route) - 1)]
        start = self.route[self.waypoint_index - 1] if self.waypoint_index > 0 else self._point_tuple(self.task.get("start", {}))
        ax, az = start
        bx, bz = end
        length = math.hypot(bx - ax, bz - az)
        if length <= 1e-6:
            return 0.0
        return ((self.state[0] - ax) * (bz - az) - (self.state[1] - az) * (bx - ax)) / length

    def _info(self, terminated: bool, truncated: bool, goal_reached: bool) -> Dict[str, Any]:
        nearest = self._nearest_obstacle(False)
        return {
            "task_id": str(self.task.get("id", "unknown")),
            "dataset_split": self.split,
            "is_success": bool(goal_reached and self.collision_count == 0),
            "goal_reached": bool(goal_reached),
            "truncated": bool(truncated),
            "collisions": self.collision_count,
            "terrain_collisions": self.terrain_collision_count,
            "near_misses": self.near_miss_count,
            "minimum_clearance_meters": float(nearest["clearance"]) if self.steps == 0 else self.minimum_clearance,
            "minimum_dcpa_meters": (
                float(nearest["dcpa"])
                if self.steps == 0 and bool(nearest["dynamic"])
                else (
                    self.minimum_dcpa
                    if math.isfinite(self.minimum_dcpa)
                    else float(self.environment_config["sensor_range_m"])
                )
            ),
            "nearest_obstacle_name": str(nearest["name"]),
            "nearest_obstacle_kind": str(nearest["kind"]),
            "max_cross_track_error_meters": self.max_cross_track_error,
            "path_length_meters": self.path_length,
            "waypoint_index": self.waypoint_index,
            "dynamic_obstacle_count": sum(1 for obstacle in self.obstacles if obstacle.dynamic),
            "observation_size": OBSERVATION_SIZE,
            "last_collision": dict(self.last_collision),
        }

    def _record_sample(self, command: Sequence[float], reward: float, collision: bool) -> None:
        nearest = self._nearest_obstacle(False)
        self.trajectory.append(
            {
                "index": len(self.trajectory), "time": round(self.steps * self.delta, 4),
                "x": round(float(self.state[0]), 5), "z": round(float(self.state[1]), 5),
                "heading_degrees": round(math.degrees(float(self.state[2])) % 360.0, 4),
                "speed_mps": round(float(self.state[3]), 5),
                "throttle": round(float(command[0]), 5), "rudder": round(float(command[1]), 5),
                "reward": round(float(reward), 6), "collision": bool(collision),
                "nearest_obstacle_name": str(nearest["name"]),
                "nearest_obstacle_kind": str(nearest["kind"]),
                "nearest_clearance_meters": round(float(nearest["clearance"]), 5),
                "nearest_tcpa_seconds": round(float(nearest["tcpa"]), 5),
                "nearest_dcpa_meters": round(float(nearest["dcpa"]), 5),
                "nearest_is_dynamic": bool(nearest["dynamic"]),
                "waypoint_index": self.waypoint_index,
                "dynamic_obstacles": [
                    {"name": obstacle.name, "x": round(obstacle.x, 5), "z": round(obstacle.z, 5)}
                    for obstacle in self.obstacles if obstacle.dynamic
                ],
            }
        )

    def obstacle_export_records(self) -> List[Dict[str, Any]]:
        records: List[Dict[str, Any]] = []
        for obstacle in self.obstacles:
            record: Dict[str, Any] = {
                "name": obstacle.name, "kind": obstacle.kind, "shape": obstacle.shape,
                "position": {"x": obstacle.x, "z": obstacle.z},
                "dynamic": obstacle.dynamic, "velocity": {"x": obstacle.vx, "z": obstacle.vz},
                "source": obstacle.source,
            }
            if obstacle.shape == "box":
                record["size"] = {"x": obstacle.half_x * 2.0, "y": 7.0, "z": obstacle.half_z * 2.0}
                record["radius"] = math.hypot(obstacle.half_x, obstacle.half_z)
            elif obstacle.shape == "polygon":
                record["points"] = [{"x": x, "z": z} for x, z in obstacle.points]
                record["radius"] = max((math.hypot(x - obstacle.x, z - obstacle.z) for x, z in obstacle.points), default=1.0)
            else:
                record["radius"] = obstacle.radius
                record["size"] = {"x": obstacle.radius * 2.0, "y": 7.0, "z": obstacle.radius * 2.0}
            records.append(record)
        return records

    @staticmethod
    def _point_tuple(value: Any) -> Tuple[float, float]:
        if isinstance(value, Mapping):
            return float(value.get("x", 0.0)), float(value.get("z", 0.0))
        return float(value[0]), float(value[1])

    def render(self) -> str | None:
        if self.render_mode == "ansi":
            nearest = self._nearest_obstacle(False)
            return f"task={self.task.get('id')} step={self.steps} x={self.state[0]:.1f} z={self.state[1]:.1f} nearest={nearest['name']}:{nearest['clearance']:.1f}m"
        return None


class LosPidController:
    """Line-of-sight PID baseline with explicit nearest-hazard avoidance."""

    def __init__(self, kp: float = 1.35, ki: float = 0.015, kd: float = 0.24) -> None:
        self.kp, self.ki, self.kd = kp, ki, kd
        self.integral = 0.0
        self.previous_error = 0.0

    def reset(self) -> None:
        self.integral = 0.0
        self.previous_error = 0.0

    def predict(self, env: ShipNavigationEnv) -> np.ndarray:
        distance, error, clearance = env.navigation_error()
        hazard = env.avoidance_context()
        self.integral = float(np.clip(self.integral + error * env.delta, -1.5, 1.5))
        derivative = (error - self.previous_error) / max(env.delta, 1e-6)
        self.previous_error = error
        rudder = float(np.clip(self.kp * error + self.ki * self.integral + self.kd * derivative, -1.0, 1.0))
        throttle = 0.72
        if abs(error) > math.radians(45.0):
            throttle = 0.32
        elif abs(error) > math.radians(22.0):
            throttle = 0.48
        avoidance_distance = 46.0 if str(hazard.get("kind")) in ("cliff", "terrain", "shoreline") else 34.0
        if clearance < avoidance_distance:
            throttle = min(throttle, 0.28 if clearance < 16.0 else 0.38)
            bearing = float(hazard.get("bearing", 0.0))
            avoidance_rudder = -1.0 if bearing >= 0.0 else 1.0
            urgency = float(np.clip((avoidance_distance - clearance) / max(avoidance_distance, 1.0), 0.0, 1.0))
            rudder = float(np.clip((1.0 - urgency) * rudder + urgency * avoidance_rudder, -1.0, 1.0))
        if distance < 24.0:
            throttle = min(throttle, max(0.18, distance / 34.0))
        return np.asarray([throttle, rudder], dtype=np.float32)


def _polygon_distance(x: float, z: float, points: Sequence[Tuple[float, float]]) -> Tuple[float, float, float]:
    best_distance = float("inf")
    best_x, best_z = points[0]
    for index, (ax, az) in enumerate(points):
        bx, bz = points[(index + 1) % len(points)]
        dx, dz = bx - ax, bz - az
        length_squared = dx * dx + dz * dz
        ratio = 0.0 if length_squared <= 1e-12 else float(np.clip(((x - ax) * dx + (z - az) * dz) / length_squared, 0.0, 1.0))
        cx, cz = ax + dx * ratio, az + dz * ratio
        distance = math.hypot(x - cx, z - cz)
        if distance < best_distance:
            best_distance, best_x, best_z = distance, cx, cz
    return best_distance, best_x, best_z


def _point_in_polygon(x: float, z: float, points: Sequence[Tuple[float, float]]) -> bool:
    inside = False
    previous = points[-1]
    for current in points:
        ax, az = previous
        bx, bz = current
        if (az > z) != (bz > z):
            crossing_x = (bx - ax) * (z - az) / (bz - az) + ax
            if x < crossing_x:
                inside = not inside
        previous = current
    return inside


def _move_toward(value: float, target: float, amount: float) -> float:
    if value < target:
        return min(value + amount, target)
    return max(value - amount, target) if value > target else value


def _wrap_angle(value: float) -> float:
    return (value + math.pi) % math.tau - math.pi
