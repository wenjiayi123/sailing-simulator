#!/usr/bin/env python3
"""Build and verify a deterministic redistributable full-visual simulator bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import zipfile


ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"
RELEASE_NAME = "sailing-simulator-full-visual-v1"
ARCHIVE = DIST / f"{RELEASE_NAME}.zip"
SIDECAR = DIST / f"{RELEASE_NAME}.zip.sha256"
LEDGER = ROOT / "data/verification/visual_asset_release_manifest_v1.json"
FIXED_TIMESTAMP = (2026, 8, 28, 0, 0, 0)
TOP_LEVEL_FILES = (
    "project.godot", "main.tscn", "player.gd", "README.md", "LICENSE",
    "NOTICE", "THIRD_PARTY_ASSETS.md", "CONTRIBUTING.md", "SECURITY.md",
    "Makefile", "requirements-rl.txt", "requirements-benchmark.txt",
)
ALLOWED_TREES = (
    ".github", "assets", "data/ports", "data/public", "data/public_cache",
    "data/rl", "data/verification", "docs", "reports", "scenes", "scripts",
    "shaders", "tests", "tools", "LICENSES",
)
SKIP_PARTS = {"__pycache__", ".pytest_cache", ".mypy_cache"}
SKIP_SUFFIXES = {".pyc", ".pyo", ".import", ".tmp", ".DS_Store"}
MEDIA_SUFFIXES = {
    ".png", ".jpg", ".jpeg", ".webp", ".gif", ".svg", ".mp4",
    ".webm", ".wav", ".mp3", ".ogg", ".glb", ".gltf", ".obj", ".fbx",
}
REQUIRED = {
    "project.godot",
    "main.tscn",
    "assets/generated/release/simulator_icon.svg",
    "data/verification/visual_asset_release_manifest_v1.json",
    "data/verification/port_production_integration_profile_v1.json",
    "reports/full_visual_asset_release_v1.json",
    "reports/port_production_integration_assurance_v1.json",
    "scripts/integration/ship_port_production_gateway.gd",
    "scripts/ui/ship_port_integration_panel.gd",
    "THIRD_PARTY_ASSETS.md",
    "LICENSES/LicenseRef-User-Authorized-Public-Redistribution.txt",
}


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256(path: Path) -> str:
    return _sha256_bytes(path.read_bytes())


def _load_ledger() -> dict:
    return json.loads(LEDGER.read_text(encoding="utf-8"))


def _excluded(relative: str, ledger: dict) -> bool:
    for row in ledger.get("excluded_local_assets", []):
        if row.get("path") == relative:
            return True
        prefix = row.get("path_prefix")
        if isinstance(prefix, str) and relative.startswith(prefix):
            return True
    return False


def _selected_files() -> list[Path]:
    ledger = _load_ledger()
    included_media = {row["path"] for row in ledger.get("included_assets", [])}
    selected: set[Path] = set()
    for relative in TOP_LEVEL_FILES:
        path = ROOT / relative
        if path.is_file() and not path.is_symlink():
            selected.add(path)
    for tree in ALLOWED_TREES:
        base = ROOT / tree
        if not base.exists():
            continue
        for path in base.rglob("*"):
            if not path.is_file() or path.is_symlink():
                continue
            relative = path.relative_to(ROOT).as_posix()
            if any(part in SKIP_PARTS for part in path.relative_to(ROOT).parts):
                continue
            if path.suffix in SKIP_SUFFIXES or path.name in SKIP_SUFFIXES:
                continue
            if _excluded(relative, ledger):
                continue
            if path.suffix.lower() in MEDIA_SUFFIXES and relative not in included_media:
                raise ValueError(f"unregistered media selected: {relative}")
            selected.add(path)
    result = sorted(selected, key=lambda item: item.relative_to(ROOT).as_posix())
    present = {path.relative_to(ROOT).as_posix() for path in result}
    missing = sorted(REQUIRED - present)
    if missing:
        raise FileNotFoundError("full-visual release inputs missing: " + ", ".join(missing))
    return result


def _zip_info(name: str) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name, FIXED_TIMESTAMP)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o100644 << 16
    info.create_system = 3
    return info


def build() -> int:
    files = _selected_files()
    DIST.mkdir(parents=True, exist_ok=True)
    temporary = ARCHIVE.with_suffix(".zip.tmp")
    manifest_rows: list[str] = []
    with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in files:
            relative = path.relative_to(ROOT).as_posix()
            data = path.read_bytes()
            manifest_rows.append(f"{_sha256_bytes(data)}  {relative}")
            archive.writestr(_zip_info(f"{RELEASE_NAME}/{relative}"), data)
        archive.writestr(
            _zip_info(f"{RELEASE_NAME}/MANIFEST.sha256"),
            ("\n".join(manifest_rows) + "\n").encode("utf-8"),
        )
    temporary.replace(ARCHIVE)
    SIDECAR.write_text(f"{_sha256(ARCHIVE)}  {ARCHIVE.name}\n", encoding="utf-8")
    print(f"full-visual release: {ARCHIVE}")
    print(f"files: {len(files)}; sha256: {_sha256(ARCHIVE)}")
    return verify()


def verify() -> int:
    errors: list[str] = []
    if not ARCHIVE.is_file() or not SIDECAR.is_file():
        print("FULL_VISUAL_RELEASE:FAIL:archive or sidecar missing")
        return 1
    sidecar = SIDECAR.read_text(encoding="utf-8").strip().split()
    if not sidecar or sidecar[0] != _sha256(ARCHIVE):
        errors.append("archive SHA-256 sidecar mismatch")
    ledger = _load_ledger()
    included_media = {
        row["path"]: row["sha256"] for row in ledger.get("included_assets", [])
    }
    with zipfile.ZipFile(ARCHIVE) as archive:
        prefix = f"{RELEASE_NAME}/"
        manifest_name = prefix + "MANIFEST.sha256"
        names = archive.namelist()
        if manifest_name not in names:
            errors.append("MANIFEST.sha256 missing")
            manifest_rows: list[str] = []
        else:
            manifest_rows = archive.read(manifest_name).decode("utf-8").splitlines()
        expected: dict[str, str] = {}
        for row in manifest_rows:
            digest, separator, relative = row.partition("  ")
            if not separator or len(digest) != 64:
                errors.append(f"invalid manifest row: {row}")
            else:
                expected[relative] = digest
        payload_names = [name for name in names if name != manifest_name]
        if len(payload_names) != len(expected):
            errors.append("archive inventory differs from manifest")
        packaged_media: set[str] = set()
        for name in payload_names:
            if not name.startswith(prefix):
                errors.append(f"member outside release root: {name}")
                continue
            relative = name[len(prefix):]
            pure = PurePosixPath(relative)
            if pure.is_absolute() or ".." in pure.parts:
                errors.append(f"unsafe archive path: {relative}")
            if _excluded(relative, ledger):
                errors.append(f"excluded local asset leaked: {relative}")
            data = archive.read(name)
            digest = _sha256_bytes(data)
            if expected.get(relative) != digest:
                errors.append(f"archive manifest hash mismatch: {relative}")
            if PurePosixPath(relative).suffix.lower() in MEDIA_SUFFIXES:
                packaged_media.add(relative)
                if included_media.get(relative) != digest:
                    errors.append(f"media is unregistered or ledger hash differs: {relative}")
        missing_required = sorted(REQUIRED - set(expected))
        if missing_required:
            errors.append("required files absent: " + ", ".join(missing_required))
        missing_media = sorted(set(included_media) - packaged_media)
        if missing_media:
            errors.append("registered media absent: " + ", ".join(missing_media))
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        print("FULL_VISUAL_RELEASE:FAIL")
        return 1
    print(
        f"FULL_VISUAL_RELEASE:PASS:media={len(included_media)}:"
        f"sha256={_sha256(ARCHIVE)}"
    )
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("build", "verify"))
    return parser.parse_args()


if __name__ == "__main__":
    arguments = parse_args()
    raise SystemExit(build() if arguments.command == "build" else verify())
