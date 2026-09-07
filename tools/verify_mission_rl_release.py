#!/usr/bin/env python3
"""Verify every published scene policy and the native UI acceptance receipts."""
from __future__ import annotations

import json
from pathlib import Path

from audit_mission_rl import ROOT, candidate_entry, sha


def verify() -> list[str]:
    errors: list[str] = []
    catalog = json.loads((ROOT / "data/rl/mission_rl_catalog_v1.json").read_text())
    profile = json.loads((ROOT / "data/ports/default_port_profile.json").read_text())
    scenes = catalog.get("scenarios", {})
    expected = {item["scenario_key"] for item in profile["navigation_missions"]}
    if set(scenes) != expected:
        errors.append("scene catalog does not cover every navigation task")
    if catalog.get("production_authority") is not False:
        errors.append("scene catalog production boundary is not closed")
    for key, entry in scenes.items():
        actual = candidate_entry(ROOT / entry["receipt_path"])
        admitted = bool(entry.get("live_switch_admitted"))
        if actual["live_switch_admitted"] != admitted:
            errors.append(f"{key}: catalog differs from frozen training/native evidence")
        if not admitted:
            continue
        path = ROOT / entry["actor_path"].removeprefix("res://")
        if not path.is_file() or sha(path) != entry["actor_sha256"]:
            errors.append(f"{key}: missing or altered deployable actor")
            continue
        actor = json.loads(path.read_text())
        if actor.get("scenario") != key or actor.get("live_switch_admitted") is not True:
            errors.append(f"{key}: deployable actor belongs to another/unqualified task")
        # Admission exports may add metadata; network parameters remain frozen.
        frozen = json.loads((ROOT / entry["receipt_path"]).with_name("actor.json").read_text())
        for field in ("layers", "terminal_layers", "action_low", "action_high", "observation_contract"):
            if actor.get(field) != frozen.get(field):
                errors.append(f"{key}: exported {field} differs from validated actor")
    for name in ("acceptance_02.json", "rendered_acceptance_01.json"):
        path = ROOT / "reports/artifacts/mission_rl_ui_v1" / name
        receipt = json.loads(path.read_text())
        if receipt.get("passed") is not True or not receipt.get("checks"):
            errors.append(f"{name}: native UI acceptance did not pass")
        if not all(row.get("passed") is True for row in receipt.get("checks", [])):
            errors.append(f"{name}: native UI acceptance contains failures")
        if receipt.get("ui_source_sha256") != sha(ROOT / "scripts/ui/ship_navigation_planning_panel.gd"):
            errors.append(f"{name}: native UI receipt is stale")
        if receipt.get("production_authority") is not False:
            errors.append(f"{name}: production boundary is not closed")
    return errors


if __name__ == "__main__":
    try:
        failures = verify()
    except (OSError, ValueError, KeyError, TypeError) as exc:
        failures = [str(exc)]
    for failure in failures:
        print("ERROR:", failure)
    print("MISSION_RL_RELEASE:" + ("FAIL" if failures else "PASS"))
    raise SystemExit(1 if failures else 0)
