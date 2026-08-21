#!/usr/bin/env python3
"""CLI for independent headless cargo-circuit training and test rollout."""

from __future__ import annotations

import argparse
import json
import traceback
from pathlib import Path

from cargo_rl.trainer import CARGO_ALGORITHMS, evaluate_cargo, train_cargo
from ship_rl.trainer import TrainRequest, write_json_atomic


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train/test the independent cargo-circuit policy without rendering.")
    parser.add_argument("--mode", choices=("train", "evaluate"), default="train")
    parser.add_argument("--algorithm", choices=CARGO_ALGORITHMS, default="sac")
    parser.add_argument("--config", default="data/rl/cargo_circuit_experiment_v1.json")
    parser.add_argument("--total-timesteps", type=int, default=300000)
    parser.add_argument("--steps", type=int, default=2400)
    parser.add_argument("--agents", type=int, default=1)
    parser.add_argument("--eval-episodes", type=int, default=1)
    parser.add_argument("--eval-split", choices=("validation", "test"), default="test")
    parser.add_argument("--lr", type=float, default=3e-4)
    parser.add_argument("--gamma", type=float, default=0.995)
    parser.add_argument("--rollout-horizon", type=int, default=1024)
    parser.add_argument("--batch-size", type=int, default=256)
    parser.add_argument("--minibatch-size", type=int, default=128)
    parser.add_argument("--replay-buffer-size", type=int, default=350000)
    parser.add_argument("--warmup-steps", type=int, default=10000)
    parser.add_argument("--seed", type=int, default=260815)
    parser.add_argument("--los-kp", type=float, default=1.35)
    parser.add_argument("--los-ki", type=float, default=0.015)
    parser.add_argument("--los-kd", type=float, default=0.24)
    parser.add_argument("--output-dir", default="output/cargo_rl")
    parser.add_argument("--progress-json", default="output/cargo_rl/progress.json")
    parser.add_argument("--checkpoint-json", default="output/cargo_rl/cargo_policy_checkpoint.json")
    parser.add_argument("--trajectory-json", default="output/cargo_rl/cargo_policy_test_trajectory.json")
    parser.add_argument("--evidence-json", default="reports/cargo_circuit_rl_evidence_v1.json")
    parser.add_argument(
        "--initialize-from-checkpoint",
        default="",
        help="Optional cargo checkpoint whose neural weights initialize a new SAC training run.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config = Path(args.config).expanduser().resolve()
    output = Path(args.output_dir).expanduser().resolve()
    progress = Path(args.progress_json).expanduser().resolve()
    checkpoint = Path(args.checkpoint_json).expanduser().resolve()
    trajectory = Path(args.trajectory_json).expanduser().resolve()
    evidence = Path(args.evidence_json).expanduser().resolve() if args.evidence_json else None
    try:
        if args.mode == "train":
            result = train_cargo(
                TrainRequest(
                    algorithm=args.algorithm,
                    config_path=config,
                    output_dir=output,
                    progress_path=progress,
                    checkpoint_path=checkpoint,
                    total_timesteps=max(1, args.total_timesteps),
                    max_steps=max(1, args.steps),
                    parallel_envs=max(1, args.agents),
                    seed=args.seed,
                    learning_rate=args.lr,
                    gamma=args.gamma,
                    rollout_horizon=args.rollout_horizon,
                    batch_size=args.batch_size,
                    minibatch_size=args.minibatch_size,
                    replay_buffer_size=args.replay_buffer_size,
                    warmup_steps=args.warmup_steps,
                    los_kp=args.los_kp,
                    los_ki=args.los_ki,
                    los_kd=args.los_kd,
                ),
                initialize_from_checkpoint=(
                    Path(args.initialize_from_checkpoint).expanduser().resolve()
                    if args.initialize_from_checkpoint
                    else None
                ),
            )
        else:
            result = evaluate_cargo(
                algorithm=args.algorithm,
                config_path=config,
                output_dir=output,
                progress_path=progress,
                checkpoint_path=checkpoint,
                trajectory_path=trajectory,
                split=args.eval_split,
                episodes=max(1, args.eval_episodes),
                max_steps=max(1, args.steps),
                seed=args.seed,
                evidence_path=evidence if args.eval_split == "test" else None,
            )
    except Exception as exc:
        write_json_atomic(
            progress,
            {
                "status": "failed",
                "ok": False,
                "module": "cargo_circuit_rl",
                "operation": args.mode,
                "error_type": type(exc).__name__,
                "error": str(exc),
                "traceback": traceback.format_exc(),
                "render": False,
            },
        )
        raise
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
