"""Stable-Baselines3 training and recorded test-rollout export."""

from __future__ import annotations

import csv
import json
import math
import os
import time
import traceback
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Sequence, Tuple

import numpy as np

from .environment import (
    OBSERVATION_SIZE,
    LosPidController,
    ShipNavigationEnv,
    dataset_fingerprint,
    experiment_fingerprint,
    load_experiment,
)


RL_ALGORITHMS = ("ppo", "sac", "td3", "dqn")
CONTROL_ALGORITHMS = ("los_pid",)
ALGORITHMS = RL_ALGORITHMS + CONTROL_ALGORITHMS


def write_json_atomic(path: Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(path)


@dataclass
class TrainRequest:
    algorithm: str
    config_path: Path
    output_dir: Path
    progress_path: Path
    checkpoint_path: Path
    total_timesteps: int = 20_000
    max_steps: int = 800
    parallel_envs: int = 1
    seed: int = 240705
    learning_rate: float = 3e-4
    gamma: float = 0.985
    gae_lambda: float = 0.94
    entropy_coef: float = 0.018
    value_loss_coef: float = 0.52
    clip_range: float = 0.18
    rollout_horizon: int = 1_024
    batch_size: int = 512
    minibatch_size: int = 128
    replay_buffer_size: int = 120_000
    warmup_steps: int = 12_000
    target_update_steps: int = 1_500
    epsilon_start: float = 0.92
    epsilon_end: float = 0.06
    epsilon_decay_steps: int = 90_000
    los_kp: float = 1.35
    los_ki: float = 0.015
    los_kd: float = 0.24


@dataclass
class EvaluateRequest:
    algorithm: str
    config_path: Path
    output_dir: Path
    progress_path: Path
    checkpoint_path: Path
    trajectory_path: Path
    max_steps: int = 800
    episodes: int = 1
    seed: int = 240705
    split: str = "test"


def _sb3_imports() -> Dict[str, Any]:
    try:
        from stable_baselines3 import DQN, PPO, SAC, TD3
        from stable_baselines3.common.callbacks import BaseCallback
        from stable_baselines3.common.monitor import Monitor
        from stable_baselines3.common.vec_env import DummyVecEnv
    except ImportError as exc:  # pragma: no cover - exercised by CLI diagnostics
        raise RuntimeError(
            "RL dependencies are missing. Run: bash tools/setup_rl_env.sh"
        ) from exc
    return {
        "ppo": PPO,
        "sac": SAC,
        "td3": TD3,
        "dqn": DQN,
        "BaseCallback": BaseCallback,
        "Monitor": Monitor,
        "DummyVecEnv": DummyVecEnv,
    }


def _environment_factory(
    config: Mapping[str, Any],
    dataset: Mapping[str, Any],
    split: str,
    discrete: bool,
    max_steps: int,
    seed: int,
    task_index: int | None = None,
) -> Callable[[], ShipNavigationEnv]:
    def create() -> ShipNavigationEnv:
        return ShipNavigationEnv(
            config,
            dataset,
            split=split,
            discrete_actions=discrete,
            max_steps=max_steps,
            seed=seed,
            task_index=task_index,
            render_mode=None,
        )

    return create


def _safe_batch_size(requested: int, rollout_size: int) -> int:
    candidates = [value for value in range(8, max(9, min(requested, rollout_size)) + 1) if rollout_size % value == 0]
    return max(candidates) if candidates else min(8, rollout_size)


def _build_model(algorithm: str, env: Any, request: TrainRequest, imports: Mapping[str, Any]) -> Any:
    common = {
        "policy": "MlpPolicy",
        "env": env,
        "learning_rate": request.learning_rate,
        "gamma": request.gamma,
        "seed": request.seed,
        "verbose": 0,
        "device": "auto",
        "tensorboard_log": None,
        "policy_kwargs": {"net_arch": [128, 128]},
    }
    if algorithm == "ppo":
        maximum_useful_horizon = math.ceil(request.total_timesteps / max(request.parallel_envs, 1))
        n_steps = max(64, min(request.rollout_horizon, maximum_useful_horizon))
        rollout_size = n_steps * max(request.parallel_envs, 1)
        return imports["ppo"](
            **common,
            n_steps=n_steps,
            batch_size=_safe_batch_size(request.minibatch_size, rollout_size),
            n_epochs=10,
            gae_lambda=request.gae_lambda,
            ent_coef=request.entropy_coef,
            vf_coef=request.value_loss_coef,
            clip_range=request.clip_range,
        )
    if algorithm == "sac":
        return imports["sac"](
            **common,
            buffer_size=max(request.replay_buffer_size, 1_000),
            learning_starts=min(request.warmup_steps, max(request.total_timesteps // 4, 1)),
            batch_size=max(16, request.batch_size),
            train_freq=1,
            gradient_steps=1,
        )
    if algorithm == "td3":
        from stable_baselines3.common.noise import NormalActionNoise

        return imports["td3"](
            **common,
            buffer_size=max(request.replay_buffer_size, 1_000),
            learning_starts=min(request.warmup_steps, max(request.total_timesteps // 4, 1)),
            batch_size=max(16, request.batch_size),
            train_freq=1,
            gradient_steps=1,
            action_noise=NormalActionNoise(mean=np.zeros(2), sigma=np.full(2, 0.1)),
        )
    return imports["dqn"](
        **common,
        buffer_size=max(request.replay_buffer_size, 1_000),
        learning_starts=min(request.warmup_steps, max(request.total_timesteps // 4, 1)),
        batch_size=max(16, request.batch_size),
        target_update_interval=max(50, request.target_update_steps),
        exploration_initial_eps=request.epsilon_start,
        exploration_final_eps=request.epsilon_end,
        exploration_fraction=min(1.0, max(0.01, request.epsilon_decay_steps / max(request.total_timesteps, 1))),
        train_freq=4,
        gradient_steps=1,
    )


def _callback_class(imports: Mapping[str, Any]) -> type:
    BaseCallback = imports["BaseCallback"]

    class JsonProgressCallback(BaseCallback):
        def __init__(self, path: Path, total_timesteps: int, algorithm: str) -> None:
            super().__init__(verbose=0)
            self.path = path
            self.total_timesteps = max(total_timesteps, 1)
            self.algorithm = algorithm
            self.episodes: List[Dict[str, Any]] = []
            self.started = time.monotonic()
            self._last_write_step = -1

        def _on_step(self) -> bool:
            infos = self.locals.get("infos", [])
            for info in infos:
                episode = info.get("episode") if isinstance(info, Mapping) else None
                if isinstance(episode, Mapping):
                    self.episodes.append(
                        {
                            "episode": len(self.episodes) + 1,
                            "reward": float(episode.get("r", 0.0)),
                            "length": int(episode.get("l", 0)),
                            "collisions": int(info.get("collisions", 0)),
                            "terrain_collisions": int(info.get("terrain_collisions", 0)),
                            "near_misses": int(info.get("near_misses", 0)),
                            "minimum_clearance_meters": float(info.get("minimum_clearance_meters", 0.0)),
                            "minimum_dcpa_meters": float(info.get("minimum_dcpa_meters", 0.0)),
                            "success": bool(info.get("is_success", False)),
                            "task_id": str(info.get("task_id", "unknown")),
                        }
                    )
            if self.num_timesteps - self._last_write_step >= 100 or self.num_timesteps >= self.total_timesteps:
                self._last_write_step = self.num_timesteps
                recent = self.episodes[-20:]
                reward = float(np.mean([row["reward"] for row in recent])) if recent else 0.0
                success_rate = float(np.mean([row["success"] for row in recent])) if recent else 0.0
                elapsed = time.monotonic() - self.started
                fps = self.num_timesteps / max(elapsed, 1e-6)
                write_json_atomic(
                    self.path,
                    {
                        "status": "running",
                        "operation": "train",
                        "stage": "policy_update",
                        "algorithm": self.algorithm,
                        "completed_timesteps": self.num_timesteps,
                        "total_timesteps": self.total_timesteps,
                        "progress": min(self.num_timesteps / self.total_timesteps, 1.0),
                        "episodes_completed": len(self.episodes),
                        "mean_reward_20": reward,
                        "success_rate_20": success_rate,
                        "fps": fps,
                        "elapsed_seconds": elapsed,
                        "render": False,
                        "dataset_split": "train",
                        "last": recent[-1] if recent else {},
                    },
                )
            return True

    return JsonProgressCallback


def _write_episode_metrics(path: Path, episodes: Sequence[Mapping[str, Any]]) -> None:
    if not episodes:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(episodes[0].keys()))
        writer.writeheader()
        writer.writerows(episodes)


def train(request: TrainRequest) -> Dict[str, Any]:
    if request.algorithm not in ALGORITHMS:
        raise ValueError(f"unsupported algorithm: {request.algorithm}")
    request.output_dir.mkdir(parents=True, exist_ok=True)
    config, dataset, dataset_path = load_experiment(request.config_path)
    fingerprint = dataset_fingerprint(dataset)
    experiment_sha256 = experiment_fingerprint(config)
    write_json_atomic(
        request.progress_path,
        {
            "status": "starting",
            "operation": "train",
            "stage": "load_train_split",
            "algorithm": request.algorithm,
            "progress": 0.0,
            "render": False,
            "dataset_split": "train",
        },
    )
    started = time.monotonic()
    model_path: Path | None = None
    episode_metrics: List[Dict[str, Any]] = []
    actual_timesteps = 0
    if request.algorithm == "los_pid":
        checkpoint = {
            "format": "ship_autonomy_checkpoint_v3",
            "algorithm": request.algorithm,
            "controller": {"type": "los_pid", "kp": request.los_kp, "ki": request.los_ki, "kd": request.los_kd},
            "trained": False,
            "training_note": "control-theory baseline has no learned parameters",
            "dataset_split_used": "train",
            "dataset_sha256": fingerprint,
            "experiment_sha256": experiment_sha256,
            "dataset_path": os.fspath(dataset_path) if dataset_path else "runtime_snapshot",
            "config_path": os.fspath(request.config_path),
            "environment_parameters": config.get("environment_parameters", {}),
            "seed": request.seed,
        }
    else:
        imports = _sb3_imports()
        discrete = request.algorithm == "dqn"
        Monitor = imports["Monitor"]
        DummyVecEnv = imports["DummyVecEnv"]
        factories = []
        for index in range(max(1, request.parallel_envs)):
            base_factory = _environment_factory(
                config,
                dataset,
                "train",
                discrete,
                request.max_steps,
                request.seed + index,
            )

            def monitored(factory: Callable[[], ShipNavigationEnv] = base_factory) -> Any:
                return Monitor(factory())

            factories.append(monitored)
        vector_env = DummyVecEnv(factories)
        model = _build_model(request.algorithm, vector_env, request, imports)
        callback = _callback_class(imports)(request.progress_path, request.total_timesteps, request.algorithm)
        model.learn(total_timesteps=request.total_timesteps, callback=callback, progress_bar=False)
        actual_timesteps = int(model.num_timesteps)
        model_path = request.output_dir / f"{request.algorithm}_policy"
        model.save(model_path)
        model_path = model_path.with_suffix(".zip")
        portable_model_path = os.path.relpath(
            model_path,
            request.checkpoint_path.parent,
        )
        episode_metrics = callback.episodes
        vector_env.close()
        checkpoint = {
            "format": "ship_autonomy_checkpoint_v3",
            "algorithm": request.algorithm,
            "library": "stable-baselines3",
            "model_path": portable_model_path,
            "model_path_base": "checkpoint_directory",
            "action_space": "discrete_throttle_rudder_9" if discrete else "continuous_throttle_rudder_box",
            "observation_size": OBSERVATION_SIZE,
            "trained": True,
            "requested_timesteps": request.total_timesteps,
            "actual_timesteps": actual_timesteps,
            "parallel_envs": request.parallel_envs,
            "dataset_split_used": "train",
            "dataset_sha256": fingerprint,
            "experiment_sha256": experiment_sha256,
            "dataset_path": os.fspath(dataset_path) if dataset_path else "runtime_snapshot",
            "config_path": os.fspath(request.config_path),
            "environment_parameters": config.get("environment_parameters", {}),
            "seed": request.seed,
            "hyperparameters": {
                "learning_rate": request.learning_rate,
                "gamma": request.gamma,
                "rollout_horizon": request.rollout_horizon,
                "batch_size": request.batch_size,
                "minibatch_size": request.minibatch_size,
                "buffer_size": request.replay_buffer_size,
                "warmup_steps": request.warmup_steps,
                "target_update_steps": request.target_update_steps,
                "epsilon_start": request.epsilon_start,
                "epsilon_end": request.epsilon_end,
                "epsilon_decay_steps": request.epsilon_decay_steps,
            },
        }
    write_json_atomic(request.checkpoint_path, checkpoint)
    _write_episode_metrics(request.output_dir / f"{request.algorithm}_train_episodes.csv", episode_metrics)
    elapsed = time.monotonic() - started
    recent = episode_metrics[-20:]
    result = {
        "status": "complete",
        "ok": True,
        "operation": "train",
        "stage": "checkpoint_ready",
        "algorithm": request.algorithm,
        "progress": 1.0,
        "completed_timesteps": actual_timesteps,
        "total_timesteps": request.total_timesteps if request.algorithm != "los_pid" else 0,
        "episodes_completed": len(episode_metrics),
        "mean_reward_20": float(np.mean([row["reward"] for row in recent])) if recent else 0.0,
        "success_rate_20": float(np.mean([row["success"] for row in recent])) if recent else 0.0,
        "elapsed_seconds": elapsed,
        "checkpoint_json": os.fspath(request.checkpoint_path),
        "model_path": os.fspath(model_path) if model_path else "",
        "render": False,
        "dataset_split": "train",
        "dataset_sha256": fingerprint,
        "experiment_sha256": experiment_sha256,
        "observation_size": OBSERVATION_SIZE,
        "environment_parameters": config.get("environment_parameters", {}),
    }
    write_json_atomic(request.progress_path, result)
    return result


def _load_policy(checkpoint: Mapping[str, Any]) -> Any:
    algorithm = str(checkpoint["algorithm"])
    if algorithm == "los_pid":
        params = checkpoint.get("controller", {})
        return LosPidController(float(params.get("kp", 1.35)), float(params.get("ki", 0.015)), float(params.get("kd", 0.24)))
    imports = _sb3_imports()
    model_path = Path(str(checkpoint.get("model_path", "")))
    checkpoint_path = checkpoint.get("_checkpoint_path")
    if not model_path.is_absolute() and checkpoint_path:
        model_path = Path(str(checkpoint_path)).parent / model_path
    if not model_path.exists():
        raise FileNotFoundError(f"trained model not found: {model_path}")
    return imports[algorithm].load(model_path, device="auto")


def _policy_action(policy: Any, algorithm: str, env: ShipNavigationEnv, observation: np.ndarray) -> Any:
    if algorithm == "los_pid":
        return policy.predict(env)
    action, _state = policy.predict(observation, deterministic=True)
    return action


def _route_reference_length(task: Mapping[str, Any]) -> float:
    points: List[Tuple[float, float]] = []
    start = task.get("start", {})
    if isinstance(start, Mapping):
        points.append((float(start.get("x", 0.0)), float(start.get("z", 0.0))))
    for point in task.get("route", []):
        if isinstance(point, Mapping):
            points.append((float(point.get("x", 0.0)), float(point.get("z", 0.0))))
        else:
            points.append((float(point[0]), float(point[1])))
    return float(
        sum(
            math.hypot(bx - ax, bz - az)
            for (ax, az), (bx, bz) in zip(points, points[1:])
        )
    )


def _percentile(values: Sequence[float], fraction: float) -> float:
    if not values:
        return 0.0
    return float(np.percentile(np.asarray(values, dtype=np.float64), fraction * 100.0))


def evaluate(request: EvaluateRequest) -> Dict[str, Any]:
    if request.split not in {"validation", "test"}:
        raise ValueError("evaluation split must be validation or test")
    checkpoint = json.loads(request.checkpoint_path.read_text(encoding="utf-8"))
    checkpoint["_checkpoint_path"] = os.fspath(request.checkpoint_path)
    algorithm = str(checkpoint.get("algorithm", request.algorithm))
    if algorithm != request.algorithm:
        raise ValueError(f"checkpoint algorithm {algorithm!r} does not match requested {request.algorithm!r}")
    config, dataset, dataset_path = load_experiment(request.config_path)
    fingerprint = dataset_fingerprint(dataset)
    if checkpoint.get("dataset_sha256") != fingerprint:
        raise ValueError("dataset changed after training; retrain before evaluation")
    experiment_sha256 = experiment_fingerprint(config)
    if checkpoint.get("experiment_sha256") != experiment_sha256:
        raise ValueError("environment or training configuration changed after training; retrain before evaluation")
    write_json_atomic(
        request.progress_path,
        {
            "status": "running",
            "operation": "evaluate",
            "stage": f"{request.split}_rollout",
            "algorithm": algorithm,
            "progress": 0.0,
            "render": False,
            "dataset_split": request.split,
        },
    )
    policy = _load_policy(checkpoint)
    discrete = algorithm == "dqn"
    evaluation_tasks = dataset["splits"][request.split]
    episode_count = min(max(1, request.episodes), len(evaluation_tasks))
    results: List[Dict[str, Any]] = []
    selected_env: ShipNavigationEnv | None = None
    started = time.monotonic()
    for index in range(episode_count):
        env = ShipNavigationEnv(
            config,
            dataset,
            split=request.split,
            discrete_actions=discrete,
            max_steps=request.max_steps,
            seed=request.seed + index,
            task_index=index,
            render_mode=None,
        )
        observation, _info = env.reset(options={"task_index": index})
        if algorithm == "los_pid":
            policy.reset()
        terminated = truncated = False
        info: Dict[str, Any] = {}
        while not (terminated or truncated):
            action = _policy_action(policy, algorithm, env, observation)
            observation, _reward, terminated, truncated, info = env.step(action)
        reference_length = _route_reference_length(env.task)
        path_length = float(info.get("path_length_meters", 0.0))
        result = {
            "task_id": str(env.task.get("id", index)),
            "success": bool(info.get("is_success", False)),
            "goal_reached": bool(info.get("goal_reached", False)),
            "collisions": int(info.get("collisions", 0)),
            "terrain_collisions": int(info.get("terrain_collisions", 0)),
            "near_misses": int(info.get("near_misses", 0)),
            "dynamic_obstacle_count": int(info.get("dynamic_obstacle_count", 0)),
            "minimum_clearance_meters": float(info.get("minimum_clearance_meters", 0.0)),
            "minimum_dcpa_meters": float(info.get("minimum_dcpa_meters", 0.0)),
            "max_cross_track_error_meters": float(info.get("max_cross_track_error_meters", 0.0)),
            "path_length_meters": path_length,
            "reference_route_length_meters": reference_length,
            "path_efficiency": min(
                reference_length / max(path_length, 1e-6),
                1.0,
            ),
            "elapsed_seconds": env.steps * env.delta,
            "reward": env.total_reward,
            "steps": env.steps,
            "last_collision": dict(info.get("last_collision", {})),
        }
        results.append(result)
        if selected_env is None:
            selected_env = env
        write_json_atomic(
            request.progress_path,
            {
                "status": "running",
                "operation": "evaluate",
                "stage": f"{request.split}_rollout",
                "algorithm": algorithm,
                "completed_episodes": index + 1,
                "total_episodes": episode_count,
                "progress": (index + 1) / episode_count,
                "last": result,
                "render": False,
                "dataset_split": request.split,
            },
        )
    assert selected_env is not None
    task = selected_env.task
    start = task.get("start", {})
    route_points = []
    for point in task.get("route", []):
        if isinstance(point, Mapping):
            route_points.append({"x": float(point.get("x", 0.0)), "z": float(point.get("z", 0.0))})
        else:
            route_points.append({"x": float(point[0]), "z": float(point[1])})
    obstacles = selected_env.obstacle_export_records()
    first_result = results[0]
    trajectory = {
        "format": (
            "ship_policy_test_rollout_v3"
            if request.split == "test"
            else "ship_policy_validation_rollout_v1"
        ),
        "source": "deterministic_policy_rollout",
        "algorithm": algorithm,
        "checkpoint": os.fspath(request.checkpoint_path),
        "dataset_path": os.fspath(dataset_path) if dataset_path else "runtime_snapshot",
        "dataset_sha256": fingerprint,
        "experiment_sha256": experiment_sha256,
        "observation_size": OBSERVATION_SIZE,
        "environment_parameters": config.get("environment_parameters", {}),
        "dataset_split": request.split,
        "task_id": first_result["task_id"],
        "playback_mode": "recorded_test_rollout",
        "start": {
            "x": float(start.get("x", selected_env.trajectory[0]["x"])),
            "z": float(start.get("z", selected_env.trajectory[0]["z"])),
            "heading_degrees": float(start.get("heading_degrees", selected_env.trajectory[0]["heading_degrees"])),
        },
        "goal": route_points[-1],
        "route_points": route_points,
        "evaluation_obstacles": obstacles,
        "samples": selected_env.trajectory,
        "evaluation_metrics": first_result,
        "aggregate_metrics": {
            "episodes": len(results),
            "success_rate": float(np.mean([item["success"] for item in results])),
            "safe_completion_rate": float(
                np.mean(
                    [
                        item["success"]
                        and item["collisions"] == 0
                        and item["terrain_collisions"] == 0
                        for item in results
                    ]
                )
            ),
            "collision_episode_rate": float(
                np.mean([item["collisions"] > 0 for item in results])
            ),
            "terrain_collision_episode_rate": float(
                np.mean([item["terrain_collisions"] > 0 for item in results])
            ),
            "near_miss_episode_rate": float(
                np.mean([item["near_misses"] > 0 for item in results])
            ),
            "mean_reward": float(np.mean([item["reward"] for item in results])),
            "total_collisions": int(sum(item["collisions"] for item in results)),
            "total_terrain_collisions": int(sum(item["terrain_collisions"] for item in results)),
            "total_near_misses": int(sum(item["near_misses"] for item in results)),
            "mean_max_cross_track_error_meters": float(
                np.mean([item["max_cross_track_error_meters"] for item in results])
            ),
            "p95_max_cross_track_error_meters": _percentile(
                [item["max_cross_track_error_meters"] for item in results],
                0.95,
            ),
            "mean_minimum_clearance_meters": float(
                np.mean([item["minimum_clearance_meters"] for item in results])
            ),
            "p05_minimum_clearance_meters": _percentile(
                [item["minimum_clearance_meters"] for item in results],
                0.05,
            ),
            "mean_minimum_dcpa_meters": float(
                np.mean([item["minimum_dcpa_meters"] for item in results])
            ),
            "p05_minimum_dcpa_meters": _percentile(
                [item["minimum_dcpa_meters"] for item in results],
                0.05,
            ),
            "mean_path_efficiency": float(
                np.mean([item["path_efficiency"] for item in results])
            ),
            "mean_elapsed_seconds": float(
                np.mean([item["elapsed_seconds"] for item in results])
            ),
        },
    }
    write_json_atomic(request.trajectory_path, trajectory)
    _write_episode_metrics(request.output_dir / f"{algorithm}_test_episodes.csv", results)
    result = {
        "status": "complete",
        "ok": True,
        "operation": "evaluate",
        "stage": "trajectory_ready",
        "algorithm": algorithm,
        "progress": 1.0,
        "elapsed_seconds": time.monotonic() - started,
        "trajectory_json": os.fspath(request.trajectory_path),
        "evaluation_metrics": first_result,
        "aggregate_metrics": trajectory["aggregate_metrics"],
        "render": False,
        "render_ready": request.split == "test",
        "dataset_split": request.split,
    }
    write_json_atomic(request.progress_path, result)
    return result


def guarded_run(progress_path: Path, operation: str, function: Callable[[], Dict[str, Any]]) -> Dict[str, Any]:
    try:
        return function()
    except Exception as exc:
        payload = {
            "status": "failed",
            "ok": False,
            "operation": operation,
            "error_type": type(exc).__name__,
            "error": str(exc),
            "traceback": traceback.format_exc(),
            "render": False,
        }
        write_json_atomic(progress_path, payload)
        raise
