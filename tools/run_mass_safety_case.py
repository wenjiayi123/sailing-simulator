#!/usr/bin/env python3
"""Generate or verify the executable MASS simulator safety-case assessment."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.ship_assurance.safety_case import assess_safety_case, load_json, sha256_path


CASE_PATH = ROOT / "data/verification/mass_safety_case_v1.json"
ACCEPTANCE_PATH = ROOT / "data/verification/mass_safety_case_acceptance_manifest.template.json"
REPORT_PATH = ROOT / "reports/mass_safety_case_assessment_v1.json"
MARKDOWN_PATH = ROOT / "reports/mass_safety_case_assessment_v1.md"
INPUT_PATHS = (
    CASE_PATH,
    ACCEPTANCE_PATH,
    ROOT / "tools/ship_assurance/safety_case.py",
    Path(__file__).resolve(),
)


def build_payload() -> dict[str, Any]:
    payload = assess_safety_case(
        load_json(CASE_PATH),
        load_json(ACCEPTANCE_PATH),
        root=ROOT,
    )
    payload["inputs_sha256"] = {
        str(path.relative_to(ROOT)): sha256_path(path) for path in INPUT_PATHS
    }
    return payload


def _markdown(payload: dict[str, Any]) -> str:
    sections = payload["section_results"]
    acceptance = payload["acceptance_evidence"]
    missing = acceptance.get("missing_or_invalid", [])
    return f"""# RL 航行模拟器安全案例评估 V1

**功能安全案例：** `{'PASS' if payload['functional_safety_case_complete'] else 'FAIL'}`

**外部准入状态：** `{payload['status']}`

本报告把运行设计域、危险日志、控制措施、最小风险状态、故障树、远程控制中心、人员责任、法规适用性路由和证据注册表连接为可机读安全案例。通过只适用于模拟器研究功能，不是主管机关、船级或型式认可结论。

| 安全案例模块 | 结果 | 数量/状态 |
|---|---:|---|
| 运行设计域 | {'PASS' if sections['operational_design_domain']['passed'] else 'FAIL'} | {sections['operational_design_domain']['dimension_count']} 个维度 |
| 危险日志与控制 | {'PASS' if sections['hazard_log']['passed'] else 'FAIL'} | {sections['hazard_log']['hazard_count']} 项危险 / {sections['hazard_log']['control_count']} 项控制 |
| 最小风险状态 | {'PASS' if sections['minimum_risk_conditions']['passed'] else 'FAIL'} | {sections['minimum_risk_conditions']['mrc_count']} 项 |
| 故障树 | {'PASS' if sections['fault_trees']['passed'] else 'FAIL'} | {sections['fault_trees']['tree_count']} 棵，覆盖全部危险 |
| 远程控制中心合同 | {'PASS' if sections['remote_control_centre']['passed'] else 'FAIL'} | 现场授权 false |
| 人员责任矩阵 | {'PASS' if sections['responsibility_model']['passed'] else 'FAIL'} | {sections['responsibility_model']['role_count']} 角色 / {sections['responsibility_model']['activity_count']} 项职责 |
| 法规适用性路由 | {'PASS' if sections['regulatory_applicability']['passed'] else 'FAIL'} | {sections['regulatory_applicability']['instrument_count']} 类，均待外部决定 |
| 证据注册表 | {'PASS' if sections['evidence_registry']['passed'] else 'FAIL'} | {sections['evidence_registry']['evidence_count']} 项哈希绑定证据 |
| 运行时 ODD 越界映射 | {'PASS' if payload['runtime_odd_monitor_smoke']['passed'] else 'FAIL'} | {payload['runtime_odd_monitor_smoke']['breach_case_count']} 个越界案例均映射 MRC |

## 外部证据缺口

当前清单缺失 {len(missing)} 项现场、责任、法规决定、独立审查和支持证据。前十项为：

{chr(10).join(f'- `{item}`' for item in missing[:10])}

## 强制状态

- `independent_review_complete=false`
- `flag_state_approval=false`
- `coastal_state_approval=false`
- `class_approval=false`
- `type_approval=false`
- `mass_safety_certificate=false`
- `sea_trial_completed=false`
- `production_authority=false`

## 复现

```bash
.venv/bin/python tools/run_mass_safety_case.py verify
.venv/bin/python -m unittest tests.test_mass_safety_case -v
```
"""


def _stable(payload: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in payload.items() if key != "generated_at_utc"}


def generate() -> int:
    payload = build_payload()
    payload["generated_at_utc"] = datetime.now(timezone.utc).isoformat()
    REPORT_PATH.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    MARKDOWN_PATH.write_text(_markdown(payload), encoding="utf-8")
    print(
        "MASS_SAFETY_CASE:%s:%d/%d:%s"
        % (
            "PASS" if payload.get("functional_safety_case_complete") else "FAIL",
            sum(1 for value in payload.get("checks", {}).values() if value is True),
            len(payload.get("checks", {})),
            payload.get("status", "UNKNOWN"),
        )
    )
    return 0 if payload.get("functional_safety_case_complete") else 1


def verify() -> int:
    if not REPORT_PATH.is_file() or not MARKDOWN_PATH.is_file():
        print("MASS_SAFETY_CASE:FAIL:report missing")
        return 1
    recorded = load_json(REPORT_PATH)
    current = build_payload()
    valid = (
        _stable(recorded) == current
        and recorded.get("functional_safety_case_complete") is True
        and recorded.get("status") == "FUNCTIONAL_SAFETY_CASE_COMPLETE_EXTERNAL_ACCEPTANCE_BLOCKED"
        and all(
            recorded.get(key) is False
            for key in (
                "independent_review_complete",
                "flag_state_approval",
                "coastal_state_approval",
                "class_approval",
                "type_approval",
                "mass_safety_certificate",
                "sea_trial_completed",
                "production_authority",
                "training_performed",
                "existing_model_modified",
            )
        )
    )
    checks = recorded.get("checks", {})
    print(
        "MASS_SAFETY_CASE:%s:%d/%d:%s"
        % (
            "PASS" if valid else "FAIL",
            sum(1 for value in checks.values() if value is True),
            len(checks),
            recorded.get("status", "UNKNOWN"),
        )
    )
    return 0 if valid else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("generate", "verify"))
    args = parser.parse_args()
    return generate() if args.mode == "generate" else verify()


if __name__ == "__main__":
    raise SystemExit(main())
