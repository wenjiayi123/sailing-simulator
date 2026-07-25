#!/usr/bin/env python3
"""Train or evaluate ten baselines with the 45-D real-port contract."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from ship_rl.port_ops_trainer import (
    ALGORITHMS,
    EvaluateRequest,
    TrainRequest,
    evaluate_port_ops,
    guarded_run,
    train_port_ops,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("train", "evaluate"), default="train")
    parser.add_argument("--algorithm", choices=ALGORITHMS, default="ppo")
    parser.add_argument("--config", required=True)
    parser.add_argument("--episodes", type=int, default=25)
    parser.add_argument("--steps", type=int, default=1600)
    parser.add_argument("--agents", type=int, default=1)
    parser.add_argument("--total-timesteps", type=int, default=0)
    parser.add_argument("--eval-episodes", type=int, default=1)
    parser.add_argument(
        "--eval-split",
        choices=("validation", "test"),
        default="test",
    )
    parser.add_argument("--lr", type=float, default=3e-4)
    parser.add_argument("--gamma", type=float, default=0.99)
    parser.add_argument("--gae-lambda", type=float, default=0.95)
    parser.add_argument("--entropy-coef", type=float, default=0.012)
    parser.add_argument("--value-loss-coef", type=float, default=0.5)
    parser.add_argument("--clip-range", type=float, default=0.2)
    parser.add_argument("--rollout-horizon", type=int, default=1024)
    parser.add_argument("--batch-size", type=int, default=256)
    parser.add_argument("--minibatch-size", type=int, default=128)
    parser.add_argument("--replay-buffer-size", type=int, default=150000)
    parser.add_argument("--warmup-steps", type=int, default=5000)
    parser.add_argument("--target-update-steps", type=int, default=1500)
    parser.add_argument("--epsilon", type=float, default=0.92)
    parser.add_argument("--min-epsilon", type=float, default=0.06)
    parser.add_argument("--epsilon-decay-steps", type=int, default=90000)
    parser.add_argument("--los-kp", type=float, default=1.35)
    parser.add_argument("--los-ki", type=float, default=0.015)
    parser.add_argument("--los-kd", type=float, default=0.24)
    parser.add_argument("--seed", type=int, default=250107)
    parser.add_argument("--output-dir", default=str(Path("output") / "port_ops_runs"))
    parser.add_argument("--progress-json", required=True)
    parser.add_argument("--checkpoint-json", required=True)
    parser.add_argument("--trajectory-json", default="")
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    output_dir = Path(arguments.output_dir).expanduser().resolve()
    progress_path = Path(arguments.progress_json).expanduser().resolve()
    checkpoint_path = Path(arguments.checkpoint_json).expanduser().resolve()
    config_path = Path(arguments.config).expanduser().resolve()
    if arguments.mode == "train":
        total_timesteps = arguments.total_timesteps or max(
            1,
            arguments.episodes
            * arguments.steps
            * max(arguments.agents, 1),
        )
        request = TrainRequest(
            algorithm=arguments.algorithm,
            config_path=config_path,
            output_dir=output_dir,
            progress_path=progress_path,
            checkpoint_path=checkpoint_path,
            total_timesteps=total_timesteps,
            max_steps=arguments.steps,
            parallel_envs=max(1, arguments.agents),
            seed=arguments.seed,
            learning_rate=arguments.lr,
            gamma=arguments.gamma,
            gae_lambda=arguments.gae_lambda,
            entropy_coef=arguments.entropy_coef,
            value_loss_coef=arguments.value_loss_coef,
            clip_range=arguments.clip_range,
            rollout_horizon=arguments.rollout_horizon,
            batch_size=arguments.batch_size,
            minibatch_size=arguments.minibatch_size,
            replay_buffer_size=arguments.replay_buffer_size,
            warmup_steps=arguments.warmup_steps,
            target_update_steps=arguments.target_update_steps,
            epsilon_start=arguments.epsilon,
            epsilon_end=arguments.min_epsilon,
            epsilon_decay_steps=arguments.epsilon_decay_steps,
            los_kp=arguments.los_kp,
            los_ki=arguments.los_ki,
            los_kd=arguments.los_kd,
        )
        result = guarded_run(
            progress_path,
            "train",
            lambda: train_port_ops(request),
        )
    else:
        if not arguments.trajectory_json:
            raise SystemExit("--trajectory-json is required in evaluate mode")
        request = EvaluateRequest(
            algorithm=arguments.algorithm,
            config_path=config_path,
            output_dir=output_dir,
            progress_path=progress_path,
            checkpoint_path=checkpoint_path,
            trajectory_path=Path(arguments.trajectory_json).expanduser().resolve(),
            max_steps=arguments.steps,
            episodes=max(1, arguments.eval_episodes),
            seed=arguments.seed,
            split=arguments.eval_split,
        )
        result = guarded_run(
            progress_path,
            "evaluate",
            lambda: evaluate_port_ops(request),
        )
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
