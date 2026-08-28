#!/usr/bin/env python3
"""Fine-tune a versioned SAC champion without overwriting frozen evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import time
from typing import Any, Callable, Mapping

from stable_baselines3 import SAC
from stable_baselines3.common.callbacks import CallbackList, CheckpointCallback
from stable_baselines3.common.monitor import Monitor
from stable_baselines3.common.vec_env import DummyVecEnv

from ship_rl.environment import (
    dataset_fingerprint,
    experiment_fingerprint,
    load_experiment,
)
from ship_rl.port_contract import validate_port_dataset
from ship_rl.port_ops_environment import PORT_OPS_OBSERVATION_SIZE
from ship_rl.port_ops_trainer import _port_callback_class, _port_sb3_imports
from ship_rl.sac_champion_environment import SacChampionPortOpsEnv
from ship_rl.trainer import _write_episode_metrics, write_json_atomic


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _factory(
    config: Mapping[str, Any],
    dataset: Mapping[str, Any],
    max_steps: int,
    seed: int,
) -> Callable[[], Any]:
    def create() -> Any:
        return Monitor(
            SacChampionPortOpsEnv(
                config,
                dataset,
                split="train",
                discrete_actions=False,
                max_steps=max_steps,
                seed=seed,
                render_mode=None,
            )
        )

    return create


def _parent_model_path(checkpoint_path: Path) -> tuple[dict[str, Any], Path]:
    checkpoint = json.loads(checkpoint_path.read_text(encoding="utf-8"))
    model_path = Path(str(checkpoint.get("model_path", "")))
    if not model_path.is_absolute():
        model_path = checkpoint_path.parent / model_path
    if not model_path.is_file():
        raise FileNotFoundError(f"parent SAC model not found: {model_path}")
    if str(checkpoint.get("algorithm")) != "sac":
        raise ValueError("parent checkpoint must be a SAC policy")
    if int(checkpoint.get("observation_size", 0)) != PORT_OPS_OBSERVATION_SIZE:
        raise ValueError("parent checkpoint observation schema is not port_ops_45")
    return checkpoint, model_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--parent-checkpoint", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--progress-json", required=True)
    parser.add_argument("--checkpoint-json", required=True)
    parser.add_argument("--total-timesteps", type=int, default=40_000)
    parser.add_argument("--max-steps", type=int, default=1_600)
    parser.add_argument("--agents", type=int, default=1)
    parser.add_argument("--learning-rate", type=float, default=1e-4)
    parser.add_argument("--warmup-steps", type=int, default=5_000)
    parser.add_argument("--batch-size", type=int, default=256)
    parser.add_argument("--buffer-size", type=int, default=150_000)
    parser.add_argument("--checkpoint-interval", type=int, default=10_000)
    parser.add_argument("--seed", type=int, default=250_107)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config_path = Path(args.config).expanduser().resolve()
    parent_path = Path(args.parent_checkpoint).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve()
    progress_path = Path(args.progress_json).expanduser().resolve()
    checkpoint_path = Path(args.checkpoint_json).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    config, dataset, dataset_path = load_experiment(config_path)
    contract = validate_port_dataset(dataset)
    if contract["errors"] or not contract["research_training_ready"]:
        raise ValueError("SAC V5 requires a valid offline port dataset contract")
    parent, parent_model_path = _parent_model_path(parent_path)

    factories = [
        _factory(config, dataset, args.max_steps, args.seed + index)
        for index in range(max(1, args.agents))
    ]
    vector_env = DummyVecEnv(factories)
    model = SAC.load(parent_model_path, env=vector_env, device="auto")
    model.learning_rate = float(args.learning_rate)
    model._setup_lr_schedule()
    for parameter_group in model.actor.optimizer.param_groups:
        parameter_group["lr"] = float(args.learning_rate)
    for parameter_group in model.critic.optimizer.param_groups:
        parameter_group["lr"] = float(args.learning_rate)
    if model.ent_coef_optimizer is not None:
        for parameter_group in model.ent_coef_optimizer.param_groups:
            parameter_group["lr"] = float(args.learning_rate)
    model.learning_starts = max(1, int(args.warmup_steps))
    model.batch_size = max(16, int(args.batch_size))
    model.buffer_size = max(1_000, int(args.buffer_size))
    model.replay_buffer = model.replay_buffer_class(
        model.buffer_size,
        model.observation_space,
        model.action_space,
        device=model.device,
        n_envs=model.n_envs,
        optimize_memory_usage=model.optimize_memory_usage,
        handle_timeout_termination=True,
    )

    imports = _port_sb3_imports()
    progress_callback = _port_callback_class(imports)(
        progress_path,
        int(args.total_timesteps),
        "sac",
    )
    checkpoint_callback = CheckpointCallback(
        save_freq=max(1, int(args.checkpoint_interval)),
        save_path=os.fspath(output_dir / "milestones"),
        name_prefix="sac_champion_v5",
        save_replay_buffer=False,
        save_vecnormalize=False,
    )
    write_json_atomic(
        progress_path,
        {
            "status": "starting",
            "operation": "fine_tune",
            "stage": "load_parent_sac_and_train_split",
            "algorithm": "sac",
            "progress": 0.0,
            "render": False,
            "dataset_split": "train",
            "parent_checkpoint": os.fspath(parent_path),
        },
    )
    started = time.monotonic()
    model.learn(
        total_timesteps=max(1, int(args.total_timesteps)),
        callback=CallbackList([progress_callback, checkpoint_callback]),
        progress_bar=False,
        reset_num_timesteps=True,
    )
    final_model_base = output_dir / "sac_policy"
    model.save(final_model_base)
    final_model = final_model_base.with_suffix(".zip")
    vector_env.close()

    episodes = progress_callback.episodes
    _write_episode_metrics(output_dir / "sac_train_episodes.csv", episodes)
    recent = episodes[-20:]
    parent_steps = int(parent.get("actual_timesteps", 0) or 0)
    checkpoint = {
        "format": "ship_sac_champion_checkpoint_v5",
        "algorithm": "sac",
        "strategy_id": "sac_champion_v5",
        "library": "stable-baselines3",
        "model_path": os.path.relpath(final_model, checkpoint_path.parent),
        "model_path_base": "checkpoint_directory",
        "action_space": "continuous_throttle_rudder_box",
        "observation_size": PORT_OPS_OBSERVATION_SIZE,
        "trained": True,
        "training_mode": "reward_aligned_sac_fine_tune",
        "requested_timesteps": int(args.total_timesteps),
        "actual_timesteps": int(model.num_timesteps),
        "lineage_timesteps": parent_steps + int(model.num_timesteps),
        "parallel_envs": max(1, int(args.agents)),
        "dataset_split_used": "train",
        "dataset_sha256": dataset_fingerprint(dataset),
        "experiment_sha256": experiment_fingerprint(config),
        "dataset_path": os.fspath(dataset_path) if dataset_path else "runtime_snapshot",
        "config_path": os.fspath(config_path),
        "environment_parameters": config.get("environment_parameters", {}),
        "reward_profile": config.get("rl_parameters", {}),
        "seed": int(args.seed),
        "hyperparameters": {
            "learning_rate": float(args.learning_rate),
            "warmup_steps": int(args.warmup_steps),
            "batch_size": int(args.batch_size),
            "buffer_size": int(args.buffer_size),
            "milestone_interval": int(args.checkpoint_interval),
        },
        "parent": {
            "checkpoint": os.fspath(parent_path),
            "checkpoint_sha256": _sha256(parent_path),
            "model": os.fspath(parent_model_path),
            "model_sha256": _sha256(parent_model_path),
            "actual_timesteps": parent_steps,
        },
        "port_contract": {
            "research_training_ready": True,
            "live_control_ready": False,
        },
    }
    write_json_atomic(checkpoint_path, checkpoint)
    elapsed = time.monotonic() - started
    result = {
        "status": "complete",
        "ok": True,
        "operation": "fine_tune",
        "stage": "sac_champion_v5_checkpoint_ready",
        "algorithm": "sac",
        "progress": 1.0,
        "completed_timesteps": int(model.num_timesteps),
        "lineage_timesteps": checkpoint["lineage_timesteps"],
        "episodes_completed": len(episodes),
        "mean_reward_20": (
            sum(float(row["reward"]) for row in recent) / len(recent)
            if recent
            else 0.0
        ),
        "success_rate_20": (
            sum(bool(row["success"]) for row in recent) / len(recent)
            if recent
            else 0.0
        ),
        "port_compliant_rate_20": (
            sum(bool(row["port_compliant_success"]) for row in recent)
            / len(recent)
            if recent
            else 0.0
        ),
        "elapsed_seconds": elapsed,
        "checkpoint_json": os.fspath(checkpoint_path),
        "model_path": os.fspath(final_model),
        "render": False,
        "dataset_split": "train",
        "dataset_sha256": checkpoint["dataset_sha256"],
        "experiment_sha256": checkpoint["experiment_sha256"],
        "observation_size": PORT_OPS_OBSERVATION_SIZE,
        "port_contract": checkpoint["port_contract"],
    }
    write_json_atomic(progress_path, result)
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
