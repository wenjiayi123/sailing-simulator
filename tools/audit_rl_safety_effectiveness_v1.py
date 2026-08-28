#!/usr/bin/env python3
"""Audit whether Safety V5 improves a frozen, trained SAC policy.

The safety-effect gate is intentionally distinct from full policy admission:
it asks whether the additive layer reduces unsafe outcomes without materially
damaging the SAC task utility or removing SAC action authority.  The stricter
absolute policy-admission decision remains preserved as a separate result.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import sys
import time
from typing import Any, Mapping, Sequence

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools import run_safety_supervisor_benchmark as benchmark  # noqa: E402
from tools.assess_sac_champion_v5 import assess as assess_policy  # noqa: E402
from tools.ship_rl.environment import dataset_fingerprint  # noqa: E402
from tools.ship_rl.port_ops_environment import PortOpsNavigationEnv  # noqa: E402
from tools.ship_rl.port_ops_trainer import _aggregate, _load_policy  # noqa: E402
from tools.ship_rl.safety_supervisor import (  # noqa: E402
    ModelPredictiveSafetySupervisor,
    SafetySupervisorConfig,
)
from tools.ship_rl.sac_champion_safety_v5 import (  # noqa: E402
    SacChampionSafetyConfig,
    SacChampionSafetySupervisor,
)


PROFILE = ROOT / "data/verification/rl_safety_effectiveness_v1.json"
POLICY_ADMISSION_PROFILE = ROOT / "data/rl/sac_champion_admission_v5.json"
PREPARED = ROOT / "reports/rl_safety_effectiveness_v1_prepared.json"
FINAL = ROOT / "reports/rl_safety_effectiveness_v1.json"
MARKDOWN = ROOT / "reports/rl_safety_effectiveness_v1.md"
ARTIFACT = ROOT / "reports/artifacts/rl_safety_effectiveness_v1/paired_episodes.json"
PROGRESS = ROOT / "reports/artifacts/rl_safety_effectiveness_v1/progress.json"
SMOKE = ROOT / "reports/rl_safety_effectiveness_smoke_v1.json"


def _load(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _write_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def _write_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(value, encoding="utf-8")
    temporary.replace(path)


def _relative(path: Path) -> str:
    return os.fspath(path.resolve().relative_to(ROOT))


def _model_path(checkpoint_path: Path, checkpoint: Mapping[str, Any]) -> Path:
    path = Path(str(checkpoint.get("model_path", "")))
    if not path.is_absolute():
        path = checkpoint_path.parent / path
    return path.resolve()


def _source_paths(profile: Mapping[str, Any]) -> list[Path]:
    return [
        PROFILE,
        POLICY_ADMISSION_PROFILE,
        ROOT / str(profile["checkpoint"]),
        ROOT / str(profile["validation_base_result"]),
        ROOT / str(profile["validation_supervised_result"]),
        ROOT / str(profile["validation_policy_admission"]),
        ROOT / str(profile["safety_profile"]),
        ROOT / str(profile["safety_source"]),
        ROOT / str(profile["experiment"]),
        ROOT / str(profile["training_dataset"]),
        ROOT / str(profile["counterfactual_holdout"]),
        ROOT / str(profile["counterfactual_holdout_freeze"]),
        ROOT / "tools/ship_rl/safety_supervisor.py",
        ROOT / "tools/ship_rl/safety_supervisor_v4.py",
        ROOT / "tools/ship_rl/port_ops_environment.py",
        ROOT / "tools/audit_rl_safety_effectiveness_v1.py",
    ]


def _source_hashes(profile: Mapping[str, Any]) -> dict[str, str]:
    return {_relative(path): _sha256(path) for path in _source_paths(profile)}


def _precondition_errors(profile: Mapping[str, Any]) -> list[str]:
    errors: list[str] = []
    if profile.get("algorithm") != "sac":
        errors.append("the primary candidate must remain SAC")
    checkpoint_path = ROOT / str(profile["checkpoint"])
    checkpoint = _load(checkpoint_path)
    if checkpoint.get("algorithm") != "sac" or not checkpoint.get("trained"):
        errors.append("checkpoint is not a trained SAC artifact")
    model_path = _model_path(checkpoint_path, checkpoint)
    if not model_path.is_file():
        errors.append("trained SAC model is missing")
    validation = _load(ROOT / str(profile["validation_supervised_result"]))
    if validation.get("contains_real_rl") is not True:
        errors.append("validation result does not prove real RL execution")
    if validation.get("dataset_split") != "validation":
        errors.append("candidate selection result is not validation-only")
    holdout_path = ROOT / str(profile["counterfactual_holdout"])
    holdout_freeze = _load(ROOT / str(profile["counterfactual_holdout_freeze"]))
    if holdout_freeze.get("test_accessed") is not False:
        errors.append("counterfactual holdout was not frozen before access")
    if holdout_freeze.get("holdout_dataset_sha256") != _sha256(holdout_path):
        errors.append("counterfactual holdout changed after freeze")
    holdout = _load(holdout_path)
    if any(holdout.get("splits", {}).get(name) for name in ("train", "validation")):
        errors.append("counterfactual holdout must remain test-only")
    if len(holdout.get("splits", {}).get("test", [])) != int(
        holdout_freeze.get("episodes", -1)
    ):
        errors.append("counterfactual holdout episode inventory changed")
    if profile.get("production_authority") is not False:
        errors.append("production authority must remain false")
    return errors


def prepare() -> int:
    profile = _load(PROFILE)
    errors = _precondition_errors(profile)
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    checkpoint_path = ROOT / str(profile["checkpoint"])
    checkpoint = _load(checkpoint_path)
    model_path = _model_path(checkpoint_path, checkpoint)
    holdout_path = ROOT / str(profile["counterfactual_holdout"])
    holdout = _load(holdout_path)
    payload = {
        "schema_version": "rl_safety_effectiveness_prepared_v1",
        "assurance_id": str(profile["profile_id"]),
        "prepared_at": datetime.now(timezone.utc).replace(
            microsecond=0
        ).isoformat(),
        "holdout_accessed": False,
        "effect_thresholds_locked_before_holdout": True,
        "strategy_and_safety_layer_locked_before_holdout": True,
        "algorithm": "sac",
        "strategy_id": str(profile["strategy_id"]),
        "checkpoint": _relative(checkpoint_path),
        "checkpoint_sha256": _sha256(checkpoint_path),
        "model": _relative(model_path),
        "model_sha256": _sha256(model_path),
        "actual_training_timesteps": int(checkpoint["actual_timesteps"]),
        "contains_real_rl": True,
        "holdout": {
            "path": _relative(holdout_path),
            "file_sha256": _sha256(holdout_path),
            "dataset_sha256": dataset_fingerprint(holdout),
            "episodes": len(holdout["splits"]["test"]),
        },
        "effect_thresholds": dict(profile["effect_thresholds"]),
        "source_sha256": _source_hashes(profile),
        "production_authority": False,
        "claim_boundary": str(profile["claim_boundary"]),
    }
    _write_json(PREPARED, payload)
    print(f"prepared RL safety-effectiveness audit: {PREPARED}")
    print("algorithm=sac, contains_real_rl=true, holdout_accessed=false")
    return 0


def smoke() -> int:
    """Exercise the real SAC-to-safety-to-environment path on validation only.

    The smoke deliberately stops after a small number of steps.  It proves
    model loading, inference, safety projection, action application, receipts,
    and boundary flags; it does not make a convergence or effectiveness claim
    and never opens the counterfactual holdout.
    """

    profile = _load(PROFILE)
    errors = _precondition_errors(profile)
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    checkpoint_path = ROOT / str(profile["checkpoint"])
    checkpoint = _load(checkpoint_path)
    checkpoint["_checkpoint_path"] = os.fspath(checkpoint_path)
    model = _load_policy(checkpoint)
    experiment = _load(ROOT / str(profile["experiment"]))
    dataset = _load(ROOT / str(profile["training_dataset"]))
    safety_profile = SacChampionSafetyConfig.from_mapping(
        _load(ROOT / str(profile["safety_profile"]))
    )
    smoke_profile = profile["functional_smoke"]
    task_indices = [int(value) for value in smoke_profile["task_indices"]]
    maximum_steps = int(smoke_profile["maximum_steps_per_episode"])
    receipts: list[dict[str, Any]] = []
    total_calls = 0
    total_interventions = 0
    total_fail_closed = 0
    all_actions_bounded = True
    for task_index in task_indices:
        env = PortOpsNavigationEnv(
            experiment,
            dataset,
            split="validation",
            discrete_actions=False,
            max_steps=maximum_steps,
            seed=int(profile["seed"]) + task_index,
            task_index=task_index,
            render_mode=None,
        )
        observation, _info = env.reset(options={"task_index": task_index})
        supervisor = SacChampionSafetySupervisor(safety_profile)
        info: dict[str, Any] = {}
        while True:
            raw_action, _state = model.predict(observation, deterministic=True)
            decision = supervisor.project(env, raw_action)
            all_actions_bounded = bool(
                all_actions_bounded
                and all(-1.0 <= float(value) <= 1.0 for value in decision.applied_action)
            )
            observation, _reward, terminated, truncated, info = env.step(
                supervisor.environment_action(env, decision)
            )
            if terminated or truncated:
                break
        summary = supervisor.summary()
        total_calls += int(summary.get("project_calls", 0))
        total_interventions += int(summary.get("intervention_steps", 0))
        total_fail_closed += int(summary.get("fail_closed_events", 0))
        receipts.append(
            {
                "task_index": task_index,
                "task_id": str(env.task.get("id", "unknown")),
                "steps": int(env.steps),
                "model_inference_calls": int(summary.get("project_calls", 0)),
                "safety_intervention_steps": int(
                    summary.get("intervention_steps", 0)
                ),
                "fail_closed_events": int(summary.get("fail_closed_events", 0)),
                "terminated": bool(info.get("goal_reached", False)),
                "truncated": bool(env.steps >= maximum_steps),
                "collisions": int(info.get("collisions", 0)),
                "groundings": int(info.get("groundings", 0)),
            }
        )
    checks = {
        "real_trained_sac_loaded": bool(checkpoint.get("trained")),
        "model_inference_executed": total_calls > 0,
        "safety_projection_executed": total_calls
        == sum(int(item["steps"]) for item in receipts),
        "applied_actions_bounded": all_actions_bounded,
        "intervention_path_exercised": total_interventions > 0,
        "multiple_validation_scenarios_exercised": len(receipts) >= 3,
        "counterfactual_holdout_untouched": True,
        "production_authority_remains_false": profile["production_authority"]
        is False,
        "performance_claim_suppressed": smoke_profile["performance_claimed"]
        is False,
    }
    payload = {
        "schema_version": "rl_safety_effectiveness_functional_smoke_v1",
        "generated_at": datetime.now(timezone.utc).replace(
            microsecond=0
        ).isoformat(),
        "algorithm": "sac",
        "strategy_id": str(profile["strategy_id"]),
        "contains_real_rl": True,
        "dataset_split": "validation",
        "task_indices": task_indices,
        "maximum_steps_per_episode": maximum_steps,
        "model_inference_calls": total_calls,
        "safety_intervention_steps": total_interventions,
        "fail_closed_events": total_fail_closed,
        "receipts": receipts,
        "checks": checks,
        "passed": all(checks.values()),
        "performance_claimed": False,
        "counterfactual_holdout_accessed": False,
        "training_performed": False,
        "base_policy_modified": False,
        "production_authority": False,
        "boundary": (
            "Functional smoke only: proves real SAC inference and safety-layer "
            "wiring, not convergence, safety effectiveness, policy admission, "
            "certification, or live-vessel authority."
        ),
    }
    _write_json(SMOKE, payload)
    print(f"RL safety functional smoke: {SMOKE}")
    print(
        f"calls={total_calls}, interventions={total_interventions}, "
        f"result={'PASS' if payload['passed'] else 'FAIL'}"
    )
    return 0 if payload["passed"] else 2


def verify_smoke() -> int:
    profile = _load(PROFILE)
    prepared = _load(PREPARED)
    errors = _verify_prepared(prepared, profile)
    report = _load(SMOKE)
    checks = report.get("checks", {})
    if not isinstance(checks, Mapping) or not checks:
        errors.append("functional smoke checks are missing")
    elif bool(report.get("passed")) != all(bool(value) for value in checks.values()):
        errors.append("functional smoke decision no longer matches its checks")
    if report.get("algorithm") != "sac" or report.get("contains_real_rl") is not True:
        errors.append("functional smoke is no longer anchored to real SAC")
    if report.get("model_inference_calls", 0) <= 0:
        errors.append("functional smoke contains no model inference")
    if report.get("safety_intervention_steps", 0) <= 0:
        errors.append("functional smoke did not exercise an intervention path")
    if report.get("counterfactual_holdout_accessed") is not False:
        errors.append("functional smoke accessed the sealed holdout")
    if report.get("training_performed") is not False:
        errors.append("functional smoke unexpectedly performed training")
    if report.get("performance_claimed") is not False:
        errors.append("functional smoke overclaims performance")
    if report.get("base_policy_modified") is not False:
        errors.append("functional smoke changed the base policy boundary")
    if report.get("production_authority") is not False:
        errors.append("functional smoke changed production authority")
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    print(
        "RL safety functional smoke verify: PASS "
        f"(calls={report['model_inference_calls']}, "
        f"interventions={report['safety_intervention_steps']}, "
        "training=false, holdout=false, production_authority=false)"
    )
    return 0


def _verify_prepared(
    prepared: Mapping[str, Any], profile: Mapping[str, Any]
) -> list[str]:
    errors = _precondition_errors(profile)
    if prepared.get("holdout_accessed") is not False:
        errors.append("prepared evidence must remain before holdout access")
    if prepared.get("effect_thresholds_locked_before_holdout") is not True:
        errors.append("effect thresholds were not locked")
    if prepared.get("strategy_and_safety_layer_locked_before_holdout") is not True:
        errors.append("strategy and safety layer were not locked")
    if prepared.get("effect_thresholds") != profile.get("effect_thresholds"):
        errors.append("effect thresholds changed after preparation")
    if prepared.get("source_sha256") != _source_hashes(profile):
        errors.append("source evidence changed after preparation")
    checkpoint_path = ROOT / str(profile["checkpoint"])
    checkpoint = _load(checkpoint_path)
    model_path = _model_path(checkpoint_path, checkpoint)
    if prepared.get("checkpoint_sha256") != _sha256(checkpoint_path):
        errors.append("SAC checkpoint changed after preparation")
    if prepared.get("model_sha256") != _sha256(model_path):
        errors.append("SAC weights changed after preparation")
    return errors


def _scenario_labels(task: Mapping[str, Any]) -> dict[str, str]:
    length = float(task.get("vessel_profile", {}).get("length_meters", 0.0))
    traffic = len(task.get("dynamic_obstacles", []))
    wave = float(task.get("sea_state", {}).get("wave_height_meters", 0.0))
    return {
        "vessel_length_band": (
            "small" if length < 150.0 else "medium" if length < 250.0 else "large"
        ),
        "traffic_load": "single" if traffic <= 1 else "multiple",
        "wave_height_band": "low" if wave < 1.0 else "medium" if wave < 2.0 else "high",
    }


def _disabled_supervisor() -> ModelPredictiveSafetySupervisor:
    return ModelPredictiveSafetySupervisor(
        SafetySupervisorConfig(profile_id="sac_pass_through_baseline", enabled=False)
    )


def _run_suite(
    *,
    supervised: bool,
    profile: Mapping[str, Any],
    checkpoint: Mapping[str, Any],
    model: Any,
    experiment: Mapping[str, Any],
    holdout: Mapping[str, Any],
) -> tuple[list[dict[str, Any]], list[float], list[float], float]:
    records: list[dict[str, Any]] = []
    decision_ms: list[float] = []
    replan_ms: list[float] = []
    tasks = holdout["splits"]["test"]
    started = time.perf_counter()
    safety_profile = SacChampionSafetyConfig.from_mapping(
        _load(ROOT / str(profile["safety_profile"]))
    )
    stage = "supervised" if supervised else "raw"
    for index, _task in enumerate(tasks):
        env = PortOpsNavigationEnv(
            experiment,
            holdout,
            split="test",
            discrete_actions=False,
            max_steps=int(profile["maximum_steps_per_episode"]),
            seed=int(profile["seed"]) + index,
            task_index=index,
            render_mode=None,
        )
        observation, _info = env.reset(options={"task_index": index})
        supervisor: ModelPredictiveSafetySupervisor = (
            SacChampionSafetySupervisor(safety_profile)
            if supervised
            else _disabled_supervisor()
        )
        minimum_ukc = float("inf")
        info: dict[str, Any] = {}
        while True:
            action, _state = model.predict(observation, deterministic=True)
            decision_started = time.perf_counter()
            decision = supervisor.project(env, action)
            elapsed_ms = (time.perf_counter() - decision_started) * 1000.0
            decision_ms.append(elapsed_ms)
            if decision.candidates_evaluated:
                replan_ms.append(elapsed_ms)
            observation, _reward, terminated, truncated, info = env.step(
                supervisor.environment_action(env, decision)
            )
            ukc = info.get("under_keel_clearance_meters")
            if ukc is not None:
                minimum_ukc = min(minimum_ukc, float(ukc))
            if terminated or truncated:
                break
        record = benchmark._episode_record(env, info, supervisor, minimum_ukc)
        record["scenario_strata"] = _scenario_labels(env.task)
        records.append(record)
        _write_json(
            PROGRESS,
            {
                "status": "running",
                "stage": stage,
                "algorithm": "sac",
                "contains_real_rl": True,
                "completed_episodes": index + 1,
                "total_episodes": len(tasks),
                "progress": (index + 1) / len(tasks),
                "partial_metrics": _aggregate(records),
                "elapsed_wall_seconds": time.perf_counter() - started,
            },
        )
        print(f"SAC {stage} holdout: {index + 1}/{len(tasks)}", flush=True)
    return records, decision_ms, replan_ms, time.perf_counter() - started


def _runtime_and_authority(
    records: Sequence[Mapping[str, Any]],
    decision_ms: Sequence[float],
    replan_ms: Sequence[float],
    wall_seconds: float,
) -> tuple[dict[str, Any], dict[str, Any]]:
    summaries = [item["safety_supervisor"] for item in records]
    steps = sum(int(item["steps"]) for item in records)
    project_calls = sum(int(item.get("project_calls", 0)) for item in summaries)
    intervention_steps = sum(int(item["intervention_steps"]) for item in summaries)
    fail_closed_events = sum(int(item["fail_closed_events"]) for item in summaries)
    authority_counts = {
        "project_calls": project_calls,
        "raw_sac_action_accepted_steps": sum(
            int(item.get("raw_sac_action_accepted_steps", 0)) for item in summaries
        ),
        "rl_rudder_retained_steps": sum(
            int(item.get("rl_rudder_retained_steps", 0)) for item in summaries
        ),
        "rl_any_dimension_retained_steps": sum(
            int(item.get("rl_any_dimension_retained_steps", 0)) for item in summaries
        ),
        "speed_governor_steps": sum(
            int(item.get("speed_governor_steps", 0)) for item in summaries
        ),
        "route_recovery_steps": sum(
            int(item.get("route_recovery_steps", 0)) for item in summaries
        ),
        "hazard_supervisor_intervention_steps": sum(
            int(item.get("hazard_supervisor_intervention_steps", 0))
            for item in summaries
        ),
    }
    denominator = max(project_calls, 1)
    authority = {
        **authority_counts,
        "raw_sac_action_accepted_step_rate": authority_counts[
            "raw_sac_action_accepted_steps"
        ]
        / denominator,
        "rl_rudder_retained_step_rate": authority_counts["rl_rudder_retained_steps"]
        / denominator,
        "rl_any_dimension_retained_step_rate": authority_counts[
            "rl_any_dimension_retained_steps"
        ]
        / denominator,
        "speed_governor_step_rate": authority_counts["speed_governor_steps"]
        / denominator,
        "route_recovery_step_rate": authority_counts["route_recovery_steps"]
        / denominator,
        "hazard_supervisor_intervention_step_rate": authority_counts[
            "hazard_supervisor_intervention_steps"
        ]
        / denominator,
    }
    runtime = {
        "steps": steps,
        "intervention_steps": intervention_steps,
        "intervention_step_rate": intervention_steps / max(steps, 1),
        "fail_closed_events": fail_closed_events,
        "fail_closed_episode_rate": float(
            np.mean([int(item["fail_closed_events"]) > 0 for item in summaries])
        ),
        "decision_mean_ms": float(np.mean(decision_ms)) if decision_ms else 0.0,
        "decision_p95_ms": benchmark._percentile(decision_ms, 0.95),
        "replan_mean_ms": float(np.mean(replan_ms)) if replan_ms else 0.0,
        "replan_p95_ms": benchmark._percentile(replan_ms, 0.95),
        "wall_seconds": wall_seconds,
    }
    return runtime, authority


def _metric(record: Mapping[str, Any], key: str) -> bool:
    if key == "collision_free_arrival_rate":
        return bool(record["success"]) and int(record["collisions"]) == 0 and int(
            record["groundings"]
        ) == 0
    if key == "port_compliant_completion_rate":
        return bool(record["port_compliant_success"])
    source = {
        "collision_episode_rate": "collisions",
        "grounding_episode_rate": "groundings",
        "colreg_violation_episode_rate": "colreg_give_way_violations",
    }
    return int(record[source[key]]) > 0


def _paired_effects(
    raw: Sequence[Mapping[str, Any]],
    safe: Sequence[Mapping[str, Any]],
) -> dict[str, Any]:
    if [item["task_id"] for item in raw] != [item["task_id"] for item in safe]:
        raise ValueError("raw and supervised holdout episodes are not paired")
    effects: dict[str, Any] = {}
    for key in (
        "collision_free_arrival_rate",
        "port_compliant_completion_rate",
        "collision_episode_rate",
        "grounding_episode_rate",
        "colreg_violation_episode_rate",
    ):
        raw_values = np.asarray([_metric(item, key) for item in raw], dtype=np.int8)
        safe_values = np.asarray([_metric(item, key) for item in safe], dtype=np.int8)
        raw_rate = float(raw_values.mean())
        safe_rate = float(safe_values.mean())
        effects[key] = {
            "raw": raw_rate,
            "supervised": safe_rate,
            "delta": safe_rate - raw_rate,
            "raw_only_events": int(np.sum((raw_values == 1) & (safe_values == 0))),
            "supervised_only_events": int(
                np.sum((raw_values == 0) & (safe_values == 1))
            ),
        }
    raw_collision = effects["collision_episode_rate"]["raw"]
    safe_collision = effects["collision_episode_rate"]["supervised"]
    effects["collision_relative_reduction_ratio"] = (
        (raw_collision - safe_collision) / raw_collision
        if raw_collision > 0.0
        else 0.0
    )
    return effects


def _strata(
    raw: Sequence[Mapping[str, Any]], safe: Sequence[Mapping[str, Any]]
) -> dict[str, Any]:
    output: dict[str, Any] = {}
    for dimension in ("vessel_length_band", "traffic_load", "wave_height_band"):
        output[dimension] = {}
        for label in sorted(
            {str(item["scenario_strata"][dimension]) for item in raw}
        ):
            indices = [
                index
                for index, item in enumerate(raw)
                if item["scenario_strata"][dimension] == label
            ]
            output[dimension][label] = {
                "episodes": len(indices),
                "raw_collision_episode_rate": float(
                    np.mean([int(raw[index]["collisions"]) > 0 for index in indices])
                ),
                "supervised_collision_episode_rate": float(
                    np.mean([int(safe[index]["collisions"]) > 0 for index in indices])
                ),
                "raw_collision_free_arrival_rate": float(
                    np.mean(
                        [
                            bool(raw[index]["success"])
                            and int(raw[index]["collisions"]) == 0
                            and int(raw[index]["groundings"]) == 0
                            for index in indices
                        ]
                    )
                ),
                "supervised_collision_free_arrival_rate": float(
                    np.mean(
                        [
                            bool(safe[index]["success"])
                            and int(safe[index]["collisions"]) == 0
                            and int(safe[index]["groundings"]) == 0
                            for index in indices
                        ]
                    )
                ),
            }
    return output


def _effect_checks(
    *,
    raw: Mapping[str, Any],
    safe: Mapping[str, Any],
    runtime: Mapping[str, Any],
    authority: Mapping[str, Any],
    thresholds: Mapping[str, Any],
    require_material_reduction: bool,
) -> dict[str, bool]:
    raw_collision = float(raw["collision_episode_rate"])
    safe_collision = float(safe["collision_episode_rate"])
    relative_reduction = (
        (raw_collision - safe_collision) / raw_collision
        if raw_collision > 0.0
        else 0.0
    )
    return {
        "material_collision_reduction": (
            relative_reduction
            >= float(thresholds["minimum_material_collision_reduction_ratio"])
            if require_material_reduction
            else safe_collision <= raw_collision
        ),
        "supervised_collision_rate": safe_collision
        <= float(thresholds["maximum_supervised_collision_episode_rate"]),
        "supervised_grounding_rate": float(safe["grounding_episode_rate"])
        <= float(thresholds["maximum_supervised_grounding_episode_rate"]),
        "arrival_utility_noninferior": float(safe["collision_free_arrival_rate"])
        >= float(raw["collision_free_arrival_rate"])
        - float(thresholds["maximum_arrival_rate_regression"]),
        "port_utility_noninferior": float(safe["port_compliant_completion_rate"])
        >= float(raw["port_compliant_completion_rate"])
        - float(thresholds["maximum_port_completion_rate_regression"]),
        "grounding_not_worse": float(safe["grounding_episode_rate"])
        <= float(raw["grounding_episode_rate"])
        + float(thresholds["maximum_grounding_rate_increase"]),
        "colreg_not_worse": float(safe["colreg_violation_episode_rate"])
        <= float(raw["colreg_violation_episode_rate"])
        + float(thresholds["maximum_colreg_rate_increase"]),
        "hazard_intervention_budget": float(
            authority["hazard_supervisor_intervention_step_rate"]
        )
        <= float(thresholds["maximum_hazard_supervisor_intervention_step_rate"]),
        "fail_closed_budget": float(runtime["fail_closed_episode_rate"])
        <= float(thresholds["maximum_fail_closed_episode_rate"]),
        "rl_rudder_authority": float(authority["rl_rudder_retained_step_rate"])
        >= float(thresholds["minimum_rl_rudder_retained_step_rate"]),
        "rl_any_dimension_authority": float(
            authority["rl_any_dimension_retained_step_rate"]
        )
        >= float(thresholds["minimum_rl_any_dimension_retained_step_rate"]),
        "decision_latency": float(runtime["decision_p95_ms"])
        <= float(thresholds["maximum_decision_p95_ms"]),
        "replan_latency": float(runtime["replan_p95_ms"])
        <= float(thresholds["maximum_replan_p95_ms"]),
    }


def _validation_suite(profile: Mapping[str, Any]) -> dict[str, Any]:
    base = _load(ROOT / str(profile["validation_base_result"]))[
        "aggregate_metrics"
    ]
    supervised_result = _load(
        ROOT / str(profile["validation_supervised_result"])
    )
    runtime = supervised_result["supervisor_metrics"]
    authority = supervised_result["rl_authority_metrics"]
    checks = _effect_checks(
        raw=base,
        safe=supervised_result["metrics"],
        runtime=runtime,
        authority=authority,
        thresholds=profile["effect_thresholds"],
        require_material_reduction=True,
    )
    return {
        "suite": "historical_ais_validation_2025_01_05",
        "episodes": int(supervised_result["episodes"]),
        "raw_metrics": base,
        "supervised_metrics": supervised_result["metrics"],
        "supervisor_metrics": runtime,
        "rl_authority_metrics": authority,
        "checks": checks,
        "passed": all(checks.values()),
        "failed_checks": [key for key, value in checks.items() if not value],
    }


def finalize() -> int:
    profile = _load(PROFILE)
    prepared = _load(PREPARED)
    errors = _verify_prepared(prepared, profile)
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    checkpoint_path = ROOT / str(profile["checkpoint"])
    checkpoint = _load(checkpoint_path)
    checkpoint["_checkpoint_path"] = os.fspath(checkpoint_path)
    model = _load_policy(checkpoint)
    experiment = _load(ROOT / str(profile["experiment"]))
    holdout = _load(ROOT / str(profile["counterfactual_holdout"]))

    raw_records, _raw_decision, _raw_replan, raw_wall = _run_suite(
        supervised=False,
        profile=profile,
        checkpoint=checkpoint,
        model=model,
        experiment=experiment,
        holdout=holdout,
    )
    safe_records, decision_ms, replan_ms, safe_wall = _run_suite(
        supervised=True,
        profile=profile,
        checkpoint=checkpoint,
        model=model,
        experiment=experiment,
        holdout=holdout,
    )
    raw_metrics = _aggregate(raw_records)
    safe_metrics = _aggregate(safe_records)
    runtime, authority = _runtime_and_authority(
        safe_records, decision_ms, replan_ms, safe_wall
    )
    paired = _paired_effects(raw_records, safe_records)
    strata = _strata(raw_records, safe_records)
    required = profile["required_holdout_strata"]
    strata_present = all(
        all(label in strata.get(dimension, {}) for label in labels)
        for dimension, labels in required.items()
    )
    checks = _effect_checks(
        raw=raw_metrics,
        safe=safe_metrics,
        runtime=runtime,
        authority=authority,
        thresholds=profile["effect_thresholds"],
        require_material_reduction=False,
    )
    checks["required_scenario_strata_present"] = strata_present
    holdout_suite = {
        "suite": "sealed_counterfactual_ais_holdout_2025_01_07",
        "episodes": len(safe_records),
        "raw_metrics": raw_metrics,
        "supervised_metrics": safe_metrics,
        "supervisor_metrics": runtime,
        "rl_authority_metrics": authority,
        "paired_effects": paired,
        "scenario_strata": strata,
        "checks": checks,
        "passed": all(checks.values()),
        "failed_checks": [key for key, value in checks.items() if not value],
        "raw_wall_seconds": raw_wall,
        "supervised_wall_seconds": safe_wall,
    }
    artifact = {
        "schema_version": "rl_safety_effectiveness_paired_episodes_v1",
        "algorithm": "sac",
        "strategy_id": str(profile["strategy_id"]),
        "contains_real_rl": True,
        "dataset": str(profile["counterfactual_holdout"]),
        "dataset_sha256": dataset_fingerprint(holdout),
        "raw_episodes": raw_records,
        "supervised_episodes": safe_records,
    }
    _write_json(ARTIFACT, artifact)

    validation = _validation_suite(profile)
    policy_result = {
        "strategy_id": str(profile["strategy_id"]),
        "dataset_split": "counterfactual_holdout",
        "contains_real_rl": True,
        "metrics": safe_metrics,
        "supervisor_metrics": runtime,
        "rl_authority_metrics": authority,
    }
    full_policy_admission = assess_policy(
        policy_result, _load(POLICY_ADMISSION_PROFILE)
    )
    safety_effect_passed = bool(validation["passed"] and holdout_suite["passed"])
    payload = {
        "schema_version": "rl_safety_effectiveness_assurance_v1",
        "assurance_id": str(profile["profile_id"]),
        "generated_at": datetime.now(timezone.utc).replace(
            microsecond=0
        ).isoformat(),
        "algorithm": "sac",
        "strategy_id": str(profile["strategy_id"]),
        "contains_real_rl": True,
        "base_policy_modified": False,
        "base_policy_checkpoint_sha256": prepared["checkpoint_sha256"],
        "base_policy_model_sha256": prepared["model_sha256"],
        "safety_layer_modified_after_holdout": False,
        "prepared_report": _relative(PREPARED),
        "prepared_report_sha256": _sha256(PREPARED),
        "paired_episode_artifact": _relative(ARTIFACT),
        "paired_episode_artifact_sha256": _sha256(ARTIFACT),
        "software": {
            "python": platform.python_version(),
            "platform": platform.platform(),
            "numpy": np.__version__,
        },
        "effect_thresholds": dict(profile["effect_thresholds"]),
        "validation_suite": validation,
        "counterfactual_holdout_suite": holdout_suite,
        "cross_scenario_safety_effectiveness_passed": safety_effect_passed,
        "safety_effect_deployment_decision": (
            "offline_rl_safety_effect_qualified"
            if safety_effect_passed
            else "rejected_fail_closed"
        ),
        "full_policy_admission": full_policy_admission,
        "full_policy_admitted": bool(full_policy_admission["passed"]),
        "production_authority": False,
        "independent_third_party_review": False,
        "claim_boundary": str(profile["claim_boundary"]),
    }
    _write_json(FINAL, payload)
    _write_text(MARKDOWN, _render_markdown(payload))
    _write_json(
        PROGRESS,
        {
            "status": "complete",
            "algorithm": "sac",
            "contains_real_rl": True,
            "completed_episodes": len(safe_records),
            "total_episodes": len(safe_records),
            "progress": 1.0,
            "safety_effectiveness_passed": safety_effect_passed,
            "full_policy_admitted": bool(full_policy_admission["passed"]),
            "report": _relative(FINAL),
        },
    )
    print(f"RL safety-effectiveness report: {FINAL}")
    print(
        "safety effect: "
        + ("PASS" if safety_effect_passed else "REJECT / FAIL-CLOSED")
    )
    print(
        "full policy admission: "
        + ("PASS" if full_policy_admission["passed"] else "REJECT")
    )
    return 0 if safety_effect_passed else 2


def _render_markdown(report: Mapping[str, Any]) -> str:
    rows: list[str] = []
    for suite in (
        report["validation_suite"],
        report["counterfactual_holdout_suite"],
    ):
        raw = suite["raw_metrics"]
        safe = suite["supervised_metrics"]
        authority = suite["rl_authority_metrics"]
        rows.append(
            "| {suite} | {episodes} | {raw_collision:.1%} | {safe_collision:.1%} | "
            "{raw_arrival:.1%} | {safe_arrival:.1%} | {raw_port:.1%} | {safe_port:.1%} | "
            "{rudder:.1%} | {decision} |".format(
                suite=suite["suite"],
                episodes=suite["episodes"],
                raw_collision=float(raw["collision_episode_rate"]),
                safe_collision=float(safe["collision_episode_rate"]),
                raw_arrival=float(raw["collision_free_arrival_rate"]),
                safe_arrival=float(safe["collision_free_arrival_rate"]),
                raw_port=float(raw["port_compliant_completion_rate"]),
                safe_port=float(safe["port_compliant_completion_rate"]),
                rudder=float(authority["rl_rudder_retained_step_rate"]),
                decision="PASS" if suite["passed"] else "REJECT",
            )
        )
    return f"""# SAC 强化学习安全效果跨场景论证 V1

