#!/usr/bin/env python3
"""Generate fail-closed named-vessel readiness and functional smoke reports."""

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

from tools.ship_assurance.named_vessel_twin import build_functional_smoke, evaluate_manifest


DEFAULT_MANIFEST = ROOT / "data/verification/named_vessel_twin_manifest.template.json"
DYNAMICS_CONFIG = ROOT / "data/verification/catamaran_usv_dynamics_reference_v2.json"
READINESS_REPORT = ROOT / "reports/named_vessel_twin_readiness_v1.json"
SMOKE_REPORT = ROOT / "reports/named_vessel_twin_functional_smoke_v1.json"


def _read(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _write(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def generate_readiness(manifest_path: Path) -> dict[str, Any]:
    payload = evaluate_manifest(
        _read(manifest_path),
        manifest_path=manifest_path,
        dynamics_config_path=DYNAMICS_CONFIG,
    )
    payload["generated_at"] = datetime.now(timezone.utc).isoformat()
    payload["manifest_path"] = str(manifest_path.relative_to(ROOT)) if manifest_path.is_relative_to(ROOT) else str(manifest_path)
    return payload


def generate_smoke() -> dict[str, Any]:
    payload = build_functional_smoke(_read(DYNAMICS_CONFIG))
    payload["generated_at"] = datetime.now(timezone.utc).isoformat()
    return payload


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("generate", "verify", "smoke", "verify-smoke"))
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    args = parser.parse_args()
    if args.mode in ("generate", "verify"):
        payload = generate_readiness(args.manifest.resolve())
        if args.mode == "generate":
            _write(READINESS_REPORT, payload)
        else:
            recorded = _read(READINESS_REPORT)
            payload.pop("generated_at", None)
            recorded.pop("generated_at", None)
            if payload != recorded:
                raise SystemExit("named-vessel readiness report is stale")
        print(f"NAMED_VESSEL_READINESS:{payload['status']}")
        return 0
    payload = generate_smoke()
    if args.mode == "smoke":
        _write(SMOKE_REPORT, payload)
    else:
        recorded = _read(SMOKE_REPORT)
        payload.pop("generated_at", None)
        recorded.pop("generated_at", None)
        if payload != recorded:
            raise SystemExit("named-vessel functional smoke report is stale")
    print(f"NAMED_VESSEL_FUNCTIONAL_SMOKE:{'PASS' if payload['passed'] else 'FAIL'}:{payload['maneuver_count']}")
    return 0 if payload["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
