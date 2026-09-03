#!/usr/bin/env bash
# test-halt-predicate-events.sh — CREDIBLE-622 (CREDIBLE-109 slice):
# unit coverage for halt_predicate_emit / halt_predicate_run in
# scripts/lib/halt-class-emit.sh.
#
# Verifies each of the three distinct halt-predicate events —
# halt_predicate_success, halt_predicate_failure, halt_predicate_timeout —
# is emitted under its matching simulated condition, and that each event
# carries predicate name, timestamp, and execution duration.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
LIB="$REPO_ROOT/scripts/lib/halt-class-emit.sh"

if [[ ! -f "$LIB" ]]; then
    echo "FAIL: $LIB not found" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$LIB"

_pass=0
_fail=0
_ok()   { echo "  ✓ $*"; (( _pass++ )) || true; }
_bad()  { echo "  ✗ FAIL: $*" >&2; (( _fail++ )) || true; }

# Run inside an isolated throwaway git repo so _halt_class_lock_dir resolves
# to a scratch .chump-locks/ambient.jsonl instead of the real fleet stream.
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
( cd "$WORKDIR" && git init -q . )
cd "$WORKDIR"
AMBIENT="$WORKDIR/.chump-locks/ambient.jsonl"

_last_event_field() {
    local kind="$1" field="$2"
    python3 -c "
import json, sys
kind, field = sys.argv[1], sys.argv[2]
last = None
with open(sys.argv[3]) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        rec = json.loads(line)
        if rec.get('kind') == kind:
            last = rec
if last is None:
    sys.exit(1)
print(last.get(field, ''))
" "$kind" "$field" "$AMBIENT"
}

_event_count() {
    local kind="$1"
    grep -cE "\"kind\":[[:space:]]*\"$kind\"" "$AMBIENT" 2>/dev/null || true
}

# ── Direct halt_predicate_emit coverage ─────────────────────────────────────

halt_predicate_emit "unit-test-predicate" success 42 '{"probe":"direct"}'
if [[ "$(_event_count halt_predicate_success)" -eq 1 ]]; then
    _ok "halt_predicate_emit success -> halt_predicate_success emitted"
else
    _bad "halt_predicate_emit success did not emit halt_predicate_success"
fi

halt_predicate_emit "unit-test-predicate" failure 17 '{"probe":"direct"}'
if [[ "$(_event_count halt_predicate_failure)" -eq 1 ]]; then
    _ok "halt_predicate_emit failure -> halt_predicate_failure emitted"
else
    _bad "halt_predicate_emit failure did not emit halt_predicate_failure"
fi

halt_predicate_emit "unit-test-predicate" timeout 900 '{"probe":"direct"}'
if [[ "$(_event_count halt_predicate_timeout)" -eq 1 ]]; then
    _ok "halt_predicate_emit timeout -> halt_predicate_timeout emitted"
else
    _bad "halt_predicate_emit timeout did not emit halt_predicate_timeout"
fi

# Payload shape: predicate name, timestamp, duration on every emitted kind.
for kind in halt_predicate_success halt_predicate_failure halt_predicate_timeout; do
    predicate="$(_last_event_field "$kind" predicate || true)"
    ts="$(_last_event_field "$kind" ts || true)"
    duration="$(_last_event_field "$kind" duration_ms || true)"
    if [[ "$predicate" == "unit-test-predicate" ]]; then
        _ok "$kind carries predicate name"
    else
        _bad "$kind missing/wrong predicate field (got '$predicate')"
    fi
    if [[ -n "$ts" ]]; then
        _ok "$kind carries a timestamp"
    else
        _bad "$kind missing ts field"
    fi
    if [[ "$duration" =~ ^[0-9]+$ ]]; then
        _ok "$kind carries a numeric duration_ms"
    else
        _bad "$kind missing/non-numeric duration_ms (got '$duration')"
    fi
done

# Invalid status must be rejected, not silently swallowed.
if halt_predicate_emit "unit-test-predicate" bogus 1 2>/dev/null; then
    _bad "halt_predicate_emit accepted an invalid status"
else
    _ok "halt_predicate_emit rejects an invalid status"
fi

# ── halt_predicate_run: simulated success / failure / timeout conditions ───

: > "$AMBIENT"

halt_predicate_run "run-success" 5 -- true
[[ "$(_event_count halt_predicate_success)" -eq 1 ]] \
    && _ok "halt_predicate_run(true) -> halt_predicate_success" \
    || _bad "halt_predicate_run(true) did not emit halt_predicate_success"

halt_predicate_run "run-failure" 5 -- false || true
[[ "$(_event_count halt_predicate_failure)" -eq 1 ]] \
    && _ok "halt_predicate_run(false) -> halt_predicate_failure" \
    || _bad "halt_predicate_run(false) did not emit halt_predicate_failure"

if command -v timeout >/dev/null 2>&1; then
    halt_predicate_run "run-timeout" 1 -- sleep 5 || true
    [[ "$(_event_count halt_predicate_timeout)" -eq 1 ]] \
        && _ok "halt_predicate_run(sleep 5, 1s budget) -> halt_predicate_timeout" \
        || _bad "halt_predicate_run(sleep 5, 1s budget) did not emit halt_predicate_timeout"
else
    echo "  (skip: 'timeout' binary not available on this host)"
fi

echo ""
echo "halt-predicate-events: $_pass passed, $_fail failed"
[[ "$_fail" -eq 0 ]]
