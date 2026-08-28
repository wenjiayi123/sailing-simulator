#!/usr/bin/env python3
"""Apply the predeclared SAC V5 offline-admission thresholds."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Mapping


ROOT = Path(__file__).resolve().parents[1]
PROFILE = ROOT / "data/rl/sac_champion_admission_v5.json"
DEFAULT_RESULT = (
    ROOT
    / "reports/artifacts/sac_champion_v5/validation_sac20k_safety_v5"
    / "validation_result.json"
)


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


def assess(result: Mapping[str, Any], profile: Mapping[str, Any]) -> dict[str, Any]:
    thresholds = profile["thresholds"]
    metrics = result["metrics"]
    runtime = result["supervisor_metrics"]
    authority = result["rl_authority_metrics"]
    checks = {
        "collision_free_arrival_rate": (
            float(metrics["collision_free_arrival_rate"])
            >= float(thresholds["minimum_collision_free_arrival_rate"])
        ),
        "port_compliant_completion_rate": (
            float(metrics["port_compliant_completion_rate"])
            >= float(thresholds["minimum_port_compliant_completion_rate"])
        ),
        "mean_route_completion_ratio": (
            float(metrics["mean_route_completion_ratio"])
            >= float(thresholds["minimum_mean_route_completion_ratio"])
        ),
        "collision_episode_rate": (
            float(metrics["collision_episode_rate"])
            <= float(thresholds["maximum_collision_episode_rate"])
        ),
        "grounding_episode_rate": (
            float(metrics["grounding_episode_rate"])
            <= float(thresholds["maximum_grounding_episode_rate"])
        ),
        "colreg_violation_episode_rate": (
            float(metrics["colreg_violation_episode_rate"])
            <= float(thresholds["maximum_colreg_violation_episode_rate"])
        ),
        "channel_departure_episode_rate": (
            float(metrics["channel_departure_episode_rate"])
            <= float(thresholds["maximum_channel_departure_episode_rate"])
        ),
        "speed_violation_episode_rate": (
            float(metrics["speed_violation_episode_rate"])
            <= float(thresholds["maximum_speed_violation_episode_rate"])
        ),
        "hazard_supervisor_intervention_step_rate": (
            float(authority["hazard_supervisor_intervention_step_rate"])
            <= float(
                thresholds[
                    "maximum_hazard_supervisor_intervention_step_rate"
                ]
            )
        ),
        "fail_closed_episode_rate": (
            float(runtime["fail_closed_episode_rate"])
            <= float(thresholds["maximum_fail_closed_episode_rate"])
        ),
        "raw_sac_action_accepted_step_rate": (
            float(authority["raw_sac_action_accepted_step_rate"])
            >= float(
                thresholds["minimum_raw_sac_action_accepted_step_rate"]
            )
        ),
        "rl_rudder_retained_step_rate": (
            float(authority["rl_rudder_retained_step_rate"])
            >= float(thresholds["minimum_rl_rudder_retained_step_rate"])
        ),
        "rl_any_dimension_retained_step_rate": (
            float(authority["rl_any_dimension_retained_step_rate"])
            >= float(
                thresholds["minimum_rl_any_dimension_retained_step_rate"]
            )
        ),
        "decision_p95_ms": (
            float(runtime["decision_p95_ms"])
            <= float(thresholds["maximum_decision_p95_ms"])
        ),
        "replan_p95_ms": (
            float(runtime["replan_p95_ms"])
            <= float(thresholds["maximum_replan_p95_ms"])
        ),
        "contains_real_rl": bool(result.get("contains_real_rl", False)),
    }
    return {
        "profile_id": profile["profile_id"],
        "strategy_id": result["strategy_id"],
        "dataset_split": result["dataset_split"],
        "thresholds": thresholds,
        "checks": checks,
        "passed": all(checks.values()),
        "failed_checks": [name for name, passed in checks.items() if not passed],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("result", type=Path, nargs="?", default=DEFAULT_RESULT)
    parser.add_argument("--profile", type=Path, default=PROFILE)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result_path = args.result.resolve()
    assessment = assess(_load(result_path), _load(args.profile.resolve()))
    output = args.output.resolve() if args.output else result_path.with_name(
        result_path.stem + "_admission.json"
    )
    _write(output, assessment)
    print(json.dumps(assessment, ensure_ascii=False), flush=True)
    return 0 if assessment["passed"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
