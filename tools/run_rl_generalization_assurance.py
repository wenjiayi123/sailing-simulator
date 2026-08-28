#!/usr/bin/env python3
"""Generate or verify the fail-closed RL generalization assurance package."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.ship_rl.generalization_assurance import assess_generalization_campaign


CAMPAIGN = ROOT / "data/verification/rl_generalization_campaign_v1.json"
RESULTS_TEMPLATE = ROOT / "data/verification/rl_generalization_results_manifest.template.json"
BASE_DATASET = ROOT / "data/rl/long_beach_ais_port_ops_benchmark_v2.json"
PRESERVED_POLICY_REPORT = ROOT / "reports/port_ops_benchmark_v2.json"
REPORT = ROOT / "reports/rl_generalization_assurance_v1.json"
MARKDOWN = ROOT / "reports/rl_generalization_assurance_v1.md"
PLAN = ROOT / "reports/rl_generalization_evaluation_plan_v1.json"
INPUTS = (
    CAMPAIGN,
    RESULTS_TEMPLATE,
    BASE_DATASET,
    PRESERVED_POLICY_REPORT,
    ROOT / "tools/ship_rl/generalization_environment.py",
    ROOT / "tools/ship_rl/generalization_assurance.py",
    ROOT / "tools/run_rl_generalization_assurance.py",
    ROOT / "tests/test_rl_generalization_assurance.py",
)


def _read(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path}")
    return value


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build_payload() -> dict[str, Any]:
    payload = assess_generalization_campaign(
        _read(CAMPAIGN),
        _read(RESULTS_TEMPLATE),
        root=ROOT,
    )
    payload["inputs_sha256"] = {
        str(path.relative_to(ROOT)): _sha256(path) for path in INPUTS
    }
    return payload


def _markdown(payload: dict[str, Any]) -> str:
    domains = payload["domain_summary"]
    plan = payload["evaluation_plan"]
    gate = payload["results_evidence_gate"]
    smoke = payload["functional_smoke"]
    rows = []
    for item in smoke["results"]:
        rows.append(
            "| {fixture} | {port} | {season} | {vessel} | {traffic} | {receipts} | {status} |".format(
                fixture=item["fixture_id"],
                port=item["port_domain_id"],
                season=item["season_domain_id"],
                vessel=item["vessel_domain_id"],
                traffic=item["traffic_domain_id"],
                receipts=item["interaction_receipt_count"],
                status="PASS" if item["passed"] else "FAIL",
            )
        )
    return f"""# RL 泛化与训练可信度保障 V1

**功能框架：** `{'PASS' if payload['functional_framework_complete'] else 'FAIL'}`

**泛化/收敛证据：** `{payload['status']}`

本轮没有训练策略。完成的是训练前必须冻结的多域实验、域外测试、消融、压力和影子运行功能，并用拒绝门禁防止把短烟测或合成场景写成“已收敛、已证明泛化”。

| 维度 | 数量 | 真实观测证据 | 当前解释 |
|---|---:|---:|---|
| 港口原型 | {domains['declared_port_archetype_count']} | {domains['real_observed_port_count']} | 其余 {domains['synthetic_port_domain_count']} 个仅为仿真功能域 |
| 季节 | {domains['declared_season_count']} | {domains['real_observed_season_count']} | 其余 {domains['synthetic_season_overlay_count']} 个为环境叠加 |
| 船型族 | {domains['vessel_family_count']} | 0 个指定船舶标定 | 使用现有环境的船长/船宽/吃水上下文 |
| 随机种子 | {domains['random_seed_count']} | 尚未执行训练 | 未来必须逐种子报告与保留失败种子 |
| 响应式交通行为 | {domains['interactive_traffic_behavior_count']} | 仿真交通 | 有界响应和哈希链回执 |

## 冻结评测计划

- 基础多域矩阵：{plan['base_matrix_cell_count']} 个单元；
- 配对消融：{plan['ablation_pair_count']} 对；
- 压力测试：{plan['stress_cell_count']} 个单元；
- 域外测试：{plan['ood_cell_count']} 个单元；
- 合计：{plan['total_planned_cell_count']} 个计划单元，`test_results_accessed=false`。

## 功能烟测

| 功能夹具 | 港口域 | 季节域 | 船型域 | 交通行为 | 回执数 | 结果 |
|---|---|---|---|---|---:|---:|
{chr(10).join(rows)}

