#!/usr/bin/env python3
"""Generate or verify maritime cybersecurity functional assurance evidence."""

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

from tools.ship_assurance.maritime_cybersecurity import (
    build_maritime_cybersecurity_report,
    load_json,
    sha256_path,
)


PROFILE = ROOT / "data/verification/maritime_cybersecurity_profile_v1.json"
MANIFEST = ROOT / "data/verification/maritime_cybersecurity_acceptance_manifest.template.json"
REPORT = ROOT / "reports/maritime_cybersecurity_assurance_v1.json"
MARKDOWN = ROOT / "reports/maritime_cybersecurity_assurance_v1.md"
INPUTS = (
    PROFILE,
    MANIFEST,
    ROOT / "data/verification/bridge_secure_boot_manifest_v1.json",
    ROOT / "data/verification/cyber_range_signed_update_payload_v1.json",
    ROOT / "data/verification/cyber_range_signed_update_signature_v1.json",
    ROOT / "data/verification/cyber_range_update_public_key_v1.pem",
    ROOT / "scripts/security/ship_bridge_cybersecurity_suite.gd",
    ROOT / "scripts/ui/ship_bridge_cybersecurity_panel.gd",
    ROOT / "tools/godot_bridge_cybersecurity_smoke.gd",
    ROOT / "tests/test_maritime_cybersecurity.py",
)


def build_payload() -> dict[str, Any]:
    payload = build_maritime_cybersecurity_report(
        ROOT, load_json(PROFILE), load_json(MANIFEST)
    )
    payload["inputs_sha256"] = {
        str(path.relative_to(ROOT)): sha256_path(path) for path in INPUTS
    }
    return payload


def markdown(payload: dict[str, Any]) -> str:
    profile = payload["profile_evaluation"]
    runtime = payload["runtime_acceptance"]
    boot = payload["software_boot_integrity"]
    external = payload["external_acceptance_gate"]
    return f"""# 船舶网络安全功能可信度报告 V1

**功能状态：** `{payload['status']}`

本层面向强化学习航行模拟器，提供离线船桥网络安全训练与控制验证。它不会转发网络报文到执行器，也不会修改船舶运动模型、观测空间、动作空间、奖励函数或任何既有策略。

| 项目 | 当前证据 |
|---|---:|
| 网络安全分区 | {len(profile['zone_ids'])}/7 |
| 许可数据流 | {profile['allowed_flow_count']}/8 |
| Godot 运行验收 | {runtime['passed_count']}/{runtime['check_count']} |
| 软件启动哈希清单 | {boot['file_count']} 文件 |
| 既有策略哈希 | {payload['preserved_policy_inventory']['policy_count']}/10 |
| 功能控制层 | {'PASS' if payload['functional_cyber_controls_complete'] else 'FAIL'} |
| 生产网络安全认可 | BLOCKED |

## 已实现

- 七区默认拒绝网络策略、八条显式许可流、禁止外部交换区直接控制安全关键区。
- 四类训练身份、角色权限、会话时限、三次失败锁定和随机数重放检测。
- RSA PKCS#1 v1.5 / SHA-256 离线签名更新验证；合法包只进入隔离区，不安装；篡改包被阻断并告警；私钥不在仓库。
- 七文件软件哈希启动清单；明确不是硬件安全启动、可信平台模块或度量启动证据。
- 八类入侵检测规则、SHA-256 链式审计、告警确认、人工确认恢复点。
- 八类攻击用例：错误口令、重放、越权、越区直控、篡改更新、启动哈希异常、审计篡改、未确认恢复。

## 强制阻断

- `production_network_segmentation_verified=false`
- `hardware_secure_boot_verified=false`
- `production_signed_update_verified=false`
- `production_ids_verified=false`
- `disaster_recovery_field_verified=false`
- `independent_penetration_test_completed=false`
- `class_or_flag_cyber_approval=false`
- `production_authority=false`

外部证据模板当前为 `{external['status']}`。生产网络实建图、身份源和多因素认证、硬件信任根、签名密钥仪式、安全运营中心链路、离线备份/裸机恢复、恢复时间目标/恢复点目标、独立渗透测试复测及船旗国或船级社决定必须由外部主体提交并逐文件校验；项目自身声明不能解锁。

## 复现

```bash
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-bridge-cybersecurity-smoke
.venv/bin/python tools/run_maritime_cybersecurity_assurance.py verify
.venv/bin/python -m unittest tests.test_maritime_cybersecurity -v
```
"""


def _stable(payload: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in payload.items() if key != "generated_at_utc"}


def generate() -> int:
    payload = build_payload()
    payload["generated_at_utc"] = datetime.now(timezone.utc).isoformat()
    REPORT.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    MARKDOWN.write_text(markdown(payload), encoding="utf-8")
    passed = payload["functional_cyber_controls_complete"]
    print(
        "MARITIME_CYBERSECURITY_ASSURANCE:"
        f"{'PASS' if passed else 'FAIL'}:"
        f"{sum(payload['checks'].values())}/{len(payload['checks'])}:"
        "production=false:training=false"
    )
    return 0 if passed else 1


def verify() -> int:
    if not REPORT.is_file() or not MARKDOWN.is_file():
        print("MARITIME_CYBERSECURITY_ASSURANCE:FAIL:checked-in evidence missing")
        return 1
    recorded = load_json(REPORT)
    current = build_payload()
    if _stable(recorded) != current:
        print("MARITIME_CYBERSECURITY_ASSURANCE:FAIL:stale or modified report")
        return 1
    if not recorded.get("functional_cyber_controls_complete"):
        print("MARITIME_CYBERSECURITY_ASSURANCE:FAIL:functional controls incomplete")
        return 1
    if any(value is not False for value in recorded.get("claims", {}).values()):
        print("MARITIME_CYBERSECURITY_ASSURANCE:FAIL:claim boundary changed")
        return 1
    print("MARITIME_CYBERSECURITY_ASSURANCE:PASS:external assurance remains blocked")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("generate", "verify"))
    args = parser.parse_args()
    return generate() if args.mode == "generate" else verify()


if __name__ == "__main__":
    raise SystemExit(main())
