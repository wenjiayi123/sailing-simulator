#!/usr/bin/env python3
"""Generate or verify the dynamics/COLREG/HIL/sea-trial assurance report."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import sys
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.ship_assurance.colreg import run_scenario_catalog
from tools.ship_assurance.dynamics import DynamicsConfig, run_dynamics_acceptance
from tools.ship_assurance.hil import run_hil_loopback_campaign
from tools.ship_assurance.environment import run_assured_environment_smoke
from tools.ship_assurance.sea_trial import run_sea_trial_dry_run


DYNAMICS = ROOT / "data/verification/vessel_dynamics_reference_v1.json"
COLREG = ROOT / "data/verification/colreg_encounter_catalog_v1.json"
HIL = ROOT / "data/verification/hil_loopback_profile_v1.json"
SEA_TRIAL = ROOT / "data/verification/sea_trial_protocol_v1.json"
REPORT = ROOT / "reports/maritime_assurance_v1.json"
MARKDOWN = ROOT / "reports/maritime_assurance_v1.md"
EVIDENCE_INPUTS = (
    DYNAMICS,
    COLREG,
    HIL,
    SEA_TRIAL,
    ROOT / "tools/ship_assurance/dynamics.py",
    ROOT / "tools/ship_assurance/__init__.py",
    ROOT / "tools/ship_assurance/environment.py",
    ROOT / "tools/ship_assurance/colreg.py",
    ROOT / "tools/ship_assurance/hil.py",
    ROOT / "tools/ship_assurance/sea_trial.py",
    ROOT / "tools/run_maritime_assurance.py",
    ROOT / "tests/test_maritime_assurance.py",
)


def _read(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path}")
    return value


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _comparison_differences(
    recorded: Any,
    current: Any,
    path: str = "$",
) -> list[str]:
    """Compare deterministic evidence with tight cross-platform float tolerance."""
    if isinstance(recorded, bool) or isinstance(current, bool):
        return [] if recorded is current else [path]
    if isinstance(recorded, (int, float)) and isinstance(current, (int, float)):
        equivalent = math.isclose(
            float(recorded),
            float(current),
            rel_tol=1e-12,
            abs_tol=1e-9,
        )
        return [] if equivalent else [path]
    if isinstance(recorded, dict) and isinstance(current, dict):
        differences = [f"{path}.keys"] if set(recorded) != set(current) else []
        for key in sorted(set(recorded) & set(current)):
            differences.extend(
                _comparison_differences(recorded[key], current[key], f"{path}.{key}")
            )
        return differences
    if isinstance(recorded, list) and isinstance(current, list):
        if len(recorded) != len(current):
            return [f"{path}.length"]
        differences: list[str] = []
        for index, (recorded_item, current_item) in enumerate(zip(recorded, current)):
            differences.extend(
                _comparison_differences(
                    recorded_item,
                    current_item,
                    f"{path}[{index}]",
                )
            )
        return differences
    return [] if recorded == current else [path]


def build_payload() -> dict[str, Any]:
    dynamics_input = _read(DYNAMICS)
    colreg_input = _read(COLREG)
    hil_input = _read(HIL)
    sea_trial_input = _read(SEA_TRIAL)
    dynamics = run_dynamics_acceptance(DynamicsConfig.from_mapping(dynamics_input))
    connected_environment = run_assured_environment_smoke(dynamics_input)
    colreg = run_scenario_catalog(colreg_input)
    hil = run_hil_loopback_campaign(hil_input)
    sea_trial = run_sea_trial_dry_run(sea_trial_input)
    software_passed = bool(
        dynamics["passed"]
        and connected_environment["passed"]
        and colreg["passed"]
        and hil["passed"]
        and sea_trial["evidence_completeness_refusal_gate_passed"]
    )
    return {
        "schema_version": "maritime_assurance_report_v1",
        "inputs_sha256": {
            str(path.relative_to(ROOT)): _sha256(path)
            for path in EVIDENCE_INPUTS
        },
        "overall": {
            "software_assurance_passed": software_passed,
            "production_readiness": "BLOCKED_EXTERNAL_EVIDENCE_REQUIRED",
            "production_authority": False,
        },
        "claim_matrix": {
            "three_dof_software_model_verified": bool(dynamics["passed"]),
            "three_dof_rl_environment_connected": bool(connected_environment["passed"]),
            "named_vessel_dynamics_calibrated": False,
            "colreg_scenario_regression_verified": bool(colreg["passed"]),
            "colreg_certified": False,
            "software_hil_loopback_verified": bool(hil["passed"]),
            "physical_hil_verified": False,
            "sea_trial_protocol_and_refusal_gate_verified": bool(sea_trial["evidence_completeness_refusal_gate_passed"]),
            "real_vessel_sea_trial_completed": False,
        },
        "dynamics": dynamics,
        "connected_environment": connected_environment,
        "colreg": colreg,
        "hil": hil,
        "sea_trial": sea_trial,
        "boundary": "PASS means the new software verification and anti-overclaim gates executed successfully. It does not mean vessel calibration, COLREG certification, physical HIL, sea trial or production authorization.",
    }


def _markdown(payload: dict[str, Any]) -> str:
    dynamics = payload["dynamics"]
    connected = payload["connected_environment"]
    colreg = payload["colreg"]
    hil = payload["hil"]
    sea = payload["sea_trial"]
    overall = "PASS" if payload["overall"]["software_assurance_passed"] else "FAIL"
    return f"""# 航海保障验证 V1 / Maritime Assurance Verification V1

