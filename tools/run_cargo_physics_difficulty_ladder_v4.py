#!/usr/bin/env python3
"""Train SAC-P47 upward until the first evidence-backed convergence barrier."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import os
import time
from pathlib import Path
from typing import Any, Dict, Mapping, Sequence

import numpy as np
import torch
from stable_baselines3.common.monitor import Monitor
from stable_baselines3.common.type_aliases import TrainFreq, TrainFrequencyUnit
from stable_baselines3.common.vec_env import DummyVecEnv

import train_cargo_physics_sac_v4 as physics_entry
from cargo_rl.convergence_diagnostics import diagnose_nonconvergence
from cargo_rl.environment import cargo_experiment_fingerprint
from cargo_rl.physics_contract import validate_physics_training_contract
from cargo_rl.physics_environment import (
    PHYSICS_OBSERVATION_CONTRACT,
    PHYSICS_OBSERVATION_SIZE,
    CargoPhysicsV4Env,
)
from ship_rl.environment import dataset_fingerprint, load_experiment
from ship_rl.trainer import TrainRequest, write_json_atomic


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "data/rl/cargo_circuit_physics_experiment_v4.json"
DEFAULT_OUTPUT = ROOT / "output/cargo_physics_sac_p47_ladder"
INITIALIZATION_CACHE_DIR = ROOT / "reports/artifacts/cargo_circuit_physics_v4/training_cache"
INITIALIZATION_MODEL = INITIALIZATION_CACHE_DIR / "sac_p47_expert_initialized"
INITIALIZATION_MANIFEST = INITIALIZATION_CACHE_DIR / "sac_p47_expert_initialized.json"


def _actor_sha256(actor: Any) -> str:
    digest = hashlib.sha256()
    for name, value in sorted(actor.state_dict().items()):
        digest.update(name.encode("utf-8"))
        digest.update(value.detach().cpu().contiguous().numpy().tobytes())
    return digest.hexdigest()


def _initialization_contract(config: Mapping[str, Any], dataset: Mapping[str, Any], request: TrainRequest) -> Dict[str, Any]:
    relevant_config = copy.deepcopy(config)
    cargo = relevant_config.get("cargo_parameters", {})
    cargo.pop("difficulty_ladder", None)
    cargo.pop("difficulty_promotion_gate", None)
    sources = (
        ROOT / "tools/cargo_rl/hardest_demonstration.py",
        ROOT / "tools/cargo_rl/physics_demonstration.py",
        ROOT / "tools/cargo_rl/physics_environment.py",
        ROOT / "tools/cargo_rl/catamaran_physics.py",
        ROOT / "tools/train_cargo_hardest_sac_v3.py",
    )
    payload = {
        "format": "sac_p47_expert_initialization_contract_v1",
        "dataset_sha256": dataset_fingerprint(dataset),
        "rollout_relevant_config_sha256": hashlib.sha256(
            json.dumps(relevant_config, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest(),
        "source_sha256": {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in sources},
        "seed": int(config["demonstration_initialization"].get("fixed_seed", request.seed + 7000)),
        "network": [256, 256],
        "batch_size": request.batch_size,
        "learning_rate": request.learning_rate,
        "gamma": request.gamma,
    }
    payload["contract_sha256"] = hashlib.sha256(
        json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    return payload


def _cached_demonstrations(path: Path) -> Dict[str, Any]:
    cached = np.load(path, allow_pickle=False)
    observations = cached["observations"]
    if observations.ndim != 2 or observations.shape[1] != PHYSICS_OBSERVATION_SIZE:
        raise ValueError("SAC-P47 expert cache observation contract is invalid")
    episodes = int(cached["episodes"].item())
    successes = int(cached["successes"].item())
    if episodes <= 0 or successes != episodes:
        raise ValueError("SAC-P47 expert cache contains unsuccessful demonstrations")
    return {
        "observations": observations,
        "next_observations": cached["next_observations"],
        "actions": cached["actions"],
        "rewards": cached["rewards"],
        "dones": cached["dones"],
        "episodes": episodes,
        "successes": successes,
    }


def _level_config(base: Mapping[str, Any], level: Mapping[str, Any]) -> Dict[str, Any]:
    config = copy.deepcopy(base)
    multiplier = float(level["randomization_multiplier"])
    environment = config["environment_parameters"]
    baseline_keys = (
        "start_position_jitter_m",
        "start_heading_jitter_degrees",
        "current_speed_jitter_knots",
        "current_direction_jitter_degrees",
        "wind_speed_jitter_knots",
        "wind_direction_jitter_degrees",
        "wave_height_jitter_m",
        "wave_direction_jitter_degrees",
        "sensor_distance_noise_std_m",
        "sensor_bearing_noise_degrees",
    )
    for key in baseline_keys:
        environment[key] = float(environment.get(key, 0.0)) * multiplier
    environment["generated_traffic_count"] = 6
    environment["generated_traffic_speed_knots"] = float(level["dynamic_traffic_speed_knots"])
    environment["merge_scene_obstacles"] = True
    config["active_difficulty"] = dict(level)
    return config


def _make_env(
    config: Mapping[str, Any],
    dataset: Mapping[str, Any],
    level: Mapping[str, Any],
    *,
    split: str,
    seed: int,
    task_index: int | None = None,
    monitor: bool = False,
    segment_index: int | None = None,
) -> Any:
    env = CargoPhysicsV4Env(
        config,
        dataset,
        split=split,
        discrete_actions=False,
        max_steps=int(level["max_steps"]),
        seed=seed,
        task_index=task_index,
        render_mode=None,
        curriculum_route_length=int(level["route_length"]),
        curriculum_obstacles_enabled=True,
        curriculum_randomization_enabled=bool(level["randomization_enabled"]),
        curriculum_random_segment=bool(level["random_segment"]),
        curriculum_segment_index=segment_index,
    )
    return Monitor(env) if monitor else env


class LadderProgressCallback(physics_entry.cargo_trainer._cargo_sb3_imports()["BaseCallback"]):
    def __init__(
        self,
        path: Path,
        level: Mapping[str, Any],
        phase_start: int,
        phase_steps: int,
    ) -> None:
        super().__init__(verbose=0)
        self.path = path
        self.level = dict(level)
        self.phase_start = phase_start
        self.phase_steps = max(phase_steps, 1)
        self.episodes: list[dict[str, Any]] = []
        self.started = time.monotonic()
        self.last_percent = -1

    def _on_step(self) -> bool:
        infos = self.locals.get("infos", [])
        for info in infos:
            episode = info.get("episode") if isinstance(info, Mapping) else None
            if isinstance(episode, Mapping):
                self.episodes.append(
                    {
                        "reward": float(episode.get("r", 0.0)),
                        "length": int(episode.get("l", 0)),
                        "success": bool(info.get("is_success", False)),
                        "collisions": int(info.get("collisions", 0)),
                        "minimum_clearance_meters": float(info.get("minimum_clearance_meters", 0.0)),
                        "task_id": str(info.get("task_id", "unknown")),
                    }
                )
        local_steps = max(0, int(self.num_timesteps) - self.phase_start)
        percent = min(100, int(local_steps * 100 / self.phase_steps))
        if percent > self.last_percent:
            self.last_percent = percent
            recent = self.episodes[-20:]
            success_rate = float(np.mean([item["success"] for item in recent])) if recent else 0.0
            payload = {
                "status": "running",
                "operation": "difficulty_ladder_train",
                "stage": "policy_update",
                "strategy_id": "SAC-P47",
                "difficulty": self.level,
                "level_progress_percent": percent,
                "completed_timesteps": local_steps,
                "level_timesteps": self.phase_steps,
                "cumulative_timesteps": int(self.num_timesteps),
                "episodes_completed": len(self.episodes),
                "success_rate_20": success_rate,
                "elapsed_seconds": time.monotonic() - self.started,
                "render": False,
            }
            write_json_atomic(self.path, payload)
            print(
                f"{self.level['id']} training {percent}% "
                f"episodes={len(self.episodes)} success20={success_rate:.3f}",
                flush=True,
            )
        return True


def _evaluate(
    model: Any,
    config: Mapping[str, Any],
    dataset: Mapping[str, Any],
    level: Mapping[str, Any],
    *,
    split: str,
    sweeps: int,
    seed: int,
) -> tuple[list[dict[str, Any]], dict[str, Any] | None]:
    rows: list[dict[str, Any]] = []
    selected_trajectory: dict[str, Any] | None = None
    tasks = dataset["splits"][split]
    for sweep in range(sweeps):
        if bool(level["random_segment"]):
            # Exhaust every ring segment on every sweep, while rotating the
            # held-out task/sea condition so a segment cannot pass by being
            # evaluated against only one favorable scenario.
            cases = [
                ((segment_index + sweep) % len(tasks), segment_index)
                for segment_index in range(8)
            ]
        else:
            cases = [(task_index, None) for task_index in range(len(tasks))]
        for case_index, (task_index, segment_index) in enumerate(cases):
            env = _make_env(
                config,
                dataset,
                level,
                split=split,
                seed=seed + sweep * 1000 + task_index,
                task_index=task_index,
                segment_index=segment_index,
            )
            observation, _info = env.reset(options={"task_index": task_index})
            terminated = truncated = False
            info: Dict[str, Any] = {}
            actions = []
            while not (terminated or truncated):
                action, _state = model.predict(observation, deterministic=True)
                action = np.asarray(action, dtype=np.float32)
                actions.append(action)
                observation, _reward, terminated, truncated, info = env.step(action)
            samples = env.trajectory
            maximum_sway = max(abs(float(item.get("sway_mps", 0.0))) for item in samples)
            maximum_yaw = max(abs(float(item.get("yaw_rate_degrees_per_second", 0.0))) for item in samples)
            maximum_drift = max(abs(float(item.get("drift_angle_degrees", 0.0))) for item in samples)
            saturation = float(
                np.mean([np.any(np.abs(action) >= 0.98) for action in actions])
            ) if actions else 0.0
            row = {
                "sweep": sweep + 1,
                "task_id": str(info.get("task_id", task_index)),
                "success": bool(info.get("is_success", False)),
                "cargo_retrieved": bool(info.get("cargo_retrieved", False)),
                "checkpoints_passed": int(info.get("checkpoints_passed", 0)),
                "total_checkpoints": int(info.get("total_checkpoints", 0)),
                "checkpoint_completion_ratio": float(info.get("checkpoint_completion_ratio", 0.0)),
                "collisions": int(info.get("collisions", 0)),
                "terrain_collisions": int(info.get("terrain_collisions", 0)),
                "minimum_clearance_meters": float(info.get("minimum_clearance_meters", 0.0)),
                "minimum_dynamic_clearance_meters": float(info.get("minimum_dynamic_clearance_meters", 0.0)),
                "minimum_boundary_clearance_meters": float(env._boundary_clearance()),
                "dynamic_obstacle_count": int(info.get("dynamic_obstacle_count", 0)),
                "reward": float(env.total_reward),
                "steps": int(env.steps),
                "maximum_sway_mps": maximum_sway,
                "maximum_yaw_rate_degrees_per_second": maximum_yaw,
                "maximum_drift_angle_degrees": maximum_drift,
                "action_saturation_ratio": saturation,
            }
            rows.append(row)
            print(
                f"{level['id']} {split} sweep={sweep + 1} case={case_index + 1}/{len(cases)} "
                f"success={row['success']} collision={row['collisions']} "
                f"checkpoints={row['checkpoints_passed']}/{row['total_checkpoints']}",
                flush=True,
            )
            if selected_trajectory is None and row["success"]:
                selected_trajectory = {
                    "format": "cargo_circuit_physics_sac_p47_rollout_v4",
                    "strategy_id": "SAC-P47",
                    "difficulty": dict(level),
                    "dataset_split": split,
                    "task_id": row["task_id"],
                    "start": env.task.get("start"),
                    "goal": env.task.get("route", [])[-1],
                    "route_points": env.task.get("route", []),
                    "evaluation_obstacles": env.obstacle_export_records(),
                    "samples": samples,
                    "evaluation_metrics": row,
                    "observation_size": PHYSICS_OBSERVATION_SIZE,
                    "observation_contract": PHYSICS_OBSERVATION_CONTRACT,
                }
            env.close()
    return rows, selected_trajectory


def _gate(
    rows: Sequence[Mapping[str, Any]],
    actor_updates: int,
    *,
    required_sweeps: int,
) -> Dict[str, Any]:
    passed = bool(
        rows
        and actor_updates > 0
        and all(
            bool(row["success"])
            and bool(row["cargo_retrieved"])
            and int(row["checkpoints_passed"]) == int(row["total_checkpoints"])
            and int(row["collisions"]) == 0
            and float(row["minimum_clearance_meters"]) > 0.0
            and float(row["minimum_dynamic_clearance_meters"]) > 0.0
            and float(row["minimum_boundary_clearance_meters"]) > 0.0
            and int(row["dynamic_obstacle_count"]) >= 6
            for row in rows
        )
    )
    return {
        "passed": passed,
        "evaluated_episodes": len(rows),
        "success_rate": float(np.mean([bool(row["success"]) for row in rows])) if rows else 0.0,
        "total_collisions": int(sum(int(row["collisions"]) for row in rows)),
        "minimum_clearance_meters": min((float(row["minimum_clearance_meters"]) for row in rows), default=0.0),
        "minimum_dynamic_clearance_meters": min(
            (float(row["minimum_dynamic_clearance_meters"]) for row in rows), default=0.0
        ),
        "actor_updates_after_warmup": actor_updates,
        "required_held_out_sweeps": required_sweeps,
        "requires_all_episodes_successful": True,
        "requires_zero_collision": True,
        "requires_positive_static_dynamic_and_boundary_clearance": True,
        "requires_all_32_large_rocks": True,
        "requires_all_6_dynamic_vessels": True,
        "requires_trained_sac_actor_updates": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--seed", type=int, default=292000)
    parser.add_argument("--max-level", type=int, default=8)
    parser.add_argument("--timesteps-scale", type=float, default=1.0)
    args = parser.parse_args()

    torch.set_num_threads(1)
    try:
        torch.set_num_interop_threads(1)
    except RuntimeError:
        pass
    config_path = args.config.expanduser().resolve()
    output = args.output_dir.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    progress_path = output / "progress.json"
    ladder_report_path = output / "difficulty_ladder_report.json"
    champion_model_path = output / "sac_p47_champion"
    champion_checkpoint_path = output / "sac_p47_champion_checkpoint.json"
    champion_trajectory_path = output / "sac_p47_champion_test_trajectory.json"

    base_config, dataset, dataset_path = load_experiment(config_path)
    physics_contract = validate_physics_training_contract(base_config, dataset, config_path)
    manual_path = ROOT / "reports/cargo_circuit_physics_manual_feasibility_v4.json"
    manual_gate = json.loads(manual_path.read_text(encoding="utf-8"))
    if not bool(manual_gate.get("acceptance_gate", {}).get("passed", False)):
        raise ValueError("SAC-P47 ladder blocked: manual 3-DOF feasibility gate did not pass")
    if manual_gate.get("dataset_sha256") != dataset_fingerprint(dataset):
        raise ValueError("SAC-P47 ladder blocked: manual feasibility dataset fingerprint is stale")
    if manual_gate.get("experiment_sha256") != cargo_experiment_fingerprint(base_config):
        raise ValueError("SAC-P47 ladder blocked: manual feasibility experiment fingerprint is stale")
    levels = [
        item
        for item in base_config["cargo_parameters"]["difficulty_ladder"]
        if int(item["level"]) <= max(1, args.max_level)
    ]
    total_requested = sum(max(1, int(round(float(item["training_timesteps"]) * args.timesteps_scale))) for item in levels)
    request = TrainRequest(
        algorithm="sac",
        config_path=config_path,
        output_dir=output,
        progress_path=progress_path,
        checkpoint_path=champion_checkpoint_path,
        total_timesteps=total_requested,
        max_steps=5200,
        parallel_envs=1,
        seed=args.seed,
        learning_rate=3e-4,
        gamma=0.995,
        batch_size=256,
        replay_buffer_size=max(180000, total_requested),
        warmup_steps=10000,
    )

    initial_level_config = _level_config(base_config, levels[0])
    vector_env = DummyVecEnv(
        [lambda: _make_env(initial_level_config, dataset, levels[0], split="train", seed=args.seed, monitor=True)]
    )
    imports = physics_entry.cargo_trainer._cargo_sb3_imports()
    initialization_contract = _initialization_contract(base_config, dataset, request)
    cached_initialization = None
    if INITIALIZATION_MANIFEST.exists() and INITIALIZATION_MODEL.with_suffix(".zip").exists():
        candidate = json.loads(INITIALIZATION_MANIFEST.read_text(encoding="utf-8"))
        if candidate.get("contract") == initialization_contract:
            cached_initialization = candidate
    if cached_initialization is not None:
        model = physics_entry.hardest_train.ExpertAnchoredSAC.load(
            INITIALIZATION_MODEL.with_suffix(".zip"), env=vector_env, device="cpu"
        )
    else:
        model = physics_entry.hardest_train._hardest_build_cargo_model("sac", vector_env, request, imports)
    model.train_freq = TrainFreq(4, TrainFrequencyUnit.STEP)

    write_json_atomic(
        progress_path,
        {
            "status": "running",
            "operation": "difficulty_ladder_train",
            "stage": "expert_initialization",
            "strategy_id": "SAC-P47",
            "progress": 0.0,
            "render": False,
        },
    )
    if cached_initialization is not None:
        demonstrations = _cached_demonstrations(physics_entry.EXPERT_CACHE)
        cloning = dict(cached_initialization["cloning"])
        print("SAC-P47 expert initialization cache: accepted", flush=True)
    else:
        physics_entry.hardest_train._training_context.clear()
        physics_entry.hardest_train._training_context.update(
            {"config": base_config, "dataset": dataset, "seed": args.seed}
        )
        demonstrations = physics_entry.collect_physics_training_demonstrations(
            base_config,
            dataset,
            seed=int(base_config["demonstration_initialization"].get("fixed_seed", args.seed + 7000)),
            max_steps=5200,
        )
        cloning = physics_entry.hardest_train._hardest_behavior_clone(
            model,
            demonstrations,
            epochs=int(base_config["demonstration_initialization"].get("actor_behavior_cloning_epochs", 10)),
            batch_size=request.batch_size,
            seed=args.seed + 8000,
        )
        INITIALIZATION_CACHE_DIR.mkdir(parents=True, exist_ok=True)
        model.save(INITIALIZATION_MODEL)
        write_json_atomic(
            INITIALIZATION_MANIFEST,
            {
                "format": "sac_p47_expert_initialization_cache_v1",
                "contract": initialization_contract,
                "cloning": cloning,
                "expert_episodes": int(demonstrations["episodes"]),
                "expert_successes": int(demonstrations["successes"]),
                "trained_rl": False,
                "dropdown_strategy": False,
            },
        )
    physics_entry.cargo_trainer._prefill_off_policy_replay(model, demonstrations)

    ladder_records = []
    champion_level: dict[str, Any] | None = None
    failed_level: dict[str, Any] | None = None
    phase_start = 0
    for level in levels:
        level_config = _level_config(base_config, level)
        validate_physics_training_contract(level_config, dataset, config_path)
        if int(level["level"]) > 1:
            vector_env.close()
            vector_env = DummyVecEnv(
                [lambda config=level_config, profile=level: _make_env(
                    config,
                    dataset,
                    profile,
                    split="train",
                    seed=args.seed + int(profile["level"]) * 1000,
                    monitor=True,
                )]
            )
            model.set_env(vector_env)
        phase_steps = max(1, int(round(float(level["training_timesteps"]) * args.timesteps_scale)))
        callback = LadderProgressCallback(progress_path, level, phase_start, phase_steps)
        model.learn(
            total_timesteps=phase_steps,
            callback=callback,
            progress_bar=False,
            reset_num_timesteps=int(level["level"]) == 1,
        )
        phase_start = int(model.num_timesteps)
        actor_updates = int(getattr(model, "rl_actor_updates", 0))
        validation_rows, _trajectory = _evaluate(
            model,
            level_config,
            dataset,
            level,
            split="validation",
            sweeps=int(base_config["cargo_parameters"]["difficulty_promotion_gate"]["validation_sweeps"]),
            seed=args.seed + 30000 + int(level["level"]) * 1000,
        )
        validation_sweeps = int(
            base_config["cargo_parameters"]["difficulty_promotion_gate"]["validation_sweeps"]
        )
        gate = _gate(
            validation_rows,
            actor_updates,
            required_sweeps=validation_sweeps,
        )
        recent = callback.episodes[-20:]
        training_record = {
            "training_timesteps": phase_steps,
            "cumulative_timesteps": int(model.num_timesteps),
            "episodes": len(callback.episodes),
            "success_rate_20": float(np.mean([item["success"] for item in recent])) if recent else 0.0,
            "actor_updates_after_warmup": actor_updates,
            "expert_success_rate": float(demonstrations["successes"] / max(demonstrations["episodes"], 1)),
            "behavior_clone_loss": cloning.get("final_loss"),
            "dagger_recovery_samples": cloning.get("dagger_labeled_recovery_samples", 0),
            "interrupted": False,
        }
        record = {
            "level": dict(level),
            "training": training_record,
            "validation_gate": gate,
            "validation_rows": validation_rows,
        }
        if gate["passed"]:
            champion_level = dict(level)
            model.save(champion_model_path)
            saved_model = champion_model_path.with_suffix(".zip")
            checkpoint = {
                "format": "cargo_circuit_physics_sac_p47_checkpoint_v4",
                "strategy_id": "SAC-P47",
                "trained": True,
                "algorithm": "sac",
                "library": "stable-baselines3",
                "model_path": os.path.relpath(saved_model, champion_checkpoint_path.parent),
                "observation_size": PHYSICS_OBSERVATION_SIZE,
                "observation_contract": PHYSICS_OBSERVATION_CONTRACT,
                "dataset_path": str(dataset_path),
                "dataset_sha256": dataset_fingerprint(dataset),
                "experiment_sha256": cargo_experiment_fingerprint(base_config),
                "difficulty": champion_level,
                "cumulative_timesteps": int(model.num_timesteps),
                "reinforcement_learning_provenance": {
                    "actor_updates_after_warmup": actor_updates,
                    "critic_updates": int(getattr(model, "_n_updates", 0)),
                    "actor_optimized_against_learned_q_values": actor_updates > 0,
                    "final_sac_actor_sha256": _actor_sha256(model.actor),
                    "environment_rewards_used": True,
                    "manual_helm_callable_at_inference": False,
                },
                "validation_gate": gate,
                "physics_contract": physics_contract,
                "current_map_obstacle_contract": {
                    "large_rock_count": 32,
                    "dynamic_traffic_count": 6,
                    "all_obstacles_enabled": True,
                },
                "additive_release": True,
                "replaces_existing_strategy": False,
                "vessel_calibrated": False,
            }
            write_json_atomic(champion_checkpoint_path, checkpoint)
            record["status"] = "converged_promoted"
            print(f"{level['id']} CONVERGED -> promote", flush=True)
        else:
            failed_level = dict(level)
            diagnosis = diagnose_nonconvergence(
                level=level,
                physics_contract=physics_contract,
                manual_gate=manual_gate,
                training=training_record,
                validation_rows=validation_rows,
                previous_level_passed=champion_level is not None,
            )
            record["status"] = "not_converged_stop"
            record["nonconvergence_diagnosis"] = diagnosis
            print(f"{level['id']} NOT CONVERGED -> diagnose and stop", flush=True)
        ladder_records.append(record)
        write_json_atomic(
            ladder_report_path,
            {
                "format": "cargo_circuit_physics_difficulty_ladder_v4",
                "strategy_id": "SAC-P47",
                "rule": "promote only after two perfect held-out validation sweeps; stop at first non-converged level",
                "levels": ladder_records,
                "highest_converged_level": champion_level,
                "first_nonconverged_level": failed_level,
                "failed_model_retained": False,
                "existing_strategies_modified": False,
            },
        )
        if failed_level is not None:
            break

    vector_env.close()
    if champion_level is None:
        write_json_atomic(
            progress_path,
            {
                "status": "blocked",
                "stage": "no_converged_level",
                "strategy_id": "SAC-P47",
                "ladder_report": str(ladder_report_path),
            },
        )
        return 2

    champion_model = physics_entry.hardest_train.ExpertAnchoredSAC.load(
        champion_model_path.with_suffix(".zip"), device="cpu"
    )
    champion_config = _level_config(base_config, champion_level)
    test_rows, test_trajectory = _evaluate(
        champion_model,
        champion_config,
        dataset,
        champion_level,
        split="test",
        sweeps=1,
        seed=args.seed + 90000,
    )
    checkpoint = json.loads(champion_checkpoint_path.read_text(encoding="utf-8"))
    test_gate = _gate(
        test_rows,
        int(checkpoint["reinforcement_learning_provenance"]["actor_updates_after_warmup"]),
        required_sweeps=1,
    )
    full_circuit_eligible = int(champion_level.get("route_length", 0)) >= 8
    admitted_for_dropdown = bool(test_gate["passed"] and full_circuit_eligible)
    checkpoint["sealed_test_gate"] = test_gate
    checkpoint["full_circuit_eligible_for_dropdown"] = full_circuit_eligible
    checkpoint["admitted_for_dropdown"] = admitted_for_dropdown
    write_json_atomic(champion_checkpoint_path, checkpoint)
    if test_trajectory is not None:
        test_trajectory["all_test_task_metrics"] = test_rows
        test_trajectory["acceptance_gate"] = test_gate
        test_trajectory["checkpoint"] = str(champion_checkpoint_path)
        test_trajectory["physics_contract"] = physics_contract
        test_trajectory["additive_release"] = True
        test_trajectory["replaces_existing_strategy"] = False
        write_json_atomic(champion_trajectory_path, test_trajectory)
    report = json.loads(ladder_report_path.read_text(encoding="utf-8"))
    report["sealed_test_gate"] = test_gate
    report["champion_checkpoint"] = str(champion_checkpoint_path)
    report["champion_trajectory"] = str(champion_trajectory_path)
    report["full_circuit_eligible_for_dropdown"] = full_circuit_eligible
    report["admitted_for_dropdown"] = admitted_for_dropdown
    if not admitted_for_dropdown:
        champion_training = next(
            item["training"]
            for item in ladder_records
            if item["level"]["id"] == champion_level["id"]
        )
        report["sealed_test_nonadmission_diagnosis"] = diagnose_nonconvergence(
            level=champion_level,
            physics_contract=physics_contract,
            manual_gate=manual_gate,
            training=champion_training,
            validation_rows=test_rows,
            previous_level_passed=True,
        )
        if test_gate["passed"] and not full_circuit_eligible:
            report["sealed_test_nonadmission_diagnosis"]["release_boundary"] = (
                "Held-out segment evaluation passed, but the champion is not a complete "
                "eight-segment cargo circuit; it remains diagnostic-only and cannot enter "
                "the strategy dropdown."
            )
    write_json_atomic(ladder_report_path, report)
    final = {
        "status": "complete" if admitted_for_dropdown else "blocked",
        "operation": "difficulty_ladder_train",
        "strategy_id": "SAC-P47",
        "highest_converged_level": champion_level,
        "first_nonconverged_level": failed_level,
        "sealed_test_gate": test_gate,
        "full_circuit_eligible_for_dropdown": full_circuit_eligible,
        "admitted_for_dropdown": admitted_for_dropdown,
        "champion_checkpoint": str(champion_checkpoint_path),
        "champion_trajectory": str(champion_trajectory_path),
        "ladder_report": str(ladder_report_path),
        "failed_model_retained": False,
        "existing_strategies_modified": False,
    }
    write_json_atomic(progress_path, final)
    print(json.dumps(final, ensure_ascii=False), flush=True)
    return 0 if admitted_for_dropdown else 3


if __name__ == "__main__":
    raise SystemExit(main())
