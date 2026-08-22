#!/usr/bin/env python3
"""Apply a utility-aware, fail-closed admission gate to Safety V3 results."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
from statistics import mean
from typing import Any, Mapping, Sequence


ROOT = Path(__file__).resolve().parents[1]
RAW_REPORT = ROOT / "reports/port_ops_benchmark_v2.json"
SUPERVISED_REPORT = ROOT / "reports/safety_supervisor_benchmark_v3.json"
OUTPUT = ROOT / "reports/safety_supervisor_utility_audit_v3.json"
MARKDOWN = ROOT / "reports/safety_supervisor_utility_audit_v3.md"
ALGORITHMS = (
    "ppo",
    "sac",
    "td3",
    "dqn",
    "a2c",
    "ddpg",
    "trpo",
    "los_pid",
    "lqr",
    "mpc",
)
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


def _load(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _write(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(value, encoding="utf-8")
    temporary.replace(path)


def _metric(value: Mapping[str, Any], key: str) -> float:
    return float(value.get(key, 0.0))


def _ordered_results(report: Mapping[str, Any], key: str) -> list[Mapping[str, Any]]:
    results = report.get(key, [])
    if not isinstance(results, Sequence):
        raise ValueError(f"{key} must be a sequence")
    by_algorithm = {str(item.get("algorithm", "")): item for item in results}
    if tuple(by_algorithm) != ALGORITHMS:
        raise ValueError(f"{key} algorithm inventory is incomplete or reordered")
    return [by_algorithm[algorithm] for algorithm in ALGORITHMS]


def _build_payload(generated_at: str) -> dict[str, Any]:
    raw_report = _load(RAW_REPORT)
    supervised_report = _load(SUPERVISED_REPORT)
    raw_results = _ordered_results(raw_report, "test_results")
    supervised_results = _ordered_results(supervised_report, "test_results")
    rows: list[dict[str, Any]] = []
    admitted: list[str] = []
    for raw, supervised in zip(raw_results, supervised_results):
        algorithm = str(raw["algorithm"])
        if supervised.get("algorithm") != algorithm:
            raise ValueError(f"result pairing changed for {algorithm}")
        before = raw["metrics"]
        after = supervised["metrics"]
        runtime = supervised["supervisor_metrics"]
        checks = {
            "arrival_threshold": _metric(after, "collision_free_arrival_rate")
            >= THRESHOLDS["minimum_collision_free_arrival_rate"],
            "port_compliance_threshold": _metric(
                after, "port_compliant_completion_rate"
            )
            >= THRESHOLDS["minimum_port_compliant_completion_rate"],
            "collision_threshold": _metric(after, "collision_episode_rate")
            <= THRESHOLDS["maximum_collision_episode_rate"],
            "grounding_threshold": _metric(after, "grounding_episode_rate")
            <= THRESHOLDS["maximum_grounding_episode_rate"],
            "colreg_proxy_threshold": _metric(
                after, "colreg_violation_episode_rate"
            )
            <= THRESHOLDS["maximum_colreg_violation_episode_rate"],
            "intervention_budget": _metric(runtime, "intervention_step_rate")
            <= THRESHOLDS["maximum_intervention_step_rate"],
            "fail_closed_budget": _metric(runtime, "fail_closed_episode_rate")
            <= THRESHOLDS["maximum_fail_closed_episode_rate"],
            "latency_budget": _metric(runtime, "decision_p95_ms")
            <= THRESHOLDS["maximum_decision_p95_ms"],
            "replan_latency_budget": _metric(runtime, "replan_p95_ms")
            <= THRESHOLDS["maximum_replan_p95_ms"],
            "arrival_not_worse_than_base": _metric(
                after, "collision_free_arrival_rate"
            )
            >= _metric(before, "collision_free_arrival_rate"),
            "port_compliance_not_worse_than_base": _metric(
                after, "port_compliant_completion_rate"
            )
            >= _metric(before, "port_compliant_completion_rate"),
            "collision_not_worse_than_base": _metric(
                after, "collision_episode_rate"
            )
            <= _metric(before, "collision_episode_rate"),
            "grounding_not_worse_than_base": _metric(
                after, "grounding_episode_rate"
            )
            <= _metric(before, "grounding_episode_rate"),
        }
        passed = all(checks.values())
        strategy_id = str(supervised.get("strategy_id", f"{algorithm}+safety_v3"))
        if passed:
            admitted.append(strategy_id)
        rows.append(
            {
                "algorithm": algorithm,
                "strategy_id": strategy_id,
                "base": {
                    key: _metric(before, key)
                    for key in (
                        "collision_free_arrival_rate",
                        "port_compliant_completion_rate",
                        "collision_episode_rate",
                        "grounding_episode_rate",
                        "colreg_violation_episode_rate",
                    )
                },
                "supervised": {
                    key: _metric(after, key)
                    for key in (
                        "collision_free_arrival_rate",
                        "port_compliant_completion_rate",
                        "collision_episode_rate",
                        "grounding_episode_rate",
                        "colreg_violation_episode_rate",
                    )
                },
                "runtime": {
                    key: _metric(runtime, key)
                    for key in (
                        "intervention_step_rate",
                        "fail_closed_episode_rate",
                        "decision_p95_ms",
                        "replan_p95_ms",
                    )
                },
                "checks": checks,
                "admitted": passed,
            }
        )
    macro = {}
    for key in (
        "collision_free_arrival_rate",
        "port_compliant_completion_rate",
        "collision_episode_rate",
        "grounding_episode_rate",
    ):
        macro[f"base_{key}"] = mean(row["base"][key] for row in rows)
        macro[f"supervised_{key}"] = mean(
            row["supervised"][key] for row in rows
        )
    portfolio_checks = {
        "benchmark_complete": bool(supervised_report.get("benchmark_complete", False)),
        "collision_not_worse": macro["supervised_collision_episode_rate"]
        <= macro["base_collision_episode_rate"],
        "grounding_not_worse": macro["supervised_grounding_episode_rate"]
        <= macro["base_grounding_episode_rate"],
        "arrival_not_worse": macro["supervised_collision_free_arrival_rate"]
        >= macro["base_collision_free_arrival_rate"],
        "port_compliance_not_worse": macro[
            "supervised_port_compliant_completion_rate"
        ]
        >= macro["base_port_compliant_completion_rate"],
        "intervention_budget": max(
            row["runtime"]["intervention_step_rate"] for row in rows
        )
        <= THRESHOLDS["maximum_intervention_step_rate"],
        "latency_budget": max(row["runtime"]["decision_p95_ms"] for row in rows)
        <= THRESHOLDS["maximum_decision_p95_ms"],
        "replan_latency_budget": max(
            row["runtime"]["replan_p95_ms"] for row in rows
        )
        <= THRESHOLDS["maximum_replan_p95_ms"],
        "at_least_one_strategy_admitted": bool(admitted),
    }
    passed = all(portfolio_checks.values())
    return {
        "schema_version": "ship_port_safety_utility_audit_v3",
        "generated_at": generated_at,
        "source_reports": {
            str(RAW_REPORT.relative_to(ROOT)): _sha256(RAW_REPORT),
            str(SUPERVISED_REPORT.relative_to(ROOT)): _sha256(SUPERVISED_REPORT),
        },
        "thresholds": THRESHOLDS,
        "methods": rows,
        "macro_metrics": macro,
        "portfolio_checks": portfolio_checks,
        "admitted_offline_strategies": admitted,
        "passed": passed,
        "deployment_decision": (
            "offline_research_candidate"
            if passed
            else "rejected_fail_closed"
        ),
        "live_control_authorized": False,
        "boundary": (
            "Utility-aware offline simulator admission only. A PASS would not be "
            "COLREGs certification, class approval, type approval, or live-vessel authority."
        ),
    }


def _render_markdown(report: Mapping[str, Any]) -> str:
    rows = []
    for item in report["methods"]:
        before = item["base"]
        after = item["supervised"]
        runtime = item["runtime"]
        rows.append(
            "| {algorithm} | {ba:.1%} | {sa:.1%} | {bc:.1%} | {sc:.1%} | "
            "{intervention:.1%} | {decision} |".format(
                algorithm=str(item["algorithm"]).upper().replace("_", "-"),
                ba=before["collision_free_arrival_rate"],
                sa=after["collision_free_arrival_rate"],
                bc=before["collision_episode_rate"],
                sc=after["collision_episode_rate"],
                intervention=runtime["intervention_step_rate"],
                decision="PASS" if item["admitted"] else "REJECT",
            )
        )
    checks = report["portfolio_checks"]
    return f"""# Safety V3 效用保真准入审计

