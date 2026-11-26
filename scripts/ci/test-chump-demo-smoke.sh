#!/usr/bin/env bash
# INFRA-2391: smoke test for `chump demo` — wires the META-072 chump-demo
# crate (previously a standalone, undiscoverable binary) as a `chump`
# subcommand.
#
# Asserts:
#   1. `chump demo --help` exits 0 (forwards to chump-demo's clap parser)
#   2. `chump demo --dry-run --seed 1 --duration 1s` exits 0 end-to-end and
#      writes a well-shaped JSON metrics report
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

find_bin() {
  local name="$1"
  if [[ "$name" == "chump" && -n "${CHUMP_BIN:-}" && -x "${CHUMP_BIN}" ]]; then
    echo "$CHUMP_BIN"
  elif [[ -n "${CARGO_TARGET_DIR:-}" ]] && [[ -x "$CARGO_TARGET_DIR/debug/$name" ]]; then
    echo "$CARGO_TARGET_DIR/debug/$name"
  elif [[ -n "${CARGO_TARGET_DIR:-}" ]] && [[ -x "$CARGO_TARGET_DIR/release/$name" ]]; then
    echo "$CARGO_TARGET_DIR/release/$name"
  elif [[ -x "$ROOT/target/debug/$name" ]]; then
    echo "$ROOT/target/debug/$name"
  elif [[ -x "$ROOT/target/release/$name" ]]; then
    echo "$ROOT/target/release/$name"
  fi
}

CHUMP="$(find_bin chump)"
DEMO="$(find_bin chump-demo)"
if [[ -z "$CHUMP" ]] || [[ -z "$DEMO" ]]; then
  echo "test-chump-demo-smoke: building chump + chump-demo …" >&2
  if ! command -v cargo >/dev/null 2>&1; then
    echo "  SKIP: cargo not on PATH" >&2
    exit 77
  fi
  cargo build -q -p chump --bin chump -p chump-demo --bin chump-demo 2>&1 || {
    echo "  FAIL: cargo build failed" >&2
    exit 1
  }
  CHUMP="$(find_bin chump)"
  DEMO="$(find_bin chump-demo)"
  if [[ -z "$CHUMP" ]] || [[ -z "$DEMO" ]]; then
    echo "  FAIL: binaries still missing after cargo build" >&2
    exit 1
  fi
fi
export PATH="$(dirname "$DEMO"):$PATH"

fail=0

echo "[1/2] chump demo --help exits 0"
if ! "$CHUMP" demo --help >/dev/null 2>&1; then
  echo "  FAIL: chump demo --help did not exit 0"
  fail=1
fi

echo "[2/2] chump demo --dry-run runs end-to-end and writes a metrics report"
REPORT="$TMP/report.json"
if ! "$CHUMP" demo --dry-run --seed 1 --duration 1s --report-path "$REPORT" >/dev/null 2>&1; then
  echo "  FAIL: chump demo --dry-run did not exit 0"
  fail=1
fi
if [[ ! -f "$REPORT" ]]; then
  echo "  FAIL: metrics report was not written to $REPORT"
  fail=1
else
  for field in schema_version started_at ended_at prs_merged_per_hour; do
    if ! grep -q "\"$field\"" "$REPORT"; then
      echo "  FAIL: report missing expected field: $field"
      fail=1
    fi
  done
fi

if [[ "$fail" -eq 0 ]]; then
  echo "test-chump-demo-smoke: PASS"
else
  echo "test-chump-demo-smoke: FAIL"
fi
exit "$fail"
