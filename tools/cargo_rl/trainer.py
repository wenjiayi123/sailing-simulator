"""Training, held-out evaluation, and evidence export for cargo-circuit RL."""

from __future__ import annotations

import csv
import json
import math
import os
import time
from pathlib import Path
from typing import Any, Dict, List, Mapping, Sequence

import numpy as np

try:
    from ship_rl.environment import LosPidController, dataset_fingerprint, experiment_fingerprint, load_experiment
    from ship_rl.trainer import (
        TrainRequest,
        _build_model,
        _callback_class,
        _safe_batch_size,
        _sb3_imports,
        write_json_atomic,
    )
except ModuleNotFoundError:  # package import from repository root
    from tools.ship_rl.environment import LosPidController, dataset_fingerprint, experiment_fingerprint, load_experiment
    from tools.ship_rl.trainer import (
        TrainRequest,
        _build_model,
        _callback_class,
        _safe_batch_size,
        _sb3_imports,
        write_json_atomic,
    )

from .environment import CARGO_OBSERVATION_SIZE, CargoCircuitEnv, cargo_experiment_fingerprint
from .demonstration import collect_dynamic_training_demonstrations, collect_training_demonstrations
from .dynamic_environment import DYNAMIC_OBSERVATION_SIZE, CargoDynamicEnv, CargoDynamicResidualEnv


CARGO_RL_ALGORITHMS = ("sac", "ppo", "td3", "a2c", "ddpg", "tqc", "trpo")
CARGO_ALGORITHMS = CARGO_RL_ALGORITHMS + ("los_pid",)


def _cargo_sb3_imports() -> Dict[str, Any]:
    """Extend the shared runtime only inside the independent cargo module."""
    imports = dict(_sb3_imports())
    try:
        from stable_baselines3 import A2C, DDPG
        from sb3_contrib import TQC, TRPO
    except ImportError as exc:  # pragma: no cover - exercised by CLI diagnostics
        raise RuntimeError("Cargo RL dependencies are missing. Run: bash tools/setup_rl_env.sh") from exc
    imports.update({"a2c": A2C, "ddpg": DDPG, "tqc": TQC, "trpo": TRPO})
    return imports


