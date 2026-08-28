#!/usr/bin/env python3
"""Local interactive helm for exact PortOpsNavigationEnv feasibility trials."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
from pathlib import Path
import threading
from typing import Any, Mapping
from urllib.parse import urlparse
import sys

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
CONFIG = ROOT / "data/rl/long_beach_ais_port_ops_experiment_v2.json"
HTML = ROOT / "tools/manual_port_cockpit.html"
DEFAULT_OUTPUT = ROOT / "reports/artifacts/sac_champion_v5/manual_feasibility"

from tools.ship_rl.environment import (  # noqa: E402
    dataset_fingerprint,
    experiment_fingerprint,
    load_experiment,
)
from tools.ship_rl.port_ops_environment import PortOpsNavigationEnv  # noqa: E402
from tools.ship_rl.port_ops_trainer import _route_completion_ratio  # noqa: E402
from tools.ship_rl.trainer import _route_reference_length  # noqa: E402


def _write_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def _relative(path: Path) -> str:
    return str(path.resolve().relative_to(ROOT))


class ManualPortSession:
    def __init__(
        self,
        task_index: int,
        max_steps: int,
        seed: int,
        output_dir: Path,
    ) -> None:
        self.task_index = task_index
        self.max_steps = max_steps
        self.seed = seed
        self.output_dir = output_dir
        self.lock = threading.RLock()
        self.config, self.dataset, self.dataset_path = load_experiment(CONFIG)
        validation = self.dataset["splits"]["validation"]
        if task_index < 0 or task_index >= len(validation):
            raise ValueError(
                f"task index {task_index} is outside validation split "
                f"0..{len(validation) - 1}"
            )
        self.env: PortOpsNavigationEnv
        self.observation: np.ndarray
        self.info: dict[str, Any]
        self.samples: list[dict[str, Any]]
        self.command_events: list[dict[str, Any]]
        self.waypoint_events: list[dict[str, Any]]
        self.throttle_command = 0.0
        self.rudder_command = 0.0
        self.done = False
        self.started_at = ""
        self.saved_path: Path | None = None
        self._last_waypoint = 0
        self._last_command = (0.0, 0.0)
        self.reset()

    def reset(self) -> dict[str, Any]:
        with self.lock:
            self.env = PortOpsNavigationEnv(
                self.config,
                self.dataset,
                split="validation",
                discrete_actions=False,
                max_steps=self.max_steps,
                seed=self.seed + self.task_index,
                task_index=self.task_index,
                render_mode=None,
            )
            self.observation, self.info = self.env.reset(
                options={"task_index": self.task_index}
            )
            self.samples = []
            self.command_events = []
            self.waypoint_events = []
            self.throttle_command = 0.0
            self.rudder_command = 0.0
            self.done = False
            self.started_at = datetime.now(timezone.utc).replace(
                microsecond=0
            ).isoformat()
            self.saved_path = None
            self._last_waypoint = int(self.env.waypoint_index)
            self._last_command = (0.0, 0.0)
            self._record_sample(0.0)
            return self.state()

    def set_command(self, throttle: float, rudder: float) -> None:
        with self.lock:
            self.throttle_command = float(np.clip(throttle, -1.0, 1.0))
            self.rudder_command = float(np.clip(rudder, -1.0, 1.0))

    def advance(self, steps: int, throttle: float, rudder: float) -> dict[str, Any]:
        with self.lock:
            self.set_command(throttle, rudder)
            for _ in range(max(1, min(int(steps), 50))):
                if self.done:
                    break
                previous_waypoint = int(self.env.waypoint_index)
                action = np.asarray(
                    [self.throttle_command, self.rudder_command],
                    dtype=np.float32,
                )
                self.observation, reward, terminated, truncated, info = (
                    self.env.step(action)
                )
                self.info = dict(info)
                self.done = bool(terminated or truncated)
                self._record_sample(float(reward))
                if int(self.env.waypoint_index) != previous_waypoint:
                    self.waypoint_events.append(
                        self._maneuver_snapshot(
                            "waypoint_reached",
                            previous_waypoint,
                        )
                    )
                if self.done:
                    self.waypoint_events.append(
                        self._maneuver_snapshot(
                            "episode_finished",
                            int(self.env.waypoint_index),
                        )
                    )
                    self.save()
                    break
            return self.state()

    def _maneuver_snapshot(self, event: str, waypoint: int) -> dict[str, Any]:
        return {
            "event": event,
            "step": int(self.env.steps),
            "waypoint_index": waypoint,
            "position": {
                "x": float(self.env.state[0]),
                "z": float(self.env.state[1]),
            },
            "heading_degrees": math.degrees(float(self.env.state[2])),
            "speed_mps": float(self.env.state[3]),
            "throttle_command": self.throttle_command,
            "rudder_command": self.rudder_command,
            "actual_throttle": float(self.env.state[4]),
            "actual_rudder": float(self.env.state[5]),
            "heading_error_degrees": math.degrees(self.env._heading_error()),
            "cross_track_error_meters": float(self.env._cross_track_error()),
        }

    def _record_sample(self, reward: float) -> None:
        command = (self.throttle_command, self.rudder_command)
        if command != self._last_command:
            self.command_events.append(
                self._maneuver_snapshot(
                    "command_changed",
                    int(self.env.waypoint_index),
                )
            )
            self._last_command = command
        nearest = self.env.avoidance_context()
        encounter = self.env._encounter_context()
        self.samples.append(
            {
                "step": int(self.env.steps),
                "time_seconds": float(self.env.steps * self.env.delta),
                "x": float(self.env.state[0]),
                "z": float(self.env.state[1]),
                "heading_degrees": math.degrees(float(self.env.state[2])),
                "speed_mps": float(self.env.state[3]),
                "throttle_command": self.throttle_command,
                "rudder_command": self.rudder_command,
                "actual_throttle": float(self.env.state[4]),
                "actual_rudder": float(self.env.state[5]),
                "waypoint_index": int(self.env.waypoint_index),
                "distance_to_waypoint_meters": float(
                    self.env._distance_to_target()
                ),
                "heading_error_degrees": math.degrees(
                    self.env._heading_error()
                ),
                "cross_track_error_meters": float(
                    self.env._cross_track_error()
                ),
                "nearest_clearance_meters": float(
                    nearest.get("clearance", 0.0)
                ),
                "nearest_bearing_degrees": math.degrees(
                    float(nearest.get("bearing", 0.0))
                ),
                "tcpa_seconds": float(encounter.get("tcpa", 0.0)),
                "dcpa_meters": float(encounter.get("dcpa", 0.0)),
                "reward": reward,
                "observation": [float(value) for value in self.observation],
            }
        )

    def _metrics(self) -> dict[str, Any]:
        path_length = float(self.info.get("path_length_meters", 0.0))
        reference = float(_route_reference_length(self.env.task))
        completion = float(_route_completion_ratio(self.env))
        return {
            "task_id": str(self.env.task.get("id", "unknown")),
            "complete": self.done,
            "success": bool(self.info.get("is_success", False)),
            "port_compliant_success": bool(
                self.info.get("port_compliant_success", False)
            ),
            "goal_reached": bool(self.info.get("goal_reached", False)),
            "route_completion_ratio": completion,
            "path_efficiency": min(
                reference * completion / max(path_length, 1e-6),
                1.0,
            ),
            "steps": int(self.env.steps),
            "elapsed_seconds": float(self.env.steps * self.env.delta),
            "collisions": int(self.info.get("collisions", 0)),
            "groundings": int(self.info.get("groundings", 0)),
            "speed_limit_violations": int(
                self.info.get("speed_limit_violations", 0)
            ),
            "channel_departures": int(
                self.info.get("channel_departures", 0)
            ),
            "colreg_give_way_violations": int(
                self.info.get("colreg_give_way_violations", 0)
            ),
            "path_length_meters": path_length,
            "reference_route_length_meters": reference,
        }

    def state(self) -> dict[str, Any]:
        with self.lock:
            navigation = self.env._navigation_context()
            ukc, ukc_valid = self.env._under_keel_clearance()
            fairway_inside, fairway_margin, fairway_valid = (
                self.env._fairway_context()
            )
            nearest = self.env.avoidance_context()
            encounter = self.env._encounter_context()
            obstacles = []
            for obstacle in self.env.obstacles:
                obstacles.append(
                    {
                        "name": obstacle.name,
                        "x": float(obstacle.x),
                        "z": float(obstacle.z),
                        "radius": float(
                            max(obstacle.radius, obstacle.half_x, obstacle.half_z)
                        ),
                        "dynamic": bool(obstacle.dynamic),
                        "kind": obstacle.kind,
                    }
                )
            return {
                "task_index": self.task_index,
                "task_id": str(self.env.task.get("id", "unknown")),
                "done": self.done,
                "saved_path": (
                    _relative(self.saved_path) if self.saved_path else None
                ),
                "step": int(self.env.steps),
                "max_steps": self.max_steps,
                "delta": float(self.env.delta),
                "ship": {
                    "x": float(self.env.state[0]),
                    "z": float(self.env.state[1]),
                    "heading_degrees": math.degrees(float(self.env.state[2])),
                    "speed_mps": float(self.env.state[3]),
                    "speed_knots": abs(float(self.env.state[3])) / 0.514444,
                    "actual_throttle": float(self.env.state[4]),
                    "actual_rudder": float(self.env.state[5]),
                },
                "command": {
                    "throttle": self.throttle_command,
                    "rudder": self.rudder_command,
                },
                "navigation": {
                    "waypoint_index": int(self.env.waypoint_index),
                    "waypoint_count": len(self.env.route),
                    "distance_to_waypoint_meters": float(
                        self.env._distance_to_target()
                    ),
                    "heading_error_degrees": math.degrees(
                        self.env._heading_error()
                    ),
                    "cross_track_error_meters": float(
                        self.env._cross_track_error()
                    ),
                    "speed_limit_knots": float(
                        navigation.get("speed_limit_knots", 0.0) or 0.0
                    ),
                    "ukc_meters": float(ukc) if ukc_valid else None,
                    "fairway_inside": (
                        bool(fairway_inside) if fairway_valid else None
                    ),
                    "fairway_margin_meters": (
                        float(fairway_margin) if fairway_valid else None
                    ),
                },
                "traffic": {
                    "nearest_clearance_meters": float(
                        nearest.get("clearance", 0.0)
                    ),
                    "nearest_bearing_degrees": math.degrees(
                        float(nearest.get("bearing", 0.0))
                    ),
                    "encounter": str(encounter.get("encounter", "none")),
                    "give_way": bool(encounter.get("give_way", False)),
                    "tcpa_seconds": float(encounter.get("tcpa", 0.0)),
                    "dcpa_meters": float(encounter.get("dcpa", 0.0)),
                },
                "route": [
                    {"x": float(point[0]), "z": float(point[1])}
                    for point in self.env.route
                ],
                "start": {
                    "x": float(self.env.task["start"]["x"]),
                    "z": float(self.env.task["start"]["z"]),
                },
                "obstacles": obstacles,
                "metrics": self._metrics(),
            }

    def save(self) -> Path:
        with self.lock:
            task_id = str(self.env.task.get("id", "task"))
            path = self.output_dir / f"{task_id}_manual_trajectory.json"
            task = self.env.task
            payload = {
                "format": "ship_port_manual_feasibility_rollout_v1",
                "source": "interactive_human_authored_helm_commands",
                "trained_rl": False,
                "dataset_split": "validation",
                "task_index": self.task_index,
                "task_id": task_id,
                "started_at": self.started_at,
                "saved_at": datetime.now(timezone.utc).replace(
                    microsecond=0
                ).isoformat(),
                "config": _relative(CONFIG),
                "experiment_sha256": experiment_fingerprint(self.config),
                "dataset": (
                    _relative(self.dataset_path)
                    if self.dataset_path
                    else "runtime_snapshot"
                ),
                "dataset_sha256": dataset_fingerprint(self.dataset),
                "seed": self.seed + self.task_index,
                "start": dict(task["start"]),
                "route_points": [dict(point) for point in task["route"]],
                "command_events": self.command_events,
                "waypoint_events": self.waypoint_events,
                "samples": self.samples,
                "evaluation_metrics": self._metrics(),
                "claim_boundary": (
                    "Interactive feasibility evidence in the exact offline "
                    "simulator; not trained RL, field acceptance, or live authority."
                ),
            }
            _write_json(path, payload)
            self.saved_path = path
            return path


class Handler(BaseHTTPRequestHandler):
    session: ManualPortSession

    def _json(self, value: Mapping[str, Any], status: int = 200) -> None:
        encoded = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded)

    def _body(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length <= 0:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/":
            encoded = HTML.read_bytes()
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(encoded)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(encoded)
            return
        if path == "/api/state":
            self._json(self.session.state())
            return
        self._json({"error": "not_found"}, 404)

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        try:
            body = self._body()
            if path == "/api/advance":
                self._json(
                    self.session.advance(
                        int(body.get("steps", 1)),
                        float(body.get("throttle", 0.0)),
                        float(body.get("rudder", 0.0)),
                    )
                )
                return
            if path == "/api/reset":
                self._json(self.session.reset())
                return
            if path == "/api/save":
                saved = self.session.save()
                self._json(
                    {"saved": True, "path": _relative(saved), **self.session.state()}
                )
                return
            self._json({"error": "not_found"}, 404)
        except Exception as error:  # pragma: no cover - interactive receipt
            self._json({"error": type(error).__name__, "detail": str(error)}, 500)

    def log_message(self, format: str, *args: Any) -> None:
        return


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--task-index", type=int, default=70)
    parser.add_argument("--max-steps", type=int, default=1_600)
    parser.add_argument("--seed", type=int, default=250107)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    Handler.session = ManualPortSession(
        args.task_index,
        max(1, args.max_steps),
        args.seed,
        args.output_dir.resolve(),
    )
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(
        json.dumps(
            {
                "status": "ready",
                "url": f"http://{args.host}:{args.port}/",
                "task_index": args.task_index,
                "task_id": Handler.session.state()["task_id"],
            },
            ensure_ascii=False,
        ),
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
