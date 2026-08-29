#!/usr/bin/env python3
"""Generate or verify full-mission software bridge assurance evidence."""

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

from tools.ship_assurance.full_mission_bridge import (
    build_full_mission_bridge_report,
    load_json,
    sha256_path,
)


PROFILE = ROOT / "data/verification/full_mission_bridge_profile_v1.json"
MANIFEST = ROOT / "data/verification/full_mission_bridge_acceptance_manifest.template.json"
REPORT = ROOT / "reports/full_mission_bridge_assurance_v1.json"
MARKDOWN = ROOT / "reports/full_mission_bridge_assurance_v1.md"
INPUTS = (
    PROFILE,
    MANIFEST,
    ROOT / "scripts/navigation/ship_gmdss_communications_suite.gd",
    ROOT / "scripts/navigation/ship_full_mission_bridge_suite.gd",
    ROOT / "scripts/training/ship_advanced_mission_realism_controller.gd",
    ROOT / "scripts/ui/ship_full_mission_bridge_panel.gd",
    ROOT / "tools/godot_full_mission_bridge_smoke.gd",
    ROOT / "tests/test_full_mission_bridge.py",
)


def build_payload() -> dict[str, Any]:
    payload = build_full_mission_bridge_report(
        ROOT, load_json(PROFILE), load_json(MANIFEST)
    )
    payload["inputs_sha256"] = {
        str(path.relative_to(ROOT)): sha256_path(path) for path in INPUTS
    }
    return payload


def markdown(payload: dict[str, Any]) -> str:
    profile = payload["profile_evaluation"]
    runtime = payload["runtime_acceptance"]
    external = payload["external_acceptance_gate"]
    return f"""# 全任务软件船桥可信度报告 V1

**功能状态：** `{payload['status']}`

本层面向强化学习航行模拟和教员训练，把现有雷达/自动雷达标绘仪、电子海图显示与信息系统、综合驾驶信息、执行控制、多岗位驾驶台资源管理、教员时间线和复盘，与新增的全球海上遇险与安全系统/甚高频/数字选择性呼叫程序训练及八扇区软件全向视景连接起来。

| 项目 | 当前证据 |
|---|---:|
| 船桥设备域 | {profile['domain_count']}/10 |
| Godot 运行验收 | {runtime['passed_count']}/{runtime['check_count']} |
| 既有策略哈希 | {payload['preserved_policy_inventory']['policy_count']}/10 |
| 软件全任务船桥 | {'PASS' if payload['functional_software_bridge_complete'] else 'FAIL'} |
| 物理全任务船桥 | BLOCKED |
| 教员资质与课程认可 | BLOCKED |

## 已实现的任务链

- 雷达量测、自动目标捕获、最近会遇距离/时间、杂波与设备故障。
- 电子海图航线监控、安全等深线、危险报警与确认。
- 遇险报警双步骤保护、紧急/安全/常规数字选择性呼叫、16 频道话音跟进、确认与取消；所有记录均为训练回执，真实射频发送恒为零。
- 自动舵目标首向/速度、推进限幅与反馈、人工立即接管和急停边界。
- 九类岗位、多学员本机网络、复诵、质疑和驾驶台资源管理检查。
- 八个 45° 软件视景扇区及 360° 扫描回执；只改变镜头，不改变船舶状态转移。
- 教员确定性故障时间线、报告和复盘链路。
- 五个高级任务在原三自由度模型上叠加有界浅水、岸壁和机械故障强制；基础模型未被替换，现有策略与强化学习接口未修改。

## 强制阻断

- `physical_full_mission_bridge_verified=false`
- `type_approved_bridge_equipment=false`
- `real_radio_transmission=false`
- `instructor_qualification_verified=false`
- `approved_training_course=false`
- `production_authority=false`

外部证据模板当前状态为 `{external['status']}`。只有物理投影视场/时延、非回环多学员网络、真实设备、官方航海产品、教员资质、课程认可和独立验收材料全部提交并通过哈希校验后，才可进入独立鉴定；项目自身不能签发认可。

## 复现

```bash
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-full-mission-bridge-smoke
.venv/bin/python tools/run_full_mission_bridge_assurance.py verify
.venv/bin/python -m unittest tests.test_full_mission_bridge -v
```
"""


def _stable(payload: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in payload.items() if key != "generated_at_utc"}


def generate() -> int:
    payload = build_payload()
    payload["generated_at_utc"] = datetime.now(timezone.utc).isoformat()
    REPORT.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    MARKDOWN.write_text(markdown(payload), encoding="utf-8")
    passed = payload["functional_software_bridge_complete"]
    print(
        "FULL_MISSION_BRIDGE_ASSURANCE:"
        f"{'PASS' if passed else 'FAIL'}:"
        f"{sum(payload['checks'].values())}/{len(payload['checks'])}:"
        "physical=false:training=false"
    )
    return 0 if passed else 1


def verify() -> int:
    if not REPORT.is_file() or not MARKDOWN.is_file():
        print("FULL_MISSION_BRIDGE_ASSURANCE:FAIL:checked-in evidence missing")
        return 1
    recorded = load_json(REPORT)
    current = build_payload()
    if _stable(recorded) != current:
        print("FULL_MISSION_BRIDGE_ASSURANCE:FAIL:stale or modified report")
        return 1
    if not recorded.get("functional_software_bridge_complete"):
        print("FULL_MISSION_BRIDGE_ASSURANCE:FAIL:functional bridge incomplete")
        return 1
    if any(value is not False for value in recorded.get("claims", {}).values()):
        print("FULL_MISSION_BRIDGE_ASSURANCE:FAIL:claim boundary changed")
        return 1
    print("FULL_MISSION_BRIDGE_ASSURANCE:PASS:external acceptance remains blocked")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("generate", "verify"))
    args = parser.parse_args()
    return generate() if args.mode == "generate" else verify()


if __name__ == "__main__":
    raise SystemExit(main())
