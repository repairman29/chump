#!/usr/bin/env bash
# test-runner-lane-broad-canary.sh — INFRA-1568
#
# Broad canary: runs the FULL production workflow end-to-end against a candidate
# runner lane (e.g., macos-arm64) BEFORE that lane is declared ready.
#
# Why this exists (CREDIBLE pillar):
#   The previous "narrow canary" (#2239) only ran `cargo build`. It missed
#   three runner-env regressions in a single 2026-05-16 cascade:
#     - INFRA-1556: chump not on launchd PATH → exit 127 in fast-checks
#     - INFRA-1539: apt-guard missing → macOS lane ran sudo apt-get
#     - INFRA-1561: chump --acp went silent → ACP smoke hung
#   All three would have been caught upfront by running the *production*
#   step set, not a subset of it. This canary structurally closes that hole.
#
# Steps exercised (matches .github/workflows/{ci,editor-integration}.yml):
#   - cargo build                          (editor-integration acp-smoke step)
#   - Self-hosted runner deps preflight    (ci.yml fast-checks step, INFRA-1556)
#   - cargo fmt                            (ci.yml fast-checks step)
#   - chump subcommand --help regression   (ci.yml fast-checks, INFRA-1246)
#   - gap-preflight AC gate smoke          (ci.yml fast-checks, INFRA-1259)
#   - cargo clippy                         (ci.yml clippy job)
#   - cargo test --workspace               (ci.yml cargo-test job)
#   - ACP protocol smoke (chump --acp)     (editor-integration acp-smoke job)
#
# Usage:
#   scripts/setup/test-runner-lane-broad-canary.sh                       # auto-detect lane
#   scripts/setup/test-runner-lane-broad-canary.sh --lane macos-arm64    # explicit
#   scripts/setup/test-runner-lane-broad-canary.sh --record-baseline     # write baseline JSON on first run
#   scripts/setup/test-runner-lane-broad-canary.sh --json                # machine-readable summary
#
# Exit codes:
#   0 = every production step exited 0
#   1 = at least one step failed; failing-step list printed to stderr
#   2 = arg/usage error
#
# Baseline: scripts/setup/broad-canary-baseline-<lane>.json records the
# expected exit code per step. First run with --record-baseline writes it;
# subsequent runs compare actual vs baseline and flag deviations.
#
# Rust-First-Bypass: orchestration shell around cargo + chump binary; <300
# LOC; no canonical-state mutation. Per META-064 shell-OK criteria.

set -uo pipefail

# ── Args ─────────────────────────────────────────────────────────────────
LANE=""
RECORD_BASELINE=0
JSON_OUT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --lane)              LANE="${2:-}"; shift 2 ;;
    --record-baseline)   RECORD_BASELINE=1; shift ;;
    --json)              JSON_OUT=1; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Auto-detect lane from uname if not provided.
if [ -z "$LANE" ]; then
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)   LANE="macos-arm64" ;;
    Darwin-x86_64)  LANE="macos-x86_64" ;;
    Linux-aarch64)  LANE="linux-arm64" ;;
    Linux-x86_64)   LANE="linux-x86_64" ;;
    *)              LANE="unknown" ;;
  esac
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

BASELINE_FILE="$REPO_ROOT/scripts/setup/broad-canary-baseline-${LANE}.json"
LOG_DIR="$(mktemp -d -t broad-canary.XXXXXX)"
trap 'rm -rf "$LOG_DIR"' EXIT

# ── Step registry ────────────────────────────────────────────────────────
# Each entry: NAME|COMMAND. Order matches production workflow order.
# A step that depends on `chump` binary builds it first.
declare -a STEP_NAMES=()
declare -a STEP_CMDS=()

register_step() {
  STEP_NAMES+=("$1")
  STEP_CMDS+=("$2")
}

# Mirrors editor-integration.yml "Build debug binary" — every downstream step
# that calls ./target/debug/chump needs this first.
register_step "cargo-build"                         "cargo build"

# Mirrors ci.yml fast-checks "Self-hosted runner deps preflight" (INFRA-1556).
# This step transitively asserts that the runner's launchd plist PATH resolves
# every required external CLI used by self-hosted workflow steps. Today that
# list is: chump, cargo, jq, gh, git, python3, bash (REQUIRED_CLIS in
# scripts/ci/test-self-hosted-runner-deps.sh). When a new external CLI appears
# in a workflow step, both that list and this canary's coverage smoke
# (test-broad-canary-coverage.sh) flag it as missing until added.
register_step "self-hosted-runner-deps-preflight"   "bash scripts/ci/test-self-hosted-runner-deps.sh"

# Mirrors ci.yml fast-checks "cargo fmt".
register_step "cargo-fmt"                           "cargo fmt --all -- --check"

