#!/usr/bin/env python3
"""Additive SAC-P47 entrypoint with Godot-matched 3-DOF vessel physics."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Mapping

import cargo_rl.hardest_demonstration as hardest_demo
import cargo_rl.trainer as cargo_trainer
import cargo_rl_train as cargo_cli
import train_cargo_hardest_sac_v3 as hardest_train
from cargo_rl.physics_contract import validate_physics_training_contract
from cargo_rl.physics_demonstration import (
    collect_physics_training_demonstrations,
    physics_manual_helm,
)
from cargo_rl.physics_environment import (
    PHYSICS_MODEL_FAMILY,
    PHYSICS_OBSERVATION_CONTRACT,
    PHYSICS_OBSERVATION_SIZE,
    CargoPhysicsV4Env,
)


ROOT = Path(__file__).resolve().parents[1]
EXPERT_CACHE = ROOT / "reports/artifacts/cargo_circuit_physics_v4/expert_demonstrations_v4.npz"


# Reuse the V3 expert-anchored SAC implementation, but replace every runtime
# environment seam and cache target.  Existing V1/V2/V3 artifacts remain read-only.
hardest_train.CargoHardestV3Env = CargoPhysicsV4Env
hardest_train.HARDEST_OBSERVATION_SIZE = PHYSICS_OBSERVATION_SIZE
hardest_demo.CargoHardestV3Env = CargoPhysicsV4Env
hardest_demo.EXPERT_CACHE = EXPERT_CACHE
hardest_demo.hardest_manual_helm = physics_manual_helm
hardest_train.hardest_manual_helm = physics_manual_helm
cargo_trainer.CargoDynamicEnv = CargoPhysicsV4Env
cargo_trainer.DYNAMIC_OBSERVATION_SIZE = PHYSICS_OBSERVATION_SIZE


def _collect_physics_with_context(config, dataset, seed, max_steps=None):
    hardest_train._training_context.clear()
    hardest_train._training_context.update({"config": config, "dataset": dataset, "seed": seed})
    return collect_physics_training_demonstrations(
        config,
        dataset,
        seed,
        max_steps=max_steps or 5200,
    )


cargo_trainer.collect_dynamic_training_demonstrations = _collect_physics_with_context


def _contract(config_path: Path) -> tuple[dict[str, Any], Mapping[str, Any]]:
    config, dataset, _dataset_path = cargo_trainer.load_experiment(config_path.resolve())
    return config, validate_physics_training_contract(config, dataset, config_path.resolve())


def _dynamics_record(config: Mapping[str, Any], contract: Mapping[str, Any]) -> dict[str, Any]:
    dynamics = config.get("world", {}).get("dynamics_contract", {})
    return {
        "model_id": contract["dynamics_model_id"],
        "model_family": PHYSICS_MODEL_FAMILY,
        "sha256": contract["dynamics_sha256"],
        "path": dynamics.get("path"),
        "godot_runtime_script": dynamics.get("godot_runtime_script"),
        "runtime_physics_hz": contract["runtime_physics_hz"],
        "control_interval_seconds": contract["control_interval_seconds"],
        "vessel_calibrated": False,
        "boundary": "shared project-native simulation reference; not field-calibrated",
    }


def _obstacle_record(contract: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "large_rock_manifest_id": "taoyuan_large_rocks_reviewed_2026_08_24",
        "large_rock_count": contract["large_rock_count"],
        "dynamic_traffic_count": contract["dynamic_traffic_count"],
        "all_curriculum_obstacles_enabled": contract["all_curriculum_obstacles_enabled"],
        "visuals_hidden_for_training": False,
        "collision_geometry_removed_for_training": False,
    }


_base_train = cargo_trainer.train_cargo


def train_physics_cargo(request, initialize_from_checkpoint=None):
    config, contract = _contract(Path(request.config_path))
    if request.algorithm != "sac":
        raise ValueError("SAC-P47 is an SAC-only additive strategy")
    result = _base_train(request, initialize_from_checkpoint)
    checkpoint_path = Path(request.checkpoint_path).resolve()
    checkpoint = json.loads(checkpoint_path.read_text(encoding="utf-8"))
    checkpoint.update(
        {
            "strategy_id": "SAC-P47",
            "strategy_release_format": "cargo_circuit_physics_sac_p47_checkpoint_v4",
            "observation_size": PHYSICS_OBSERVATION_SIZE,
            "observation_contract": PHYSICS_OBSERVATION_CONTRACT,
            "observation_physics_features": [
                "sway_velocity",
                "yaw_rate",
                "drift_angle_sine",
            ],
            "dynamics_contract": _dynamics_record(config, contract),
            "current_map_obstacle_contract": _obstacle_record(contract),
            "additive_release": True,
            "replaces_existing_strategy": False,
        }
    )
    cargo_trainer.write_json_atomic(checkpoint_path, checkpoint)
    result.update(
        {
            "strategy_id": "SAC-P47",
            "observation_size": PHYSICS_OBSERVATION_SIZE,
            "observation_contract": PHYSICS_OBSERVATION_CONTRACT,
            "dynamics_contract": checkpoint["dynamics_contract"],
            "current_map_obstacle_contract": checkpoint["current_map_obstacle_contract"],
        }
    )
    cargo_trainer.write_json_atomic(Path(request.progress_path).resolve(), result)
    return result


_base_evaluate = cargo_trainer.evaluate_cargo


def evaluate_physics_cargo(**kwargs):
    config, contract = _contract(Path(kwargs["config_path"]))
    result = _base_evaluate(**kwargs)
    trajectory_path = Path(kwargs["trajectory_path"]).resolve()
    trajectory = json.loads(trajectory_path.read_text(encoding="utf-8"))
    samples = trajectory.get("samples", [])
    maximum_sway = max((abs(float(item.get("sway_mps", 0.0))) for item in samples), default=0.0)
    maximum_yaw = max(
        (abs(float(item.get("yaw_rate_degrees_per_second", 0.0))) for item in samples),
        default=0.0,
    )
    maximum_drift = max(
        (abs(float(item.get("drift_angle_degrees", 0.0))) for item in samples),
        default=0.0,
    )
    base_gate = dict(trajectory.get("acceptance_gate", {}))
    physics_observed = maximum_sway > 0.01 and maximum_yaw > 0.01 and maximum_drift > 0.01
    strict_passed = bool(base_gate.get("passed", False) and physics_observed)
    base_gate.update(
        {
            "passed": strict_passed,
            "requires_observed_sway_yaw_and_drift": True,
            "maximum_absolute_sway_mps": maximum_sway,
            "maximum_absolute_yaw_rate_degrees_per_second": maximum_yaw,
            "maximum_absolute_drift_angle_degrees": maximum_drift,
            "requires_all_32_large_rocks": True,
            "requires_all_6_dynamic_vessels": True,
        }
    )
    trajectory.update(
        {
            "strategy_id": "SAC-P47",
            "strategy_release_format": "cargo_circuit_physics_sac_p47_rollout_v4",
            "observation_size": PHYSICS_OBSERVATION_SIZE,
            "observation_contract": PHYSICS_OBSERVATION_CONTRACT,
            "observation_physics_features": [
                "sway_velocity",
                "yaw_rate",
                "drift_angle_sine",
            ],
            "dynamics_contract": _dynamics_record(config, contract),
            "current_map_obstacle_contract": _obstacle_record(contract),
            "acceptance_gate": base_gate,
            "additive_release": True,
            "replaces_existing_strategy": False,
        }
    )
    cargo_trainer.write_json_atomic(trajectory_path, trajectory)
    evidence_path = kwargs.get("evidence_path")
    if evidence_path:
        evidence_path = Path(evidence_path).resolve()
        evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
        evidence.update(
            {
                "strategy_id": "SAC-P47",
                "strategy_release_format": "cargo_circuit_physics_sac_p47_evidence_v4",
                "observation_size": PHYSICS_OBSERVATION_SIZE,
                "observation_contract": PHYSICS_OBSERVATION_CONTRACT,
                "dynamics_contract": trajectory["dynamics_contract"],
                "current_map_obstacle_contract": trajectory["current_map_obstacle_contract"],
                "acceptance_gate": base_gate,
                "additive_release": True,
                "replaces_existing_strategy": False,
            }
        )
        cargo_trainer.write_json_atomic(evidence_path, evidence)
    result.update(
        {
            "strategy_id": "SAC-P47",
            "observation_size": PHYSICS_OBSERVATION_SIZE,
            "observation_contract": PHYSICS_OBSERVATION_CONTRACT,
            "dynamics_contract": trajectory["dynamics_contract"],
            "current_map_obstacle_contract": trajectory["current_map_obstacle_contract"],
            "acceptance_gate": base_gate,
            "render_ready": bool(kwargs.get("split") == "test" and strict_passed),
        }
    )
    cargo_trainer.write_json_atomic(Path(kwargs["progress_path"]).resolve(), result)
    return result


cargo_trainer.train_cargo = train_physics_cargo
cargo_trainer.evaluate_cargo = evaluate_physics_cargo
cargo_cli.train_cargo = train_physics_cargo
cargo_cli.evaluate_cargo = evaluate_physics_cargo


if __name__ == "__main__":
    raise SystemExit(cargo_cli.main())
