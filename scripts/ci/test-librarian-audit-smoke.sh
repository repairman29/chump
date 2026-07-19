#!/usr/bin/env bash
# test-librarian-audit-smoke.sh — Phase 1 Librarian sweep smoke test (INFRA-1781).
#
# Runs `chump librarian audit <fixture-repo>` against a tiny synthetic
# fixture and asserts:
#   1. exit code 0
#   2. <fixture>/.chump-ingest/triage.md is written and non-empty
#   3. kind=librarian_audit_started and kind=librarian_audit_complete both
#      land in ambient.jsonl (observability contract, this gap's AC #1)
#   4. --json output parses and reports files_scanned >= 2 and a positive
#      cost_usd_cents (AC #2, cost tracked)
#   5. a missing target path produces failure_class=permanent (AC #3)
#
# Usage:
#   ./scripts/ci/test-librarian-audit-smoke.sh
#   CHUMP_BIN=./target/release/chump ./scripts/ci/test-librarian-audit-smoke.sh
#
# Exit: 0 if all checks pass, 1 otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -n "$CHUMP_BIN" ]] && [[ ! -x "$CHUMP_BIN" ]] && [[ ! -x "$ROOT/$CHUMP_BIN" ]]; then
  echo "WARN: \$CHUMP_BIN='$CHUMP_BIN' not executable; falling through to discovery" >&2
  CHUMP_BIN=""
fi
if [[ -z "$CHUMP_BIN" ]]; then
  if [[ -n "${CARGO_TARGET_DIR:-}" ]] && [[ -x "$CARGO_TARGET_DIR/release/chump" ]]; then
    CHUMP_BIN="$CARGO_TARGET_DIR/release/chump"
  elif [[ -n "${CARGO_TARGET_DIR:-}" ]] && [[ -x "$CARGO_TARGET_DIR/debug/chump" ]]; then
    CHUMP_BIN="$CARGO_TARGET_DIR/debug/chump"
  elif [[ -x "$ROOT/target/release/chump" ]]; then
    CHUMP_BIN="$ROOT/target/release/chump"
  elif [[ -x "$ROOT/target/debug/chump" ]]; then
    CHUMP_BIN="$ROOT/target/debug/chump"
  else
    echo "ERROR: no chump binary found; run 'cargo build' first" >&2
    exit 1
  fi
fi
echo "[librarian-audit-smoke] using CHUMP_BIN=$CHUMP_BIN" >&2

PASS=0
FAIL=0
ERRORS=()

check() {
  local label="$1" cond="$2"
  if [[ "$cond" == "0" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label" >&2
    FAIL=$((FAIL + 1))
    ERRORS+=("$label")
  fi
}

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

FIXTURE="$WORKDIR/fixture-repo"
mkdir -p "$FIXTURE"
printf '// TODO: refactor this\nfn main() {}\n' > "$FIXTURE/main.rs"
printf 'hello world\n' > "$FIXTURE/README.md"

CHUMP_HOME="$WORKDIR/chump-home"
mkdir -p "$CHUMP_HOME"
AMBIENT="$CHUMP_HOME/.chump-locks/ambient.jsonl"

echo "--- happy path ---"
set +e
OUT_JSON="$(cd "$CHUMP_HOME" && CHUMP_AMBIENT_IN_PROMPT="$AMBIENT" "$CHUMP_BIN" librarian audit "$FIXTURE" --json)"
RC=$?
set -e
check "exit code 0" "$RC"
check "triage.md written" "$([[ -s "$FIXTURE/.chump-ingest/triage.md" ]] && echo 0 || echo 1)"

FILES_SCANNED="$(echo "$OUT_JSON" | grep -o '"files_scanned":[0-9]*' | grep -o '[0-9]*' || echo 0)"
COST_CENTS="$(echo "$OUT_JSON" | grep -o '"cost_usd_cents":[0-9]*' | grep -o '[0-9]*' || echo 0)"
check "files_scanned >= 2" "$([[ "$FILES_SCANNED" -ge 2 ]] && echo 0 || echo 1)"
check "cost_usd_cents > 0" "$([[ "$COST_CENTS" -gt 0 ]] && echo 0 || echo 1)"

check "ambient has librarian_audit_started" "$(grep -q '"kind":"librarian_audit_started"' "$AMBIENT" && echo 0 || echo 1)"
check "ambient has librarian_audit_complete" "$(grep -q '"kind":"librarian_audit_complete"' "$AMBIENT" && echo 0 || echo 1)"

echo "--- failure path (missing target) ---"
set +e
FAIL_OUT="$(cd "$CHUMP_HOME" && CHUMP_AMBIENT_IN_PROMPT="$AMBIENT" "$CHUMP_BIN" librarian audit "$WORKDIR/does-not-exist" 2>&1)"
FAIL_RC=$?
set -e
check "missing target exits non-zero" "$([[ "$FAIL_RC" -ne 0 ]] && echo 0 || echo 1)"
check "missing target reports permanent failure_class" "$(echo "$FAIL_OUT" | grep -q 'permanent' && echo 0 || echo 1)"
check "ambient has librarian_audit_failed" "$(grep -q '"kind":"librarian_audit_failed"' "$AMBIENT" && echo 0 || echo 1)"

echo ""
echo "librarian-audit-smoke: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  printf 'Failed checks: %s\n' "${ERRORS[*]}" >&2
  exit 1
fi
exit 0
