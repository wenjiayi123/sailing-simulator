#!/usr/bin/env python3
"""Run the cargo collision suite, including its expected fail-closed cases."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def _run(godot: str, script: str, expected_code: int) -> str | None:
    result = subprocess.run(
        [godot, "--headless", "--path", str(ROOT), "--script", f"res://tools/{script}"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.stdout:
        print(result.stdout.rstrip())
    if result.stderr:
        print(result.stderr.rstrip(), file=sys.stderr)
    if result.returncode != expected_code:
        return f"{script}: expected exit {expected_code}, got {result.returncode}"
    return None


def _load_report(relative: str) -> dict:
    return json.loads((ROOT / relative).read_text(encoding="utf-8"))


def _verify_expected_rejections() -> list[str]:
    errors: list[str] = []
    geometry = _load_report("reports/large_rock_collision_audit_v1.json")
    expected_geometry = {
        "passed": False,
        "large_rock_count": 32,
        "trajectory_conflict_count": 0,
        "released_trajectory_replay_sweep_block_count": 2,
        "physics_guard_center_hits": 3,
        "ship_sized_sweep_blocking_hits": 3,
    }
    for key, expected in expected_geometry.items():
        if geometry.get(key) != expected:
            errors.append(
                f"large-rock geometry {key}: expected {expected!r}, got {geometry.get(key)!r}"
            )
    if geometry.get("waterline_guard_status", {}).get("guard_count") != 3:
        errors.append("large-rock geometry: expected 3 supplemental waterline guards")

    replay = _load_report("reports/cargo_circuit_full_replay_smoke_v1.json")
    results = replay.get("results", [])
    if replay.get("passed") is not False:
        errors.append("legacy cargo replay must remain fail-closed on the current rock map")
    if [item.get("name") for item in results] != ["SAC-S1", "RES-SAC-D2"]:
        errors.append("legacy cargo replay inventory changed")
    for item in results:
        if item.get("passed") is not False:
            errors.append(f"{item.get('name')}: legacy replay unexpectedly passed")
        if item.get("large_rock_replay_guard_blocks") != 1:
            errors.append(f"{item.get('name')}: expected one large-rock guard block")
        last_result = item.get("last_result", {})
        if last_result.get("success") is not False or "已阻止穿模回放" not in str(
            last_result.get("message", "")
        ):
            errors.append(f"{item.get('name')}: missing fail-closed collision receipt")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run cargo collision regression and verify expected safety rejection."
    )
    parser.add_argument("--godot", required=True)
    args = parser.parse_args()

    stages = [
        ("large_rock_training_contract_smoke.gd", 0),
        ("large_rock_collision_audit.gd", 1),
        ("cargo_circuit_godot_smoke.gd", 0),
        ("cargo_circuit_full_replay_smoke.gd", 1),
    ]
    errors = [
        error
        for script, expected_code in stages
        if (error := _run(args.godot, script, expected_code)) is not None
    ]
    errors.extend(_verify_expected_rejections())
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        print(f"CARGO_COLLISION_REGRESSION:FAIL:{len(stages) - len(errors)}/{len(stages)}")
        return 1
    print(
        "CARGO_COLLISION_REGRESSION:PASS:4/4 "
        "(legacy frozen replays rejected fail-closed)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
