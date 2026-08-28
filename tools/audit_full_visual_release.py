#!/usr/bin/env python3
"""Generate or verify the fail-closed full-visual release asset audit."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "data/verification/visual_asset_release_manifest_v1.json"
REPORT_JSON = ROOT / "reports/full_visual_asset_release_v1.json"
REPORT_MD = ROOT / "reports/full_visual_asset_release_v1.md"
MEDIA_SUFFIXES = {
    ".png", ".jpg", ".jpeg", ".webp", ".gif", ".svg", ".mp4",
    ".webm", ".wav", ".mp3", ".ogg", ".glb", ".gltf", ".obj", ".fbx",
}
SKIP_TOP_LEVEL = {
    ".git", ".godot", ".venv", "dist", "output", "backups",
    "soft_copyright_materials", "soft_copyright_template_work",
}
RUNTIME_SUFFIXES = {".gd", ".tscn", ".tres", ".gdshader", ".shader", ".cfg"}
RUNTIME_TOP_LEVEL = ("project.godot", "main.tscn")
RUNTIME_TREES = ("scripts", "scenes", "assets")


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _aggregate_digest(rows: list[tuple[str, str]]) -> str:
    body = "\n".join(f"{digest}  {path}" for path, digest in sorted(rows)) + "\n"
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


def _load_manifest() -> dict[str, Any]:
    value = json.loads(MANIFEST.read_text(encoding="utf-8"))
    if value.get("schema") != "visual-asset-release-manifest.v1":
        raise ValueError("unexpected visual asset manifest schema")
    return value


def _excluded(relative: str, exclusions: list[dict[str, Any]]) -> bool:
    for item in exclusions:
        if item.get("path") == relative:
            return True
        prefix = item.get("path_prefix")
        if isinstance(prefix, str) and relative.startswith(prefix):
            return True
    return False


def _media_files() -> list[Path]:
    result: list[Path] = []
    for path in ROOT.rglob("*"):
        if not path.is_file() or path.is_symlink() or path.suffix.lower() not in MEDIA_SUFFIXES:
            continue
        relative = path.relative_to(ROOT)
        if relative.parts and relative.parts[0] in SKIP_TOP_LEVEL:
            continue
        result.append(path)
    return sorted(result, key=lambda item: item.relative_to(ROOT).as_posix())


def _runtime_files() -> list[Path]:
    result = [ROOT / relative for relative in RUNTIME_TOP_LEVEL]
    for tree in RUNTIME_TREES:
        base = ROOT / tree
        if not base.is_dir():
            continue
        result.extend(
            path for path in base.rglob("*")
            if path.is_file() and not path.is_symlink() and path.suffix.lower() in RUNTIME_SUFFIXES
        )
    return sorted(set(result), key=lambda item: item.relative_to(ROOT).as_posix())


def _runtime_reference_violations(
    runtime_files: list[Path], exclusions: list[dict[str, Any]]
) -> list[str]:
    exact = [item["path"] for item in exclusions if isinstance(item.get("path"), str)]
    prefixes = [item["path_prefix"] for item in exclusions if isinstance(item.get("path_prefix"), str)]
    violations: list[str] = []
    for path in runtime_files:
        text = path.read_text(encoding="utf-8", errors="replace")
        relative = path.relative_to(ROOT).as_posix()
        for excluded_path in exact:
            if f"res://{excluded_path}" in text:
                violations.append(f"{relative} -> res://{excluded_path}")
        for prefix in prefixes:
            if f"res://{prefix}" in text:
                violations.append(f"{relative} -> res://{prefix}*")
    return sorted(set(violations))


def build_report() -> dict[str, Any]:
    manifest = _load_manifest()
    included_rows = manifest.get("included_assets", [])
    exclusions = manifest.get("excluded_local_assets", [])
    included = {
        row.get("path"): row for row in included_rows
        if isinstance(row, dict) and isinstance(row.get("path"), str)
    }
    errors: list[str] = []
    if len(included) != len(included_rows):
        errors.append("included asset paths must be unique non-empty strings")

    media_files = _media_files()
    actual_media = {path.relative_to(ROOT).as_posix(): path for path in media_files}
    included_details: list[dict[str, Any]] = []
    for relative, row in sorted(included.items()):
        path = ROOT / relative
        digest = _sha256(path) if path.is_file() else None
        checks = {
            "exists": path.is_file(),
            "sha256_matches": digest == row.get("sha256"),
            "origin_recorded": bool(row.get("origin")),
            "license_recorded": bool(row.get("license")),
            "source_recorded": bool(row.get("source_record")),
        }
        if relative.startswith("assets/generated/release/") and path.suffix.lower() == ".svg" and path.is_file():
            svg = path.read_text(encoding="utf-8", errors="replace").lower()
            checks["accessible_title"] = "<title>" in svg
            checks["no_external_resource_link"] = all(
                token not in svg for token in ("<image", "xlink:href", " href=")
            )
        if not all(checks.values()):
            errors.append(f"included asset failed: {relative}")
        included_details.append({"path": relative, "sha256": digest, "checks": checks})

    unregistered = sorted(
        relative for relative in actual_media
        if relative not in included and not _excluded(relative, exclusions)
    )
    if unregistered:
        errors.extend(f"unregistered media: {relative}" for relative in unregistered)
    missing_inventory = sorted(relative for relative in included if relative not in actual_media)
    if missing_inventory:
        errors.extend(f"included media absent from inventory: {relative}" for relative in missing_inventory)

    excluded_present = sorted(
        relative for relative in actual_media if _excluded(relative, exclusions)
    )
    runtime_files = _runtime_files()
    runtime_violations = _runtime_reference_violations(runtime_files, exclusions)
    if runtime_violations:
        errors.extend(f"excluded runtime reference: {item}" for item in runtime_violations)

    policy = manifest.get("release_policy", {})
    claims = manifest.get("claims", {})
    boundary_checks = {
        "manifest_requires_per_asset_ledger": policy.get("every_included_media_file_requires_ledger_entry") is True,
        "manifest_requires_excluded_reference_gate": policy.get("excluded_local_assets_must_not_be_runtime_referenced") is True,
        "manifest_requires_package_exclusion": policy.get("excluded_local_assets_must_not_be_packaged") is True,
        "manifest_claims_zero_unresolved": claims.get("unresolved_included_assets") == 0,
        "manifest_preserves_named_vessel_dynamics": claims.get("named_vessel_dynamics_changed") is False,
        "manifest_preserves_existing_policies": claims.get("existing_policy_artifacts_changed") is False,
        "manifest_denies_production_authority": claims.get("production_authority") is False,
    }
    if not all(boundary_checks.values()):
        errors.append("manifest release boundary is incomplete or overclaims authority")

    media_hash_rows = [(relative, _sha256(path)) for relative, path in actual_media.items()]
    runtime_hash_rows = [
        (path.relative_to(ROOT).as_posix(), _sha256(path)) for path in runtime_files
    ]
    passed = not errors
    return {
        "schema": "full-visual-asset-release-audit.v1",
        "status": "FULL_VISUAL_PACKAGE_READY" if passed else "FULL_VISUAL_PACKAGE_BLOCKED",
        "summary": {
            "passed": passed,
            "included_asset_count": len(included),
            "excluded_local_asset_file_count": len(excluded_present),
            "unregistered_media_count": len(unregistered),
            "runtime_excluded_reference_count": len(runtime_violations),
            "unresolved_included_asset_count": sum(
                1 for item in included_details if not all(item["checks"].values())
            ),
        },
        "boundary_checks": boundary_checks,
        "included_assets": included_details,
        "excluded_local_assets_present_but_not_referenced": excluded_present,
        "unregistered_media": unregistered,
        "runtime_excluded_references": runtime_violations,
        "errors": errors,
        "input_sha256": {
            "visual_asset_release_manifest_v1.json": _sha256(MANIFEST),
            "media_inventory": _aggregate_digest(media_hash_rows),
            "runtime_reference_set": _aggregate_digest(runtime_hash_rows),
        },
        "claims": {
            "full_visual_package_ready": passed,
            "all_included_media_hash_bound": passed,
            "excluded_local_assets_not_runtime_referenced": not runtime_violations,
            "excluded_local_assets_retained_locally": bool(excluded_present),
            "named_vessel_dynamics_changed": False,
            "existing_policy_artifacts_changed": False,
            "training_performed": False,
            "production_authority": False,
        },
    }


def _markdown(report: dict[str, Any]) -> str:
    summary = report["summary"]
    lines = [
        "# Full visual asset release audit v1",
        "",
        f"Status: `{report['status']}`",
        "",
        f"- Included and hash-bound assets: {summary['included_asset_count']}",
        f"- Local-only excluded files retained: {summary['excluded_local_asset_file_count']}",
        f"- Unregistered media: {summary['unregistered_media_count']}",
        f"- Runtime links to excluded assets: {summary['runtime_excluded_reference_count']}",
        f"- Unresolved included assets: {summary['unresolved_included_asset_count']}",
        "",
        "The result covers redistributable visual-package inputs. It does not grant",
        "production authority, change named-vessel dynamics, change released policies,",
        "or claim that field acceptance has occurred.",
        "",
    ]
    if report["errors"]:
        lines.extend(["## Blocking errors", ""])
        lines.extend(f"- {error}" for error in report["errors"])
        lines.append("")
    return "\n".join(lines)


def generate() -> int:
    report = build_report()
    REPORT_JSON.parent.mkdir(parents=True, exist_ok=True)
    REPORT_JSON.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    REPORT_MD.write_text(_markdown(report), encoding="utf-8")
    print(
        f"FULL_VISUAL_ASSET_AUDIT:{'PASS' if report['summary']['passed'] else 'FAIL'}:"
        f"{report['summary']['included_asset_count']}:"
        f"unregistered={report['summary']['unregistered_media_count']}:"
        f"runtime_excluded={report['summary']['runtime_excluded_reference_count']}"
    )
    return 0 if report["summary"]["passed"] else 1


def verify() -> int:
    expected = build_report()
    if not REPORT_JSON.is_file() or not REPORT_MD.is_file():
        print("FULL_VISUAL_ASSET_AUDIT:FAIL:missing report")
        return 1
    actual = json.loads(REPORT_JSON.read_text(encoding="utf-8"))
    if actual != expected or REPORT_MD.read_text(encoding="utf-8") != _markdown(expected):
        print("FULL_VISUAL_ASSET_AUDIT:FAIL:stale or altered report")
        return 1
    if not expected["summary"]["passed"]:
        print("FULL_VISUAL_ASSET_AUDIT:FAIL:release blocked")
        return 1
    print(
        "FULL_VISUAL_ASSET_AUDIT:PASS:"
        f"{expected['summary']['included_asset_count']}:strict-assets"
    )
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("generate", "verify"))
    return parser.parse_args()


if __name__ == "__main__":
    arguments = parse_args()
    raise SystemExit(generate() if arguments.command == "generate" else verify())
