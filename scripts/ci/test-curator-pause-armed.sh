#!/usr/bin/env bash
# test-curator-pause-armed.sh — META-065
#
# Exercises the two operator-facing curator hooks added by META-065:
#   - CHUMP_CURATOR_PAUSE=1 short-circuits the run with kind=curator_paused
#   - first run after install emits kind=curator_auto_exec_armed once,
#     then writes a sentinel so subsequent runs don't re-emit
#
# Verified against the real opus-curator.sh — no synthetic stub —
# so we catch regressions when the curator script is refactored.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CURATOR="$REPO_ROOT/scripts/coord/opus-curator.sh"

echo "=== META-065 curator pause + auto-exec-armed tests ==="

[[ -x "$CURATOR" ]] || { fail "curator not executable at $CURATOR"; exit 1; }
ok "curator present + executable"

# Sanity: the new env hatch + sentinel logic are present.
if grep -q 'CHUMP_CURATOR_PAUSE' "$CURATOR"; then
    ok "CHUMP_CURATOR_PAUSE check wired in opus-curator.sh"
else
    fail "CHUMP_CURATOR_PAUSE check missing"
fi

if grep -q 'curator_auto_exec_armed' "$CURATOR"; then
    ok "curator_auto_exec_armed first-run emit wired"
else
    fail "curator_auto_exec_armed emit missing"
fi

if grep -q 'curator-armed.sentinel' "$CURATOR"; then
    ok "first-run sentinel path referenced"
else
    fail "sentinel path missing"
fi

# ── Behavioral test 1: PAUSE=1 → early exit + ambient emit ───────────────────
TMP="$(mktemp -d -t curator-pause.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.chump-locks"
# Stub HOME to keep launchd-related side-effects sandboxed.
CHUMP_CURATOR_PAUSE=1 \
CHUMP_AMBIENT_LOG="$TMP/.chump-locks/ambient.jsonl" \
REPO_ROOT="$TMP" \
HOME="$TMP" \
  bash "$CURATOR" 2>&1 | head -3 > "$TMP/pause.out"

if grep -q 'OPUS CURATOR PAUSED' "$TMP/pause.out"; then
    ok "PAUSE=1: short-circuits with 'OPUS CURATOR PAUSED' message"
else
    fail "PAUSE=1: did not short-circuit (see: $(cat $TMP/pause.out))"
fi

if [[ -f "$TMP/.chump-locks/ambient.jsonl" ]] && grep -q 'curator_paused' "$TMP/.chump-locks/ambient.jsonl"; then
    ok "PAUSE=1: emits kind=curator_paused to ambient"
else
    fail "PAUSE=1: ambient emit missing"
fi

# Sentinel should NOT be created during a paused run.
if [[ ! -f "$TMP/.chump-locks/curator-armed.sentinel" ]]; then
    ok "PAUSE=1: does not write the first-run sentinel"
else
    fail "PAUSE=1: incorrectly wrote sentinel"
fi

# ── Behavioral test 2: launchd plist has RunAtLoad=true ─────────────────────
INSTALLER="$REPO_ROOT/scripts/setup/install-curator-launchd.sh"
if grep -A1 'RunAtLoad' "$INSTALLER" | grep -q '<true/>'; then
    ok "installer plist sets RunAtLoad=true (first install fires)"
else
    fail "installer still has RunAtLoad=false"
fi

# ── Behavioral test 3: registry has the two new kinds ───────────────────────
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
for kind in curator_paused curator_auto_exec_armed; do
    if grep -q "^  - kind: $kind\$" "$REGISTRY"; then
        ok "EVENT_REGISTRY.yaml registers kind=$kind"
    else
        fail "kind=$kind not registered in EVENT_REGISTRY.yaml"
    fi
done

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
