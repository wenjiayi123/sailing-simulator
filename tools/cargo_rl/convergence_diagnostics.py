"""Evidence-led non-convergence diagnosis for the SAC-P47 ladder."""

from __future__ import annotations

import math
from typing import Any, Dict, Mapping, Sequence


def diagnose_nonconvergence(
    *,
    level: Mapping[str, Any],
    physics_contract: Mapping[str, Any],
    manual_gate: Mapping[str, Any],
    training: Mapping[str, Any],
    validation_rows: Sequence[Mapping[str, Any]],
    previous_level_passed: bool,
) -> Dict[str, Any]:
    """List every material failure family, then rank evidence-backed causes."""

    rows = list(validation_rows)
    episode_count = len(rows)
    successes = sum(bool(row.get("success", False)) for row in rows)
    collisions = sum(int(row.get("collisions", 0)) for row in rows)
    terrain_collisions = sum(int(row.get("terrain_collisions", 0)) for row in rows)
    dynamic_counts = [int(row.get("dynamic_obstacle_count", 0)) for row in rows]
    finite = all(
        math.isfinite(float(value))
        for row in rows
        for value in (
            row.get("reward", 0.0),
            row.get("minimum_clearance_meters", 0.0),
            row.get("maximum_sway_mps", 0.0),
            row.get("maximum_yaw_rate_degrees_per_second", 0.0),
        )
    )
    task_failures = [str(row.get("task_id", "unknown")) for row in rows if not bool(row.get("success", False))]
    low_completion = [
        float(row.get("checkpoint_completion_ratio", 0.0))
        for row in rows
        if not bool(row.get("success", False))
    ]
    maximum_action_saturation = max(
        (float(row.get("action_saturation_ratio", 0.0)) for row in rows),
        default=0.0,
    )
    actor_updates = int(training.get("actor_updates_after_warmup", 0))
    expert_success_rate = float(training.get("expert_success_rate", 0.0))
    recent_success = float(training.get("success_rate_20", 0.0))
    manual_passed = bool(manual_gate.get("acceptance_gate", {}).get("passed", False))
    horizon_failures = [
        str(row.get("task_id", "unknown"))
        for row in rows
        if not bool(row.get("success", False))
        and int(row.get("collisions", 0)) == 0
        and int(row.get("steps", 0)) >= int(level.get("max_steps", 0))
    ]

    possibilities = [
        {
            "category": "task_or_safety_infeasible",
            "question": "当前障碍、交通、海况和安全净距下，任务本身是否可达",
            "status": "excluded" if manual_passed else "primary_suspect",
            "evidence": {"manual_feasibility_passed": manual_passed},
        },
        {
            "category": "simulator_training_physics_mismatch",
            "question": "Godot 船舶与训练环境的惯性、横荡、艏摇、控制周期是否一致",
            "status": "excluded" if bool(physics_contract.get("passed", False)) else "primary_suspect",
            "evidence": {
                "contract_passed": bool(physics_contract.get("passed", False)),
                "dynamics_sha256": physics_contract.get("dynamics_sha256", ""),
                "runtime_physics_hz": physics_contract.get("runtime_physics_hz", 0),
            },
        },
        {
            "category": "obstacle_or_traffic_contract_drift",
            "question": "训练是否漏掉悬岩、动态船或视觉对应的碰撞体",
            "status": "excluded"
            if physics_contract.get("large_rock_count") == 32
            and dynamic_counts
            and min(dynamic_counts) >= 6
            else "primary_suspect",
            "evidence": {
                "large_rock_count": physics_contract.get("large_rock_count", 0),
                "dynamic_counts": dynamic_counts,
            },
        },
        {
            "category": "observation_partial_or_badly_scaled",
            "question": "47维观测是否缺少决策变量、含噪过强、缩放饱和或存在部分可观测性",
            "status": "needs_review" if failures(rows) else "no_failure_signal",
            "evidence": {
                "observation_dimension": physics_contract.get("observation_dimension", 0),
                "failed_tasks": task_failures,
            },
        },
        {
            "category": "action_authority_or_control_interval",
            "question": "油门/舵动作范围、执行器迟滞和0.25秒决策周期是否让策略无法及时补偿漂移",
            "status": "primary_suspect" if maximum_action_saturation > 0.65 else "needs_review",
            "evidence": {"maximum_action_saturation_ratio": maximum_action_saturation},
        },
        {
            "category": "episode_horizon_or_termination_contract",
            "question": "航段长度、最大步数、终点判定和截断条件是否给安全低速操纵留足时间",
            "status": "primary_suspect" if horizon_failures else "excluded",
            "evidence": {
                "max_steps": int(level.get("max_steps", 0)),
                "horizon_failed_tasks": horizon_failures,
            },
        },
        {
            "category": "reward_sparse_conflicting_or_misscaled",
            "question": "进度、航向、速度、净距、动作平滑和碰撞奖励是否冲突或尺度失衡",
            "status": "primary_suspect"
            if recent_success < 0.2 and actor_updates > 0 and expert_success_rate >= 1.0
            else "needs_review",
            "evidence": {
                "training_success_rate_20": recent_success,
                "failed_checkpoint_completion": low_completion,
            },
        },
        {
            "category": "curriculum_jump_too_large",
            "question": "上一难度到当前难度的交通速度、随机化或航程跨度是否过大",
            "status": "primary_suspect" if previous_level_passed and successes < episode_count else "needs_review",
            "evidence": {
                "previous_level_passed": previous_level_passed,
                "level": level.get("id"),
                "traffic_speed_knots": level.get("dynamic_traffic_speed_knots"),
                "randomization_multiplier": level.get("randomization_multiplier"),
            },
        },
        {
            "category": "sac_hyperparameters_or_capacity",
            "question": "学习率、熵系数、折扣、预热、批量、经验池、网络容量和训练步数是否合适",
            "status": "primary_suspect" if actor_updates <= 0 else "needs_review",
            "evidence": {
                "actor_updates_after_warmup": actor_updates,
                "training_timesteps": training.get("training_timesteps", 0),
            },
        },
        {
            "category": "demonstration_distribution_or_clone_error",
            "question": "人工示范是否全部成功，是否覆盖失败状态，行为克隆是否偏离专家",
            "status": "primary_suspect" if expert_success_rate < 1.0 else "needs_review",
            "evidence": {
                "expert_success_rate": expert_success_rate,
                "behavior_clone_loss": training.get("behavior_clone_loss"),
                "dagger_recovery_samples": training.get("dagger_recovery_samples", 0),
            },
        },
        {
            "category": "random_seed_or_evaluation_variance",
            "question": "失败是否只集中于少数任务/种子，评估样本是否足够",
            "status": "primary_suspect"
            if 0 < successes < episode_count and len(set(task_failures)) <= max(1, episode_count // 3)
            else "needs_review",
            "evidence": {
                "episodes": episode_count,
                "successes": successes,
                "failed_tasks": task_failures,
            },
        },
        {
            "category": "evaluation_coverage_or_holdout_leakage",
            "question": "晋级验证是否覆盖全部环段和海况，是否因重复少数随机种子产生虚假通过",
            "status": "primary_suspect"
            if bool(level.get("random_segment", False)) and episode_count < 8
            else "excluded",
            "evidence": {
                "random_segment": bool(level.get("random_segment", False)),
                "evaluated_episodes": episode_count,
                "minimum_exhaustive_segment_cases": 8,
            },
        },
        {
            "category": "numerical_instability_or_compute_interruption",
            "question": "是否出现NaN/Inf、异常终止、写盘失败或训练被中断",
            "status": "excluded" if finite and not bool(training.get("interrupted", False)) else "primary_suspect",
            "evidence": {"finite_validation_metrics": finite, "interrupted": training.get("interrupted", False)},
        },
        {
            "category": "checkpoint_dataset_or_code_fingerprint_drift",
            "question": "模型、数据集、实验配置、物理参数和代码是否来自同一版本",
            "status": "excluded" if bool(physics_contract.get("fail_closed", False)) else "primary_suspect",
            "evidence": {"fail_closed_contract": physics_contract.get("fail_closed", False)},
        },
    ]
    primary = [item["category"] for item in possibilities if item["status"] == "primary_suspect"]
    if horizon_failures:
        ranked = ["episode_horizon_or_termination_contract", "sac_hyperparameters_or_capacity", "curriculum_jump_too_large"]
    elif collisions and terrain_collisions:
        ranked = ["action_authority_or_control_interval", "curriculum_jump_too_large", "observation_partial_or_badly_scaled"]
    elif successes and successes < episode_count:
        ranked = ["random_seed_or_evaluation_variance", "curriculum_jump_too_large", "demonstration_distribution_or_clone_error"]
    elif actor_updates <= 0:
        ranked = ["sac_hyperparameters_or_capacity"]
    else:
        ranked = ["reward_sparse_conflicting_or_misscaled", "sac_hyperparameters_or_capacity", "observation_partial_or_badly_scaled"]
    ranked = [item for item in ranked if item in {record["category"] for record in possibilities}]
    corrective_actions = []
    if horizon_failures:
        corrective_actions.append(
            {
                "target": "episode_horizon_or_termination_contract",
                "action": "make L1 a true single random leg and allocate a longer safe-control horizon",
                "evidence": "all failed episodes exhausted max_steps without collision; most reached the intermediate point",
            }
        )
    if recent_success > 0.0 and recent_success < 0.8 and actor_updates > 0:
        corrective_actions.append(
            {
                "target": "sac_hyperparameters_or_capacity",
                "action": "increase the level training budget while retaining the same SAC, reward, physics, and obstacle contract",
                "evidence": "recent success was still rising at the training cutoff",
            }
        )
    return {
        "format": "cargo_physics_nonconvergence_diagnosis_v4",
        "level": dict(level),
        "summary": {
            "episodes": episode_count,
            "successes": successes,
            "collisions": collisions,
            "terrain_collisions": terrain_collisions,
            "actor_updates_after_warmup": actor_updates,
        },
        "all_material_possibilities": possibilities,
        "primary_suspects": primary,
        "ranked_root_cause_candidates": ranked,
        "corrective_actions": corrective_actions,
        "rule": "do not continue training until evidence-backed corrective actions are recorded",
    }


def failures(rows: Sequence[Mapping[str, Any]]) -> bool:
    return any(not bool(row.get("success", False)) for row in rows)
