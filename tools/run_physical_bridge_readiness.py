#!/usr/bin/env python3
"""Generate or verify the fail-closed physical bridge/HIL readiness report."""

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

from tools.ship_assurance.physical_bridge import (
    build_physical_bridge_report,
    load_json,
    sha256_path,
)


MANIFEST = ROOT / "data/verification/physical_bridge_hil_manifest.template.json"
MAPPING = ROOT / "data/verification/simulator_standards_mapping_v1.json"
RUNTIME_PROFILE = ROOT / "data/verification/physical_hil_runtime_profile_v1.json"
WITNESS_TEMPLATE = ROOT / "data/verification/physical_hil_witnessed_test_csv_template.csv"
REPORT = ROOT / "reports/physical_bridge_readiness_v1.json"
MARKDOWN = ROOT / "reports/physical_bridge_readiness_v1.md"


def build_payload() -> dict[str, Any]:
    payload = build_physical_bridge_report(load_json(MANIFEST), load_json(MAPPING))
    payload["inputs_sha256"] = {
        str(MANIFEST.relative_to(ROOT)): sha256_path(MANIFEST),
        str(MAPPING.relative_to(ROOT)): sha256_path(MAPPING),
        str(RUNTIME_PROFILE.relative_to(ROOT)): sha256_path(RUNTIME_PROFILE),
        str(WITNESS_TEMPLATE.relative_to(ROOT)): sha256_path(WITNESS_TEMPLATE),
    }
    return payload


def markdown(payload: dict[str, Any]) -> str:
    evaluation = payload["evaluation"]
    mapping = evaluation["standards_mapping"]
    missing_hardware = evaluation["hardware_inventory"]["missing_roles"]
    missing_io = evaluation["io_contract"]["missing_channels"]
    target_runtime = evaluation["target_runtime_and_witnessed_tests"]
    return f"""# 物理驾驶台与硬件在环就绪检查 V1

**软件就绪门禁：** `{'PASS' if payload['software_readiness_gate_passed'] else 'FAIL'}`

**现场状态：** `{evaluation['status']}`

本报告证明检查器能够读取物理硬件清单、输入输出通道、安全联锁、时延/看门狗、校准/见证和标准映射，并在模板没有现场证据时保持阻断。它不证明已经连接物理驾驶台。

| 模块 | 当前结果 | 缺口 |
|---|---:|---|
| 物理硬件清单 | {'PASS' if evaluation['hardware_inventory']['passed'] else 'BLOCKED'} | {', '.join(missing_hardware) or '等待外部鉴定'} |
| 输入输出通道合同 | {'PASS' if evaluation['io_contract']['passed'] else 'BLOCKED'} | {', '.join(missing_io) or '等待外部鉴定'} |
| 独立安全联锁 | {'PASS' if evaluation['safety_interlocks']['passed'] else 'BLOCKED'} | {', '.join(evaluation['safety_interlocks']['failed_or_missing']) or '等待外部鉴定'} |
| 时延、抖动、最坏执行时间、时钟 | {'PASS' if evaluation['timing']['passed'] else 'BLOCKED'} | 需要目标硬件原始日志和见证 |
| 目标控制器、实时操作系统、真实 I/O 与双通道急停 | {'PASS' if target_runtime['passed'] else 'BLOCKED'} | 需要设备身份、构建版本、接线、掉线恢复和 12 项见证测试 |
| 现场、标定和签字证据 | {'PASS' if evaluation['site_and_test_evidence']['passed'] else 'BLOCKED'} | 需要现场填写与外部鉴定 |
| 标准追踪 | {mapping['requirement_count']} 项已路由 | {mapping['open_or_partial_count']} 项开放/部分/未评估 |

## 强制状态

- `physical_hil_verified=false`
- `site_delivery_ready=false`
- `stcw_approved=false`
- `dnv_certified=false`
- `production_authority=false`

## 复现

```bash
.venv/bin/python tools/run_physical_bridge_readiness.py verify
.venv/bin/python tools/run_physical_hil_runtime.py verify
.venv/bin/python -m unittest tests.test_physical_bridge_readiness -v
```
"""


def _stable(payload: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in payload.items() if key != "generated_at_utc"}


def generate() -> int:
    payload = build_payload()
    payload["generated_at_utc"] = datetime.now(timezone.utc).isoformat()
    REPORT.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    MARKDOWN.write_text(markdown(payload), encoding="utf-8")
    print(
        "physical bridge readiness: "
        + (
            "PASS (checker verified; physical/site/certification gates remain blocked)"
            if payload["software_readiness_gate_passed"]
            else "FAIL"
        )
    )
    return 0 if payload["software_readiness_gate_passed"] else 1


def verify() -> int:
    if not REPORT.is_file() or not MARKDOWN.is_file():
        print("physical bridge readiness: FAIL (report missing)")
        return 1
    recorded = load_json(REPORT)
    current = build_payload()
    if _stable(recorded) != current:
        print("physical bridge readiness: FAIL (stale or modified report)")
        return 1
    if any(recorded.get("claims", {}).get(key) is not False for key in (
        "physical_hil_verified",
        "site_delivery_ready",
        "stcw_approved",
        "dnv_certified",
        "production_authority",
    )):
        print("physical bridge readiness: FAIL (external boundary changed)")
        return 1
    print("physical bridge readiness: PASS (software gate only; external gates blocked)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("generate", "verify"))
    args = parser.parse_args()
    return generate() if args.mode == "generate" else verify()


if __name__ == "__main__":
    raise SystemExit(main())