**软件保障结论 / Software assurance:** `{overall}`

**生产就绪 / Production readiness:** `BLOCKED_EXTERNAL_EVIDENCE_REQUIRED`

本报告新增可执行的三自由度动力学验证、可追溯 COLREG 场景回归、HIL 软件回环与故障注入，以及海试证据防伪门禁。通过只代表软件层验证成功，不代表指定船舶标定、COLREG 认证、物理 HIL、实船海试或生产授权。

This report adds executable 3-DOF dynamics checks, traceable COLREG scenario regression, HIL software loopback/fault injection, and a sea-trial evidence-completeness refusal gate. A pass is software evidence only—not named-vessel calibration, COLREG certification, physical HIL, a real-vessel sea trial, or production authority.

| 模块 / Module | 已完成的软件证据 / Completed software evidence | 结果 / Result | 仍需外部证据 / External evidence still required |
|---|---|---:|---|
| 动力学 / Dynamics | 3-DOF surge-sway-yaw、附加质量、非线性阻尼、桨/舵执行器、RK4；{dynamics['passed_count']}/{dynamics['check_count']} checks；{connected['observation_size']}-D RL 环境连接 | {'PASS' if dynamics['passed'] and connected['passed'] else 'FAIL'} | 指定船舶辨识、zig-zag、回转圈、停船、装载工况标定；按新合同重新训练 |
| COLREG | {colreg['scenario_passed_count']}/{colreg['scenario_count']} scenarios；{colreg['action_case_passed_count']}/{colreg['action_case_count']} positive/negative action cases | {'PASS' if colreg['passed'] else 'FAIL'} | 多船/复杂水域验证、主管机关/船级/法律审查 |
| HIL | UDP JSON 完整性、NMEA 校验、时效/顺序/限幅、watchdog、drop/corrupt/replay/stale/range/session fault injection 和授权重启 | {'PASS' if hil['passed'] else 'FAIL'} | 目标控制器、真实传感/执行 I/O、独立急停、WCET/时钟、见证测试 |
| 海试 / Sea trial | 协议、遥测判据和“仿真指标再好也不得标记海试完成”的证据完整性拒绝门禁 | {'PASS' if sea['evidence_completeness_refusal_gate_passed'] else 'FAIL'} | 船舶、许可、船长/操作员、独立见证、校准、风险评估、物理 HIL、原始日志与签字记录 |

## 明确状态 / Explicit status

- `named_vessel_dynamics_calibrated=false`
- `colreg_certified=false`
- `physical_hil_verified=false`
- `real_vessel_sea_trial_completed=false`
- `production_authority=false`

## 可复现命令 / Reproduction

```bash
.venv/bin/python tools/run_maritime_assurance.py verify
.venv/bin/python -m unittest tests.test_maritime_assurance -v
```
"""


def generate() -> int:
    payload = build_payload()
    payload["generated_at_utc"] = datetime.now(timezone.utc).isoformat()
    REPORT.write_text(json.dumps(payload, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    MARKDOWN.write_text(_markdown(payload), encoding="utf-8")
    print(
        "maritime assurance: "
        + ("PASS (software only; external gates remain blocked)" if payload["overall"]["software_assurance_passed"] else "FAIL")
    )
    return 0 if payload["overall"]["software_assurance_passed"] else 1


def verify() -> int:
    if not REPORT.is_file() or not MARKDOWN.is_file():
        print("maritime assurance: FAIL (checked-in report is missing)")
        return 1
    recorded = _read(REPORT)
    current = build_payload()
    comparable = {
        key: value
        for key, value in recorded.items()
        if key != "generated_at_utc"
    }
    errors: list[str] = []
    differences = _comparison_differences(comparable, current)
    if differences:
        errors.append(
            "report content differs from a fresh deterministic execution "
            "outside the 1e-9 cross-platform numeric tolerance: "
            + ", ".join(differences[:8])
        )
    if recorded.get("claim_matrix", {}).get("physical_hil_verified") is not False:
        errors.append("physical HIL boundary changed")
    if recorded.get("claim_matrix", {}).get("real_vessel_sea_trial_completed") is not False:
        errors.append("sea-trial boundary changed")
    if recorded.get("overall", {}).get("production_authority") is not False:
        errors.append("production authority must remain false")
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        print("maritime assurance: FAIL")
        return 1
    print("maritime assurance: PASS (software only; physical HIL/sea trial remain blocked)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("generate", "verify"))
    args = parser.parse_args()
    return generate() if args.mode == "generate" else verify()


if __name__ == "__main__":
    raise SystemExit(main())
