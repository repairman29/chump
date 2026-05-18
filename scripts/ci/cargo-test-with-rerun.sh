#!/usr/bin/env bash
# cargo-test-with-rerun.sh — INFRA-764
#
# Wraps `cargo test` (or any test command) with a one-shot auto-rerun
# when EVERY failing test name appears in docs/process/KNOWN_FLAKES.yaml.
# Frees CI / queue-monitor / operator from manual "rerun and hope" cycles
# on known races while preserving fail-loud behavior for real bugs.
#
# Usage
#   scripts/ci/cargo-test-with-rerun.sh -- cargo test --bin chump --tests
#   scripts/ci/cargo-test-with-rerun.sh -- bash some_test_runner.sh
#
# Anything after `--` is the command to run. The wrapper:
#   1. Runs the command, captures stdout+stderr.
#   2. If exit 0 → done.
#   3. If exit != 0 → parse failed test names from cargo's standard
#      "test foo::bar ... FAILED" lines.
#   4. Look up each failed name in KNOWN_FLAKES.yaml.
#      - If ALL are listed → emit kind=flake_autorerun_initiated, run once
#        more. If green → emit kind=flake_autorerun_recovered, exit 0.
#        If still red → emit kind=flake_autorerun_persisted, exit 1.
#      - If ANY is NOT listed → exit 1 with the original output (real bug
#        or unknown flake; do NOT auto-rerun).
#
# Bypass: CHUMP_FLAKE_AUTORERUN=0 — wrapper exits with the first run's
#         exit code regardless of whether failures are in the catalog.
#         Use when you want the raw signal (e.g. debugging the harness
#         itself).

set -uo pipefail

# INFRA-1600: self-hosted macOS runners inherit a launchd PATH that lacks
# $HOME/.cargo/bin. Without this, the `cargo` invocation below 127s.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/lib/ensure-cargo-on-path.sh" ]]; then
    # shellcheck source=lib/ensure-cargo-on-path.sh
    source "$SCRIPT_DIR/lib/ensure-cargo-on-path.sh"
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CATALOG="$REPO_ROOT/docs/process/KNOWN_FLAKES.yaml"

# Find ambient log; fall back to stderr if path can't be resolved.
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true

# Emit a structured ambient event (best-effort; never fails the wrapper).
emit_ambient() {
    local kind="$1"; shift
    local note="$*"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    local payload
    payload=$(printf '{"ts":"%s","event":"INFO","kind":"%s","source":"cargo-test-with-rerun","note":"%s"}\n' \
        "$ts" "$kind" "$note")
    if [[ -w "$(dirname "$AMBIENT")" ]] 2>/dev/null; then
        echo "$payload" >> "$AMBIENT" 2>/dev/null || true
    fi
    # Also echo to stderr so CI logs surface the event.
    echo "[flake-autorerun] $payload" >&2
}

# Parse `--` separator and recover the command to run.
# INFRA-1612: only treat the FIRST `--` as the separator; all subsequent
# args (including any later `--` passed to cargo test as the argument
# boundary before --skip/--exact/etc.) are appended verbatim to CMD.
SEP_FOUND=0
CMD=()
for arg in "$@"; do
    if [[ "$SEP_FOUND" == "0" && "$arg" == "--" ]]; then
        SEP_FOUND=1
        continue
    fi
    if [[ "$SEP_FOUND" == "1" ]]; then
        CMD+=("$arg")
    fi
done
if [[ "${#CMD[@]}" -eq 0 ]]; then
    echo "[flake-autorerun] usage: $0 -- <cmd> [args...]" >&2
    exit 2
fi

# Bypass: just run the command and pass through.
if [[ "${CHUMP_FLAKE_AUTORERUN:-1}" == "0" ]]; then
    exec "${CMD[@]}"
fi

# Read catalog into a sorted-unique list of test names. Empty when the
# YAML has no entries (the default state — see INFRA-764 doc).
read_catalog() {
    if [[ ! -f "$CATALOG" ]]; then
        return 0
    fi
    grep -E '^[[:space:]]*-[[:space:]]*test:[[:space:]]+' "$CATALOG" 2>/dev/null \
        | sed -E 's/^[[:space:]]*-[[:space:]]*test:[[:space:]]+//; s/[[:space:]]*#.*$//; s/^"//; s/"$//' \
        | sort -u
}

# Capture run output. Use a tee to a temp file so we get both live
# streaming (CI logs) and a parseable copy.
LOG="$(mktemp -t flake-autorerun.XXXXXX)"
trap 'rm -f "$LOG"' EXIT

run_once() {
    "${CMD[@]}" 2>&1 | tee "$LOG"
    return "${PIPESTATUS[0]}"
}

run_once
RC=$?
if [[ "$RC" -eq 0 ]]; then
    exit 0
fi

# Parse failed test names from cargo's "test foo::bar ... FAILED" lines.
# Format: "test <module::path::name> ... FAILED" (whitespace separator).
FAILED=$(grep -E '^test [A-Za-z_][A-Za-z0-9_:]+ \.\.\. FAILED' "$LOG" 2>/dev/null \
    | sed -E 's/^test ([A-Za-z_][A-Za-z0-9_:]+) \.\.\. FAILED.*/\1/' \
    | sort -u)

if [[ -z "$FAILED" ]]; then
    # Failure but no parseable test names (e.g. compile error, runner OOM).
    # Don't auto-rerun — the failure isn't a known flake shape.
    emit_ambient "flake_autorerun_skipped" "no parseable failed-test names; not a flake shape"
    exit "$RC"
fi

CATALOG_TESTS="$(read_catalog)"

# Determine whether every failing test is in the catalog.
ALL_KNOWN=1
UNKNOWN=()
while IFS= read -r failed_name; do
    [[ -z "$failed_name" ]] && continue
    if ! grep -qxF "$failed_name" <<< "$CATALOG_TESTS"; then
        ALL_KNOWN=0
        UNKNOWN+=("$failed_name")
    fi
done <<< "$FAILED"

if [[ "$ALL_KNOWN" -eq 0 ]]; then
    # At least one failure is real (or an undocumented flake). Don't rerun.
    emit_ambient "flake_autorerun_skipped" "$(printf '%d unknown failure(s); ALL must be in catalog to auto-rerun' "${#UNKNOWN[@]}")"
    echo "[flake-autorerun] not auto-rerunning — at least one failed test is not in" >&2
    echo "[flake-autorerun] $CATALOG. Failures must ALL be catalogued to qualify." >&2
    echo "[flake-autorerun] Unknown: ${UNKNOWN[*]}" >&2
    exit "$RC"
fi

# Every failure is a known flake. Run once more.
FAILED_LIST=$(echo "$FAILED" | tr '\n' ',' | sed 's/,$//')
emit_ambient "flake_autorerun_initiated" "retrying $FAILED_LIST per KNOWN_FLAKES.yaml"
echo "[flake-autorerun] all failures are in $CATALOG; running once more" >&2

run_once
RC2=$?

if [[ "$RC2" -eq 0 ]]; then
    emit_ambient "flake_autorerun_recovered" "rerun green for $FAILED_LIST"
    echo "[flake-autorerun] ✓ rerun green; treating as transient flake recovery" >&2
    exit 0
else
    emit_ambient "flake_autorerun_persisted" "still red after rerun: $FAILED_LIST"
    echo "[flake-autorerun] ✗ still red after rerun; persistent failure" >&2
    exit "$RC2"
fi