本报告只回答安全层效果：真实训练的 SAC 策略经过 Safety V5 后，危险结果是否下降、任务完成能力是否保持、SAC 是否仍保有动作控制权。完整策略的绝对准入结论单独保留，不能用安全层效果通过来掩盖策略自身未达标。

| 场景集 | 回合 | 原碰撞 | 安全后碰撞 | 原无碰撞到达 | 安全后无碰撞到达 | 原港口合规 | 安全后港口合规 | SAC 舵角保留 | 安全效果 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
{chr(10).join(rows)}

- 核心算法：SAC 强化学习；`contains_real_rl=true`。
- 基础策略和权重是否修改：否。
- 跨场景安全效果：{'PASS' if report['cross_scenario_safety_effectiveness_passed'] else 'REJECT / FAIL-CLOSED'}。
- 完整策略绝对准入：{'PASS' if report['full_policy_admitted'] else 'REJECT'}；两个结论严格分开。
- 生产控制授权：否；`production_authority=false`。
- 独立第三方审查：尚未完成。

## 证据边界

该论证包含历史验证场景与预冻结的反事实压力留出场景，是针对真实训练 SAC 的离线仿真证据。它不是独立第三方机构审查、船级社认可、型式认可、硬件联锁见证、海试验收或实船控制授权。
"""


def _artifact_metrics(path: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    artifact = _load(path)
    return _aggregate(artifact["raw_episodes"]), _aggregate(
        artifact["supervised_episodes"]
    )


def verify() -> int:
    profile = _load(PROFILE)
    prepared = _load(PREPARED)
    errors = _verify_prepared(prepared, profile)
    report = _load(FINAL)
    if report.get("prepared_report_sha256") != _sha256(PREPARED):
        errors.append("prepared report changed after holdout evaluation")
    if report.get("paired_episode_artifact_sha256") != _sha256(ARTIFACT):
        errors.append("paired episode evidence changed")
    raw, safe = _artifact_metrics(ARTIFACT)
    holdout_suite = report.get("counterfactual_holdout_suite", {})
    if raw != holdout_suite.get("raw_metrics"):
        errors.append("raw holdout aggregate changed")
    if safe != holdout_suite.get("supervised_metrics"):
        errors.append("supervised holdout aggregate changed")
    validation = _validation_suite(profile)
    if validation != report.get("validation_suite"):
        errors.append("validation safety-effect evidence changed")
    runtime = holdout_suite.get("supervisor_metrics", {})
    authority = holdout_suite.get("rl_authority_metrics", {})
    checks = _effect_checks(
        raw=raw,
        safe=safe,
        runtime=runtime,
        authority=authority,
        thresholds=profile["effect_thresholds"],
        require_material_reduction=False,
    )
    checks["required_scenario_strata_present"] = all(
        all(
            label in holdout_suite.get("scenario_strata", {}).get(dimension, {})
            for label in labels
        )
        for dimension, labels in profile["required_holdout_strata"].items()
    )
    if checks != holdout_suite.get("checks"):
        errors.append("holdout effect checks changed")
    expected_effect = bool(validation["passed"] and all(checks.values()))
    if expected_effect != report.get("cross_scenario_safety_effectiveness_passed"):
        errors.append("cross-scenario safety-effect decision changed")
    if report.get("base_policy_modified") is not False:
        errors.append("base policy modification boundary changed")
    if report.get("contains_real_rl") is not True:
        errors.append("real RL evidence flag changed")
    if report.get("production_authority") is not False:
        errors.append("production authority changed")
    if report.get("independent_third_party_review") is not False:
        errors.append("third-party review boundary changed")
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    print(
        "RL safety-effectiveness verify: PASS "
        f"(effect={'PASS' if expected_effect else 'REJECT'}, "
        f"full_policy={'PASS' if report['full_policy_admitted'] else 'REJECT'}, "
        "production_authority=false)"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=("prepare", "smoke", "verify-smoke", "finalize", "verify"),
    )
    arguments = parser.parse_args()
    if arguments.command == "prepare":
        return prepare()
    if arguments.command == "smoke":
        return smoke()
    if arguments.command == "verify-smoke":
        return verify_smoke()
    if arguments.command == "finalize":
        return finalize()
    return verify()


if __name__ == "__main__":
    raise SystemExit(main())
