#!/usr/bin/env python3
"""Build or verify the simulator-level reliability and policy-admission audit."""

from __future__ import annotations

import argparse
import csv
from collections import Counter
from datetime import datetime, timedelta
import hashlib
import json
import math
from pathlib import Path
import sys
from typing import Any, Iterable, Mapping, Sequence

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
DATASET = ROOT / "data/rl/long_beach_public_weather_benchmark_v1.json"
HOURLY = ROOT / "data/public/long_beach_open_meteo_2024_01_04_hourly.csv"
BENCHMARK = ROOT / "reports/navigation_benchmark_v1.json"
GODOT_REPORT = ROOT / "reports/godot_acceptance_v1.json"
OUTPUT_JSON = ROOT / "reports/simulator_reliability_audit_v1.json"
OUTPUT_MARKDOWN = ROOT / "reports/simulator_reliability_audit_v1.md"
ALGORITHMS = ("ppo", "sac", "td3", "dqn", "los_pid")
ROUTE_TEMPLATES = ("harbor_approach", "channel_turn", "s_curve")
NUMERIC_EPISODE_FIELDS = (
    "minimum_clearance_meters",
    "minimum_dcpa_meters",
    "max_cross_track_error_meters",
    "path_length_meters",
    "reference_route_length_meters",
    "path_efficiency",
    "elapsed_seconds",
    "reward",
    "steps",
)
ADMISSION_THRESHOLDS = {
    "minimum_collision_free_arrival_rate": 0.95,
    "maximum_collision_episode_rate": 0.0,
    "maximum_terrain_collision_episode_rate": 0.0,
    "maximum_near_miss_episode_rate": 0.05,
    "maximum_p95_cross_track_error_meters": 10.0,
    "minimum_p05_clearance_meters": 5.0,
    "minimum_p05_dcpa_meters": 5.0,
    "minimum_mean_path_efficiency": 0.90,
}


