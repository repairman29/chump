#!/usr/bin/env bash
# INFRA-1783: smoke test for `chump systematize` (INFRA-1746 phase 4).
#
# Asserts:
#   1. --help exits 0
#   2. missing target-repo arg exits 2
#   3. non-existent path exits 2 (Permanent/PathNotFound) with
#      systematizer_failed failure_class=path_not_found
#   4. a fixture repo exits 0, writes <target>/docs/CAPABILITIES_REGISTRY.json
#      that validates as JSON with expected fields, and emits
#      systematizer_started + systematizer_completed
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CHUMP="${CHUMP_BIN:-}"
if [[ -n "$CHUMP" ]] && [[ ! -x "$CHUMP" ]]; then
  CHUMP=""
fi
find_chump_bin() {
  if [[ -n "${CARGO_TARGET_DIR:-}" ]] && [[ -x "$CARGO_TARGET_DIR/debug/chump" ]]; then
    echo "$CARGO_TARGET_DIR/debug/chump"
  elif [[ -x "$ROOT/target/debug/chump" ]]; then
    echo "$ROOT/target/debug/chump"
  fi
}
if [[ -z "$CHUMP" ]]; then
  CHUMP="$(find_chump_bin)"
fi
if [[ -z "$CHUMP" ]]; then
  echo "test-systematizer-smoke: building chump …" >&2
  if ! command -v cargo >/dev/null 2>&1; then
    echo "  SKIP: cargo not on PATH" >&2
    exit 0
  fi
  cargo build -q --bin chump 2>&1 || {
    echo "  SKIP: cargo build failed" >&2
    exit 0
  }
  CHUMP="$(find_chump_bin)"
  if [[ -z "$CHUMP" ]]; then
    echo "  SKIP: chump binary still missing after cargo build (tried CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-<unset>} and $ROOT/target/debug/chump)" >&2
    exit 0
  fi
fi

# Isolate ambient writes from the real .chump-locks/ambient.jsonl: systematize
# emits to repo_path::repo_root(), which honours CHUMP_REPO.
CHUMP_HOME_FIXTURE="$TMP/chump-home"
mkdir -p "$CHUMP_HOME_FIXTURE"
export CHUMP_REPO="$CHUMP_HOME_FIXTURE"
AMBIENT="$CHUMP_HOME_FIXTURE/.chump-locks/ambient.jsonl"

fail=0

echo "[1/4] --help exits 0"
if ! "$CHUMP" systematize --help >/dev/null 2>&1; then
  echo "  FAIL: --help did not exit 0"
  fail=1
fi

echo "[2/4] missing arg exits 2"
set +e
"$CHUMP" systematize >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -ne 2 ]]; then
  echo "  FAIL: missing-arg exit code was $rc, expected 2"
  fail=1
fi

echo "[3/4] non-existent path exits 2, failure_class=path_not_found"
mkdir -p "$(dirname "$AMBIENT")"
: > "$AMBIENT"
set +e
"$CHUMP" systematize "$TMP/does-not-exist" >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -ne 2 ]]; then
  echo "  FAIL: non-existent-path exit code was $rc, expected 2"
  fail=1
fi
if ! grep -q '"kind":"systematizer_failed"' "$AMBIENT"; then
  echo "  FAIL: systematizer_failed not found in ambient stream"
  fail=1
fi
if ! grep '"kind":"systematizer_failed"' "$AMBIENT" | grep -q '"failure_class":"path_not_found"'; then
  echo "  FAIL: systematizer_failed did not report failure_class=path_not_found"
  fail=1
fi

echo "[4/4] valid fixture repo exits 0, writes CAPABILITIES_REGISTRY.json, emits observability events"
FIXTURE="$TMP/fixture-repo"
mkdir -p "$FIXTURE/.git" "$FIXTURE/src" "$FIXTURE/scripts"
echo 'fn main() {}' > "$FIXTURE/src/main.rs"
printf '#!/usr/bin/env bash\necho hi\n' > "$FIXTURE/scripts/run.sh"

if ! "$CHUMP" systematize "$FIXTURE" >/dev/null; then
  echo "  FAIL: valid fixture repo run did not exit 0"
  fail=1
fi
REGISTRY="$FIXTURE/docs/CAPABILITIES_REGISTRY.json"
if [[ ! -f "$REGISTRY" ]]; then
  echo "  FAIL: CAPABILITIES_REGISTRY.json was not written"
  fail=1
elif command -v jq >/dev/null 2>&1; then
  if ! jq -e '.capabilities | type == "array"' "$REGISTRY" >/dev/null 2>&1; then
    echo "  FAIL: CAPABILITIES_REGISTRY.json .capabilities is not an array"
    fail=1
  fi
  if ! jq -e '.capabilities | any(.primitive_id == "cli-src")' "$REGISTRY" >/dev/null 2>&1; then
    echo "  FAIL: CAPABILITIES_REGISTRY.json did not detect the Rust bin entry point"
    fail=1
  fi
  if ! jq -e '.capabilities | any(.primitive_id == "script-run")' "$REGISTRY" >/dev/null 2>&1; then
    echo "  FAIL: CAPABILITIES_REGISTRY.json did not detect the scripts/run.sh entry"
    fail=1
  fi
fi
if ! grep -q '"kind":"systematizer_started"' "$AMBIENT"; then
  echo "  FAIL: systematizer_started not found in ambient stream"
  fail=1
fi
if ! grep -q '"kind":"systematizer_completed"' "$AMBIENT"; then
  echo "  FAIL: systematizer_completed not found in ambient stream"
  fail=1
fi
if ! grep '"kind":"systematizer_completed"' "$AMBIENT" | grep -q '"cost_usd_cents":0'; then
  echo "  FAIL: systematizer_completed did not report cost_usd_cents=0"
  fail=1
fi
if ! grep '"kind":"systematizer_completed"' "$AMBIENT" | grep -q '"wrote_capabilities_registry_json":true'; then
  echo "  FAIL: systematizer_completed did not report wrote_capabilities_registry_json=true"
  fail=1
fi

if [[ "$fail" -eq 0 ]]; then
  echo "test-systematizer-smoke: PASS"
else
  echo "test-systematizer-smoke: FAIL"
fi
exit "$fail"
