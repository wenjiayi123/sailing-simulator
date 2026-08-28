#!/usr/bin/env python3
"""Evaluate the SAC V5 candidate on validation data with progress receipts.

This diagnostic runner is deliberately validation-only.  It cannot open the
test split, so tuning the speed governor or safety profile cannot silently
reuse sealed-test outcomes.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
import time
from typing import Any, Mapping

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools import run_safety_supervisor_benchmark as benchmark  # noqa: E402
from tools.ship_rl.environment import (  # noqa: E402
    dataset_fingerprint,
    experiment_fingerprint,
    load_experiment,
)
from tools.ship_rl.port_ops_environment import PortOpsNavigationEnv  # noqa: E402
from tools.ship_rl.port_ops_trainer import (  # noqa: E402
    _aggregate,
    _load_policy,
    _policy_action,
)
from tools.ship_rl.sac_champion_safety_v5 import (  # noqa: E402
    SacChampionSafetyConfig,
    SacChampionSafetySupervisor,
)


CONFIG = ROOT / "data/rl/long_beach_ais_port_ops_experiment_v2.json"
PROFILE = ROOT / "data/rl/sac_champion_safety_v5.json"
CHECKPOINT = (
    ROOT
    / "reports/artifacts/sac_champion_v5/pilot_pure_20k/checkpoint.json"
)
OUTPUT = (
    ROOT
    / "reports/artifacts/sac_champion_v5/validation_sac20k_safety_v5"
)
SEED = 250107


def _load(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _write(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def _relative(path: Path) -> str:
    return os.fspath(path.resolve().relative_to(ROOT))


def evaluate(
    checkpoint_path: Path,
    output_dir: Path,
    max_steps: int,
    task_indices: list[int] | None = None,
) -> dict[str, Any]:
    checkpoint = _load(checkpoint_path)
    checkpoint["_checkpoint_path"] = os.fspath(checkpoint_path)
    if checkpoint.get("algorithm") != "sac":
        raise ValueError("V5 champion validation accepts only a SAC checkpoint")

    config, dataset, dataset_path = load_experiment(CONFIG)
    if checkpoint.get("dataset_sha256") != dataset_fingerprint(dataset):
        raise ValueError("SAC checkpoint dataset fingerprint changed")
    if checkpoint.get("experiment_sha256") != experiment_fingerprint(config):
        raise ValueError("SAC checkpoint experiment fingerprint changed")

    profile = SacChampionSafetyConfig.from_mapping(_load(PROFILE))
    policy = _load_policy(checkpoint)
    results: list[dict[str, Any]] = []
    decision_ms: list[float] = []
    replan_ms: list[float] = []
    first_env: PortOpsNavigationEnv | None = None
    first_record: dict[str, Any] = {}
    started = time.perf_counter()
    all_tasks = dataset["splits"]["validation"]
    indices = task_indices if task_indices is not None else list(range(len(all_tasks)))
    if not indices:
        raise ValueError("at least one validation task index is required")
    if min(indices) < 0 or max(indices) >= len(all_tasks):
        raise ValueError("validation task index is out of range")
    tasks = [all_tasks[index] for index in indices]

    for completed_index, task_index in enumerate(indices):
        env = PortOpsNavigationEnv(
            config,
            dataset,
            split="validation",
            discrete_actions=False,
            max_steps=max_steps,
            seed=SEED + task_index,
            task_index=task_index,
            render_mode=None,
        )
        observation, _info = env.reset(options={"task_index": task_index})
        supervisor = SacChampionSafetySupervisor(profile)
        minimum_ukc = float("inf")
        info: dict[str, Any] = {}
        while True:
            proposed = _policy_action(policy, "sac", env, observation)
            decision_started = time.perf_counter()
            decision = supervisor.project(env, proposed)
            elapsed_ms = (time.perf_counter() - decision_started) * 1_000.0
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

        record = benchmark._episode_record(
            env,
            info,
            supervisor,
            minimum_ukc,
        )
        results.append(record)
        if first_env is None:
            first_env = env
            first_record = record
        _write(
            output_dir / "progress.json",
            {
                "status": "running",
                "dataset_split": "validation",
                "completed_episodes": completed_index + 1,
                "total_episodes": len(tasks),
                "progress": len(results) / max(len(tasks), 1),
                "latest_task_id": record["task_id"],
                "partial_metrics": _aggregate(results),
                "elapsed_wall_seconds": time.perf_counter() - started,
            },
        )
        print(
            f"validation SAC+V5: {len(results)}/{len(tasks)}",
            flush=True,
        )

    assert first_env is not None
    aggregate = _aggregate(results)
    summaries = [item["safety_supervisor"] for item in results]
    steps = sum(int(item["steps"]) for item in results)
    project_calls = sum(int(item.get("project_calls", 0)) for item in summaries)
    intervention_steps = sum(
        int(item["intervention_steps"]) for item in summaries
    )
    fail_closed_events = sum(
        int(item["fail_closed_events"]) for item in summaries
    )
    authority = {
        "project_calls": project_calls,
        "raw_sac_action_accepted_steps": sum(
            int(item.get("raw_sac_action_accepted_steps", 0))
            for item in summaries
        ),
        "rl_rudder_retained_steps": sum(
            int(item.get("rl_rudder_retained_steps", 0))
            for item in summaries
        ),
        "rl_any_dimension_retained_steps": sum(
            int(item.get("rl_any_dimension_retained_steps", 0))
            for item in summaries
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
    authority.update(
        {
            "raw_sac_action_accepted_step_rate": (
                authority["raw_sac_action_accepted_steps"] / denominator
            ),
            "rl_rudder_retained_step_rate": (
                authority["rl_rudder_retained_steps"] / denominator
            ),
            "rl_any_dimension_retained_step_rate": (
                authority["rl_any_dimension_retained_steps"] / denominator
            ),
            "speed_governor_step_rate": (
                authority["speed_governor_steps"] / denominator
            ),
            "route_recovery_step_rate": (
                authority["route_recovery_steps"] / denominator
            ),
            "hazard_supervisor_intervention_step_rate": (
                authority["hazard_supervisor_intervention_steps"]
                / denominator
            ),
        }
    )
    runtime = {
        "steps": steps,
        "intervention_steps": intervention_steps,
        "intervention_step_rate": intervention_steps / max(steps, 1),
        "fail_closed_events": fail_closed_events,
        "fail_closed_episode_rate": float(
            np.mean(
                [
                    int(item["fail_closed_events"]) > 0
                    for item in summaries
                ]
            )
        ),
        "decision_mean_ms": float(np.mean(decision_ms)) if decision_ms else 0.0,
        "decision_p95_ms": benchmark._percentile(decision_ms, 0.95),
        "replan_mean_ms": float(np.mean(replan_ms)) if replan_ms else 0.0,
        "replan_p95_ms": benchmark._percentile(replan_ms, 0.95),
        "wall_seconds": time.perf_counter() - started,
    }
    result = {
        "schema_version": "sac_champion_validation_v5",
        "strategy_id": "sac_pure_20k+safety_v5",
        "algorithm": "sac",
        "contains_real_rl": True,
        "dataset_split": "validation",
        "episodes": len(results),
        "config": _relative(CONFIG),
        "dataset": _relative(dataset_path) if dataset_path else "runtime_snapshot",
        "checkpoint": _relative(checkpoint_path),
        "safety_profile": _relative(PROFILE),
        "metrics": aggregate,
        "supervisor_metrics": runtime,
        "rl_authority_metrics": authority,
    }
    episode_results_path = output_dir / "validation_episode_results.json"
    _write(
        episode_results_path,
        {
            "schema_version": "sac_champion_validation_episodes_v5",
            "strategy_id": result["strategy_id"],
            "dataset_split": "validation",
            "episodes": results,
        },
    )
    result["episode_results"] = _relative(episode_results_path)
    trajectory = {
        "format": "ship_port_policy_validation_sac_champion_v5",
        "strategy_id": result["strategy_id"],
        "checkpoint": result["checkpoint"],
        "dataset_split": "validation",
        "task_id": first_record["task_id"],
        "samples": first_env.trajectory,
        "evaluation_metrics": first_record,
        "aggregate_metrics": aggregate,
        "rl_authority_metrics": authority,
    }
    _write(output_dir / "validation_trajectory.json", trajectory)
    result["trajectory"] = _relative(
        output_dir / "validation_trajectory.json"
    )
    _write(output_dir / "validation_result.json", result)
    _write(
        output_dir / "progress.json",
        {
            "status": "complete",
            "dataset_split": "validation",
            "completed_episodes": len(results),
            "total_episodes": len(tasks),
            "progress": 1.0,
            "elapsed_wall_seconds": runtime["wall_seconds"],
            "result": _relative(output_dir / "validation_result.json"),
        },
    )
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, default=CHECKPOINT)
    parser.add_argument("--output-dir", type=Path, default=OUTPUT)
    parser.add_argument("--max-steps", type=int, default=1_600)
    parser.add_argument(
        "--task-indices",
        help="comma-separated validation indices; omit for the full split",
    )
    args = parser.parse_args()
    task_indices = None
    if args.task_indices:
        task_indices = [
            int(value.strip())
            for value in args.task_indices.split(",")
            if value.strip()
        ]
    result = evaluate(
        args.checkpoint.resolve(),
        args.output_dir.resolve(),
        max(1, args.max_steps),
        task_indices,
    )
    print(json.dumps(result, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
