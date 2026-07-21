#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON:-python3}"

"${PYTHON_BIN}" -m venv "${PROJECT_ROOT}/.venv"
"${PROJECT_ROOT}/.venv/bin/python" -m pip install --upgrade pip
"${PROJECT_ROOT}/.venv/bin/python" -m pip install -r "${PROJECT_ROOT}/requirements-rl.txt"
"${PROJECT_ROOT}/.venv/bin/python" -c "import gymnasium, stable_baselines3, torch; print('RL runtime ready:', stable_baselines3.__version__)"