本审计不只问“是否少撞”，还要求到达率、港口合规完成率不退化，并限制干预占比、fail-closed 频率与计算延迟。

| 基础策略 | 原到达 | 监督后到达 | 原碰撞 | 监督后碰撞 | 干预步占比 | 离线准入 |
|---|---:|---:|---:|---:|---:|---|
{chr(10).join(rows)}

- 完整性：{'PASS' if checks['benchmark_complete'] else 'FAIL'}
- 宏平均碰撞不退化：{'PASS' if checks['collision_not_worse'] else 'FAIL'}
- 宏平均搁浅不退化：{'PASS' if checks['grounding_not_worse'] else 'FAIL'}
- 宏平均到达率不退化：{'PASS' if checks['arrival_not_worse'] else 'FAIL'}
- 宏平均港口合规完成率不退化：{'PASS' if checks['port_compliance_not_worse'] else 'FAIL'}
- 干预预算：{'PASS' if checks['intervention_budget'] else 'FAIL'}
- 延迟预算：{'PASS' if checks['latency_budget'] else 'FAIL'}
- 真实重规划 P95 预算：{'PASS' if checks['replan_latency_budget'] else 'FAIL'}
- 最终决策：**{'PASS' if report['passed'] else 'REJECT / FAIL-CLOSED'}**
- 实船控制：**未授权**
"""


def generate() -> int:
    generated_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    report = _build_payload(generated_at)
    _write(OUTPUT, json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    _write(MARKDOWN, _render_markdown(report))
    print(f"utility-aware safety audit: {OUTPUT}")
    print(f"admission: {'PASS' if report['passed'] else 'REJECT / FAIL-CLOSED'}")
    return 0


def verify() -> int:
    report = _load(OUTPUT)
    expected = _build_payload(str(report.get("generated_at", "")))
    if report != expected:
        print("ERROR: utility-aware safety audit no longer matches source reports")
        return 1
    if report.get("live_control_authorized") is not False:
        print("ERROR: live-control boundary changed")
        return 1
    print(
        "utility-aware safety audit verify: PASS "
        f"(admission={report['deployment_decision']})"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("generate", "verify"))
    args = parser.parse_args()
    return generate() if args.command == "generate" else verify()


if __name__ == "__main__":
    raise SystemExit(main())
