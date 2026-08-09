#!/usr/bin/env bash
# check-capabilities-freshness.sh — CREDIBLE-240
#
# docs/CAPABILITIES_REGISTRY.json is now INDEXED by almanac. That means an
# agent asking "what can the fleet do?" can be handed a chunk of this file
# with a real file:line receipt — and a receipt makes a wrong answer sound
# right. In May 2026 the committed catalog was 11 weeks old: it listed 17
# crates when the workspace had 47, and it did not know the almanac MCP server
# existed. Nothing in the repo said so.
#
# This script is the thing that says so. It compares the registry's
# `generated_at` against a threshold and prints the verdict loudly.
#
# Verdicts:
#   FRESH   — age <= threshold
#   STALE   — age >  threshold  (printed as [STALE]; exit 1 under --strict)
#   BROKEN  — missing / unparseable / no generated_at (always exit 2)
#
# Exit codes:
#   0  fresh, or stale in advisory mode (the default)
#   1  stale in --strict mode
#   2  registry missing, unparseable, or has no usable generated_at
#
# Advisory by default on purpose (same reasoning as INFRA-2475 in
# check-release-staleness.sh): a wall-clock gate must not hard-fail a required
# check and freeze the whole fleet. The scheduled regenerator is what keeps
# this green; --strict exists for the tests and for anyone who wants a hard
# gate.
#
# Usage:
#   bash scripts/ci/check-capabilities-freshness.sh
#   bash scripts/ci/check-capabilities-freshness.sh --strict
#   bash scripts/ci/check-capabilities-freshness.sh --registry PATH --max-age-days 7
#   bash scripts/ci/check-capabilities-freshness.sh --json
#
# Env:
#   CHUMP_CAPABILITIES_MAX_AGE_DAYS   threshold in days (default 30)
#   CHUMP_CAPABILITIES_STRICT=1       same as --strict

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

REGISTRY="$REPO_ROOT/docs/CAPABILITIES_REGISTRY.json"
MAX_AGE_DAYS="${CHUMP_CAPABILITIES_MAX_AGE_DAYS:-30}"
STRICT="${CHUMP_CAPABILITIES_STRICT:-0}"
JSON_OUT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --registry)      REGISTRY="$2"; shift 2 ;;
        --max-age-days)  MAX_AGE_DAYS="$2"; shift 2 ;;
        --strict)        STRICT=1; shift ;;
        --json)          JSON_OUT=1; shift ;;
        -h|--help)       sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)               echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Observability, mirroring the other CI gates (CREDIBLE-048). Best-effort.
# shellcheck source=lib/gate-emit.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/gate-emit.sh" 2>/dev/null || true
gate_emit_start "CREDIBLE-240" "check-capabilities-freshness" 2>/dev/null || true

if [[ ! -f "$REGISTRY" ]]; then
    echo "[BROKEN] capabilities registry not found: $REGISTRY" >&2
    echo "         Generate it: bash scripts/dev/build-capabilities-registry.sh" >&2
    gate_emit_result "CREDIBLE-240" "fail" "registry-missing" "$REGISTRY" 2>/dev/null || true
    exit 2
fi

# All the date arithmetic in one python call — BSD date and GNU date disagree
# about -d/-j, and this gate runs on both macOS laptops and Linux runners.
REPORT="$(REGISTRY="$REGISTRY" MAX_AGE_DAYS="$MAX_AGE_DAYS" python3 - <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone

registry = os.environ["REGISTRY"]
try:
    max_age = int(os.environ["MAX_AGE_DAYS"])
except ValueError:
    print("verdict=BROKEN reason=bad-threshold age_days=0 generated_at= stale_after=")
    sys.exit(0)

try:
    with open(registry) as fh:
        doc = json.load(fh)
except Exception as exc:  # noqa: BLE001 — any parse failure is BROKEN
    print(f"verdict=BROKEN reason=unparseable:{type(exc).__name__} age_days=0 generated_at= stale_after=")
    sys.exit(0)

raw = doc.get("generated_at") or ""
if not raw:
    print("verdict=BROKEN reason=no-generated_at age_days=0 generated_at= stale_after=")
    sys.exit(0)

try:
    gen = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    if gen.tzinfo is None:
        gen = gen.replace(tzinfo=timezone.utc)
except ValueError:
    print(f"verdict=BROKEN reason=bad-timestamp age_days=0 generated_at={raw} stale_after=")
    sys.exit(0)

age_days = (datetime.now(timezone.utc) - gen).days
verdict = "STALE" if age_days > max_age else "FRESH"
declared = doc.get("stale_after", "")
print(f"verdict={verdict} reason=age age_days={age_days} generated_at={raw} stale_after={declared}")
PYEOF
)"

# shellcheck disable=SC2086
eval "$(echo "$REPORT" | tr ' ' '\n' | sed -E 's/^([a-z_]+)=(.*)$/\1="\2"/')"

VERDICT="${verdict:-BROKEN}"
AGE_DAYS="${age_days:-0}"
GENERATED_AT="${generated_at:-}"
STALE_AFTER="${stale_after:-}"
REASON="${reason:-unknown}"

if [[ "$JSON_OUT" -eq 1 ]]; then
    printf '{"verdict":"%s","age_days":%s,"max_age_days":%s,"generated_at":"%s","stale_after":"%s","registry":"%s"}\n' \
        "$VERDICT" "$AGE_DAYS" "$MAX_AGE_DAYS" "$GENERATED_AT" "$STALE_AFTER" "$REGISTRY"
fi

case "$VERDICT" in
    BROKEN)
        echo "[BROKEN] capabilities registry is unusable ($REASON): $REGISTRY" >&2
        echo "         Regenerate: bash scripts/dev/build-capabilities-registry.sh" >&2
        gate_emit_result "CREDIBLE-240" "fail" "$REASON" "$REGISTRY" 2>/dev/null || true
        exit 2
        ;;
    FRESH)
        echo "[FRESH] capabilities registry generated ${AGE_DAYS}d ago (threshold ${MAX_AGE_DAYS}d)"
        echo "        generated_at=$GENERATED_AT  stale_after=$STALE_AFTER"
        gate_emit_result "CREDIBLE-240" "pass" "" "age_days=$AGE_DAYS" 2>/dev/null || true
        exit 0
        ;;
    STALE)
        # Loud on purpose. This banner is the whole point of the gap: the
        # failure mode was a stale catalog that looked authoritative.
        echo "=============================================================="
        echo "[STALE] docs/CAPABILITIES_REGISTRY.json is ${AGE_DAYS} days old"
        echo "        threshold    : ${MAX_AGE_DAYS} days"
        echo "        generated_at : ${GENERATED_AT}"
        echo "        stale_after  : ${STALE_AFTER}"
        echo "        DO NOT quote this catalog as the current state of the repo."
        echo "        almanac indexes this file and will serve it with a"
        echo "        file:line receipt, which makes a stale answer look sourced."
        echo "        Fix: bash scripts/dev/build-capabilities-registry.sh"
        echo "=============================================================="
        gate_emit_result "CREDIBLE-240" "fail" "registry-stale" \
            "age_days=$AGE_DAYS threshold=$MAX_AGE_DAYS" 2>/dev/null || true
        if [[ "$STRICT" == "1" ]]; then
            echo "Results: 0 passed, 1 failed (strict mode)"
            exit 1
        fi
        echo "Results: 1 passed (advisory warning), 0 failed — --strict to block"
        exit 0
        ;;
esac

echo "[BROKEN] unrecognized verdict: $VERDICT" >&2
exit 2