全部夹具继续使用原 45 维观测、原动作合同和原本船运动模型；响应式交通只改变明确标记的仿真目标船，并生成连续 SHA-256 回执。只读影子回执烟测产生 {payload['shadow_receipt_smoke']['recommendation_count']} 条建议、0 次下发。

## 当前拒绝门禁

- `training_performed=false`
- `convergence_demonstrated={str(gate['convergence_demonstrated']).lower()}`
- `real_multi_port_generalization_demonstrated={str(gate['real_multi_port_generalization_demonstrated']).lower()}`
- `real_multi_season_generalization_demonstrated={str(gate['real_multi_season_generalization_demonstrated']).lower()}`
- `ood_acceptance_passed={str(gate['ood_acceptance_passed']).lower()}`
- `shadow_operation_completed={str(gate['shadow_operation_completed']).lower()}`
- `production_authority=false`

真实泛化结论仍需至少 3 个真实港口、4 个真实季节、4 个船型族、5 个随机种子、每种子不少于 100,000 步、逐种子曲线、95% 分层配对 bootstrap 区间、全部域外/消融/压力单元，以及不少于 30 天/1,000 场只读影子运行和独立审查。

## 复现

```bash
.venv/bin/python tools/run_rl_generalization_assurance.py verify
.venv/bin/python -m unittest tests.test_rl_generalization_assurance -v
```
"""


def generate() -> int:
    payload = build_payload()
    plan = payload.pop("evaluation_plan")
    PLAN.write_text(json.dumps(plan, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    payload["evaluation_plan"] = {
        key: value for key, value in plan.items() if key != "cells"
    }
    payload["evaluation_plan"]["path"] = str(PLAN.relative_to(ROOT))
    payload["evaluation_plan"]["file_sha256"] = _sha256(PLAN)
    payload["generated_at_utc"] = datetime.now(timezone.utc).isoformat()
    REPORT.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    MARKDOWN.write_text(_markdown(payload), encoding="utf-8")
    print(
        "RL_GENERALIZATION:{status}:{checks}/{total}:plan={plan}:training=false".format(
            status="PASS" if payload["functional_framework_complete"] else "FAIL",
            checks=sum(int(value) for value in payload["checks"].values()),
            total=len(payload["checks"]),
            plan=payload["evaluation_plan"]["total_planned_cell_count"],
        )
    )
    return 0 if payload["functional_framework_complete"] else 1


def _stable_report(payload: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in payload.items() if key != "generated_at_utc"}


def verify() -> int:
    if not REPORT.is_file() or not MARKDOWN.is_file() or not PLAN.is_file():
        print("RL_GENERALIZATION:FAIL:checked-in evidence missing")
        return 1
    expected = build_payload()
    expected_plan = expected.pop("evaluation_plan")
    recorded_plan = _read(PLAN)
    expected["evaluation_plan"] = {
        key: value for key, value in expected_plan.items() if key != "cells"
    }
    expected["evaluation_plan"]["path"] = str(PLAN.relative_to(ROOT))
    expected["evaluation_plan"]["file_sha256"] = _sha256(PLAN)
    recorded = _read(REPORT)
    errors: list[str] = []
    if recorded_plan != expected_plan:
        errors.append("evaluation plan differs from deterministic expansion")
    if _stable_report(recorded) != expected:
        errors.append("assurance report differs from deterministic assessment")
    claims = recorded.get("claims", {})
    for name in (
        "training_performed",
        "convergence_demonstrated",
        "real_multi_port_generalization_demonstrated",
        "real_multi_season_generalization_demonstrated",
        "ood_acceptance_passed",
        "shadow_operation_completed",
        "existing_policy_modified",
        "ship_motion_model_modified",
        "production_authority",
    ):
        if claims.get(name) is not False:
            errors.append(f"fail-closed claim changed: {name}")
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        print("RL_GENERALIZATION:FAIL")
        return 1
    print(
        f"RL_GENERALIZATION:PASS:{recorded['evaluation_plan']['total_planned_cell_count']} planned cells:training=false"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("generate", "verify"))
    args = parser.parse_args()
    return generate() if args.mode == "generate" else verify()


if __name__ == "__main__":
    raise SystemExit(main())
