#!/usr/bin/env python3
"""Run reproducible Godot parser and headless-start acceptance checks."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "reports/godot_acceptance_v1.json"
DEFAULT_MAC_GODOT = (
    Path.home() / "Downloads/Godot.app/Contents/MacOS/Godot"
)
SOURCE_SUFFIXES = {".gd", ".gdshader", ".tscn", ".tres"}


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _source_files() -> list[Path]:
    roots: Iterable[Path] = (
        ROOT / "project.godot",
        ROOT / "main.tscn",
        ROOT / "player.gd",
        ROOT / "scripts",
        ROOT / "scenes",
    )
    files: list[Path] = []
    for candidate in roots:
        if candidate.is_file():
            files.append(candidate)
        elif candidate.is_dir():
            files.extend(
                path
                for path in candidate.rglob("*")
                if path.is_file() and path.suffix.lower() in SOURCE_SUFFIXES
            )
    return sorted(set(files), key=lambda path: str(path.relative_to(ROOT)))


def _tree_fingerprint(files: Iterable[Path]) -> str:
    digest = hashlib.sha256()
    for path in files:
        relative = str(path.relative_to(ROOT)).replace(os.sep, "/")
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def _resolve_godot(explicit: str | None) -> Path:
    candidates = [
        explicit,
        os.environ.get("GODOT"),
        shutil.which("godot"),
        shutil.which("godot4"),
        str(DEFAULT_MAC_GODOT) if DEFAULT_MAC_GODOT.is_file() else None,
    ]
    for candidate in candidates:
        if candidate:
            path = Path(candidate).expanduser()
            if path.is_file():
                return path.resolve()
    raise FileNotFoundError(
        "Godot executable not found; pass --godot /path/to/Godot or set GODOT"
    )


def _run(executable: Path, arguments: list[str], timeout: int) -> dict[str, Any]:
    started = time.monotonic()
    completed = subprocess.run(
        [str(executable), *arguments],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    output = "\n".join(
        part.strip() for part in (completed.stdout, completed.stderr) if part.strip()
    )
    return {
        "arguments": arguments,
        "exit_code": completed.returncode,
        "elapsed_seconds": round(time.monotonic() - started, 3),
        "output": output,
        "passed": completed.returncode == 0,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", help="path to the Godot executable")
    parser.add_argument("--output", type=Path, default=REPORT)
    arguments = parser.parse_args()

    try:
        executable = _resolve_godot(arguments.godot)
    except FileNotFoundError as exc:
        print(f"ERROR: {exc}")
        return 1

    sources = _source_files()
    version = _run(executable, ["--version"], timeout=30)
    parser_check = _run(
        executable,
        ["--path", ".", "--check-only", "--quit"],
        timeout=120,
    )
    headless_start = _run(
        executable,
        ["--headless", "--path", ".", "--quit-after", "8"],
        timeout=120,
    )
    checks = [parser_check, headless_start]
    payload = {
        "schema_version": "godot_runtime_acceptance_v1",
        "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "project": "AI autonomous-vessel navigation simulator",
        "godot_version": version["output"].splitlines()[0] if version["output"] else "",
        "source_inventory": {
            "file_count": len(sources),
            "tree_sha256": _tree_fingerprint(sources),
            "entrypoint_sha256": _sha256(ROOT / "project.godot"),
        },
        "checks": {
            "parser_check": parser_check,
            "headless_start_8_frames": headless_start,
        },
        "passed_checks": sum(int(check["passed"]) for check in checks),
        "total_checks": len(checks),
        "passed": version["passed"] and all(check["passed"] for check in checks),
        "boundary": (
            "Parser and eight-frame headless startup acceptance; this is not an "
            "FPS, long-duration stability, hardware-in-the-loop, or sea-trial result."
        ),
    }
    output = arguments.output
    if not output.is_absolute():
        output = ROOT / output
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(output)
    print(
        f"Godot acceptance: {'PASS' if payload['passed'] else 'FAIL'} "
        f"({payload['passed_checks']}/{payload['total_checks']})"
    )
    print(f"report: {output}")
    return 0 if payload["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
