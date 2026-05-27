#!/usr/bin/env bash
# freshness-gate.sh — META-115 (sub-gap of META-114 freshness discipline cluster)
#
# Thin wrapper over freshness-preamble.sh that REFUSES the next operation
# when classification is CRITICAL_STALE, unless CHUMP_ACCEPT_STALE=1 is set.
#
# Usage (chains with && so refusal blocks the downstream MUTATE-class op):
#
#   bash scripts/coord/freshness-gate.sh && chump claim INFRA-NNNN
#
# Exit codes:
#   0 — FRESH or STALE: proceed
#   2 — CRITICAL_STALE: refuse (operator must rebase + reinstall binary)
#
# Bypass: CHUMP_ACCEPT_STALE=1 forces exit 0 but emits an audit-trail event
# `kind=freshness_critical_stale_bypassed` to .chump-locks/ambient.jsonl with
# {commits_behind, binary_age_s}.
#
# Why this exists: every "stale-tree false-positive" gap (e.g. shepherd's
# 2026-05-27 `recovery-queue-emit.sh phantom-missing`) starts with a MUTATE
# operation against a stale local view. Blocking at the gate catches the
# whole class.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PREAMBLE="$SCRIPT_DIR/freshness-preamble.sh"

if [[ ! -f "$PREAMBLE" ]]; then
    printf '[freshness-gate] ERROR: preamble script missing at %s\n' "$PREAMBLE" >&2
    # Defensive fail-open: missing preamble must not silently block operators.
    exit 0
fi

# Run preamble, capture JSON for audit-trail field extraction on bypass.
set +e
preamble_json="$(bash "$PREAMBLE" --json)"
preamble_rc=$?
set -e

# Human-readable line on stderr so chains like `&& chump claim` keep their
# own stdout clean.
printf '[freshness-gate] %s\n' "$preamble_json" >&2

if [[ $preamble_rc -ne 2 ]]; then
    # FRESH (0) or STALE (1) — proceed.
    exit 0
fi

# CRITICAL_STALE path.
if [[ "${CHUMP_ACCEPT_STALE:-0}" == "1" ]]; then
    # Audit-trail emit.
    ambient="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cb="$(printf '%s' "$preamble_json" | python3 -c \
        'import json,sys; d=json.load(sys.stdin); print(d.get("commits_behind","unknown"))' 2>/dev/null || echo unknown)"
    bas="$(printf '%s' "$preamble_json" | python3 -c \
        'import json,sys; d=json.load(sys.stdin); print(d.get("binary_age_s","unknown"))' 2>/dev/null || echo unknown)"
    mkdir -p "$(dirname "$ambient")" 2>/dev/null || true
    # scanner-anchor: "kind":"freshness_critical_stale_bypassed"
    printf '{"ts":"%s","kind":"freshness_critical_stale_bypassed","source":"freshness-gate.sh","commits_behind":"%s","binary_age_s":"%s"}\n' \
        "$ts" "$cb" "$bas" \
        >> "$ambient" 2>/dev/null || true
    printf '[freshness-gate] CRITICAL_STALE bypassed via CHUMP_ACCEPT_STALE=1 — proceeding (audit emitted).\n' >&2
    exit 0
fi

printf '[freshness-gate] REFUSED: CRITICAL_STALE — rebase main + reinstall binary, or set CHUMP_ACCEPT_STALE=1 to bypass.\n' >&2
exit 2
