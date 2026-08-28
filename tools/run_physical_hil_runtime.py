#!/usr/bin/env python3
"""Generate or verify the physical-HIL runtime functional-smoke evidence."""

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

from tools.ship_assurance.physical_bridge import load_json, sha256_path
from tools.ship_assurance.physical_hil_runtime import run_physical_hil_functional_smoke


PROFILE = ROOT / "data/verification/physical_hil_runtime_profile_v1.json"
REPORT = ROOT / "reports/physical_hil_runtime_functional_smoke_v1.json"
INPUT_FILES = (
    PROFILE,
    ROOT / "tools/ship_assurance/physical_hil_runtime.py",
    ROOT / "tools/ship_assurance/hil.py",
    Path(__file__).resolve(),
)


def build_payload() -> dict[str, Any]:
    payload = run_physical_hil_functional_smoke(load_json(PROFILE))
    payload["inputs_sha256"] = {
        str(path.relative_to(ROOT)): sha256_path(path) for path in INPUT_FILES
    }
    return payload


def generate() -> int:
    payload = build_payload()
    payload["generated_at_utc"] = datetime.now(timezone.utc).isoformat()
    REPORT.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(
        "PHYSICAL_HIL_RUNTIME_SMOKE:%s:%d/%d"
        % (
            "PASS" if payload.get("passed") else "FAIL",
            sum(1 for passed in payload.get("checks", {}).values() if passed is True),
            len(payload.get("checks", {})),
        )
    )
    return 0 if payload.get("passed") else 1


def verify() -> int:
    if not REPORT.is_file():
        print("PHYSICAL_HIL_RUNTIME_SMOKE:FAIL:report missing")
        return 1
    payload = load_json(REPORT)
    input_hashes = payload.get("inputs_sha256", {})
    expected_hashes = {
        str(path.relative_to(ROOT)): sha256_path(path) for path in INPUT_FILES
    }
    checks = payload.get("checks", {})
    false_claims = all(
        payload.get(key) is False
        for key in (
            "target_controller_connected",
            "real_io_connected",
            "rtos_verified",
            "physical_hil_verified",
            "site_delivery_ready",
            "production_authority",
            "training_performed",
            "existing_model_modified",
        )
    )
    valid = (
        payload.get("schema_version") == "physical_hil_runtime_functional_smoke_v1"
        and payload.get("passed") is True
        and checks
        and all(value is True for value in checks.values())
        and input_hashes == expected_hashes
        and false_claims
    )
    print(
        "PHYSICAL_HIL_RUNTIME_SMOKE:%s:%d/%d"
        % (
            "PASS" if valid else "FAIL",
            sum(1 for passed in checks.values() if passed is True),
            len(checks),
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
