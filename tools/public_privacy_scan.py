#!/usr/bin/env python3
"""Fail closed when the publishable worktree contains private release traces."""

from __future__ import annotations

import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MAX_TEXT_BYTES = 12_000_000


def _joined(*parts: str) -> str:
    return "".join(parts)


FORBIDDEN_TERMS = (
    _joined("co", "dex"),
    _joined("chat", "gpt"),
    _joined("res", "ume"),
    _joined("inter", "view"),
    "".join(chr(codepoint) for codepoint in (0x7B80, 0x5386)),
    "".join(chr(codepoint) for codepoint in (0x9762, 0x8BD5)),
    "".join(chr(codepoint) for codepoint in (0x6C42, 0x804C)),
)
FORBIDDEN_FILENAME_TERMS = (
    "录制台词",
    "演示台词",
    "演示脚本",
    "demo_script",
    "recording_script",
    "个人简历",
    "求职材料",
    "个人自传",
    "内部流转",
)
ROOT_MEDIA_SUFFIXES = (
    ".png",
    ".jpg",
    ".jpeg",
    ".webp",
    ".gif",
    ".png.import",
    ".jpg.import",
    ".jpeg.import",
    ".webp.import",
    ".gif.import",
)
FORBIDDEN_TERM_RE = re.compile(
    "(?:" + "|".join(re.escape(value) for value in FORBIDDEN_TERMS) + ")",
    re.IGNORECASE,
)
LOCAL_ACCOUNT_RE = re.compile(
    _joined(r"(?:/", "Users", r"/[^/\s]+|/", "home", r"/[^/\s]+|[A-Z]:\\", "Users", r"\\[^\\\s]+)"),
    re.IGNORECASE,
)
EMAIL_RE = re.compile(r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b")
PHONE_RE = re.compile(r"(?<![0-9A-Za-z.])1[3-9]\d{9}(?![0-9A-Za-z.])")
PRIVATE_KEY_RE = re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")


def _publishable_files() -> list[Path]:
    completed = subprocess.run(
        ["git", "ls-files", "-co", "--exclude-standard", "-z"],
        cwd=ROOT,
        check=True,
        capture_output=True,
    )
    return [ROOT / item.decode("utf-8") for item in completed.stdout.split(b"\0") if item]


def _text(path: Path) -> str | None:
    if not path.is_file() or path.stat().st_size > MAX_TEXT_BYTES:
        return None
    raw = path.read_bytes()
    if b"\0" in raw:
        return None
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return None


def main() -> int:
    findings: list[tuple[str, int, str]] = []
    scanner_path = Path(__file__).resolve()
    for path in _publishable_files():
        relative = path.relative_to(ROOT).as_posix()
        is_scanner = path.resolve() == scanner_path
        lowered_relative = relative.casefold()
        if any(term.casefold() in lowered_relative for term in FORBIDDEN_FILENAME_TERMS):
            findings.append((relative, 0, "private-material filename"))
        if "/" not in relative and lowered_relative.endswith(ROOT_MEDIA_SUFFIXES):
            findings.append((relative, 0, "root-level personal-media risk"))
        if not is_scanner and FORBIDDEN_TERM_RE.search(relative):
            findings.append((relative, 0, "forbidden filename"))
        content = _text(path)
        if content is None:
            continue
        for line_number, line in enumerate(content.splitlines(), start=1):
            checks = (
                ("forbidden topic", FORBIDDEN_TERM_RE),
                ("local account path", LOCAL_ACCOUNT_RE),
                ("email address", EMAIL_RE),
                ("phone number", PHONE_RE),
                ("private key", PRIVATE_KEY_RE),
            )
            for label, pattern in checks:
                if is_scanner and label == "forbidden topic":
                    continue
                if pattern.search(line):
                    findings.append((relative, line_number, label))

    branch = subprocess.run(
        ["git", "branch", "--show-current"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    if FORBIDDEN_TERM_RE.search(branch):
        findings.append(("<current-branch>", 0, "forbidden branch name"))

    if findings:
        print(f"PUBLIC_PRIVACY_SCAN:FAIL:{len(findings)}")
        for relative, line_number, label in findings:
            location = f"{relative}:{line_number}" if line_number else relative
            print(f"- {location}: {label}")
        return 1
    print("PUBLIC_PRIVACY_SCAN:PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
