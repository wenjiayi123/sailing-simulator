"""Fail-closed contract checks for the additive SAC-P47 cargo task."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, Mapping

from .catamaran_physics import canonical_sha256


PHYSICS_SCHEMA = "cargo_circuit_physics_experiment_v4"
PHYSICS_DATASET_SCHEMA = "cargo_circuit_physics_dataset_v4"
PHYSICS_OBSERVATIONS = 47
ROCK_MANIFEST_ID = "taoyuan_large_rocks_reviewed_2026_08_24"
REQUIRED_LARGE_ROCKS = 32
REQUIRED_DYNAMIC_TRAFFIC = 6


def _project_path(raw_path: str, config_path: Path) -> Path:
    if raw_path.startswith("res://"):
        project_root = config_path.resolve()
        while project_root.parent != project_root and not (project_root / "project.godot").exists():
            project_root = project_root.parent
        return (project_root / raw_path.removeprefix("res://")).resolve()
    path = Path(raw_path).expanduser()
    if not path.is_absolute():
        path = config_path.resolve().parent / path
    return path.resolve()


def validate_physics_training_contract(
    config: Mapping[str, Any],
    dataset: Mapping[str, Any],
    config_path: Path,
) -> Dict[str, Any]:
    """Reject any training configuration that hides rocks, traffic, or drift."""

    errors = []
    if config.get("schema_version") != PHYSICS_SCHEMA:
        errors.append(f"schema_version must be {PHYSICS_SCHEMA}")
    if dataset.get("schema_version") != PHYSICS_DATASET_SCHEMA:
        errors.append(f"dataset schema_version must be {PHYSICS_DATASET_SCHEMA}")
    decision = config.get("algorithm_decision", {})
    if decision.get("new_strategy_id") != "SAC-P47" or not bool(
        decision.get("preserves_existing_strategies", False)
    ):
        errors.append("SAC-P47 must be additive and preserve every existing strategy")

    mission = dataset.get("mission_contract", {})
    if int(mission.get("observation_dimension", -1)) != PHYSICS_OBSERVATIONS:
        errors.append("dataset observation_dimension must be 47")
    if int(mission.get("large_rock_count", -1)) != REQUIRED_LARGE_ROCKS:
        errors.append("dataset must declare all 32 reviewed large rocks")
    if int(mission.get("dynamic_traffic_count", -1)) < REQUIRED_DYNAMIC_TRAFFIC:
        errors.append("dataset must declare at least six dynamic traffic vessels")

    environment = config.get("environment_parameters", {})
    if not bool(environment.get("merge_scene_obstacles", False)):
        errors.append("merge_scene_obstacles must stay enabled")
    traffic_count = int(environment.get("generated_traffic_count", 0))
    if traffic_count < REQUIRED_DYNAMIC_TRAFFIC:
        errors.append("all curriculum stages require at least six dynamic vessels")

    cargo = config.get("cargo_parameters", {})
    obstacles_enabled = list(cargo.get("curriculum_obstacles_enabled", []))
    if not obstacles_enabled or not all(bool(value) for value in obstacles_enabled):
        errors.append("rocks and traffic must remain enabled in every curriculum stage")

    world = config.get("world", {})
    obstacle_contract = world.get("obstacles", {})
    boxes = obstacle_contract.get("boxes", [])
    rocks = [
        item
        for item in boxes
        if item.get("manifest_id") == ROCK_MANIFEST_ID
        and item.get("shape") == "box"
    ]
    if len(rocks) != REQUIRED_LARGE_ROCKS:
        errors.append(f"expected 32 reviewed rock collision boxes, got {len(rocks)}")
    if len({str(item.get("name", "")) for item in rocks}) != REQUIRED_LARGE_ROCKS:
        errors.append("reviewed rock collision box names must be unique")

    dynamics = world.get("dynamics_contract", {})
    dynamics_path: Path | None = None
    actual_sha = ""
    raw_dynamics_path = str(dynamics.get("path", ""))
    if not raw_dynamics_path:
        errors.append("world.dynamics_contract.path is required")
    else:
        dynamics_path = _project_path(raw_dynamics_path, config_path)
        if not dynamics_path.exists():
            errors.append(f"shared Godot/Python dynamics file is missing: {dynamics_path}")
        else:
            actual_sha = canonical_sha256(dynamics_path)
            if actual_sha != str(dynamics.get("sha256", "")):
                errors.append("shared Godot/Python dynamics SHA-256 does not match")
            payload = json.loads(dynamics_path.read_text(encoding="utf-8"))
            if payload.get("model_id") != dynamics.get("model_id"):
                errors.append("shared Godot/Python dynamics model_id does not match")
            if mission.get("dynamics_model_id") != payload.get("model_id"):
                errors.append("dataset and runtime dynamics model_id do not match")
    if int(dynamics.get("runtime_physics_hz", 0)) != 60:
        errors.append("Godot/Python physics must run at the shared 60 Hz contract")
    if abs(float(dynamics.get("control_interval_seconds", -1.0)) - float(config.get("delta", 0.0))) > 1e-12:
        errors.append("physics control interval must equal the environment delta")
    runtime_script = _project_path(str(dynamics.get("godot_runtime_script", "")), config_path)
    if not runtime_script.exists():
        errors.append("Godot 3-DOF runtime script is missing")

    if errors:
        raise ValueError("SAC-P47 training contract rejected: " + "; ".join(errors))
    return {
        "passed": True,
        "fail_closed": True,
        "observation_dimension": PHYSICS_OBSERVATIONS,
        "large_rock_count": len(rocks),
        "dynamic_traffic_count": traffic_count,
        "all_curriculum_obstacles_enabled": True,
        "dynamics_model_id": str(dynamics.get("model_id", "")),
        "dynamics_sha256": actual_sha,
        "dynamics_path": str(dynamics_path) if dynamics_path else "",
        "runtime_physics_hz": int(dynamics.get("runtime_physics_hz", 0)),
        "control_interval_seconds": float(dynamics.get("control_interval_seconds", 0.0)),
    }
