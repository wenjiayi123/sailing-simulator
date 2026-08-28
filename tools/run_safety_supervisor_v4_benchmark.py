#!/usr/bin/env python3
"""Freeze, finalize, and verify the additive V4 safety benchmark."""

from __future__ import annotations

import argparse
from concurrent.futures import ProcessPoolExecutor, as_completed
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import sys
from typing import Any, Mapping, Sequence

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools import run_safety_supervisor_benchmark as v3  # noqa: E402
from tools.ship_rl.environment import (  # noqa: E402
    dataset_fingerprint,
    experiment_fingerprint,
    load_experiment,
)
from tools.ship_rl.port_ops_trainer import ALGORITHMS  # noqa: E402
from tools.ship_rl.safety_supervisor_v4 import (  # noqa: E402
    UtilityPreservingSafetyConfig,
    UtilityPreservingSafetySupervisor,
)


CONFIG = v3.CONFIG
SUPERVISOR_CONFIG = ROOT / "data/rl/port_ops_safety_supervisor_v4.json"
V2_PREPARED = v3.V2_PREPARED
V2_FINAL = v3.V2_FINAL
PREPARED = ROOT / "reports/safety_supervisor_benchmark_v4_prepared.json"
FINAL = ROOT / "reports/safety_supervisor_benchmark_v4.json"
MARKDOWN = ROOT / "reports/safety_supervisor_benchmark_v4.md"
ARTIFACT_ROOT = ROOT / "reports/artifacts/safety_supervisor_v4"
DEFAULT_MAX_STEPS = 1_600
DEFAULT_WORKERS = 4
THRESHOLDS = {
    "minimum_collision_free_arrival_rate": 0.80,
    "minimum_port_compliant_completion_rate": 0.75,
    "maximum_collision_episode_rate": 0.10,
    "maximum_grounding_episode_rate": 0.05,
    "maximum_colreg_violation_episode_rate": 0.10,
    "maximum_intervention_step_rate": 0.20,
    "maximum_fail_closed_episode_rate": 0.05,
    "maximum_decision_p95_ms": 250.0,
    "maximum_replan_p95_ms": 250.0,
}
EVIDENCE_FILES = (
    "data/rl/long_beach_ais_port_ops_benchmark_v2.json",
    "data/rl/long_beach_ais_port_ops_experiment_v2.json",
    "data/rl/port_ops_safety_supervisor_v4.json",
    "reports/port_ops_benchmark_v2_prepared.json",
    "reports/port_ops_benchmark_v2.json",
    "tools/ship_rl/safety_supervisor_v4.py",
    "tools/run_safety_supervisor_v4_benchmark.py",
)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _load(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


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


def _profile() -> UtilityPreservingSafetyConfig:
    return UtilityPreservingSafetyConfig.from_mapping(_load(SUPERVISOR_CONFIG))


def _evidence_hashes() -> dict[str, str]:
    return {value: _sha256(ROOT / value) for value in EVIDENCE_FILES}


def _evaluate_algorithm(
    artifact: Mapping[str, Any],
    split: str,
    max_steps: int,
) -> dict[str, Any]:
    # Reuse the frozen V3 episode recorder and aggregation contract while
    # replacing only the supervisor implementation and output namespace.
    v3.ModelPredictiveSafetySupervisor = UtilityPreservingSafetySupervisor
    v3._profile = _profile
    v3.ARTIFACT_ROOT = ARTIFACT_ROOT
    result = v3._evaluate_algorithm(artifact, split, max_steps)
    algorithm = str(result["algorithm"])
    result["strategy_id"] = f"{algorithm}+safety_v4"
    trajectory_path = ROOT / str(result["trajectory"])
    trajectory = _load(trajectory_path)
    trajectory.update(
        {
            "format": f"ship_port_policy_{split}_safety_v4",
            "source": (
                "deterministic_base_policy_with_utility_preserving_"
                "safety_supervisor_v4"
            ),
            "strategy_id": f"{algorithm}+safety_v4",
            "playback_mode": f"recorded_safety_supervised_{split}_rollout",
        }
    )
    _write_json(trajectory_path, trajectory)
    result["trajectory_sha256"] = _sha256(trajectory_path)
    return result


def _evaluate_all(
    split: str,
    max_steps: int,
    workers: int,
) -> list[dict[str, Any]]:
    artifacts = _load(V2_PREPARED)["artifacts"]
    by_algorithm: dict[str, dict[str, Any]] = {}
    with ProcessPoolExecutor(max_workers=max(1, workers)) as executor:
        futures = {
            executor.submit(_evaluate_algorithm, item, split, max_steps): str(
                item["algorithm"]
            )
            for item in artifacts
        }
        for future in as_completed(futures):
            algorithm = futures[future]
            by_algorithm[algorithm] = future.result()
            print(f"{split} {algorithm}: V4 rollout complete", flush=True)
    return [by_algorithm[algorithm] for algorithm in ALGORITHMS]


def _raw_by_algorithm() -> dict[str, Mapping[str, Any]]:
    return {
        str(item["algorithm"]): item
        for item in _load(V2_FINAL)["test_results"]
    }


def _admission_checks(
    result: Mapping[str, Any],
    raw: Mapping[str, Any] | None,
) -> dict[str, bool]:
    metrics = result["metrics"]
    runtime = result["supervisor_metrics"]
    checks = {
        "collision_free_arrival_rate": (
            float(metrics["collision_free_arrival_rate"])
            >= THRESHOLDS["minimum_collision_free_arrival_rate"]
        ),
        "port_compliant_completion_rate": (
            float(metrics["port_compliant_completion_rate"])
            >= THRESHOLDS["minimum_port_compliant_completion_rate"]
        ),
        "collision_episode_rate": (
            float(metrics["collision_episode_rate"])
            <= THRESHOLDS["maximum_collision_episode_rate"]
        ),
        "grounding_episode_rate": (
            float(metrics["grounding_episode_rate"])
            <= THRESHOLDS["maximum_grounding_episode_rate"]
        ),
        "colreg_violation_episode_rate": (
            float(metrics["colreg_violation_episode_rate"])
            <= THRESHOLDS["maximum_colreg_violation_episode_rate"]
        ),
        "intervention_step_rate": (
            float(runtime["intervention_step_rate"])
            <= THRESHOLDS["maximum_intervention_step_rate"]
        ),
        "fail_closed_episode_rate": (
            float(runtime["fail_closed_episode_rate"])
            <= THRESHOLDS["maximum_fail_closed_episode_rate"]
        ),
        "decision_p95_ms": (
            float(runtime["decision_p95_ms"])
            <= THRESHOLDS["maximum_decision_p95_ms"]
        ),
        "replan_p95_ms": (
            float(runtime["replan_p95_ms"])
            <= THRESHOLDS["maximum_replan_p95_ms"]
        ),
    }
    if raw is not None:
        raw_metrics = raw["metrics"]
        checks.update(
            {
                "arrival_not_worse_than_base": (
                    float(metrics["collision_free_arrival_rate"])
                    >= float(raw_metrics["collision_free_arrival_rate"])
                ),
                "port_completion_not_worse_than_base": (
                    float(metrics["port_compliant_completion_rate"])
                    >= float(raw_metrics["port_compliant_completion_rate"])
                ),
                "collision_not_worse_than_base": (
                    float(metrics["collision_episode_rate"])
                    <= float(raw_metrics["collision_episode_rate"])
                ),
                "grounding_not_worse_than_base": (
                    float(metrics["grounding_episode_rate"])
                    <= float(raw_metrics["grounding_episode_rate"])
                ),
            }
        )
    return checks


def _admission_report(
    results: Sequence[Mapping[str, Any]],
    raw: Mapping[str, Mapping[str, Any]] | None,
) -> dict[str, Any]:
    strategies = []
    for result in results:
        algorithm = str(result["algorithm"])
        checks = _admission_checks(
            result,
            raw.get(algorithm) if raw is not None else None,
        )
        strategies.append(
            {
                "algorithm": algorithm,
                "strategy_id": str(result["strategy_id"]),
                "checks": checks,
                "passed": all(checks.values()),
            }
        )
    admitted = [
        str(item["strategy_id"]) for item in strategies if item["passed"]
    ]
    return {
        "thresholds": THRESHOLDS,
        "strategies": strategies,
        "admitted_offline_strategies": admitted,
        "admitted_count": len(admitted),
        "passed": bool(admitted),
    }


def _verify_base_artifacts(
    artifacts: Sequence[Mapping[str, Any]],
) -> list[str]:
    return v3._verify_base_artifacts(artifacts)


def prepare(max_steps: int, workers: int) -> int:
    v2_prepared = _load(V2_PREPARED)
    errors = _verify_base_artifacts(v2_prepared["artifacts"])
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    config, dataset, _dataset_path = load_experiment(CONFIG)
    validation = _evaluate_all("validation", max_steps, workers)
    admission = _admission_report(validation, None)
    payload = {
        "schema_version": "ship_port_safety_supervisor_benchmark_v4",
        "benchmark_id": "long_beach_ais_port_ops_safety_supervisor_v4",
        "prepared_at": datetime.now(timezone.utc).replace(
            microsecond=0
        ).isoformat(),
        "test_split_accessed": False,
        "selection_policy": (
            "V4 source, profile, thresholds, ten base policies, and validation "
            "evidence are frozen before any V4 test evaluation"
        ),
        "software": {
            "python": platform.python_version(),
            "platform": platform.platform(),
            "numpy": np.__version__,
        },
        "evidence_sha256": _evidence_hashes(),
        "data": {
            "split_sizes": {
                key: len(value) for key, value in dataset["splits"].items()
            },
            "dataset_sha256": dataset_fingerprint(dataset),
            "experiment_sha256": experiment_fingerprint(config),
        },
        "experiment": {
            "seed": v3.SEED,
            "max_steps_per_episode": max_steps,
            "algorithms": list(ALGORITHMS),
            "strategy_inventory": [
                f"{algorithm}+safety_v4" for algorithm in ALGORITHMS
            ],
            "base_strategy_count": len(ALGORITHMS),
            "additive_strategy_count": len(ALGORITHMS),
            "safety_profile": _profile().to_dict(),
            "live_control_authorized": False,
        },
        "base_artifacts": v2_prepared["artifacts"],
        "validation_results": validation,
        "validation_admission": admission,
    }
    _write_json(PREPARED, payload)
    print(f"prepared report: {PREPARED}")
    print(
        "validation admitted: "
        + str(admission["admitted_count"])
        + "/"
        + str(len(ALGORITHMS))
    )
    return 0


def _verify_prepared(value: Mapping[str, Any]) -> list[str]:
    errors: list[str] = []
    if value.get("test_split_accessed") is not False:
        errors.append("prepared V4 report must precede test access")
    if value.get("evidence_sha256") != _evidence_hashes():
        errors.append("V4 evidence source hash changed after preparation")
    errors.extend(_verify_base_artifacts(value.get("base_artifacts", [])))
    validation = value.get("validation_results", [])
    if [item.get("algorithm") for item in validation] != list(ALGORITHMS):
        errors.append("V4 validation strategy inventory is incomplete")
    for item in validation:
        trajectory = ROOT / str(item.get("trajectory", ""))
        if (
            not trajectory.is_file()
            or _sha256(trajectory) != item.get("trajectory_sha256")
        ):
            errors.append(
                f"V4 validation trajectory changed: {item.get('algorithm')}"
            )
    return errors


def finalize(workers: int) -> int:
    prepared = _load(PREPARED)
    errors = _verify_prepared(prepared)
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    test_results = _evaluate_all(
        "test",
        int(prepared["experiment"]["max_steps_per_episode"]),
        workers,
    )
    expected = int(prepared["data"]["split_sizes"]["test"])
    complete = bool(
        [item.get("algorithm") for item in test_results] == list(ALGORITHMS)
        and all(item.get("dataset_split") == "test" for item in test_results)
        and sum(int(item["episodes"]) for item in test_results)
        == expected * len(ALGORITHMS)
    )
    raw = _raw_by_algorithm()
    admission = _admission_report(test_results, raw)
    impact = v3._portfolio_impact(test_results)
    report = {
        **prepared,
        "generated_at": datetime.now(timezone.utc).replace(
            microsecond=0
        ).isoformat(),
        "test_split_accessed": True,
        "test_access_policy": (
            "V4 test was accessed once after source, profile, thresholds, base "
            "policy hashes, and validation evidence were frozen"
        ),
        "test_results": test_results,
        "benchmark_complete": complete,
        "portfolio_impact": impact,
        "test_admission": admission,
        "safety_effectiveness_gate": bool(complete and admission["passed"]),
        "admitted_offline_strategies": admission[
            "admitted_offline_strategies"
        ],
        "live_control_authorized": False,
        "production_authority": False,
        "deployment_decision": (
            "offline_research_only_fail_closed_for_live_control"
        ),
        "limitations": [
            "Historical AIS traffic is replayed in an offline counterfactual simulator.",
            "The COLREG signal is a declared engineering proxy, not certification.",
            "No live VTS/TOS, official in-force ENC, sensor freshness, HIL, sea trial, or authority approval is present.",
            "Rare escape-plan searches may exceed the P95 budget even when aggregate P95 passes; latency tails remain review evidence.",
        ],
    }
    _write_json(FINAL, report)
    _write_text(MARKDOWN, _render_markdown(report))
    print(f"final report: {FINAL}")
    print(
        "V4 admission: "
        + ("PASS" if admission["passed"] else "REJECT / FAIL-CLOSED")
        + f" ({admission['admitted_count']}/{len(ALGORITHMS)})"
    )
    return 0 if complete else 1


def verify(deep: bool, workers: int) -> int:
    report = _load(FINAL)
    prepared_view = {**report, "test_split_accessed": False}
    errors = _verify_prepared(prepared_view)
    tests = report.get("test_results", [])
    if [item.get("algorithm") for item in tests] != list(ALGORITHMS):
        errors.append("V4 test strategy inventory is incomplete")
    for item in tests:
        trajectory = ROOT / str(item.get("trajectory", ""))
        if (
            not trajectory.is_file()
            or _sha256(trajectory) != item.get("trajectory_sha256")
        ):
            errors.append(
                f"V4 test trajectory changed: {item.get('algorithm')}"
            )
    if deep and not errors:
        current = _evaluate_all(
            "test",
            int(report["experiment"]["max_steps_per_episode"]),
            workers,
        )
        for actual, expected in zip(current, tests):
            if actual["metrics"] != expected["metrics"]:
                errors.append(
                    f"V4 deep metrics changed: {expected.get('algorithm')}"
                )
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    print(
        "safety supervisor V4 benchmark verify: PASS "
        + ("(deep)" if deep else "(hash)")
    )
    return 0


def _render_markdown(report: Mapping[str, Any]) -> str:
    rows = []
    admitted = set(report["admitted_offline_strategies"])
    for item in report["test_results"]:
        metrics = item["metrics"]
        runtime = item["supervisor_metrics"]
        rows.append(
            "| {name} | {arrival:.1%} | {port:.1%} | {collision:.1%} | "
            "{grounding:.1%} | {intervention:.1%} | {fail_closed:.1%} | "
            "{latency:.1f} | {status} |".format(
                name=str(item["algorithm"]).upper().replace("_", "-"),
                arrival=metrics["collision_free_arrival_rate"],
                port=metrics["port_compliant_completion_rate"],
                collision=metrics["collision_episode_rate"],
                grounding=metrics["grounding_episode_rate"],
                intervention=runtime["intervention_step_rate"],
                fail_closed=runtime["fail_closed_episode_rate"],
                latency=runtime["replan_p95_ms"],
                status=(
                    "ADMITTED"
                    if item["strategy_id"] in admitted
                    else "REJECTED"
                ),
            )
        )
    return f"""# 长滩港十策略运行时安全监督基准 V4

生成时间：{report['generated_at']}

V4 保留 V2 基础策略、检查点与原始失败证据，以增量方式加入效用保真单步投影、运营边界前视和小型短序列可达性规划。参数在 validation 后冻结，随后一次性评估独立 test。

| 基础策略 | 无碰撞到达 | 港口合规 | 碰撞 | 搁浅 | 干预步 | Fail-closed 回合 | 重规划 P95(ms) | 准入 |
|---|---:|---:|---:|---:|---:|---:|---:|---|
{chr(10).join(rows)}

- 十策略完整性：{'PASS' if report['benchmark_complete'] else 'FAIL'}。
- 通过离线准入：{report['test_admission']['admitted_count']}/{len(ALGORITHMS)}。
- 安全有效性：{'PASS' if report['safety_effectiveness_gate'] else 'REJECT / FAIL-CLOSED'}。
- 实船控制授权：无；`production_authority=false`。

## 边界

该监督层是离线仿真中的软件安全投影，不是《国际海上避碰规则》认证、船级社认可、型式认可或实船控制授权。历史 AIS 交通下的动作是反事实仿真；缺少实时 VTS/TOS、官方在航 ENC、传感器时效、硬件联锁、硬件在环、海试和主管机关批准，因此 live control 始终 fail-closed。
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("--max-steps", type=int, default=DEFAULT_MAX_STEPS)
    prepare_parser.add_argument("--workers", type=int, default=DEFAULT_WORKERS)
    finalize_parser = subparsers.add_parser("finalize")
    finalize_parser.add_argument("--workers", type=int, default=DEFAULT_WORKERS)
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--deep", action="store_true")
    verify_parser.add_argument("--workers", type=int, default=DEFAULT_WORKERS)
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    if arguments.command == "prepare":
        return prepare(arguments.max_steps, arguments.workers)
    if arguments.command == "finalize":
        return finalize(arguments.workers)
    return verify(arguments.deep, arguments.workers)


if __name__ == "__main__":
    raise SystemExit(main())
