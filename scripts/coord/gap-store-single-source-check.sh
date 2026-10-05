#!/usr/bin/env bash
# gap-store-single-source-check.sh — assert ONE source of truth for the gap store.
#
# WHY THIS EXISTS ([[gap-store-split-brain-swamp]] / RESILIENT-1057):
#   The fleet's gap registry has three representations:
#     1. sqlite  .chump/state.db   — THE canonical store (what the CLI + workers
#                                     actually read/write).
#     2. YAML    docs/gaps/*.yaml  — a DERIVED git mirror, reconciled by
#                                     `chump gap sync` / gap-doctor (drift here is
#                                     expected staleness, not a second truth).
#     3. postgrest shared_gaps     — a DORMANT future backend (INFRA-2092,
#                                     postgres-backend cargo feature, OFF by
#                                     default). Empty until a migration + backfill
#                                     lands. It must NEVER be silently treated as
#                                     canonical while it diverges from state.db.
#
#   The split-brain that cost us: postgrest was "configured" but broken
#   (permission denied to set role "chump_anon"), so the fleet silently ran on
#   sqlite while a second, empty store sat there looking authoritative. This
#   guard makes any such divergence LOUD instead of silent.
#
# CHECKS (exit non-zero on ANY split-brain):
#   A) CLI open-count == sqlite open-count           (CLI and store agree)
#   B) if a postgrest gap store is reachable AND non-empty AND its open-count
#      diverges from state.db  -> FAIL (a real second store is diverging).
#      (unreachable / empty postgrest == expected dormant state == OK)
#
# Receipts on stdout. Designed to be run by hand or by a scheduled organ.
set -uo pipefail

REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
STATE_DB="${CHUMP_STATE_DB:-$REPO_ROOT/.chump/state.db}"
CHUMP_BIN="${CHUMP_BIN:-$(command -v chump || echo chump)}"
# Dormant postgrest store; only checked if reachable. Same var the substrate
# installer and node-install env-pin resolve (INFRA-3634).
GAP_STORE_URL="${CHUMP_GAP_STORE_URL:-http://100.90.52.126:3000}"

fail=0
say() { printf '[gap-store-single-source] %s\n' "$*"; }

# ---- A) CLI vs sqlite ----
if [[ ! -f "$STATE_DB" ]]; then
  say "FAIL: canonical store $STATE_DB missing"; exit 2
fi
sqlite_open="$(sqlite3 "$STATE_DB" 'SELECT count(*) FROM gaps WHERE status="open";' 2>/dev/null)"
# CLI prints: "--- 1945 shown / 1946 total open across N domains ..."
cli_line="$("$CHUMP_BIN" gap list --status open 2>/dev/null | grep -oE '[0-9]+ total open' | head -1)"
cli_open="${cli_line%% *}"
say "canonical(sqlite state.db) open = ${sqlite_open:-<none>}"
say "CLI (chump gap list)      open = ${cli_open:-<none>}"
if [[ -z "$sqlite_open" || -z "$cli_open" ]]; then
  say "FAIL(A): could not read one of the counts"; fail=1
elif [[ "$sqlite_open" != "$cli_open" ]]; then
  say "FAIL(A): CLI and canonical store DISAGREE ($cli_open vs $sqlite_open) — split-brain between CLI and store"; fail=1
else
  say "OK(A): CLI and canonical store agree ($sqlite_open open)"
fi

# ---- B) dormant postgrest must not silently diverge ----
pg_code="$(curl -s -o /dev/null -w '%{http_code}' -m 8 "$GAP_STORE_URL/shared_gaps?select=id&limit=1" 2>/dev/null)"
if [[ "$pg_code" == "200" ]]; then
  pg_count="$(curl -s -m 8 -H 'Prefer: count=exact' -D - -o /dev/null "$GAP_STORE_URL/shared_gaps?select=id" 2>/dev/null | grep -i content-range | grep -oE '/[0-9]+' | tr -d '/')"
  pg_count="${pg_count:-0}"
  say "postgrest(shared_gaps) reachable, rows = $pg_count (dormant backend)"
  if [[ "$pg_count" != "0" && "$pg_count" != "$sqlite_open" ]]; then
    say "FAIL(B): postgrest store is NON-EMPTY ($pg_count) and diverges from canonical ($sqlite_open) — second store diverging. Either finish the INFRA-2092 migration (backfill+wire) or clear shared_gaps."; fail=1
  else
    say "OK(B): postgrest is dormant (empty) — not a competing source of truth"
  fi
elif [[ "$pg_code" == "000" ]]; then
  say "OK(B): postgrest unreachable — dormant, not a competing source of truth"
else
  say "OK(B): postgrest returned HTTP $pg_code (not serving gaps) — dormant"
fi

if [[ "$fail" -ne 0 ]]; then
  say "RESULT: SPLIT-BRAIN DETECTED"; exit 1
fi
say "RESULT: single source of truth confirmed (sqlite state.db)"
exit 0
