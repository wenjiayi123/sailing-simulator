#!/usr/bin/env python3
"""Generate or verify additive complex-COLREG simulator evidence."""

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

from tools.ship_assurance.colreg import run_scenario_catalog
from tools.ship_assurance.colreg_complex import run_complex_colreg_catalog


LEGACY_CATALOG = ROOT / "data/verification/colreg_encounter_catalog_v1.json"
COMPLEX_CATALOG = ROOT / "data/verification/colreg_complex_scenario_catalog_v2.json"
LOCAL_RULES = ROOT / "data/verification/local_navigation_rules_template_v1.json"
REPORT = ROOT / "reports/colreg_complex_assurance_v2.json"
MARKDOWN = ROOT / "reports/colreg_complex_assurance_v2.md"
INPUTS = (
    LEGACY_CATALOG,
    COMPLEX_CATALOG,
    LOCAL_RULES,
    ROOT / "tools/ship_assurance/colreg.py",
    ROOT / "tools/ship_assurance/colreg_complex.py",
    ROOT / "tools/run_colreg_complex_assurance.py",
    ROOT / "tests/test_colreg_complex.py",
)


def _read(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path}")
    return value


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build_payload() -> dict[str, Any]:
    legacy = run_scenario_catalog(_read(LEGACY_CATALOG))
    local_rules = _read(LOCAL_RULES)
    complex_result = run_complex_colreg_catalog(_read(COMPLEX_CATALOG), local_rules)
    passed = bool(
        legacy.get("passed") is True
        and legacy.get("scenario_count") == 6
        and legacy.get("action_case_count", 0) >= 11
        and complex_result.get("passed") is True
        and complex_result.get("scenario_count", 0) >= 16
        and complex_result.get("case_count", 0) >= 45
        and complex_result.get("legacy_v1_replaced") is False
        and complex_result.get("colreg_certified") is False
        and complex_result.get("production_authority") is False
    )
    return {
        "schema_version": "colreg_complex_assurance_v2",
        "inputs_sha256": {
            str(path.relative_to(ROOT)): _sha256(path)
            for path in INPUTS
        },
        "functional_assurance_passed": passed,
        "legacy_v1_regression": {
            "passed": legacy.get("passed") is True,
            "scenario_count": legacy.get("scenario_count"),
            "action_case_count": legacy.get("action_case_count"),
            "legacy_v1_replaced": False,
        },
        "complex_assurance": complex_result,
        "claim_matrix": {
            "multi_ship_duty_graph_verified": "multi_ship" in complex_result.get("covered_capabilities", []),
            "narrow_channel_scenarios_verified": "narrow_channel" in complex_result.get("covered_capabilities", []),
            "traffic_separation_scenarios_verified": "traffic_separation_scheme" in complex_result.get("covered_capabilities", []),
            "special_status_priority_verified": all(
                value in complex_result.get("covered_capabilities", [])
                for value in (
                    "restricted_in_ability_to_manoeuvre",
                    "not_under_command",
                    "fishing_vessel",
                )
            ),
            "lights_shapes_sound_regression_verified": all(
                value in complex_result.get("covered_capabilities", [])
                for value in ("lights_and_shapes", "sound_signals")
            ),
            "complex_restricted_visibility_verified": "complex_restricted_visibility" in complex_result.get("covered_capabilities", []),
            "simulator_local_rule_template_verified": "local_rules" in complex_result.get("covered_capabilities", []),
            "official_local_rules_connected": local_rules.get("official_authorization_verified") is True,
            "colreg_certified": False,
            "production_authority": False,
        },
        "source_boundary": {
            "local_rule_source_class": local_rules.get("source_class"),
            "official_authorization_verified": local_rules.get("official_authorization_verified") is True,
            "training_performed": False,
            "existing_policy_modified": False,
            "ship_motion_model_modified": False,
        },
        "boundary": "PASS is deterministic simulator-function evidence. It is not a complete legal interpretation, official local-rule feed, COLREG certification, type/class approval or authority for live-vessel control.",
    }


