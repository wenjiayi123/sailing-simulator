#!/usr/bin/env python3
"""Generate or verify port production-integration assurance evidence."""

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

from tools.ship_assurance.port_production_integration import (
    build_port_production_integration_report,
    load_json,
    sha256_path,
)


PROFILE = ROOT / "data/verification/port_production_integration_profile_v1.json"
MANIFEST = ROOT / "data/verification/port_production_site_acceptance_manifest.template.json"
REPORT = ROOT / "reports/port_production_integration_assurance_v1.json"
MARKDOWN = ROOT / "reports/port_production_integration_assurance_v1.md"
INPUTS = (
    PROFILE,
    MANIFEST,
    ROOT / "scripts/integration/ship_port_production_gateway.gd",
    ROOT / "scripts/ui/ship_port_integration_panel.gd",
    ROOT / "tools/godot_port_production_integration_smoke.gd",
    ROOT / "tests/test_port_production_integration.py",
)


def build_payload() -> dict[str, Any]:
    payload = build_port_production_integration_report(
        ROOT, load_json(PROFILE), load_json(MANIFEST)
    )
    payload["inputs_sha256"] = {
        str(path.relative_to(ROOT)): sha256_path(path) for path in INPUTS
    }
    return payload


def markdown(payload: dict[str, Any]) -> str:
    profile = payload["profile_evaluation"]
    runtime = payload["runtime_acceptance"]
    gate = payload["site_acceptance_gate"]
    return f"""# 港口生产联动功能保障报告 V1

**功能状态：** `{payload['status']}`

本层为强化学习航行模拟器提供船舶交通服务、码头操作系统、引航、拖轮、泊位资源和官方航海通告六类可替换接口。当前运行证据来自签名离线夹具，不冒充真实港口连接。

| 项目 | 当前证据 |
|---|---:|
| 适配器 | {profile['adapter_count']}/6 |
| Godot 运行验收 | {runtime['passed_count']}/{runtime['check_count']} |
| 既有策略哈希 | {payload['preserved_policy_inventory']['policy_count']}/10 |
| 功能联动闭环 | {'PASS' if payload['functional_port_integration_complete'] else 'FAIL'} |
| 真实港口站点准入 | BLOCKED |

## 已实现

- 每适配器独立身份、HMAC-SHA256、载荷 SHA-256、单调序号、唯一快照和防重放。
- 必填字段、单位、时间基准、未来时间、时效窗口和官方通告有效期检查。
- 船舶交通服务、码头操作系统、引航、拖轮、泊位、通告六类数据的权威范围分离。
- 断链和过期自动撤销数据源权威，进入显式降级模式并要求人工协调。
- 引航和拖轮协调请求必须人工确认、类型在白名单内；调度回执形成哈希审计链。
- 仅持久化摘要、载荷哈希和来源链；不持久化业务载荷正文。
- `external_dispatch_performed=false`、`mapped_to_vessel_actuation=false`。

## 外部门禁

当前站点模板为 `{gate['status']}`。真实上线必须提交六方接口授权、数据映射和单位、签署服务级别协议、时效/时钟/断链测试、身份与证书、网络分区、密钥轮换、防篡改审计、至少 30 天且 1,000 场的影子运行、零关键偏差、回滚演练、操作员验收以及港口/VTS/码头/引航/拖轮/船旗或船级和法律责任批准。

布尔值不能绕过逐文件 SHA-256 证据。完整材料也只进入独立站点决定，不由模拟器自行签发生产授权。

## 复现

```bash
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-port-production-integration-smoke
.venv/bin/python tools/run_port_production_integration_assurance.py verify
.venv/bin/python -m unittest tests.test_port_production_integration -v
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
    passed = payload["functional_port_integration_complete"]
    print(
        "PORT_PRODUCTION_INTEGRATION_ASSURANCE:"
        f"{'PASS' if passed else 'FAIL'}:"
        f"{sum(payload['checks'].values())}/{len(payload['checks'])}:"
        "live=false:dispatch=false"
    )
    return 0 if passed else 1


def verify() -> int:
    if not REPORT.is_file() or not MARKDOWN.is_file():
        print("PORT_PRODUCTION_INTEGRATION_ASSURANCE:FAIL:checked-in evidence missing")
        return 1
    recorded = load_json(REPORT)
    current = build_payload()
    if _stable(recorded) != current:
        print("PORT_PRODUCTION_INTEGRATION_ASSURANCE:FAIL:stale or modified report")
        return 1
    if not recorded.get("functional_port_integration_complete"):
        print("PORT_PRODUCTION_INTEGRATION_ASSURANCE:FAIL:functional integration incomplete")
        return 1
    if any(value is not False for value in recorded.get("claims", {}).values()):
        print("PORT_PRODUCTION_INTEGRATION_ASSURANCE:FAIL:claim boundary changed")
        return 1
    print("PORT_PRODUCTION_INTEGRATION_ASSURANCE:PASS:external site acceptance remains blocked")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("generate", "verify"))
    args = parser.parse_args()
    return generate() if args.mode == "generate" else verify()


if __name__ == "__main__":
    raise SystemExit(main())
