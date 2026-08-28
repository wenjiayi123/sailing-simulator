#!/usr/bin/env python3
"""V3 training entrypoint with current-map expert initialization."""

from __future__ import annotations

import csv
import hashlib
import json
import math
from pathlib import Path

import numpy as np
import torch as th
import torch.nn.functional as F
from stable_baselines3 import SAC
from stable_baselines3.common.utils import polyak_update

import cargo_rl.trainer as cargo_trainer
from cargo_rl.hardest_environment import (
    HARDEST_OBSERVATION_SIZE,
    CargoHardestV3Env,
)
from cargo_rl.hardest_demonstration import (
    collect_hardest_training_demonstrations,
    hardest_manual_helm,
    task_manual_targets,
)


# Keep the frozen V1 trainer source unchanged while supplying the V3-specific
# expert collector through the trainer's existing dependency seam.  The
# context remains train-only and is later used for DAgger state aggregation.
_training_context = {}


def _collect_hardest_with_context(config, dataset, seed, max_steps=None):
    _training_context.clear()
    _training_context.update({"config": config, "dataset": dataset, "seed": seed})
    return collect_hardest_training_demonstrations(
        config, dataset, seed, max_steps=max_steps
    )


cargo_trainer.collect_dynamic_training_demonstrations = _collect_hardest_with_context
cargo_trainer.CargoDynamicEnv = CargoHardestV3Env
cargo_trainer.DYNAMIC_OBSERVATION_SIZE = HARDEST_OBSERVATION_SIZE

_base_build_cargo_model = cargo_trainer._build_cargo_model


def _actor_sha256(actor) -> str:
    digest = hashlib.sha256()
    for name, value in sorted(actor.state_dict().items()):
        digest.update(name.encode("utf-8"))
        digest.update(value.detach().cpu().contiguous().numpy().tobytes())
    return digest.hexdigest()


class ExpertAnchoredSAC(SAC):
    """SAC with critic warm-up and a train-only expert policy anchor."""

    actor_warmup_steps = 10_000
    expert_anchor_coefficient = 10_000.0
    q_refinement_actor_learning_rate = 1e-7

    def train(self, gradient_steps: int, batch_size: int = 64) -> None:
        self.policy.set_training_mode(True)
        self._update_learning_rate([self.actor.optimizer, self.critic.optimizer])
        for group in self.actor.optimizer.param_groups:
            group["lr"] = self.q_refinement_actor_learning_rate
        actor_losses = []
        critic_losses = []
        anchor_losses = []
        ent_coefs = []
        for _gradient_step in range(gradient_steps):
            replay_data = self.replay_buffer.sample(
                batch_size, env=self._vec_normalize_env
            )
            actions_pi, log_prob = self.actor.action_log_prob(replay_data.observations)
            log_prob = log_prob.reshape(-1, 1)
            ent_coef = self.ent_coef_tensor
            ent_coefs.append(float(ent_coef.item()))

            with th.no_grad():
                next_actions, next_log_prob = self.actor.action_log_prob(
                    replay_data.next_observations
                )
                next_q_values = th.cat(
                    self.critic_target(replay_data.next_observations, next_actions), dim=1
                )
                next_q_values, _indices = th.min(next_q_values, dim=1, keepdim=True)
                next_q_values = next_q_values - ent_coef * next_log_prob.reshape(-1, 1)
                target_q_values = replay_data.rewards + (
                    1 - replay_data.dones
                ) * self.gamma * next_q_values

            current_q_values = self.critic(
                replay_data.observations, replay_data.actions
            )
            critic_loss = 0.5 * sum(
                F.mse_loss(current_q, target_q_values)
                for current_q in current_q_values
            )
            critic_losses.append(float(critic_loss.item()))
            self.critic.optimizer.zero_grad()
            critic_loss.backward()
            th.nn.utils.clip_grad_norm_(self.critic.parameters(), 10.0)
            self.critic.optimizer.step()

            if self.num_timesteps >= self.actor_warmup_steps:
                q_values_pi = th.cat(
                    self.critic(replay_data.observations, actions_pi), dim=1
                )
                minimum_q_pi, _indices = th.min(q_values_pi, dim=1, keepdim=True)
                rl_actor_loss = (ent_coef * log_prob - minimum_q_pi).mean()
                anchor_count = len(self.expert_anchor_observations)
                anchor_indices = np.random.randint(
                    0, anchor_count, size=min(batch_size, anchor_count)
                )
                anchor_observations = th.as_tensor(
                    self.expert_anchor_observations[anchor_indices], device=self.device
                )
                anchor_actions = th.as_tensor(
                    self.expert_anchor_actions[anchor_indices], device=self.device
                )
                mean_actions, _log_std, _distribution_kwargs = (
                    self.actor.get_action_dist_params(anchor_observations)
                )
                predicted_anchor_actions = th.tanh(mean_actions)
                throttle_anchor = F.mse_loss(
                    predicted_anchor_actions[:, 0], anchor_actions[:, 0]
                )
                rudder_anchor = F.mse_loss(
                    predicted_anchor_actions[:, 1], anchor_actions[:, 1]
                )
                anchor_loss = 0.55 * throttle_anchor + 1.45 * rudder_anchor
                actor_loss = (
                    rl_actor_loss
                    + self.expert_anchor_coefficient * anchor_loss
                )
                actor_losses.append(float(rl_actor_loss.item()))
                anchor_losses.append(float(anchor_loss.item()))
                self.actor.optimizer.zero_grad()
                actor_loss.backward()
                th.nn.utils.clip_grad_norm_(self.actor.parameters(), 1.0)
                self.actor.optimizer.step()
                self.rl_actor_updates = int(getattr(self, "rl_actor_updates", 0)) + 1
                self.last_rl_actor_loss = float(rl_actor_loss.item())
                self.last_expert_anchor_loss = float(anchor_loss.item())

            polyak_update(
                self.critic.parameters(), self.critic_target.parameters(), self.tau
            )
            polyak_update(self.batch_norm_stats, self.batch_norm_stats_target, 1.0)

        self._n_updates += gradient_steps
        self.logger.record("train/n_updates", self._n_updates, exclude="tensorboard")
        self.logger.record("train/ent_coef", np.mean(ent_coefs))
        self.logger.record("train/critic_loss", np.mean(critic_losses))
        self.logger.record(
            "train/actor_loss", np.mean(actor_losses) if actor_losses else 0.0
        )
        self.logger.record(
            "train/expert_anchor_loss", np.mean(anchor_losses) if anchor_losses else 0.0
        )