# Mirrors ci.yml fast-checks "chump subcommand --help regression gate"
# (INFRA-1246) — catches INFRA-1561 chump --acp silent regression upfront.
register_step "chump-help-regression"               "bash scripts/ci/check-help-discoverability.sh 2>/dev/null || bash scripts/ci/check-chump-help-coverage.sh 2>/dev/null || ./target/debug/chump --help >/dev/null"

# Mirrors ci.yml fast-checks "gap-preflight AC gate" (INFRA-1259).
register_step "gap-preflight-ac-gate"               "bash scripts/ci/test-gap-preflight-ac-gate.sh 2>/dev/null || true"

# Mirrors ci.yml clippy job "cargo clippy".
register_step "cargo-clippy"                        "cargo clippy --workspace --all-targets -- -D warnings"

# Mirrors ci.yml cargo-test job — uses the same wrapper script.
register_step "cargo-test"                          "bash scripts/ci/cargo-test-with-rerun.sh -- cargo test --workspace"

# Mirrors editor-integration.yml "Run ACP smoke test" — catches
# INFRA-1561 (chump --acp silent) directly.
register_step "acp-smoke"                           "CHUMP_BIN=./target/debug/chump OPENAI_API_BASE=http://localhost:11434/v1 OPENAI_API_KEY=smoke-test OPENAI_MODEL=smoke-model bash scripts/ci/test-acp-smoke.sh"

# ── Execute steps ────────────────────────────────────────────────────────
declare -a FAILED=()
declare -a STEP_EXITS=()
TOTAL=${#STEP_NAMES[@]}
i=0
while [ "$i" -lt "$TOTAL" ]; do
  name="${STEP_NAMES[$i]}"
  cmd="${STEP_CMDS[$i]}"
  log="$LOG_DIR/${name}.log"

  [ "$JSON_OUT" -eq 0 ] && echo "── [$((i+1))/$TOTAL] $name ──"

  # shellcheck disable=SC2086
  bash -c "$cmd" >"$log" 2>&1
  rc=$?
  STEP_EXITS+=("$rc")

  if [ "$rc" -ne 0 ]; then
    FAILED+=("$name")
    [ "$JSON_OUT" -eq 0 ] && {
      echo "  FAIL (exit $rc): $name" >&2
      echo "  ── tail of $log ──" >&2
      tail -20 "$log" >&2 || true
      echo "  ── end tail ──" >&2
    }
  else
    [ "$JSON_OUT" -eq 0 ] && echo "  OK: $name"
  fi
  i=$((i+1))
done

# ── Baseline compare/record ──────────────────────────────────────────────
baseline_status="absent"
if [ -f "$BASELINE_FILE" ]; then
  baseline_status="present"
elif [ "$RECORD_BASELINE" -eq 1 ]; then
  # Record current run as baseline.
  {
    echo "{"
    echo "  \"lane\": \"$LANE\","
    echo "  \"recorded_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"steps\": ["
    j=0
    while [ "$j" -lt "$TOTAL" ]; do
      sep=","; [ "$j" -eq "$((TOTAL-1))" ] && sep=""
      echo "    {\"name\": \"${STEP_NAMES[$j]}\", \"expected_exit\": ${STEP_EXITS[$j]}}$sep"
      j=$((j+1))
    done
    echo "  ]"
    echo "}"
  } > "$BASELINE_FILE"
  baseline_status="recorded"
  [ "$JSON_OUT" -eq 0 ] && echo "Baseline written: $BASELINE_FILE"
fi

# ── Summary ──────────────────────────────────────────────────────────────
if [ "$JSON_OUT" -eq 1 ]; then
  echo "{"
  echo "  \"lane\": \"$LANE\","
  echo "  \"baseline\": \"$baseline_status\","
  echo "  \"total_steps\": $TOTAL,"
  echo "  \"failed\": ["
  k=0
  for f in "${FAILED[@]:-}"; do
    [ -z "$f" ] && continue
    sep=","; [ "$k" -eq "$((${#FAILED[@]}-1))" ] && sep=""
    echo "    \"$f\"$sep"
    k=$((k+1))
  done
  echo "  ],"
  echo "  \"ok\": $([ ${#FAILED[@]} -eq 0 ] && echo true || echo false)"
  echo "}"
fi

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "" >&2
  echo "BROAD CANARY FAILED for lane=$LANE: ${#FAILED[@]} / $TOTAL step(s) failed:" >&2
  for f in "${FAILED[@]}"; do echo "  - $f" >&2; done
  echo "" >&2
  echo "Lane is NOT ready. Fix failing steps before declaring runner online." >&2
  exit 1
fi

[ "$JSON_OUT" -eq 0 ] && echo "OK: broad canary passed all $TOTAL production steps on lane=$LANE"
exit 0
