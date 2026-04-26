#!/usr/bin/env bash
# Lane A smoke — cheap checks for RESEARCH-018 harness surface (no API calls).
# Run from repo root: bash scripts/eval/research-lane-a-smoke.sh

set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

PY="${PYTHON:-python3.12}"
if ! command -v "$PY" >/dev/null 2>&1; then
    PY=python3
fi

echo "[research-lane-a-smoke] gen-null-prose --self-test ($PY)"
"$PY" scripts/ab-harness/gen-null-prose.py --self-test

echo "[research-lane-a-smoke] py_compile run-cloud-v2.py ($PY)"
"$PY" -m py_compile scripts/ab-harness/run-cloud-v2.py

echo "[research-lane-a-smoke] py_compile together_spend_gate.py ($PY)"
"$PY" -m py_compile scripts/ab-harness/together_spend_gate.py

echo "[research-lane-a-smoke] bash -n run-cloud-v2-with-env.sh"
bash -n scripts/ab-harness/run-cloud-v2-with-env.sh

echo "[research-lane-a-smoke] run-cloud-v2.py --help ($PY)"
"$PY" scripts/ab-harness/run-cloud-v2.py --help >/dev/null

echo "[research-lane-a-smoke] together_spend_gate.py self-test ($PY)"
"$PY" scripts/ab-harness/together_spend_gate.py

echo "[research-lane-a-smoke] OK"
