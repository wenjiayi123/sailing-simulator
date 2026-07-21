#!/usr/bin/env python3
"""CLI for real headless training and post-training test rollouts."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from ship_rl.trainer import ALGORITHMS, EvaluateRequest, TrainRequest, evaluate, guarded_run, train


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train or evaluate ship-autonomy baselines without rendering.")
    parser.add_argument("--mode", choices=("train", "evaluate"), default="train")
    parser.add_argument("--algorithm", choices=ALGORITHMS, default="ppo")
    parser.add_argument("--config", required=True)
    parser.add_argument("--episodes", type=int, default=25, help="UI compatibility; multiplied by --steps for total samples")
    parser.add_argument("--steps", type=int, default=800)
    parser.add_argument("--agents", type=int, default=1, help="parallel numeric environments, not rendered vessels")
    parser.add_argument("--total-timesteps", type=int, default=0)
    parser.add_argument("--eval-episodes", type=int, default=1)
    parser.add_argument("--lr", type=float, default=3e-4)
    parser.add_argument("--gamma", type=float, default=0.985)
    parser.add_argument("--gae-lambda", type=float, default=0.94)
    parser.add_argument("--entropy-coef", type=float, default=0.018)
    parser.add_argument("--value-loss-coef", type=float, default=0.52)
    parser.add_argument("--clip-range", type=float, default=0.18)
    parser.add_argument("--rollout-horizon", type=int, default=1024)
    parser.add_argument("--batch-size", type=int, default=512)
    parser.add_argument("--minibatch-size", type=int, default=128)
    parser.add_argument("--replay-buffer-size", type=int, default=120000)
    parser.add_argument("--warmup-steps", type=int, default=12000)
    parser.add_argument("--target-update-steps", type=int, default=1500)
    parser.add_argument("--epsilon", type=float, default=0.92)
    parser.add_argument("--min-epsilon", type=float, default=0.06)
    parser.add_argument("--epsilon-decay-steps", type=int, default=90000)
    parser.add_argument("--los-kp", type=float, default=1.35)
    parser.add_argument("--los-ki", type=float, default=0.015)
    parser.add_argument("--los-kd", type=float, default=0.24)
    parser.add_argument("--seed", type=int, default=240705)
    parser.add_argument("--output-dir", default=str(Path("output") / "rl_runs"))
    parser.add_argument("--progress-json", required=True)
    parser.add_argument("--checkpoint-json", required=True)
    parser.add_argument("--trajectory-json", default="")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    output_dir = Path(args.output_dir).expanduser().resolve()
    progress_path = Path(args.progress_json).expanduser().resolve()
    checkpoint_path = Path(args.checkpoint_json).expanduser().resolve()
    config_path = Path(args.config).expanduser().resolve()
    if args.mode == "train":
        total_timesteps = args.total_timesteps or max(1, args.episodes * args.steps * max(args.agents, 1))
        request = TrainRequest(
            algorithm=args.algorithm,
            config_path=config_path,
            output_dir=output_dir,
            progress_path=progress_path,
            checkpoint_path=checkpoint_path,
            total_timesteps=total_timesteps,
            max_steps=args.steps,
            parallel_envs=max(1, args.agents),
            seed=args.seed,
            learning_rate=args.lr,
            gamma=args.gamma,
            gae_lambda=args.gae_lambda,
            entropy_coef=args.entropy_coef,
            value_loss_coef=args.value_loss_coef,
            clip_range=args.clip_range,
            rollout_horizon=args.rollout_horizon,
            batch_size=args.batch_size,
            minibatch_size=args.minibatch_size,
            replay_buffer_size=args.replay_buffer_size,
            warmup_steps=args.warmup_steps,
            target_update_steps=args.target_update_steps,
            epsilon_start=args.epsilon,
            epsilon_end=args.min_epsilon,
            epsilon_decay_steps=args.epsilon_decay_steps,
            los_kp=args.los_kp,
            los_ki=args.los_ki,
            los_kd=args.los_kd,
        )
        result = guarded_run(progress_path, "train", lambda: train(request))
    else:
        if not args.trajectory_json:
            raise SystemExit("--trajectory-json is required in evaluate mode")
        request = EvaluateRequest(
            algorithm=args.algorithm,
            config_path=config_path,
            output_dir=output_dir,
            progress_path=progress_path,
            checkpoint_path=checkpoint_path,
            trajectory_path=Path(args.trajectory_json).expanduser().resolve(),
            max_steps=args.steps,
            episodes=max(1, args.eval_episodes),
            seed=args.seed,
        )
        result = guarded_run(progress_path, "evaluate", lambda: evaluate(request))
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