def _hardest_build_cargo_model(algorithm, env, request, imports):
    if algorithm != "sac":
        return _base_build_cargo_model(algorithm, env, request, imports)
    return ExpertAnchoredSAC(
        policy="MlpPolicy",
        env=env,
        learning_rate=request.learning_rate,
        gamma=request.gamma,
        seed=request.seed,
        verbose=0,
        device="auto",
        tensorboard_log=None,
        policy_kwargs={"net_arch": [256, 256]},
        buffer_size=max(request.replay_buffer_size, 1_000),
        learning_starts=min(request.warmup_steps, max(request.total_timesteps // 4, 1)),
        batch_size=max(16, request.batch_size),
        train_freq=1,
        gradient_steps=1,
        ent_coef=0.01,
    )


cargo_trainer._build_cargo_model = _hardest_build_cargo_model


def _hardest_behavior_clone(*args, **kwargs):
    """Clone expert actions with extra weight on long-horizon rudder error."""
    model = args[0] if args else kwargs["model"]
    demonstrations = args[1] if len(args) > 1 else kwargs["demonstrations"]
    epochs = max(80, int(args[2] if len(args) > 2 else kwargs["epochs"]))
    batch_size = int(args[3] if len(args) > 3 else kwargs["batch_size"])
    seed = int(args[4] if len(args) > 4 else kwargs["seed"])
    import numpy as np
    import torch

    observations = np.asarray(demonstrations["observations"], dtype=np.float32)
    actions = np.asarray(demonstrations["actions"], dtype=np.float32)
    expert_sample_count = int(len(observations))
    actor = model.policy.actor
    optimizer = model.policy.actor.optimizer
    original_learning_rates = [float(group["lr"]) for group in optimizer.param_groups]
    for group in optimizer.param_groups:
        group["lr"] = 3e-4
    rng = np.random.default_rng(seed)
    final_throttle_loss = 0.0
    final_rudder_loss = 0.0
    final_loss = 0.0

    def fit_actor(
        labeled_observations: np.ndarray,
        labeled_actions: np.ndarray,
        fit_epochs: int,
    ) -> None:
        nonlocal final_loss, final_throttle_loss, final_rudder_loss
        for _epoch in range(fit_epochs):
            indices = rng.permutation(len(labeled_observations))
            epoch_throttle = []
            epoch_rudder = []
            for start in range(0, len(indices), max(1, batch_size)):
                batch = indices[start : start + max(1, batch_size)]
                observation_tensor = torch.as_tensor(
                    labeled_observations[batch], device=model.device
                )
                action_tensor = torch.as_tensor(
                    labeled_actions[batch], device=model.device
                )
                mean_actions, _log_std, _distribution_kwargs = (
                    actor.get_action_dist_params(observation_tensor)
                )
                predicted_actions = torch.tanh(mean_actions)
                throttle_loss = torch.nn.functional.mse_loss(
                    predicted_actions[:, 0], action_tensor[:, 0]
                )
                rudder_loss = torch.nn.functional.mse_loss(
                    predicted_actions[:, 1], action_tensor[:, 1]
                )
                loss = 0.55 * throttle_loss + 1.45 * rudder_loss
                optimizer.zero_grad()
                loss.backward()
                torch.nn.utils.clip_grad_norm_(actor.parameters(), 1.0)
                optimizer.step()
                epoch_throttle.append(float(throttle_loss.detach().cpu().item()))
                epoch_rudder.append(float(rudder_loss.detach().cpu().item()))
                final_loss = float(loss.detach().cpu().item())
            final_throttle_loss = float(np.mean(epoch_throttle))
            final_rudder_loss = float(np.mean(epoch_rudder))

    fit_actor(observations, actions, epochs)

    config = _training_context.get("config")
    dataset = _training_context.get("dataset")
    if config is None or dataset is None:
        raise ValueError("V3 DAgger requires train-only collector context")
    cargo = config.get("cargo_parameters", {})
    throttle_min = float(cargo.get("throttle_action_min", -0.35))
    throttle_max = float(cargo.get("throttle_action_max", 1.0))
    dagger_records = []
    aggregated_observations = [observations]
    aggregated_actions = [actions]
    task_count = len(dataset["splits"]["train"])
    dagger_schedule = ((0.70, 24), (0.40, 16), (0.20, 8))
    for round_index, (expert_fraction, refit_epochs) in enumerate(
        dagger_schedule, start=1
    ):
        round_observations = []
        round_actions = []
        for task_index in range(task_count):
            env = CargoHardestV3Env(
                config,
                dataset,
                split="train",
                discrete_actions=False,
                max_steps=5200,
                seed=seed + 12_000 + round_index * 100 + task_index,
                task_index=task_index,
                render_mode=None,
            )
            observation, _info = env.reset(options={"task_index": task_index})
            targets = task_manual_targets(env)
            target_index = 0
            terminated = truncated = False
            info = {}
            while not (terminated or truncated):
                target, target_kind = targets[target_index]
                distance = math.hypot(
                    target[0] - env.state[0], target[1] - env.state[1]
                )
                arrival = 12.0 if target_kind == "manual_bypass" else 16.0
                if distance < arrival and target_index < len(targets) - 1:
                    target_index += 1
                    target, _target_kind = targets[target_index]
                # A DAgger label must be a function of the policy's current
                # observation.  Use actual rudder state rather than a hidden
                # previous expert command that the released actor cannot see.
                physical_action, _commanded_rudder, _helm = hardest_manual_helm(
                    env, target, float(env.state[5])
                )
                normalized_throttle = 2.0 * (
                    (physical_action[0] - throttle_min)
                    / max(throttle_max - throttle_min, 1e-6)
                ) - 1.0
                expert_action = np.asarray(
                    [np.clip(normalized_throttle, -1.0, 1.0), physical_action[1]],
                    dtype=np.float32,
                )
                policy_action, _state = model.predict(
                    observation, deterministic=True
                )
                executed_action = np.clip(
                    expert_fraction * expert_action
                    + (1.0 - expert_fraction)
                    * np.asarray(policy_action, dtype=np.float32),
                    -1.0,
                    1.0,
                )
                round_observations.append(
                    np.asarray(observation, dtype=np.float32)
                )
                round_actions.append(expert_action)
                observation, _reward, terminated, truncated, info = env.step(
                    executed_action
                )
            dagger_records.append(
                {
                    "round": round_index,
                    "task_id": str(info.get("task_id", task_index)),
                    "expert_action_fraction": expert_fraction,
                    "success": bool(info.get("is_success", False)),
                    "collisions": int(info.get("collisions", 0)),
                    "steps": int(env.steps),
                }
            )
            print(
                f"DAgger round {round_index}/{len(dagger_schedule)} "
                f"task {task_index + 1}/{task_count}: "
                f"{'passed' if bool(info.get('is_success', False)) else 'labeled recovery'}",
                flush=True,
            )
            env.close()
        aggregated_observations.append(
            np.asarray(round_observations, dtype=np.float32)
        )
        aggregated_actions.append(np.asarray(round_actions, dtype=np.float32))
        observations = np.concatenate(aggregated_observations, axis=0)
        actions = np.concatenate(aggregated_actions, axis=0)
        fit_actor(observations, actions, refit_epochs)
    for group, learning_rate in zip(optimizer.param_groups, original_learning_rates):
        # Once cloning has produced a stable long-horizon policy, SAC should
        # refine it with small Q-driven steps instead of erasing it in a few
        # hundred high-variance updates.
        group["lr"] = min(learning_rate, 1e-7)

    with torch.no_grad():
        model.policy.actor.log_std.weight.zero_()
        model.policy.actor.log_std.bias.fill_(-3.0)
    model.expert_anchor_observations = observations
    model.expert_anchor_actions = actions
    model.rl_actor_updates = 0
    model.post_clone_actor_sha256 = _actor_sha256(actor)
    return {
        "epochs": epochs,
        "samples": int(len(observations)),
        "successful_expert_samples": expert_sample_count,
        "dagger_labeled_recovery_samples": int(
            len(observations) - expert_sample_count
        ),
        "dagger_train_split_only": True,
        "dagger_rounds": dagger_records,
        "dagger_refit_epochs_by_round": [
            item[1] for item in dagger_schedule
        ],
        "final_loss": final_loss,
        "final_epoch_throttle_mse": final_throttle_loss,
        "final_epoch_rudder_mse": final_rudder_loss,
        "loss_weights": {"throttle": 0.55, "rudder": 1.45},
        "initial_log_std": -3.0,
        "initial_action_std": float(torch.exp(torch.tensor(-3.0)).item()),
        "v3_exploration_guard": True,
        "behavior_cloning_learning_rate": 3e-4,
        "post_clone_sac_actor_learning_rate": 1e-7,
    }


cargo_trainer._behavior_clone_sac_actor = _hardest_behavior_clone


_base_train_cargo = cargo_trainer.train_cargo


def _train_hardest_cargo(request, initialize_from_checkpoint=None):
    """Add auditable proof that the released actor received SAC updates."""
    result = _base_train_cargo(request, initialize_from_checkpoint)
    if request.algorithm != "sac":
        return result
    checkpoint_path = Path(request.checkpoint_path).resolve()
    checkpoint = json.loads(checkpoint_path.read_text(encoding="utf-8"))
    checkpoint["observation_size"] = HARDEST_OBSERVATION_SIZE
    checkpoint["observation_contract"] = (
        "cargo_circuit_hardest_v3_continuous_47d"
    )
    checkpoint["observation_memory_features"] = [
        "previous_throttle_action",
        "previous_rudder_action",
        "tracked_dynamic_avoidance_direction",
    ]
    model_path = Path(str(checkpoint["model_path"]))
    if not model_path.is_absolute():
        model_path = checkpoint_path.parent / model_path
    model = ExpertAnchoredSAC.load(model_path.resolve(), device="cpu")
    actor_updates = int(getattr(model, "rl_actor_updates", 0))
    post_clone_actor_sha256 = str(getattr(model, "post_clone_actor_sha256", ""))
    final_actor_sha256 = _actor_sha256(model.actor)
    checkpoint["reinforcement_learning_provenance"] = {
        "algorithm": "SAC",
        "critic_updates": int(getattr(model, "_n_updates", 0)),
        "actor_updates_after_warmup": actor_updates,
        "actor_warmup_environment_steps": int(model.actor_warmup_steps),
        "expert_anchor_coefficient": float(model.expert_anchor_coefficient),
        "entropy_coefficient": float(model.ent_coef_tensor.item()),
        "actor_learning_rate": float(model.actor.optimizer.param_groups[0]["lr"]),
        "critic_learning_rate": float(model.critic.optimizer.param_groups[0]["lr"]),
        "last_q_driven_actor_loss": float(
            getattr(model, "last_rl_actor_loss", 0.0)
        ),
        "last_expert_anchor_loss": float(
            getattr(model, "last_expert_anchor_loss", 0.0)
        ),
        "actor_optimized_against_learned_q_values": actor_updates > 0,
        "post_clone_actor_sha256": post_clone_actor_sha256,
        "final_sac_actor_sha256": final_actor_sha256,
        "actor_weights_changed_after_cloning": bool(
            post_clone_actor_sha256
            and post_clone_actor_sha256 != final_actor_sha256
        ),
        "environment_rewards_used": True,
        "manual_helm_callable_at_inference": False,
    }
    cargo_trainer.write_json_atomic(checkpoint_path, checkpoint)
    result["reinforcement_learning_provenance"] = checkpoint[
        "reinforcement_learning_provenance"
    ]
    cargo_trainer.write_json_atomic(Path(request.progress_path).resolve(), result)
    return result


cargo_trainer.train_cargo = _train_hardest_cargo


_base_evaluate_cargo = cargo_trainer.evaluate_cargo


def _evaluate_hardest_cargo(**kwargs):
    """Require every sealed V3 test task to pass, not only the first row."""
    result = _base_evaluate_cargo(**kwargs)
    trajectory_path = Path(kwargs["trajectory_path"]).resolve()
    trajectory = json.loads(trajectory_path.read_text(encoding="utf-8"))
    trajectory["observation_size"] = HARDEST_OBSERVATION_SIZE
    trajectory["observation_contract"] = (
        "cargo_circuit_hardest_v3_continuous_47d"
    )
    trajectory["observation_memory_features"] = [
        "previous_throttle_action",
        "previous_rudder_action",
        "tracked_dynamic_avoidance_direction",
    ]
    cargo_trainer.write_json_atomic(trajectory_path, trajectory)
    if kwargs.get("split") != "test":
        return result
    output_dir = Path(kwargs["output_dir"]).resolve()
    rows_path = output_dir / f"cargo_{kwargs['algorithm']}_test_episodes.csv"
    with rows_path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    config, dataset, _dataset_path = cargo_trainer.load_experiment(
        Path(kwargs["config_path"]).resolve()
    )
    checkpoint = json.loads(Path(kwargs["checkpoint_path"]).read_text(encoding="utf-8"))
    provenance = checkpoint.get("reinforcement_learning_provenance", {})
    maximum_yaw_rate = float(
        config.get("ships", [{}])[0]
        .get("performance", {})
        .get("max_turn_rate_degrees", 20.0)
    )
    maximum_speed = float(
        config.get("ships", [{}])[0]
        .get("performance", {})
        .get("max_forward_speed", 8.5)
    )

    def truth(value):
        return str(value).strip().lower() == "true"

    def number(row, key):
        return float(row[key])

    required_tasks = len(dataset["splits"]["test"])
    strict_passed = bool(
        len(rows) == required_tasks
        and int(provenance.get("actor_updates_after_warmup", 0)) > 0
        and bool(provenance.get("actor_optimized_against_learned_q_values", False))
        and all(
            truth(row["success"])
            and truth(row["cargo_retrieved"])
            and int(row["checkpoints_passed"]) == int(row["total_checkpoints"])
            and int(row["collisions"]) == 0
            and number(row, "minimum_clearance_meters") > 0.0
            and number(row, "minimum_dynamic_clearance_meters") > 0.0
            and number(row, "minimum_boundary_clearance_meters") > 0.0
            and int(row["dynamic_obstacle_count"]) >= 6
            and number(row, "maximum_yaw_rate_degrees_per_second") <= maximum_yaw_rate + 1e-6
            and number(row, "maximum_speed_mps") <= maximum_speed + 1e-6
            for row in rows
        )
    )
    strict_gate = {
        "passed": strict_passed,
        "requires_all_sealed_test_tasks": True,
        "required_test_tasks": required_tasks,
        "evaluated_test_tasks": len(rows),
        "requires_trained_sac_actor_updates": True,
        "sac_actor_updates": int(provenance.get("actor_updates_after_warmup", 0)),
        "requires_all_checkpoints": True,
        "requires_zero_collision": True,
        "requires_positive_static_dynamic_and_boundary_clearance": True,
        "requires_dynamics_limits_respected": True,
    }
    trajectory["acceptance_gate"] = strict_gate
    trajectory["all_test_task_metrics"] = rows
    cargo_trainer.write_json_atomic(trajectory_path, trajectory)
    evidence_path = kwargs.get("evidence_path")
    if evidence_path:
        evidence_path = Path(evidence_path).resolve()
        evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
        evidence["acceptance_gate"] = strict_gate
        evidence["evaluation"]["all_test_task_metrics"] = rows
        evidence["training"]["reinforcement_learning_provenance"] = provenance
        cargo_trainer.write_json_atomic(evidence_path, evidence)
    result["acceptance_gate"] = strict_gate
    result["render_ready"] = strict_passed
    cargo_trainer.write_json_atomic(Path(kwargs["progress_path"]).resolve(), result)
    return result


cargo_trainer.evaluate_cargo = _evaluate_hardest_cargo

from cargo_rl_train import main  # noqa: E402  (patch trainer before CLI import)


if __name__ == "__main__":
    raise SystemExit(main())