def _build_cargo_model(
    algorithm: str,
    env: Any,
    request: TrainRequest,
    imports: Mapping[str, Any],
) -> Any:
    if algorithm in ("sac", "ppo", "td3"):
        return _build_model(algorithm, env, request, imports)
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
    if algorithm == "a2c":
        maximum_useful_horizon = math.ceil(request.total_timesteps / max(request.parallel_envs, 1))
        n_steps = max(5, min(request.rollout_horizon, maximum_useful_horizon))
        return imports["a2c"](
            **common,
            n_steps=n_steps,
            gae_lambda=request.gae_lambda,
            ent_coef=request.entropy_coef,
            vf_coef=request.value_loss_coef,
            normalize_advantage=True,
        )
    if algorithm == "ddpg":
        from stable_baselines3.common.noise import NormalActionNoise

        return imports["ddpg"](
            **common,
            buffer_size=max(request.replay_buffer_size, 1_000),
            learning_starts=min(request.warmup_steps, max(request.total_timesteps // 4, 1)),
            batch_size=max(16, request.batch_size),
            train_freq=1,
            gradient_steps=1,
            action_noise=NormalActionNoise(mean=np.zeros(2), sigma=np.full(2, 0.1)),
        )
    if algorithm == "tqc":
        return imports["tqc"](
            **common,
            buffer_size=max(request.replay_buffer_size, 1_000),
            learning_starts=min(request.warmup_steps, max(request.total_timesteps // 4, 1)),
            batch_size=max(16, request.batch_size),
            train_freq=1,
            gradient_steps=1,
        )
    if algorithm == "trpo":
        maximum_useful_horizon = math.ceil(request.total_timesteps / max(request.parallel_envs, 1))
        n_steps = max(64, min(request.rollout_horizon, maximum_useful_horizon))
        rollout_size = n_steps * max(request.parallel_envs, 1)
        return imports["trpo"](
            **common,
            n_steps=n_steps,
            batch_size=_safe_batch_size(request.minibatch_size, rollout_size),
            gae_lambda=request.gae_lambda,
        )
    raise ValueError(f"unsupported cargo RL model: {algorithm}")


def _require_manual_feasibility_gate(
    config: Mapping[str, Any],
    config_path: Path,
    dataset_sha: str,
    experiment_sha: str,
) -> Dict[str, Any]:
    gate_config = config.get("pretraining_feasibility_gate", {})
    if not bool(gate_config.get("required", False)):
        return {"required": False, "passed": True}
    raw_path = str(gate_config.get("path", ""))
    if not raw_path:
        raise ValueError("required manual feasibility gate path is missing")
    if raw_path.startswith("res://"):
        project_root = config_path
        while project_root.parent != project_root and not (project_root / "project.godot").exists():
            project_root = project_root.parent
        gate_path = project_root / raw_path.removeprefix("res://")
    else:
        gate_path = Path(raw_path).expanduser()
        if not gate_path.is_absolute():
            gate_path = config_path.parent / gate_path
    gate_path = gate_path.resolve()
    if not gate_path.exists():
        raise ValueError(
            "manual feasibility gate is missing; run: "
            "PYTHONPATH=tools .venv/bin/python tools/cargo_rl_manual_feasibility.py"
        )
    payload = json.loads(gate_path.read_text(encoding="utf-8"))
    accepted = payload.get("acceptance_gate", {})
    if not bool(accepted.get("passed", False)):
        raise ValueError("manual feasibility gate did not pass; RL training is blocked")
    if bool(gate_config.get("requires_matching_dataset_and_experiment_sha256", True)):
        if payload.get("dataset_sha256") != dataset_sha or payload.get("experiment_sha256") != experiment_sha:
            raise ValueError("manual feasibility evidence is stale; rerun it before RL training")
    return {
        "required": True,
        "passed": True,
        "path": os.fspath(gate_path),
        "episodes": int(payload.get("aggregate", {}).get("episodes", 0)),
        "success_rate": float(payload.get("aggregate", {}).get("success_rate", 0.0)),
        "total_collisions": int(payload.get("aggregate", {}).get("total_collisions", 0)),
        "minimum_safety_envelope_clearance_meters": float(
            payload.get("aggregate", {}).get("minimum_safety_envelope_clearance_meters", 0.0)
        ),
    }


def _write_csv(path: Path, rows: Sequence[Mapping[str, Any]]) -> None:
    if not rows:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def _behavior_clone_sac_actor(
    model: Any,
    demonstrations: Mapping[str, Any],
    epochs: int,
    batch_size: int,
    seed: int,
) -> Dict[str, Any]:
    """Initialize SAC's actor from transparent helm demonstrations."""
    import torch

    observations = np.asarray(demonstrations["observations"], dtype=np.float32)
    actions = np.asarray(demonstrations["actions"], dtype=np.float32)
    if observations.size == 0 or epochs <= 0:
        return {"epochs": 0, "samples": int(len(observations)), "final_loss": None}
    actor = model.policy.actor
    rng = np.random.default_rng(seed)
    device = model.device
    final_loss = 0.0
    for _epoch in range(epochs):
        indices = rng.permutation(len(observations))
        for start in range(0, len(indices), max(1, batch_size)):
            batch = indices[start : start + max(1, batch_size)]
            observation_tensor = torch.as_tensor(observations[batch], device=device)
            action_tensor = torch.as_tensor(actions[batch], device=device)
            mean_actions, _log_std, _kwargs = actor.get_action_dist_params(observation_tensor)
            predicted_actions = torch.tanh(mean_actions)
            loss = torch.nn.functional.mse_loss(predicted_actions, action_tensor)
            actor.optimizer.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(actor.parameters(), 1.0)
            actor.optimizer.step()
            final_loss = float(loss.detach().cpu().item())
    return {"epochs": epochs, "samples": int(len(observations)), "final_loss": final_loss}


def _prefill_off_policy_replay(model: Any, demonstrations: Mapping[str, Any]) -> int:
    replay_buffer = getattr(model, "replay_buffer", None)
    if replay_buffer is None:
        return 0
    observations = demonstrations["observations"]
    next_observations = demonstrations["next_observations"]
    actions = demonstrations["actions"]
    rewards = demonstrations["rewards"]
    dones = demonstrations["dones"]
    for observation, next_observation, action, reward, done in zip(
        observations, next_observations, actions, rewards, dones
    ):
        replay_buffer.add(
            np.asarray(observation, dtype=np.float32)[None, :],
            np.asarray(next_observation, dtype=np.float32)[None, :],
            np.asarray(action, dtype=np.float32)[None, :],
            np.asarray([reward], dtype=np.float32),
            np.asarray([done], dtype=np.float32),
            [{}],
        )
    return int(len(observations))


def _checkpoint_model_path(checkpoint_path: Path, checkpoint: Mapping[str, Any]) -> Path:
    model_path = Path(str(checkpoint.get("model_path", "")))
    if not model_path.is_absolute():
        model_path = checkpoint_path.parent / model_path
    return model_path.resolve()


def _transfer_static_policy_to_dynamic(source_model: Any, target_model: Any) -> Dict[str, Any]:
    """Copy the accepted 36D SAC policy into a 44D policy with zero-new-feature priors."""
    import torch

    source = source_model.policy.state_dict()
    target = target_model.policy.state_dict()
    copied_exact = 0
    copied_expanded = 0
    with torch.no_grad():
        for key, target_value in target.items():
            source_value = source.get(key)
            if source_value is None:
                continue
            if tuple(source_value.shape) == tuple(target_value.shape):
                target_value.copy_(source_value)
                copied_exact += 1
                continue
            if source_value.ndim != 2 or target_value.ndim != 2 or source_value.shape[0] != target_value.shape[0]:
                continue
            if source_value.shape[1] == CARGO_OBSERVATION_SIZE and target_value.shape[1] == DYNAMIC_OBSERVATION_SIZE:
                target_value[:, :CARGO_OBSERVATION_SIZE].copy_(source_value)
                copied_expanded += 1
            elif source_value.shape[1] == CARGO_OBSERVATION_SIZE + 2 and target_value.shape[1] == DYNAMIC_OBSERVATION_SIZE + 2:
                target_value[:, :CARGO_OBSERVATION_SIZE].copy_(source_value[:, :CARGO_OBSERVATION_SIZE])
                target_value[:, DYNAMIC_OBSERVATION_SIZE:].copy_(source_value[:, CARGO_OBSERVATION_SIZE:])
                copied_expanded += 1
        target_model.policy.load_state_dict(target)
    return {"exact_tensors": copied_exact, "expanded_input_tensors": copied_expanded}


def _initialize_zero_residual_actor(model: Any) -> None:
    """Start deterministic residual control at exactly the frozen base action."""
    import torch

    actor = model.policy.actor
    with torch.no_grad():
        actor.mu.weight.zero_()
        actor.mu.bias.zero_()
        actor.log_std.weight.zero_()
        actor.log_std.bias.fill_(-3.0)


def train_cargo(
    request: TrainRequest,
    initialize_from_checkpoint: Path | None = None,
) -> Dict[str, Any]:
    if request.algorithm not in CARGO_ALGORITHMS:
        raise ValueError(f"unsupported cargo algorithm: {request.algorithm}")
    request.output_dir.mkdir(parents=True, exist_ok=True)
    config, dataset, dataset_path = load_experiment(request.config_path)
    dynamic_module = str(config.get("module", "cargo_circuit_rl")) == "cargo_circuit_dynamic_rl"
    module_name = "cargo_circuit_dynamic_rl" if dynamic_module else "cargo_circuit_rl"
    checkpoint_format = "cargo_circuit_dynamic_checkpoint_v2" if dynamic_module else "cargo_circuit_checkpoint_v1"
    observation_size = DYNAMIC_OBSERVATION_SIZE if dynamic_module else CARGO_OBSERVATION_SIZE
    observation_contract = (
        "cargo_circuit_dynamic_continuous_v2_44d"
        if dynamic_module
        else "cargo_circuit_continuous_v1_36d"
    )
    residual_dynamic = bool(config.get("cargo_parameters", {}).get("residual_policy", False))
    environment_class = (
        CargoDynamicResidualEnv
        if dynamic_module and residual_dynamic
        else (CargoDynamicEnv if dynamic_module else CargoCircuitEnv)
    )
    dataset_sha = dataset_fingerprint(dataset)
    experiment_sha = cargo_experiment_fingerprint(config)
    feasibility_gate = _require_manual_feasibility_gate(
        config,
        request.config_path,
        dataset_sha,
        experiment_sha,
    )
    write_json_atomic(
        request.progress_path,
        {
            "status": "starting",
            "operation": "train",
            "stage": "load_train_split",
            "module": module_name,
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
    initialization_record: Dict[str, Any] = {
        "checkpoint": None,
        "demonstrations": {"enabled": False},
    }

    if request.algorithm == "los_pid":
        checkpoint: Dict[str, Any] = {
            "format": checkpoint_format,
            "module": module_name,
            "algorithm": "los_pid",
            "controller": {"type": "los_pid", "kp": request.los_kp, "ki": request.los_ki, "kd": request.los_kd},
            "trained": False,
            "training_note": "control-theory comparison baseline; not an RL policy",
        }
    else:
        # Small MLP updates are substantially faster and more reproducible with
        # one Torch CPU thread than with macOS' high-overhead default pool.
        import torch

        torch.set_num_threads(1)
        try:
            torch.set_num_interop_threads(1)
        except RuntimeError:
            pass
        imports = _cargo_sb3_imports()
        Monitor = imports["Monitor"]
        DummyVecEnv = imports["DummyVecEnv"]
        cargo_parameters = config.get("cargo_parameters", {})
        route_lengths = [int(value) for value in cargo_parameters.get("curriculum_route_lengths", [8])]
        obstacles_enabled = [bool(value) for value in cargo_parameters.get("curriculum_obstacles_enabled", [True] * len(route_lengths))]
        randomization_enabled = [bool(value) for value in cargo_parameters.get("curriculum_randomization_enabled", [True] * len(route_lengths))]
        random_segment = [bool(value) for value in cargo_parameters.get("curriculum_random_segment", [False] * len(route_lengths))]
        curriculum_max_steps = [int(value) for value in cargo_parameters.get("curriculum_max_steps", [request.max_steps] * len(route_lengths))]
        fractions = [float(value) for value in cargo_parameters.get("curriculum_fractions", [1.0])]
        if (
            len(route_lengths) != len(fractions)
            or len(route_lengths) != len(obstacles_enabled)
            or len(route_lengths) != len(curriculum_max_steps)
            or len(route_lengths) != len(randomization_enabled)
            or len(route_lengths) != len(random_segment)
            or not route_lengths
        ):
            raise ValueError("cargo curriculum route lengths/fractions are inconsistent")
        fraction_sum = sum(fractions)
        if fraction_sum <= 0.0:
            raise ValueError("cargo curriculum fractions must sum to a positive value")
        fractions = [value / fraction_sum for value in fractions]

        def make_vector_env(
            route_length: int,
            phase_index: int,
            include_obstacles: bool,
            include_randomization: bool,
            use_random_segment: bool,
            phase_max_steps: int,
        ) -> Any:
            factories = []
            for index in range(max(1, request.parallel_envs)):
                seed = request.seed + phase_index * 1000 + index

                def create(seed_value: int = seed, limit: int = route_length) -> Any:
                    return Monitor(
                        environment_class(
                            config,
                            dataset,
                            split="train",
                            discrete_actions=False,
                            max_steps=min(request.max_steps, max(1, phase_max_steps)),
                            seed=seed_value,
                            render_mode=None,
                            curriculum_route_length=limit,
                            curriculum_obstacles_enabled=include_obstacles,
                            curriculum_randomization_enabled=include_randomization,
                            curriculum_random_segment=use_random_segment,
                        )
                    )

                factories.append(create)
            return DummyVecEnv(factories)

        vector_env = make_vector_env(
            route_lengths[0], 0, obstacles_enabled[0], randomization_enabled[0], random_segment[0], curriculum_max_steps[0]
        )
        if initialize_from_checkpoint is not None:
            source_checkpoint_path = initialize_from_checkpoint.expanduser().resolve()
            source_checkpoint = json.loads(source_checkpoint_path.read_text(encoding="utf-8"))
            if source_checkpoint.get("format") != "cargo_circuit_checkpoint_v1":
                raise ValueError("initialization checkpoint is not a cargo-circuit model")
            if str(source_checkpoint.get("algorithm")) != request.algorithm:
                raise ValueError("initialization checkpoint algorithm does not match")
            source_model_path = _checkpoint_model_path(source_checkpoint_path, source_checkpoint)
            if not source_model_path.exists():
                raise FileNotFoundError(f"initialization model not found: {source_model_path}")
            source_observation_size = int(source_checkpoint.get("observation_size", -1))
            if source_observation_size == observation_size:
                model = imports[request.algorithm].load(source_model_path, env=vector_env, device="auto")
                transfer = {"mode": "exact_observation_contract"}
            elif (
                dynamic_module
                and request.algorithm == "sac"
                and source_observation_size == CARGO_OBSERVATION_SIZE
                and observation_size == DYNAMIC_OBSERVATION_SIZE
            ):
                model = _build_cargo_model(request.algorithm, vector_env, request, imports)
                source_model = imports[request.algorithm].load(source_model_path, device="auto")
                transfer = {
                    "mode": "static_36d_to_dynamic_44d_partial_network_transfer",
                    **_transfer_static_policy_to_dynamic(source_model, model),
                }
            else:
                raise ValueError("initialization checkpoint observation contract does not match")
            model.learning_starts = request.warmup_steps
            model.learning_rate = request.learning_rate
            model.lr_schedule = lambda _progress: request.learning_rate
            for optimizer in (
                getattr(getattr(model, "policy", None), "actor", None),
                getattr(getattr(model, "policy", None), "critic", None),
            ):
                optimizer = getattr(optimizer, "optimizer", None)
                if optimizer is not None:
                    for group in optimizer.param_groups:
                        group["lr"] = request.learning_rate
            initialization_record["checkpoint"] = {
                "path": os.fspath(source_checkpoint_path),
                "model_path": os.fspath(source_model_path),
                "source_experiment_sha256": source_checkpoint.get("experiment_sha256"),
                "source_timesteps": int(source_checkpoint.get("actual_timesteps", 0)),
                "weights_only": True,
                "transfer": transfer,
            }
        else:
            model = _build_cargo_model(request.algorithm, vector_env, request, imports)
            if dynamic_module and residual_dynamic and request.algorithm == "sac":
                _initialize_zero_residual_actor(model)
        if request.algorithm in ("sac", "td3", "ddpg", "tqc"):
            from stable_baselines3.common.type_aliases import TrainFreq, TrainFrequencyUnit

            # One gradient update per four fresh transitions keeps the desktop
            # training loop practical while retaining off-policy replay.
            model.train_freq = TrainFreq(4, TrainFrequencyUnit.STEP)
        demonstration_config = config.get("demonstration_initialization", {})
        if request.algorithm == "sac" and bool(demonstration_config.get("enabled_for_sac", False)):
            if dynamic_module:
                demonstrations = collect_dynamic_training_demonstrations(
                    config,
                    dataset,
                    seed=int(demonstration_config.get("fixed_seed", request.seed + 7000)),
                )
            else:
                demonstrations = collect_training_demonstrations(
                    config,
                    dataset,
                    seed=request.seed + 7000,
                    episodes_per_task=int(demonstration_config.get("episodes_per_train_task", 1)),
                )
            cloning = _behavior_clone_sac_actor(
                model,
                demonstrations,
                epochs=int(demonstration_config.get("actor_behavior_cloning_epochs", 0)),
                batch_size=request.batch_size,
                seed=request.seed + 8000,
            )
            replay_samples = 0
            if bool(demonstration_config.get("replay_buffer_prefill", True)):
                replay_samples = _prefill_off_policy_replay(model, demonstrations)
            initialization_record["demonstrations"] = {
                "enabled": True,
                "source": demonstration_config.get("source"),
                "episodes": int(demonstrations["episodes"]),
                "successful_episodes": int(demonstrations["successes"]),
                "samples": int(len(demonstrations["observations"])),
                "actor_behavior_cloning": cloning,
                "replay_buffer_prefill_samples": replay_samples,
                "bypass_points_available_to_released_policy": False,
            }
        callback = _callback_class(imports)(request.progress_path, request.total_timesteps, request.algorithm)
        allocated = 0
        curriculum_records: List[Dict[str, Any]] = []
        for phase_index, (
            route_length,
            include_obstacles,
            include_randomization,
            use_random_segment,
            phase_max_steps,
            fraction,
        ) in enumerate(
            zip(route_lengths, obstacles_enabled, randomization_enabled, random_segment, curriculum_max_steps, fractions)
        ):
            phase_steps = (
                request.total_timesteps - allocated
                if phase_index == len(route_lengths) - 1
                else max(1, int(round(request.total_timesteps * fraction)))
            )
            if phase_index > 0:
                vector_env.close()
                vector_env = make_vector_env(
                    route_length,
                    phase_index,
                    include_obstacles,
                    include_randomization,
                    use_random_segment,
                    phase_max_steps,
                )
                model.set_env(vector_env)
            # SB3 resets num_timesteps for the first curriculum phase.  When
            # weights were initialized from another checkpoint, subtracting
            # that source counter would make phase 1 appear negative even
            # though all requested transitions were collected.
            phase_start = 0 if phase_index == 0 else int(model.num_timesteps)
            model.learn(
                total_timesteps=phase_steps,
                callback=callback,
                progress_bar=False,
                reset_num_timesteps=phase_index == 0,
            )
            phase_actual = int(model.num_timesteps) - phase_start
            allocated += phase_steps
            curriculum_records.append(
                {
                    "phase": phase_index + 1,
                    "route_length": route_length,
                    "obstacles_enabled": include_obstacles,
                    "randomization_enabled": include_randomization,
                    "random_segment": use_random_segment,
                    "max_steps": phase_max_steps,
                    "requested_timesteps": phase_steps,
                    "actual_timesteps": phase_actual,
                }
            )
        actual_timesteps = int(model.num_timesteps)
        model_stem = "cargo_dynamic" if dynamic_module else "cargo"
        model_path = request.output_dir / f"{model_stem}_{request.algorithm}_policy"
        model.save(model_path)
        model_path = model_path.with_suffix(".zip")
        episode_metrics = callback.episodes
        vector_env.close()
        checkpoint = {
            "format": checkpoint_format,
            "module": module_name,
            "algorithm": request.algorithm,
            "library": "stable-baselines3",
            "model_path": os.path.relpath(model_path, request.checkpoint_path.parent),
            "model_path_base": "checkpoint_directory",
            "trained": True,
            "requested_timesteps": request.total_timesteps,
            "actual_timesteps": actual_timesteps,
            "parallel_envs": request.parallel_envs,
            "observation_size": observation_size,
            "observation_contract": observation_contract,
            "action_contract": {
                "type": "residual_continuous_box" if residual_dynamic else "continuous_box",
                "shape": 2,
                "order": ["throttle", "rudder"],
                "range": [-1.0, 1.0],
                "physical_throttle_mapping": [
                    float(config.get("cargo_parameters", {}).get("throttle_action_min", -0.35)),
                    float(config.get("cargo_parameters", {}).get("throttle_action_max", 1.0)),
                ],
                "physical_rudder_mapping": [-1.0, 1.0],
                "frozen_static_policy_path": config.get("cargo_parameters", {}).get("frozen_static_policy_path") if residual_dynamic else None,
                "residual_scale": [
                    float(config.get("cargo_parameters", {}).get("residual_throttle_scale", 0.45)),
                    float(config.get("cargo_parameters", {}).get("residual_rudder_scale", 0.60)),
                ] if residual_dynamic else None,
            },
            "seed": request.seed,
            "curriculum": curriculum_records,
            "hyperparameters": {
                "learning_rate": request.learning_rate,
                "gamma": request.gamma,
                "batch_size": request.batch_size,
                "buffer_size": request.replay_buffer_size,
                "warmup_steps": request.warmup_steps,
                "rollout_horizon": request.rollout_horizon,
                "minibatch_size": request.minibatch_size,
            },
            "initialization": initialization_record,
        }

    checkpoint.update(
        {
            "dataset_split_used": "train",
            "dataset_sha256": dataset_sha,
            "experiment_sha256": experiment_sha,
            "dataset_path": os.fspath(dataset_path) if dataset_path else "",
            "config_path": os.fspath(request.config_path),
            "render": False,
            "environment_parameters": config.get("environment_parameters", {}),
            "ship_performance": config.get("ships", [{}])[0].get("performance", {}),
            "pretraining_feasibility_gate": feasibility_gate,
        }
    )
    write_json_atomic(request.checkpoint_path, checkpoint)
    _write_csv(request.output_dir / f"cargo_{request.algorithm}_train_episodes.csv", episode_metrics)
    recent = episode_metrics[-20:]
    result = {
        "status": "complete",
        "ok": True,
        "operation": "train",
        "stage": "checkpoint_ready",
        "module": module_name,
        "algorithm": request.algorithm,
        "progress": 1.0,
        "completed_timesteps": actual_timesteps,
        "total_timesteps": request.total_timesteps if request.algorithm != "los_pid" else 0,
        "episodes_completed": len(episode_metrics),
        "mean_reward_20": float(np.mean([row["reward"] for row in recent])) if recent else 0.0,
        "success_rate_20": float(np.mean([row["success"] for row in recent])) if recent else 0.0,
        "elapsed_seconds": time.monotonic() - started,
        "checkpoint_json": os.fspath(request.checkpoint_path),
        "model_path": os.fspath(model_path) if model_path else "",
        "render": False,
        "dataset_split": "train",
        "dataset_sha256": dataset_sha,
        "experiment_sha256": experiment_sha,
        "observation_size": observation_size,
    }
    write_json_atomic(request.progress_path, result)
    return result


def _load_policy(checkpoint: Mapping[str, Any], checkpoint_path: Path) -> Any:
    algorithm = str(checkpoint.get("algorithm", ""))
    if algorithm == "los_pid":
        params = checkpoint.get("controller", {})
        return LosPidController(
            float(params.get("kp", 1.35)),
            float(params.get("ki", 0.015)),
            float(params.get("kd", 0.24)),
        )
    imports = _cargo_sb3_imports()
    model_path = Path(str(checkpoint.get("model_path", "")))
    if not model_path.is_absolute():
        model_path = checkpoint_path.parent / model_path
    if not model_path.exists():
        raise FileNotFoundError(f"trained cargo model not found: {model_path}")
    return imports[algorithm].load(model_path, device="auto")


def _reference_length(task: Mapping[str, Any]) -> float:
    points = [task.get("start", {}), *task.get("route", [])]
    tuples = [(float(point.get("x", 0.0)), float(point.get("z", 0.0))) for point in points]
    return float(sum(math.hypot(bx - ax, bz - az) for (ax, az), (bx, bz) in zip(tuples, tuples[1:])))


def evaluate_cargo(
    *,
    algorithm: str,
    config_path: Path,
    output_dir: Path,
    progress_path: Path,
    checkpoint_path: Path,
    trajectory_path: Path,
    split: str,
    episodes: int,
    max_steps: int,
    seed: int,
    evidence_path: Path | None = None,
) -> Dict[str, Any]:
    if split not in ("validation", "test"):
        raise ValueError("cargo evaluation split must be validation or test")
    config, dataset, dataset_path = load_experiment(config_path)
    dynamic_module = str(config.get("module", "cargo_circuit_rl")) == "cargo_circuit_dynamic_rl"
    module_name = "cargo_circuit_dynamic_rl" if dynamic_module else "cargo_circuit_rl"
    checkpoint_format = "cargo_circuit_dynamic_checkpoint_v2" if dynamic_module else "cargo_circuit_checkpoint_v1"
    trajectory_format = (
        "cargo_circuit_dynamic_test_rollout_v2"
        if dynamic_module and split == "test"
        else (
            "cargo_circuit_dynamic_validation_rollout_v2"
            if dynamic_module
            else ("cargo_circuit_test_rollout_v1" if split == "test" else "cargo_circuit_validation_rollout_v1")
        )
    )
    observation_size = DYNAMIC_OBSERVATION_SIZE if dynamic_module else CARGO_OBSERVATION_SIZE
    observation_contract = (
        "cargo_circuit_dynamic_continuous_v2_44d"
        if dynamic_module
        else "cargo_circuit_continuous_v1_36d"
    )
    residual_dynamic = bool(config.get("cargo_parameters", {}).get("residual_policy", False))
    environment_class = (
        CargoDynamicResidualEnv
        if dynamic_module and residual_dynamic
        else (CargoDynamicEnv if dynamic_module else CargoCircuitEnv)
    )
    checkpoint = json.loads(checkpoint_path.read_text(encoding="utf-8"))
    if checkpoint.get("format") != checkpoint_format:
        raise ValueError("checkpoint does not match the requested cargo-circuit module")
    if str(checkpoint.get("algorithm")) != algorithm:
        raise ValueError("checkpoint algorithm does not match requested algorithm")
    dataset_sha = dataset_fingerprint(dataset)
    experiment_sha = cargo_experiment_fingerprint(config)
    if checkpoint.get("dataset_sha256") != dataset_sha:
        raise ValueError("cargo dataset changed after training; retrain before evaluation")
    if checkpoint.get("experiment_sha256") != experiment_sha:
        raise ValueError("cargo experiment changed after training; retrain before evaluation")

    write_json_atomic(
        progress_path,
        {
            "status": "running",
            "operation": "evaluate",
            "stage": f"{split}_rollout",
            "module": module_name,
            "algorithm": algorithm,
            "progress": 0.0,
            "render": False,
            "dataset_split": split,
        },
    )
    policy = _load_policy(checkpoint, checkpoint_path)
    task_count = len(dataset["splits"][split])
    episode_count = min(max(1, episodes), task_count)
    rows: List[Dict[str, Any]] = []
    selected_env: CargoCircuitEnv | None = None
    started = time.monotonic()
    for index in range(episode_count):
        env = environment_class(
            config,
            dataset,
            split=split,
            discrete_actions=False,
            max_steps=max_steps,
            seed=seed + index,
            task_index=index,
            render_mode=None,
        )
        observation, _ = env.reset(options={"task_index": index})
        if algorithm == "los_pid":
            policy.reset()
        terminated = truncated = False
        info: Dict[str, Any] = {}
        while not (terminated or truncated):
            if algorithm == "los_pid":
                action = policy.predict(env)
            else:
                action, _state = policy.predict(observation, deterministic=True)
            observation, _reward, terminated, truncated, info = env.step(action)
        reference = _reference_length(env.task)
        path_length = float(info.get("path_length_meters", 0.0))
        maximum_actual_rudder = max(abs(float(sample.get("actual_rudder", 0.0))) for sample in env.trajectory)
        maximum_yaw_rate = max(abs(float(sample.get("yaw_rate_degrees_per_second", 0.0))) for sample in env.trajectory)
        maximum_speed = max(abs(float(sample.get("speed_mps", 0.0))) for sample in env.trajectory)
        reverse_steps = sum(float(sample.get("speed_mps", 0.0)) < -0.05 for sample in env.trajectory)
        effective_boundary = (
            float(env.task.get("boundary_half_extent", 240.0))
            - float(env.environment_config["boundary_margin_m"])
            - float(env.environment_config["vessel_radius_m"])
        )
        minimum_boundary_clearance = min(
            effective_boundary - max(abs(float(sample["x"])), abs(float(sample["z"])))
            for sample in env.trajectory
        )
        row = {
            "task_id": str(info.get("task_id", index)),
            "success": bool(info.get("is_success", False)),
            "cargo_retrieved": bool(info.get("cargo_retrieved", False)),
            "checkpoints_passed": int(info.get("checkpoints_passed", 0)),
            "total_checkpoints": int(info.get("total_checkpoints", 0)),
            "checkpoint_completion_ratio": float(info.get("checkpoint_completion_ratio", 0.0)),
            "collisions": int(info.get("collisions", 0)),
            "terrain_collisions": int(info.get("terrain_collisions", 0)),
            "near_misses": int(info.get("near_misses", 0)),
            "minimum_clearance_meters": float(info.get("minimum_clearance_meters", 0.0)),
            "minimum_dynamic_clearance_meters": float(
                info.get("minimum_dynamic_clearance_meters", env.environment_config["sensor_range_m"])
            ),
            "minimum_dcpa_meters": float(info.get("minimum_dcpa_meters", env.environment_config["sensor_range_m"])),
            "dynamic_obstacle_count": int(info.get("dynamic_obstacle_count", 0)),
            "max_cross_track_error_meters": float(info.get("max_cross_track_error_meters", 0.0)),
            "path_length_meters": path_length,
            "reference_route_length_meters": reference,
            "path_efficiency": min(reference / max(path_length, 1e-6), 1.0),
            "elapsed_seconds": env.steps * env.delta,
            "reward": env.total_reward,
            "steps": env.steps,
            "maximum_actual_rudder_normalized": maximum_actual_rudder,
            "maximum_yaw_rate_degrees_per_second": maximum_yaw_rate,
            "maximum_speed_mps": maximum_speed,
            "reverse_steps": reverse_steps,
            "minimum_boundary_clearance_meters": minimum_boundary_clearance,
        }
        rows.append(row)
        if selected_env is None:
            selected_env = env
        write_json_atomic(
            progress_path,
            {
                "status": "running",
                "operation": "evaluate",
                "stage": f"{split}_rollout",
                "algorithm": algorithm,
                "completed_episodes": index + 1,
                "total_episodes": episode_count,
                "progress": (index + 1) / episode_count,
                "last": row,
                "render": False,
                "dataset_split": split,
            },
        )

    assert selected_env is not None
    selected_task = selected_env.task
    route = [
        {"name": str(point.get("name", f"航点 {index + 1}")), "x": float(point["x"]), "z": float(point["z"])}
        for index, point in enumerate(selected_task.get("route", []))
    ]
    aggregate = {
        "episodes": len(rows),
        "success_rate": float(np.mean([row["success"] for row in rows])),
        "safe_completion_rate": float(np.mean([row["success"] and row["collisions"] == 0 for row in rows])),
        "mean_checkpoint_completion_ratio": float(np.mean([row["checkpoint_completion_ratio"] for row in rows])),
        "total_collisions": int(sum(row["collisions"] for row in rows)),
        "mean_minimum_clearance_meters": float(np.mean([row["minimum_clearance_meters"] for row in rows])),
        "mean_path_efficiency": float(np.mean([row["path_efficiency"] for row in rows])),
        "mean_elapsed_seconds": float(np.mean([row["elapsed_seconds"] for row in rows])),
        "mean_reward": float(np.mean([row["reward"] for row in rows])),
    }
    first = rows[0]
    acceptance = {
        "passed": bool(
            split == "test"
            and checkpoint.get("trained", False)
            and first["success"]
            and first["cargo_retrieved"]
            and first["checkpoints_passed"] == first["total_checkpoints"]
            and first["collisions"] == 0
            and first["minimum_clearance_meters"] > 0.0
            and first["minimum_boundary_clearance_meters"] > 0.0
            and (not dynamic_module or first["dynamic_obstacle_count"] >= 6)
            and (not dynamic_module or first["minimum_dynamic_clearance_meters"] > 0.0)
            and first["maximum_yaw_rate_degrees_per_second"]
            <= float(config.get("ships", [{}])[0].get("performance", {}).get("max_turn_rate_degrees", 20.0)) + 1e-6
            and first["maximum_speed_mps"]
            <= float(config.get("ships", [{}])[0].get("performance", {}).get("max_forward_speed", 8.5)) + 1e-6
        ),
        "requires_trained_rl": True,
        "requires_test_split": True,
        "requires_all_checkpoints": True,
        "requires_zero_collision": True,
        "requires_positive_safety_envelope_clearance": True,
        "requires_positive_boundary_clearance": True,
        "requires_dynamics_limits_respected": True,
        "requires_dynamic_traffic_present": dynamic_module,
        "requires_positive_dynamic_clearance": dynamic_module,
    }
    start = selected_task.get("start", {})
    trajectory = {
        "format": trajectory_format,
        "module": module_name,
        "source": "deterministic_trained_policy_rollout" if checkpoint.get("trained", False) else "comparison_controller_rollout",
        "algorithm": algorithm,
        "trained_rl": bool(checkpoint.get("trained", False)),
        "checkpoint": os.fspath(checkpoint_path),
        "dataset_path": os.fspath(dataset_path) if dataset_path else "",
        "dataset_sha256": dataset_sha,
        "experiment_sha256": experiment_sha,
        "dataset_split": split,
        "task_id": first["task_id"],
        "playback_mode": "recorded_numeric_test_states",
        "rendered_during_training": False,
        "observation_size": observation_size,
        "observation_contract": observation_contract,
        "action_contract": checkpoint.get("action_contract", {}),
        "ship_performance": config.get("ships", [{}])[0].get("performance", {}),
        "start": {"x": float(start.get("x", 0.0)), "z": float(start.get("z", 0.0)), "heading_degrees": float(start.get("heading_degrees", 0.0))},
        "goal": route[-1],
        "route_points": route,
        "checkpoint_labels": [point["name"] for point in route[:-1]],
        "destination_label": route[-1]["name"],
        "evaluation_obstacles": selected_env.obstacle_export_records(),
        "samples": selected_env.trajectory,
        "evaluation_metrics": first,
        "aggregate_metrics": aggregate,
        "acceptance_gate": acceptance,
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    write_json_atomic(trajectory_path, trajectory)
    _write_csv(output_dir / f"cargo_{algorithm}_{split}_episodes.csv", rows)
    if evidence_path is not None:
        evidence = {
            "format": "cargo_circuit_dynamic_rl_evidence_v2" if dynamic_module else "cargo_circuit_rl_evidence_v1",
            "module": module_name,
            "boundary": "project-native numeric simulation; not real-port or production evidence",
            "algorithm_decision": config.get("algorithm_decision", {}),
            "training": {
                "trained": bool(checkpoint.get("trained", False)),
                "algorithm": algorithm,
                "timesteps": int(checkpoint.get("actual_timesteps", 0)),
                "render": False,
                "dataset_split": checkpoint.get("dataset_split_used", ""),
                "seed": checkpoint.get("seed"),
            },
            "evaluation": {
                "dataset_split": split,
                "render": False,
                "metrics": first,
                "aggregate": aggregate,
            },
            "acceptance_gate": acceptance,
            "artifacts": {
                "checkpoint": os.fspath(checkpoint_path),
                "trajectory": os.fspath(trajectory_path),
                "dataset_sha256": dataset_sha,
                "experiment_sha256": experiment_sha,
            },
        }
        write_json_atomic(evidence_path, evidence)
    result = {
        "status": "complete",
        "ok": True,
        "operation": "evaluate",
        "stage": "trajectory_ready",
        "module": module_name,
        "algorithm": algorithm,
        "progress": 1.0,
        "elapsed_seconds": time.monotonic() - started,
        "trajectory_json": os.fspath(trajectory_path),
        "evidence_json": os.fspath(evidence_path) if evidence_path else "",
        "evaluation_metrics": first,
        "aggregate_metrics": aggregate,
        "acceptance_gate": acceptance,
        "render": False,
        "render_ready": split == "test" and bool(acceptance["passed"]),
        "dataset_split": split,
    }
    write_json_atomic(progress_path, result)
    return result
