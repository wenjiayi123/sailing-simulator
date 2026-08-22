#!/usr/bin/env python3
"""Evaluate a real-vessel sea-trial evidence manifest and telemetry log."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.ship_assurance.sea_trial import (
    SeaTrialEvidence,
    evaluate_sea_trial_gate,
    load_telemetry_csv,
)


DEFAULT_PROTOCOL = ROOT / "data/verification/sea_trial_protocol_v1.json"


def _read(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path}")
    return value


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--telemetry", type=Path, required=True)
    parser.add_argument("--protocol", type=Path, default=DEFAULT_PROTOCOL)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    manifest_path = arguments.manifest.expanduser().resolve()
    telemetry_path = arguments.telemetry.expanduser().resolve()
    protocol_path = arguments.protocol.expanduser().resolve()
    output_path = arguments.output.expanduser().resolve()
    manifest = _read(manifest_path)
    protocol = _read(protocol_path)
    if Path(str(manifest.get("raw_log_path", ""))).expanduser().resolve() != telemetry_path:
        raise ValueError("manifest raw_log_path must resolve to the --telemetry file")
    evidence = SeaTrialEvidence.from_mapping(manifest)
    rows = load_telemetry_csv(telemetry_path)
    result = evaluate_sea_trial_gate(evidence, protocol, rows)
    payload = {
        "schema_version": "sea_trial_evaluation_report_v1",
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "manifest_sha256": _sha256(manifest_path),
        "protocol_sha256": _sha256(protocol_path),
        "telemetry_sha256": _sha256(telemetry_path),
        "external_documents_authenticated_by_software": False,
        "result": result,
        "boundary": "This tool validates declared fields, raw-log integrity and telemetry metrics. It cannot authenticate permits, people, signatures, calibration reports or witness independence; those require external review.",
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, allow_nan=False) + "\n",
        encoding="utf-8",
    )
    print(f"sea-trial evaluation: {result['status']}")
    print(f"report: {output_path}")
    return 0 if result["evidence_package_complete"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
