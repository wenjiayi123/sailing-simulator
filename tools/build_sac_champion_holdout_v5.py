#!/usr/bin/env python3
"""Build the predeclared counterfactual holdout for the SAC V5 champion.

The holdout is derived from 2025-01-07 historical AIS tasks but applies a
deterministic perturbation profile inside the simulator's already-declared
domain-randomization envelope.  It is a new sealed simulation scenario set,
not newly observed AIS and not independent field evidence.
"""

from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import random
from typing import Any, Mapping


ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "data/rl/long_beach_ais_port_ops_benchmark_v2.json"
OUTPUT = ROOT / "data/rl/sac_champion_counterfactual_holdout_v5.json"
MANIFEST = ROOT / "reports/sac_champion_counterfactual_holdout_v5_prepared.json"
SEED = 250828
SOURCE_DATE = "2025-01-07"


def _load(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _write(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _rng(task_id: str) -> random.Random:
    digest = hashlib.sha256(f"{SEED}:{task_id}".encode("utf-8")).digest()
    return random.Random(int.from_bytes(digest[:8], "big"))


def _symmetric(generator: random.Random, magnitude: float) -> float:
    return generator.uniform(-magnitude, magnitude)


def _perturb_task(raw: Mapping[str, Any]) -> dict[str, Any]:
    task = copy.deepcopy(dict(raw))
    generator = _rng(str(task["id"]))
    original_id = str(task["id"])
    task["id"] = f"{original_id}_cfv5"
    task["counterfactual_v5"] = {
        "base_task_id": original_id,
        "seed": SEED,
        "new_observation": False,
        "profile": "declared_domain_randomization_envelope_v1",
    }

    start = task["start"]
    start["x"] = round(float(start["x"]) + _symmetric(generator, 4.0), 3)
    start["z"] = round(float(start["z"]) + _symmetric(generator, 4.0), 3)
    start["heading_degrees"] = round(
        (float(start["heading_degrees"]) + _symmetric(generator, 3.0)) % 360.0,
        3,
    )

    for obstacle in task.get("dynamic_obstacles", []):
        obstacle["x"] = round(
            float(obstacle["x"]) + _symmetric(generator, 8.0), 3
        )
        obstacle["z"] = round(
            float(obstacle["z"]) + _symmetric(generator, 8.0), 3
        )
        obstacle["course_degrees"] = round(
            (
                float(obstacle.get("course_degrees", 0.0))
                + _symmetric(generator, 4.0)
            )
            % 360.0,
            3,
        )
        obstacle["speed_knots"] = round(
            max(
                0.0,
                float(obstacle.get("speed_knots", 0.0))
                * generator.uniform(0.95, 1.05),
            ),
            3,
        )

    sea = task.get("sea_state", {})
    sea["wind_speed_knots"] = round(
        max(0.0, float(sea.get("wind_speed_knots", 0.0)) + _symmetric(generator, 0.5)),
        3,
    )
    sea["wind_direction_degrees"] = round(
        (float(sea.get("wind_direction_degrees", 0.0)) + _symmetric(generator, 3.0))
        % 360.0,
        3,
    )
    sea["wave_height_meters"] = round(
        max(0.0, float(sea.get("wave_height_meters", 0.0)) + _symmetric(generator, 0.05)),
        3,
    )
    sea["wave_direction_degrees"] = round(
        (float(sea.get("wave_direction_degrees", 0.0)) + _symmetric(generator, 3.0))
        % 360.0,
        3,
    )
    sea["current_speed_knots"] = round(
        max(0.0, float(sea.get("current_speed_knots", 0.0)) + _symmetric(generator, 0.08)),
        3,
    )
    sea["current_direction_degrees"] = round(
        (float(sea.get("current_direction_degrees", 0.0)) + _symmetric(generator, 3.0))
        % 360.0,
        3,
    )
    return task


def main() -> int:
    base = _load(BASE)
    selected = [
        task
        for task in base["splits"]["test"]
        if SOURCE_DATE in str(task.get("id", ""))
    ]
    if not selected:
        raise ValueError(f"no base test tasks found for {SOURCE_DATE}")
    tasks = [_perturb_task(task) for task in selected]
    dataset = {
        "schema_version": "ship_port_counterfactual_holdout_v5",
        "dataset_id": "sac_champion_counterfactual_holdout_v5",
        "name": "SAC champion sealed counterfactual Long Beach holdout",
        "description": (
            "Deterministic perturbations of historical 2025-01-07 AIS tasks "
            "inside the declared simulator randomization envelope."
        ),
        "coordinate_system": base["coordinate_system"],
        "port": base["port"],
        "source": {
            "base_dataset": str(BASE.relative_to(ROOT)),
            "base_dataset_sha256": _sha256(BASE),
            "base_source_date": SOURCE_DATE,
            "observed_ais_base": True,
            "counterfactual_perturbations": True,
            "new_observed_ais": False,
            "live_data_verified": False,
        },
        "split_policy": {
            "method": "predeclared_date_slice_plus_deterministic_counterfactual_v5",
            "seed": SEED,
            "test": SOURCE_DATE,
            "test_only": True,
            "test_access_rule": (
                "evaluate exactly once after validation admission and champion freeze"
            ),
        },
        "perturbation_profile": {
            "start_position_jitter_m": 4.0,
            "start_heading_jitter_degrees": 3.0,
            "dynamic_obstacle_position_jitter_m": 8.0,
            "dynamic_obstacle_course_jitter_degrees": 4.0,
            "dynamic_obstacle_speed_multiplier": [0.95, 1.05],
            "wind_speed_jitter_knots": 0.5,
            "wind_direction_jitter_degrees": 3.0,
            "wave_height_jitter_m": 0.05,
            "wave_direction_jitter_degrees": 3.0,
            "current_speed_jitter_knots": 0.08,
            "current_direction_jitter_degrees": 3.0,
        },
        "shared_environment": base["shared_environment"],
        "operational_rules": base["operational_rules"],
        "splits": {"train": [], "validation": [], "test": tasks},
        "live_integration": base["live_integration"],
    }
    _write(OUTPUT, dataset)
    manifest = {
        "schema_version": "sac_champion_counterfactual_holdout_prepared_v5",
        "holdout_id": dataset["dataset_id"],
        "test_accessed": False,
        "prepared_before_champion_test": True,
        "generator": str(Path(__file__).resolve().relative_to(ROOT)),
        "generator_sha256": _sha256(Path(__file__).resolve()),
        "base_dataset": str(BASE.relative_to(ROOT)),
        "base_dataset_sha256": _sha256(BASE),
        "holdout_dataset": str(OUTPUT.relative_to(ROOT)),
        "holdout_dataset_sha256": _sha256(OUTPUT),
        "seed": SEED,
        "source_date": SOURCE_DATE,
        "episodes": len(tasks),
        "claim_boundary": (
            "Counterfactual simulation holdout derived from historical AIS; "
            "not newly observed traffic, field validation, or live authority."
        ),
    }
    _write(MANIFEST, manifest)
    print(json.dumps(manifest, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
