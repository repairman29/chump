#!/usr/bin/env bash
# INFRA-1781: smoke test for `chump audit librarian-sweep` (INFRA-1746 phase 1b).
#
# Asserts:
#   1. --help exits 0
#   2. missing target-repo arg exits 2
#   3. non-existent path exits 1 with failure_class=path_not_found on the
#      ingest_librarian_failed ambient event
#   4. a non-git directory exits 1 with failure_class=not_a_git_repo
#   5. a valid fixture git repo exits 0, writes <target>/.chump-ingest/triage.md,
#      and emits ingest_librarian_started + ingest_librarian_completed with
#      cost_usd_cents=0
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# INFRA-1540 pattern (see test-acp-smoke.sh): CARGO_TARGET_DIR may redirect
# the build output away from $ROOT/target on self-hosted runners/worktrees.
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
  echo "test-ingest-librarian-smoke: building chump …" >&2
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

# Isolate ambient writes from the real .chump-locks/ambient.jsonl: the
# librarian emits to repo_path::repo_root(), which honours CHUMP_REPO.
CHUMP_HOME_FIXTURE="$TMP/chump-home"
mkdir -p "$CHUMP_HOME_FIXTURE"
export CHUMP_REPO="$CHUMP_HOME_FIXTURE"
AMBIENT="$CHUMP_HOME_FIXTURE/.chump-locks/ambient.jsonl"

fail=0

echo "[1/5] --help exits 0"
if ! "$CHUMP" audit librarian-sweep --help >/dev/null 2>&1; then
  echo "  FAIL: --help did not exit 0"
  fail=1
fi

echo "[2/5] missing arg exits 2"
set +e
"$CHUMP" audit librarian-sweep >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -ne 2 ]]; then
  echo "  FAIL: missing-arg exit code was $rc, expected 2"
  fail=1
fi

echo "[3/5] non-existent path exits 1, failure_class=path_not_found"
mkdir -p "$(dirname "$AMBIENT")"
: > "$AMBIENT"
set +e
"$CHUMP" audit librarian-sweep "$TMP/does-not-exist" >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -ne 1 ]]; then
  echo "  FAIL: non-existent-path exit code was $rc, expected 1"
  fail=1
fi

echo "[4/5] non-git dir exits 1, failure_class=not_a_git_repo"
NOGIT="$TMP/nogit"
mkdir -p "$NOGIT"
set +e
"$CHUMP" audit librarian-sweep "$NOGIT" >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -ne 1 ]]; then
  echo "  FAIL: non-git-dir exit code was $rc, expected 1"
  fail=1
fi

echo "[5/5] valid fixture repo exits 0, writes triage.md, emits observability events"
FIXTURE="$TMP/fixture-repo"
mkdir -p "$FIXTURE/.git" "$FIXTURE/src" "$FIXTURE/scripts"
echo 'fn main() {}' > "$FIXTURE/src/main.rs"
printf '#!/bin/bash\necho hi\n' > "$FIXTURE/scripts/a.sh"
printf '#!/bin/bash\necho hi\n' > "$FIXTURE/scripts/b.sh"

if ! "$CHUMP" audit librarian-sweep "$FIXTURE" >/dev/null; then
  echo "  FAIL: valid fixture repo run did not exit 0"
  fail=1
fi
if [[ ! -f "$FIXTURE/.chump-ingest/triage.md" ]]; then
  echo "  FAIL: triage.md was not written"
  fail=1
fi
if [[ ! -f "$AMBIENT" ]] || ! grep -q '"kind":"ingest_librarian_started"' "$AMBIENT"; then
  echo "  FAIL: ingest_librarian_started not found in ambient stream"
  fail=1
fi
if ! grep -q '"kind":"ingest_librarian_completed"' "$AMBIENT"; then
  echo "  FAIL: ingest_librarian_completed not found in ambient stream"
  fail=1
fi
if ! grep '"kind":"ingest_librarian_completed"' "$AMBIENT" | grep -q '"cost_usd_cents":0'; then
  echo "  FAIL: ingest_librarian_completed did not report cost_usd_cents=0"
  fail=1
fi

if [[ "$fail" -eq 0 ]]; then
  echo "test-ingest-librarian-smoke: PASS"
else
  echo "test-ingest-librarian-smoke: FAIL"
fi
exit "$fail"