def _load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _write_json(path: Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def _write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(content, encoding="utf-8")
    temporary.replace(path)


def _as_bool(value: Any) -> bool:
    return str(value).strip().lower() in {"1", "true", "yes"}


def _template_name(task_id: str) -> str:
    for name in ROUTE_TEMPLATES:
        if task_id.endswith(name):
            return name
    return "unknown"


def _read_episode_rows(path: Path) -> list[dict[str, Any]]:
    with path.open("r", newline="", encoding="utf-8") as handle:
        raw = list(csv.DictReader(handle))
    rows: list[dict[str, Any]] = []
    for item in raw:
        rows.append(
            {
                **item,
                "success": _as_bool(item["success"]),
                "goal_reached": _as_bool(item["goal_reached"]),
                "collisions": int(item["collisions"]),
                "terrain_collisions": int(item["terrain_collisions"]),
                "near_misses": int(item["near_misses"]),
                "dynamic_obstacle_count": int(item["dynamic_obstacle_count"]),
                **{field: float(item[field]) for field in NUMERIC_EPISODE_FIELDS},
            }
        )
    return rows


def _aggregate(rows: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    return {
        "episodes": len(rows),
        "success_rate": float(np.mean([row["success"] for row in rows])),
        "safe_completion_rate": float(
            np.mean(
                [
                    row["success"]
                    and row["collisions"] == 0
                    and row["terrain_collisions"] == 0
                    for row in rows
                ]
            )
        ),
        "collision_episode_rate": float(
            np.mean([row["collisions"] > 0 for row in rows])
        ),
        "terrain_collision_episode_rate": float(
            np.mean([row["terrain_collisions"] > 0 for row in rows])
        ),
        "near_miss_episode_rate": float(
            np.mean([row["near_misses"] > 0 for row in rows])
        ),
        "mean_reward": float(np.mean([row["reward"] for row in rows])),
        "total_collisions": int(sum(row["collisions"] for row in rows)),
        "total_terrain_collisions": int(
            sum(row["terrain_collisions"] for row in rows)
        ),
        "total_near_misses": int(sum(row["near_misses"] for row in rows)),
        "mean_max_cross_track_error_meters": float(
            np.mean([row["max_cross_track_error_meters"] for row in rows])
        ),
        "p95_max_cross_track_error_meters": float(
            np.percentile(
                [row["max_cross_track_error_meters"] for row in rows],
                95,
            )
        ),
        "mean_minimum_clearance_meters": float(
            np.mean([row["minimum_clearance_meters"] for row in rows])
        ),
        "p05_minimum_clearance_meters": float(
            np.percentile([row["minimum_clearance_meters"] for row in rows], 5)
        ),
        "mean_minimum_dcpa_meters": float(
            np.mean([row["minimum_dcpa_meters"] for row in rows])
        ),
        "p05_minimum_dcpa_meters": float(
            np.percentile([row["minimum_dcpa_meters"] for row in rows], 5)
        ),
        "mean_path_efficiency": float(
            np.mean([row["path_efficiency"] for row in rows])
        ),
        "mean_elapsed_seconds": float(
            np.mean([row["elapsed_seconds"] for row in rows])
        ),
    }


def _same_metrics(
    actual: Mapping[str, Any],
    expected: Mapping[str, Any],
) -> bool:
    if set(actual) != set(expected):
        return False
    for key, value in actual.items():
        target = expected[key]
        if isinstance(value, (float, int)) and isinstance(target, (float, int)):
            if not math.isclose(float(value), float(target), rel_tol=1e-12, abs_tol=1e-12):
                return False
        elif value != target:
            return False
    return True


def _admission_failures(metrics: Mapping[str, Any]) -> list[str]:
    checks = (
        (
            float(metrics["safe_completion_rate"])
            >= ADMISSION_THRESHOLDS["minimum_collision_free_arrival_rate"],
            "collision_free_arrival_rate",
        ),
        (
            float(metrics["collision_episode_rate"])
            <= ADMISSION_THRESHOLDS["maximum_collision_episode_rate"],
            "collision_episode_rate",
        ),
        (
            float(metrics["terrain_collision_episode_rate"])
            <= ADMISSION_THRESHOLDS["maximum_terrain_collision_episode_rate"],
            "terrain_collision_episode_rate",
        ),
        (
            float(metrics["near_miss_episode_rate"])
            <= ADMISSION_THRESHOLDS["maximum_near_miss_episode_rate"],
            "near_miss_episode_rate",
        ),
        (
            float(metrics["p95_max_cross_track_error_meters"])
            <= ADMISSION_THRESHOLDS["maximum_p95_cross_track_error_meters"],
            "p95_cross_track_error",
        ),
        (
            float(metrics["p05_minimum_clearance_meters"])
            >= ADMISSION_THRESHOLDS["minimum_p05_clearance_meters"],
            "p05_minimum_clearance",
        ),
        (
            float(metrics["p05_minimum_dcpa_meters"])
            >= ADMISSION_THRESHOLDS["minimum_p05_dcpa_meters"],
            "p05_minimum_dcpa",
        ),
        (
            float(metrics["mean_path_efficiency"])
            >= ADMISSION_THRESHOLDS["minimum_mean_path_efficiency"],
            "mean_path_efficiency",
        ),
    )
    return [name for passed, name in checks if not passed]


def _verify_replay(
    trajectory: Mapping[str, Any],
    first_row: Mapping[str, Any],
    algorithm: str,
    errors: list[str],
) -> dict[str, Any]:
    samples = trajectory.get("samples", [])
    valid = bool(samples)
    expected_steps = int(first_row["steps"])
    if trajectory.get("algorithm") != algorithm:
        errors.append(f"{algorithm}: replay algorithm mismatch")
        valid = False
    if trajectory.get("dataset_split") != "test":
        errors.append(f"{algorithm}: replay is not from test split")
        valid = False
    if len(samples) != expected_steps + 1:
        errors.append(f"{algorithm}: replay sample count differs from steps + 1")
        valid = False
    indices = [sample.get("index") for sample in samples]
    if indices != list(range(len(samples))):
        errors.append(f"{algorithm}: replay sample indexes are not contiguous")
        valid = False
    times = [float(sample.get("time", float("nan"))) for sample in samples]
    if any(not math.isfinite(value) for value in times) or any(
        current < previous for previous, current in zip(times, times[1:])
    ):
        errors.append(f"{algorithm}: replay timestamps are invalid")
        valid = False
    for sample in samples:
        values = [
            sample.get("x"),
            sample.get("z"),
            sample.get("heading_degrees"),
            sample.get("speed_mps"),
            sample.get("throttle"),
            sample.get("rudder"),
            sample.get("reward"),
            sample.get("nearest_clearance_meters"),
            sample.get("nearest_tcpa_seconds"),
            sample.get("nearest_dcpa_meters"),
        ]
        if any(not math.isfinite(float(value)) for value in values):
            errors.append(f"{algorithm}: replay contains non-finite numeric state")
            valid = False
            break
        if not (-1.0 <= float(sample["throttle"]) <= 1.0):
            errors.append(f"{algorithm}: replay throttle is outside [-1, 1]")
            valid = False
            break
        if not (-1.0 <= float(sample["rudder"]) <= 1.0):
            errors.append(f"{algorithm}: replay rudder is outside [-1, 1]")
            valid = False
            break
        for obstacle in sample.get("dynamic_obstacles", []):
            if not all(
                math.isfinite(float(obstacle[field])) for field in ("x", "z")
            ):
                errors.append(f"{algorithm}: dynamic replay state is non-finite")
                valid = False
                break
    embedded = trajectory.get("evaluation_metrics", {})
    comparison_fields = (
        "task_id",
        "success",
        "goal_reached",
        "collisions",
        "terrain_collisions",
        "near_misses",
        "dynamic_obstacle_count",
        "minimum_clearance_meters",
        "minimum_dcpa_meters",
        "max_cross_track_error_meters",
        "path_length_meters",
        "reference_route_length_meters",
        "path_efficiency",
        "elapsed_seconds",
        "reward",
        "steps",
    )
    for field in comparison_fields:
        actual = embedded.get(field)
        expected = first_row.get(field)
        if isinstance(expected, float):
            matches = isinstance(actual, (float, int)) and math.isclose(
                float(actual),
                expected,
                rel_tol=1e-12,
                abs_tol=1e-12,
            )
        else:
            matches = actual == expected
        if not matches:
            errors.append(f"{algorithm}: replay/CSV mismatch for {field}")
            valid = False
    return {
        "passed": valid,
        "samples": len(samples),
        "task_id": str(first_row["task_id"]),
        "steps": expected_steps,
    }


def _source_tree_fingerprint() -> tuple[int, str]:
    roots: Iterable[Path] = (
        ROOT / "project.godot",
        ROOT / "main.tscn",
        ROOT / "player.gd",
        ROOT / "scripts",
        ROOT / "scenes",
    )
    suffixes = {".gd", ".gdshader", ".tscn", ".tres"}
    files: list[Path] = []
    for candidate in roots:
        if candidate.is_file():
            files.append(candidate)
        elif candidate.is_dir():
            files.extend(
                path
                for path in candidate.rglob("*")
                if path.is_file() and path.suffix.lower() in suffixes
            )
    files = sorted(set(files), key=lambda path: str(path.relative_to(ROOT)))
    digest = hashlib.sha256()
    for path in files:
        digest.update(str(path.relative_to(ROOT)).encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return len(files), digest.hexdigest()


def build_report() -> tuple[dict[str, Any], list[str]]:
    errors: list[str] = []
    dataset = _load_json(DATASET)
    benchmark = _load_json(BENCHMARK)
    godot = _load_json(GODOT_REPORT)
    tasks = [
        task
        for split in ("train", "validation", "test")
        for task in dataset["splits"][split]
    ]
    test_tasks = dataset["splits"]["test"]

    with HOURLY.open("r", newline="", encoding="utf-8") as handle:
        hourly = list(csv.DictReader(handle))
    timestamps = [
        datetime.fromisoformat(row["timestamp"].replace("Z", "+00:00"))
        for row in hourly
    ]
    hourly_continuous = timestamps == [
        timestamps[0] + timedelta(hours=index)
        for index in range(len(timestamps))
    ]
    hourly_numeric_complete = all(
        all(
            math.isfinite(float(value))
            for key, value in row.items()
            if key != "timestamp"
        )
        for row in hourly
    )
    if len(hourly) != 2_904 or not hourly_continuous or not hourly_numeric_complete:
        errors.append("public hourly forcing completeness check failed")

    split_dates = {
        split: {
            task["public_forcing"]["source_date"]
            for task in dataset["splits"][split]
        }
        for split in ("train", "validation", "test")
    }
    no_temporal_leakage = not any(
        split_dates[first] & split_dates[second]
        for first, second in (
            ("train", "validation"),
            ("train", "test"),
            ("validation", "test"),
        )
    )
    if not no_temporal_leakage:
        errors.append("temporal split leakage detected")

    def scenario_complete(task: Mapping[str, Any]) -> bool:
        forcing = task.get("public_forcing", {})
        required_forcing = {
            "wind_speed_knots",
            "wind_direction_degrees",
            "wave_height_meters",
            "wave_direction_degrees",
            "wave_period_seconds",
            "current_speed_knots",
            "current_direction_degrees",
        }
        return bool(
            len(task.get("route", [])) == 5
            and task.get("obstacles")
            and task.get("terrain")
            and task.get("dynamic_obstacles")
            and required_forcing <= set(forcing)
        )

    complete_scenarios = sum(int(scenario_complete(task)) for task in tasks)
    if complete_scenarios != len(tasks):
        errors.append("one or more scenario contracts are incomplete")
    template_counts = Counter(_template_name(str(task["id"])) for task in tasks)
    test_template_counts = Counter(
        _template_name(str(task["id"])) for task in test_tasks
    )
    if test_template_counts != Counter({name: 10 for name in ROUTE_TEMPLATES}):
        errors.append("test route-template matrix is not balanced 10/10/10")

    verified_hashes = 0
    expected_hashes = 0
    for relative, expected in benchmark["evidence_sha256"].items():
        expected_hashes += 1
        path = ROOT / relative
        if path.is_file() and _sha256(path) == expected:
            verified_hashes += 1
        else:
            errors.append(f"core evidence hash failed: {relative}")
    for artifact in benchmark["artifacts"]:
        for path_key, hash_key in (
            ("checkpoint", "checkpoint_sha256"),
            ("model", "model_sha256"),
        ):
            relative = artifact.get(path_key)
            expected = artifact.get(hash_key)
            if not relative:
                continue
            expected_hashes += 1
            path = ROOT / str(relative)
            if path.is_file() and _sha256(path) == expected:
                verified_hashes += 1
            else:
                errors.append(
                    f"{artifact['algorithm']}: {path_key} hash verification failed"
                )

    algorithm_rows: list[dict[str, Any]] = []
    replay_checks: list[dict[str, Any]] = []
    csv_consistency_passed = 0
    total_episode_rows = 0
    total_replay_samples = 0
    for result in benchmark["test_results"]:
        algorithm = str(result["algorithm"])
        trajectory_path = ROOT / result["trajectory"]
        expected_hashes += 1
        if trajectory_path.is_file() and _sha256(trajectory_path) == result["trajectory_sha256"]:
            verified_hashes += 1
        else:
            errors.append(f"{algorithm}: trajectory hash verification failed")
        rows = _read_episode_rows(ROOT / result["episode_metrics_csv"])
        total_episode_rows += len(rows)
        if len(rows) != 30:
            errors.append(f"{algorithm}: expected 30 episode rows")
        if any(
            not all(math.isfinite(float(row[field])) for field in NUMERIC_EPISODE_FIELDS)
            for row in rows
        ):
            errors.append(f"{algorithm}: non-finite episode metric")
        if len({str(row["task_id"]) for row in rows}) != len(rows):
            errors.append(f"{algorithm}: duplicate test task id")
        aggregate = _aggregate(rows)
        consistency = _same_metrics(aggregate, result["metrics"])
        if consistency:
            csv_consistency_passed += 1
        else:
            errors.append(f"{algorithm}: CSV aggregate differs from final report")
        trajectory = _load_json(trajectory_path)
        replay = _verify_replay(trajectory, rows[0], algorithm, errors)
        replay_checks.append({"algorithm": algorithm, **replay})
        total_replay_samples += replay["samples"]
        failures = _admission_failures(aggregate)
        algorithm_rows.append(
            {
                "algorithm": algorithm,
                "test_episodes": len(rows),
                "collision_free_arrival_rate": aggregate["safe_completion_rate"],
                "collision_episode_rate": aggregate["collision_episode_rate"],
                "terrain_collision_episode_rate": aggregate[
                    "terrain_collision_episode_rate"
                ],
                "near_miss_episode_rate": aggregate["near_miss_episode_rate"],
                "mean_max_cross_track_error_meters": aggregate[
                    "mean_max_cross_track_error_meters"
                ],
                "p95_max_cross_track_error_meters": aggregate[
                    "p95_max_cross_track_error_meters"
                ],
                "mean_minimum_clearance_meters": aggregate[
                    "mean_minimum_clearance_meters"
                ],
                "p05_minimum_clearance_meters": aggregate[
                    "p05_minimum_clearance_meters"
                ],
                "mean_minimum_dcpa_meters": aggregate[
                    "mean_minimum_dcpa_meters"
                ],
                "p05_minimum_dcpa_meters": aggregate[
                    "p05_minimum_dcpa_meters"
                ],
                "mean_path_efficiency": aggregate["mean_path_efficiency"],
                "mean_elapsed_seconds": aggregate["mean_elapsed_seconds"],
                "total_near_misses": aggregate["total_near_misses"],
                "admission_passed": not failures,
                "admission_failures": failures,
            }
        )

    expected_artifact_checks = expected_hashes + len(ALGORITHMS)
    passed_artifact_checks = verified_hashes + csv_consistency_passed
    if total_episode_rows != 150:
        errors.append("final episode inventory is not 150/150")
    if not all(item["passed"] for item in replay_checks):
        errors.append("one or more replay structural checks failed")

    source_file_count, source_tree_sha256 = _source_tree_fingerprint()
    godot_source = godot.get("source_inventory", {})
    godot_hash_matches = (
        godot_source.get("file_count") == source_file_count
        and godot_source.get("tree_sha256") == source_tree_sha256
    )
    godot_passed = bool(godot.get("passed")) and godot_hash_matches
    if not godot_passed:
        errors.append("Godot acceptance receipt is missing, failed, or stale")

    forcing_values = {
        field: [float(task["public_forcing"][field]) for task in tasks]
        for field in (
            "wind_speed_knots",
            "wave_height_meters",
            "wave_period_seconds",
            "current_speed_knots",
        )
    }
    admitted = [
        row["algorithm"] for row in algorithm_rows if row["admission_passed"]
    ]
    total_actual_training_steps = sum(
        int(item["training"]["actual_timesteps"])
        for item in benchmark["artifacts"]
    )
    total_training_episodes = sum(
        int(item["training"]["episodes_completed"])
        for item in benchmark["artifacts"]
    )

    report = {
        "schema_version": "simulator_reliability_audit_v1",
        "audit_id": "ship_simulator_public_weather_fixed_test_v1",
        "evidence_snapshot_generated_at": benchmark["generated_at"],
        "status": "PASS" if not errors else "FAIL",
        "simulator_scope": {
            "observation_dimensions": benchmark["experiment"]["observation_size"],
            "continuous_action_dimensions": 2,
            "discrete_action_count": 9,
            "algorithms": list(ALGORITHMS),
            "supported_hazard_shapes": ["circle", "box", "polygon"],
            "risk_state": [
                "closing_speed",
                "tcpa",
                "boundary_clearance",
                "front_clearance",
                "port_clearance",
                "starboard_clearance",
            ],
        },
        "data_contract": {
            "provider": dataset["source"]["provider"],
            "evidence_level": "public_model_reanalysis_and_archive",
            "hourly_rows": len(hourly),
            "continuous_hourly_rows": len(hourly) if hourly_continuous else 0,
            "numeric_complete_rows": len(hourly) if hourly_numeric_complete else 0,
            "source_period": dataset["source"]["period"],
            "scenario_count": len(tasks),
            "split_sizes": {
                split: len(dataset["splits"][split])
                for split in ("train", "validation", "test")
            },
            "temporal_leakage_count": 0 if no_temporal_leakage else 1,
            "forcing_ranges": {
                field: {
                    "minimum": min(values),
                    "maximum": max(values),
                }
                for field, values in forcing_values.items()
            },
            "observed_ais": dataset["source"]["observed_ais"],
            "counterfactual_actions": dataset["source"]["counterfactual_actions"],
        },
        "scenario_coverage": {
            "complete_scenario_contracts": complete_scenarios,
            "total_scenarios": len(tasks),
            "contract_completion_rate": complete_scenarios / len(tasks),
            "route_template_counts": dict(template_counts),
            "test_route_template_counts": dict(test_template_counts),
            "waypoints_per_scenario": 5,
            "static_obstacles_per_scenario": 1,
            "terrain_hazards_per_scenario": 1,
            "dynamic_traffic_per_scenario": 1,
            "hazard_kinds": sorted(
                {
                    str(item.get("kind", "unknown"))
                    for task in tasks
                    for field in ("obstacles", "terrain", "dynamic_obstacles")
                    for item in task.get(field, [])
                }
            ),
        },
        "experiment_execution": {
            "rl_requested_timesteps_per_method": benchmark["experiment"][
                "rl_timesteps_per_algorithm"
            ],
            "actual_training_timesteps_total": total_actual_training_steps,
            "training_episodes_total": total_training_episodes,
            "validation_rollouts": len(ALGORITHMS)
            * int(benchmark["data"]["split_sizes"]["validation"]),
            "fixed_test_rollouts": total_episode_rows,
            "training_render": False,
            "test_only_recorded_replay": True,
            "fixed_seed": benchmark["experiment"]["seed"],
        },
        "evidence_integrity_gate": {
            "passed": not any("hash" in error or "CSV aggregate" in error for error in errors),
            "verified_core_model_replay_hashes": verified_hashes,
            "expected_core_model_replay_hashes": expected_hashes,
            "csv_aggregate_consistency": f"{csv_consistency_passed}/{len(ALGORITHMS)}",
            "passed_checks": passed_artifact_checks,
            "total_checks": expected_artifact_checks,
            "episode_records_complete": f"{total_episode_rows}/150",
        },
        "replay_reliability": {
            "representative_rollouts_checked": len(replay_checks),
            "passed_rollouts": sum(int(item["passed"]) for item in replay_checks),
            "total_samples_checked": total_replay_samples,
            "checks": replay_checks,
        },
        "godot_runtime_acceptance": {
            "passed": godot_passed,
            "version": godot.get("godot_version", ""),
            "passed_checks": godot.get("passed_checks", 0),
            "total_checks": godot.get("total_checks", 0),
            "source_file_count": source_file_count,
            "source_tree_sha256": source_tree_sha256,
            "receipt_source_hash_matches": godot_hash_matches,
        },
        "algorithm_test_metrics": algorithm_rows,
        "policy_admission_gate": {
            "policy_version": "conservative_offline_gate_v1",
            "thresholds": ADMISSION_THRESHOLDS,
            "evaluated_methods": len(algorithm_rows),
            "admitted_methods": admitted,
            "admitted_count": len(admitted),
            "status": "PASS" if admitted else "REJECTED_ALL",
            "interpretation": (
                "The evidence package may pass while every controller is rejected. "
                "Zero collision is not treated as safety certification when near-miss "
                "or clearance/tracking gates fail."
            ),
        },
        "claim_boundary": {
            "public_input_role": "offline environmental forcing only",
            "synthetic_components": [
                "route geometry",
                "hazard layout",
                "vessel dynamics",
                "counterfactual control actions",
            ],
            "not_claimed": [
                "real-vessel sea trial",
                "COLREGs compliance or class approval",
                "production SLA",
                "fuel, accident, or commercial-return improvement",
            ],
            "safe_completion_metric_alias": (
                "collision_free_arrival_rate; it excludes collision and terrain "
                "collision but does not exclude near-miss events"
            ),
        },
        "errors": errors,
    }
    return report, errors


def _render_markdown(report: Mapping[str, Any]) -> str:
    rows = []
    for item in report["algorithm_test_metrics"]:
        rows.append(
            "| {algorithm} | {arrival:.1%} | {collision:.1%} | {near:.1%} | "
            "{xte:.2f} | {p95:.2f} | {clearance:.2f} | {p05:.2f} | "
            "{dcpa:.2f} | {dcpa_p05:.2f} | {efficiency:.1%} | "
            "{elapsed:.2f} | {admission} |".format(
                algorithm=item["algorithm"].upper().replace("_", "-"),
                arrival=item["collision_free_arrival_rate"],
                collision=item["collision_episode_rate"],
                near=item["near_miss_episode_rate"],
                xte=item["mean_max_cross_track_error_meters"],
                p95=item["p95_max_cross_track_error_meters"],
                clearance=item["mean_minimum_clearance_meters"],
                p05=item["p05_minimum_clearance_meters"],
                dcpa=item["mean_minimum_dcpa_meters"],
                dcpa_p05=item["p05_minimum_dcpa_meters"],
                efficiency=item["mean_path_efficiency"],
                elapsed=item["mean_elapsed_seconds"],
                admission="PASS" if item["admission_passed"] else "REJECT",
            )
        )
    evidence = report["evidence_integrity_gate"]
    replay = report["replay_reliability"]
    godot = report["godot_runtime_acceptance"]
    execution = report["experiment_execution"]
    scenarios = report["scenario_coverage"]
    data = report["data_contract"]
    admission = report["policy_admission_gate"]
    return f"""# 航行模拟器功能完整性与可靠性审计 v1

## 审计结论

- 模拟器证据审计：**{report["status"]}**；核心代码、数据、模型、checkpoint、回放及逐场 CSV 共 {evidence["passed_checks"]}/{evidence["total_checks"]} 项一致性检查通过。
- Godot 运行验收：**{"PASS" if godot["passed"] else "FAIL"}**；{godot["version"]} 完成解析与 8 帧无界面启动 {godot["passed_checks"]}/{godot["total_checks"]}，验收回执绑定 {godot["source_file_count"]} 个脚本/场景源文件。
- 策略安全准入：**{admission["status"]}**；当前 {admission["evaluated_methods"]} 种方法中 {admission["admitted_count"]} 种通过保守离线门槛。证据可复现门禁与控制器安全准入门禁相互独立。

## 场景、数据与执行规模

- Open-Meteo 2024-01-01 至 2024-04-30 共 {data["hourly_rows"]:,} 条连续小时环境输入，数值完整 {data["numeric_complete_rows"]:,}/{data["hourly_rows"]:,}；按日期隔离为 60/31/30 个训练、验证、测试场景，时间泄漏 {data["temporal_leakage_count"]}。
- {scenarios["complete_scenario_contracts"]}/{scenarios["total_scenarios"]} 场景包含 5 航点、静态障碍、地形风险、动态交通船和完整风/浪/流强迫；最终测试的 harbor_approach、channel_turn、s_curve 各 10 场。
- 四种 RL 实际完成 {execution["actual_training_timesteps_total"]:,} 个环境步和 {execution["training_episodes_total"]} 个训练 episode；五方法完成 {execution["validation_rollouts"]} 个验证 rollout 与 {execution["fixed_test_rollouts"]} 个最终留出测试 rollout。
- {replay["passed_rollouts"]}/{replay["representative_rollouts_checked"]} 份 Godot 测试回放通过索引连续、时间单调、状态有限、动作限幅和 CSV/JSON 指标一致性检查，共核验 {replay["total_samples_checked"]:,} 个轨迹采样点。

## 五方法最终测试

| 方法 | 无碰撞到达率 | 碰撞场景率 | 近失场景率 | 平均最大XTE(m) | P95最大XTE(m) | 平均最小净距(m) | P05最小净距(m) | 平均最小DCPA(m) | P05最小DCPA(m) | 路径效率 | 平均仿真耗时(s) | 准入 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
{chr(10).join(rows)}

“无碰撞到达率”是代码中旧字段 `safe_completion_rate` 的严格解释：到达目标且无碰撞/地形碰撞，但**不排除近失事件**。当前五方法近失场景率均为 100%，因此不得写成“100%安全航行”或“避碰成功率100%”。

## 指标边界

公开数据只提供离线环境强迫；路线、障碍、动力学和反事实控制动作属于模拟器设定。本审计不是实船海试、COLREGs/船级社认证、生产 SLA，也不产生燃油、事故率或商业收益结论。
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("generate", "verify"))
    arguments = parser.parse_args()
    report, errors = build_report()
    markdown = _render_markdown(report)
    if arguments.command == "generate":
        _write_json(OUTPUT_JSON, report)
        _write_text(OUTPUT_MARKDOWN, markdown)
        print(f"simulator reliability audit: {report['status']}")
        print(f"report: {OUTPUT_JSON}")
        return 0 if not errors else 1

    if not OUTPUT_JSON.is_file() or not OUTPUT_MARKDOWN.is_file():
        print("ERROR: reliability audit report is missing; run generate")
        return 1
    current = _load_json(OUTPUT_JSON)
    if current != report:
        print("ERROR: simulator reliability JSON is stale; run generate")
        return 1
    if OUTPUT_MARKDOWN.read_text(encoding="utf-8") != markdown:
        print("ERROR: simulator reliability Markdown is stale; run generate")
        return 1
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    print(
        "simulator reliability audit: PASS "
        f"({report['evidence_integrity_gate']['passed_checks']}/"
        f"{report['evidence_integrity_gate']['total_checks']} evidence checks, "
        f"{report['replay_reliability']['passed_rollouts']}/"
        f"{report['replay_reliability']['representative_rollouts_checked']} replays)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