def _markdown(payload: dict[str, Any]) -> str:
    result = payload["complex_assurance"]
    legacy = payload["legacy_v1_regression"]
    rows = []
    for item in result["results"]:
        assessment = item["assessment"]
        rows.append(
            "| {scenario} | {targets} | {duty} | {cases}/{total} | {status} |".format(
                scenario=item["scenario_id"],
                targets=assessment["target_count"],
                duty=assessment["primary_duty"],
                cases=sum(int(case["matched"]) for case in item["cases"]),
                total=len(item["cases"]),
                status="PASS" if item["passed"] else "FAIL",
            )
        )
    status = "PASS" if payload["functional_assurance_passed"] else "FAIL"
    return f"""# 复杂避碰规则功能保障 V2 / Complex COLREG Functional Assurance V2

**功能结论：** `{status}`

- 原 V1 基线：{legacy['scenario_count']} 个双船场景、{legacy['action_case_count']} 个动作案例，`legacy_v1_replaced=false`。
- V2 复杂层：{result['scenario_passed_count']}/{result['scenario_count']} 场景，{result['case_matched_count']}/{result['case_count']} 正反动作/信号案例。
- 覆盖：多船责任图、狭水道、分道通航、操纵能力受限船、失去控制船、捕鱼船、灯号号型、能见度不良声号、复杂能见度和地方规则模板。
- 未训练任何策略，未修改船舶运动模型或现有策略。

| 场景 | 目标数 | 主要责任 | 案例匹配 | 结果 |
|---|---:|---|---:|---:|
{chr(10).join(rows)}

## 边界

地方规则文件是 `SIMULATOR_AUTHORED_EXERCISE_RULES`，`official_authorization_verified=false`。本报告通过只证明确定性仿真功能和回归门禁，不构成法律解释、官方地方规则接入、《国际海上避碰规则》认证、型式/船级认可或实船控制授权。

## 复现

```bash
.venv/bin/python tools/run_colreg_complex_assurance.py verify
.venv/bin/python -m unittest tests.test_colreg_complex -v
```
"""


def generate() -> int:
    payload = build_payload()
    payload["generated_at_utc"] = datetime.now(timezone.utc).isoformat()
    REPORT.write_text(json.dumps(payload, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    MARKDOWN.write_text(_markdown(payload), encoding="utf-8")
    result = payload["complex_assurance"]
    print(
        "COLREG_COMPLEX:{status}:{scenarios}/{total}:{cases}/{case_total}:legacy_v1={legacy}".format(
            status="PASS" if payload["functional_assurance_passed"] else "FAIL",
            scenarios=result["scenario_passed_count"],
            total=result["scenario_count"],
            cases=result["case_matched_count"],
            case_total=result["case_count"],
            legacy=payload["legacy_v1_regression"]["passed"],
        )
    )
    return 0 if payload["functional_assurance_passed"] else 1


def verify() -> int:
    if not REPORT.is_file() or not MARKDOWN.is_file():
        print("COLREG_COMPLEX:FAIL:checked-in report missing")
        return 1
    recorded = _read(REPORT)
    current = build_payload()
    comparable = {key: value for key, value in recorded.items() if key != "generated_at_utc"}
    errors: list[str] = []
    if comparable != current:
        errors.append("checked-in report differs from deterministic execution")
    if recorded.get("claim_matrix", {}).get("official_local_rules_connected") is not False:
        errors.append("official local-rule boundary changed")
    if recorded.get("claim_matrix", {}).get("colreg_certified") is not False:
        errors.append("COLREG certification boundary changed")
    if recorded.get("claim_matrix", {}).get("production_authority") is not False:
        errors.append("production authority boundary changed")
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        print("COLREG_COMPLEX:FAIL")
        return 1
    result = recorded["complex_assurance"]
    print(f"COLREG_COMPLEX:PASS:{result['scenario_count']} scenarios:{result['case_count']} cases")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("generate", "verify"))
    args = parser.parse_args()
    return generate() if args.mode == "generate" else verify()


if __name__ == "__main__":
    raise SystemExit(main())
