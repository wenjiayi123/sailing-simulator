#!/usr/bin/env python3
"""Build and verify a deterministic headless research-core release archive."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path, PurePosixPath
import zipfile


ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"
RELEASE_NAME = "sailing-simulator-research-core-v3"
ARCHIVE = DIST / f"{RELEASE_NAME}.zip"
SIDECAR = DIST / f"{RELEASE_NAME}.zip.sha256"
FIXED_TIMESTAMP = (2026, 1, 1, 0, 0, 0)
TOP_LEVEL_FILES = (
    "README.md",
    "LICENSE",
    "NOTICE",
    "CONTRIBUTING.md",
    "SECURITY.md",
    "Makefile",
    "requirements-rl.txt",
    "requirements-benchmark.txt",
)
GLOBS = (
    ".github/workflows/*.yml",
    "docs/*.md",
    "tools/*.py",
    "tools/*.sh",
    "tools/ship_rl/*.py",
    "tools/cargo_rl/*.py",
    "tests/*.py",
    "data/rl/*.json",
    "data/public/*.json",
    "data/public/*.csv",
    "data/ports/*.json",
    "reports/*.json",
    "reports/*.md",
    "reports/*.lock",
    "reports/artifacts/navigation_benchmark_v1/**/*.json",
    "reports/artifacts/navigation_benchmark_v1/**/*.csv",
    "reports/artifacts/navigation_benchmark_v1/**/*.zip",
    "reports/artifacts/navigation_benchmark_v2/**/*.json",
    "reports/artifacts/navigation_benchmark_v2/**/*.csv",
    "reports/artifacts/navigation_benchmark_v2/**/*.zip",
    "reports/artifacts/safety_supervisor_v3/**/*.json",
    "reports/artifacts/cargo_circuit_rl_v1/**/*.json",
    "reports/artifacts/cargo_circuit_rl_v1/**/*.csv",
    "reports/artifacts/cargo_circuit_rl_v1/**/*.zip",
    "reports/artifacts/cargo_circuit_dynamic_rl_v2/**/*.json",
    "reports/artifacts/cargo_circuit_dynamic_rl_v2/**/*.csv",
    "reports/artifacts/cargo_circuit_dynamic_rl_v2/**/*.zip",
)
FORBIDDEN_PREFIXES = (
    "assets/",
    "characters/",
    "docs/screenshots/",
    "soft_copyright_materials/",
    "soft_copyright_template_work/",
    "backups/",
)
FORBIDDEN_SUFFIXES = (
    ".png",
    ".jpg",
    ".jpeg",
    ".webp",
    ".gif",
    ".wav",
    ".mp3",
    ".ogg",
    ".glb",
    ".gltf",
)
FORBIDDEN_CONTAINS = (
    "soft_copyright",
    "__pycache__",
    "/.venv/",
)


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _sha256(path: Path) -> str:
    return _sha256_bytes(path.read_bytes())


def _selected_files() -> list[Path]:
    selected: set[Path] = set()
    for relative in TOP_LEVEL_FILES:
        path = ROOT / relative
        if path.is_file():
            selected.add(path)
    for pattern in GLOBS:
        for path in ROOT.glob(pattern):
            relative = path.relative_to(ROOT).as_posix() if path.is_file() else ""
            lowered = relative.lower()
            forbidden = bool(
                relative.startswith(FORBIDDEN_PREFIXES)
                or lowered.endswith(FORBIDDEN_SUFFIXES)
                or any(value in lowered for value in FORBIDDEN_CONTAINS)
            )
            if path.is_file() and not path.is_symlink() and not forbidden:
                selected.add(path)
    result = sorted(selected, key=lambda value: value.relative_to(ROOT).as_posix())
    for path in result:
        relative = path.relative_to(ROOT).as_posix()
        lowered = relative.lower()
        if (
            relative.startswith(FORBIDDEN_PREFIXES)
            or lowered.endswith(FORBIDDEN_SUFFIXES)
            or any(value in lowered for value in FORBIDDEN_CONTAINS)
        ):
            raise ValueError(f"forbidden visual/binary asset selected: {relative}")
    return result


def _zip_info(name: str) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name, FIXED_TIMESTAMP)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o100644 << 16
    info.create_system = 3
    return info


def build() -> int:
    files = _selected_files()
    required = {
        "tools/ship_rl/safety_supervisor.py",
        "tools/run_safety_supervisor_benchmark.py",
        "tools/run_nonmutating_deep_verify.py",
        "reports/safety_supervisor_benchmark_v3.json",
        "reports/safety_supervisor_benchmark_v3_prepared.json",
        "reports/safety_supervisor_utility_audit_v3.json",
        "reports/port_ops_benchmark_v2.json",
        "reports/godot_acceptance_v3.json",
        "reports/simulator_reliability_audit_v3.json",
        "reports/simulator_reliability_audit_v3.md",
    }
    present = {path.relative_to(ROOT).as_posix() for path in files}
    missing = sorted(required - present)
    if missing:
        raise FileNotFoundError("release evidence is incomplete: " + ", ".join(missing))
    manifest_rows = []
    DIST.mkdir(parents=True, exist_ok=True)
    temporary = ARCHIVE.with_suffix(".zip.tmp")
    with zipfile.ZipFile(
        temporary,
        "w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
    ) as archive:
        for path in files:
            relative = path.relative_to(ROOT).as_posix()
            data = path.read_bytes()
            manifest_rows.append(f"{_sha256_bytes(data)}  {relative}")
            archive.writestr(_zip_info(f"{RELEASE_NAME}/{relative}"), data)
        manifest = ("\n".join(manifest_rows) + "\n").encode("utf-8")
        archive.writestr(
            _zip_info(f"{RELEASE_NAME}/MANIFEST.sha256"),
            manifest,
        )
    temporary.replace(ARCHIVE)
    SIDECAR.write_text(f"{_sha256(ARCHIVE)}  {ARCHIVE.name}\n", encoding="utf-8")
    print(f"research-core release: {ARCHIVE}")
    print(f"files: {len(files)}; sha256: {_sha256(ARCHIVE)}")
    return verify()


def verify() -> int:
    errors: list[str] = []
    if not ARCHIVE.is_file() or not SIDECAR.is_file():
        print("ERROR: research-core archive or SHA-256 sidecar is missing")
        return 1
    sidecar = SIDECAR.read_text(encoding="utf-8").strip().split()
    if not sidecar or sidecar[0] != _sha256(ARCHIVE):
        errors.append("archive SHA-256 sidecar mismatch")
    with zipfile.ZipFile(ARCHIVE) as archive:
        names = archive.namelist()
        prefix = f"{RELEASE_NAME}/"
        manifest_name = prefix + "MANIFEST.sha256"
        if manifest_name not in names:
            errors.append("MANIFEST.sha256 missing from archive")
            manifest_rows: list[str] = []
        else:
            manifest_rows = archive.read(manifest_name).decode("utf-8").splitlines()
        expected: dict[str, str] = {}
        for row in manifest_rows:
            digest, separator, relative = row.partition("  ")
            if not separator or len(digest) != 64:
                errors.append(f"invalid manifest row: {row}")
                continue
            expected[relative] = digest
        payload_names = [name for name in names if name != manifest_name]
        if len(payload_names) != len(expected):
            errors.append("manifest inventory does not match archive inventory")
        for name in payload_names:
            if not name.startswith(prefix):
                errors.append(f"archive member outside release root: {name}")
                continue
            relative = name[len(prefix) :]
            pure = PurePosixPath(relative)
            if pure.is_absolute() or ".." in pure.parts:
                errors.append(f"unsafe archive path: {relative}")
            lowered = relative.lower()
            if (
                relative.startswith(FORBIDDEN_PREFIXES)
                or lowered.endswith(FORBIDDEN_SUFFIXES)
                or any(value in lowered for value in FORBIDDEN_CONTAINS)
            ):
                errors.append(f"visual/unverified asset leaked into release: {relative}")
            if _sha256_bytes(archive.read(name)) != expected.get(relative):
                errors.append(f"manifest hash mismatch: {relative}")
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    print("research-core release verify: PASS (visual assets excluded)")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("build", "verify"))
    return parser.parse_args()


if __name__ == "__main__":
    arguments = parse_args()
    raise SystemExit(build() if arguments.command == "build" else verify())
