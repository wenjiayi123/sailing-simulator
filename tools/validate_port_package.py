#!/usr/bin/env python3
"""Validate a replaceable port dataset and emit a machine-readable report."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.ship_rl.port_contract import validate_port_dataset_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset", type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument(
        "--require-research-ready",
        action="store_true",
        help="return a failure status unless the offline research contract passes",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    report = validate_port_dataset_path(arguments.dataset.expanduser().resolve())
    text = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if arguments.report:
        output = arguments.report.expanduser().resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(text, encoding="utf-8")
    print(text, end="")
    if report["errors"]:
        return 1
    if arguments.require_research_ready and not report["research_training_ready"]:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
