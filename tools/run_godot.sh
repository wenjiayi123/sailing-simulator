#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"

find_godot() {
  if [[ -n "${GODOT:-}" && -x "${GODOT}" ]]; then
    printf '%s\n' "${GODOT}"
    return 0
  fi
  if command -v godot4 >/dev/null 2>&1; then
    command -v godot4
    return 0
  fi
  if command -v godot >/dev/null 2>&1; then
    command -v godot
    return 0
  fi
  for candidate in \
    "/Applications/Godot.app/Contents/MacOS/Godot" \
    "${PROJECT_ROOT}/Godot.app/Contents/MacOS/Godot"
  do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

if ! GODOT_BIN="$(find_godot)"; then
  printf '%s\n' \
    "Godot 4 was not found." \
    "Install Godot 4.7, add it to PATH, or set GODOT to the executable."
  exit 1
fi

case "${MODE}" in
  run)
    exec "${GODOT_BIN}" --path "${PROJECT_ROOT}"
    ;;
  editor)
    exec "${GODOT_BIN}" --editor --path "${PROJECT_ROOT}"
    ;;
  check)
    exec "${GODOT_BIN}" --headless --path "${PROJECT_ROOT}" --quit-after 8
    ;;
  *)
    printf 'Usage: %s [run|editor|check]\n' "$0"
    exit 2
    ;;
esac
