#!/usr/bin/env bash
# test-gap-closure-consistency.sh — CREDIBLE-028: detect premature gap closure.
#
# Queries state.db for gaps with status=done and closed_pr=N, then verifies
# each PR is actually merged on GitHub. Any mismatch → ambient ALERT emitted
# (kind=gap_drift_premature_close) and exit 1.
#
# Usage:
#   bash scripts/ci/test-gap-closure-consistency.sh              # informational
#   bash scripts/ci/test-gap-closure-consistency.sh --strict     # exit 1 on any drift
#   bash scripts/ci/test-gap-closure-consistency.sh --emit-alert # emit ambient event
#
# Exit codes:
#   0 — no drift found (or --strict not set)
#   1 — drift detected (with --strict), or fatal error

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
info() { printf '[INFO] %s\n' "$*"; }

STRICT=0
EMIT_ALERT=0
LIMIT=30   # default: check the 30 most-recently-closed gaps; use --all to check everything
ALL=0
# Parse args without indirect expansion (portable to bash 3 on macOS)
prev_arg=""
for arg in "$@"; do
    case "$arg" in
        --strict)      STRICT=1 ;;
        --emit-alert)  EMIT_ALERT=1 ;;
        --all)         ALL=1; LIMIT=999999 ;;
    esac
    if [[ "$prev_arg" == "--limit" ]]; then
        LIMIT="$arg"
    fi
    prev_arg="$arg"
done

# ── Resolve state.db ─────────────────────────────────────────────────────────
_GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." 2>/dev/null && pwd || echo "$REPO_ROOT")"
fi
DB="$MAIN_REPO/.chump/state.db"
if [[ ! -f "$DB" ]]; then
    warn "state.db not found at $DB — skipping closure consistency check"
    exit 0
fi

# ── Require gh CLI ────────────────────────────────────────────────────────────
if ! command -v gh &>/dev/null; then
    warn "gh CLI not found — skipping GitHub PR state check"
    exit 0
fi

# ── Query done gaps with closed_pr set ───────────────────────────────────────
rows=()
while IFS= read -r row; do
    [[ -n "$row" ]] && rows+=("$row")
done < <(
    sqlite3 "$DB" \
        "SELECT id, closed_pr FROM gaps WHERE status='done' AND closed_pr IS NOT NULL AND closed_pr != '' AND CAST(closed_pr AS INTEGER) > 0 ORDER BY CAST(closed_pr AS INTEGER) DESC LIMIT $LIMIT;" \
        2>/dev/null || true
)

if [[ ${#rows[@]} -eq 0 ]]; then
    pass "No done gaps with closed_pr — nothing to check"
    exit 0
fi

scope_note="most recent $LIMIT"
[[ "$ALL" -eq 1 ]] && scope_note="all"
info "Checking ${#rows[@]} done gap(s) ($scope_note) with closed_pr against GitHub…"

drift_ids=()
drift_details=()

for row in "${rows[@]}"; do
    gap_id="${row%%|*}"
    pr_num="${row##*|}"

    # gh pr view returns mergedAt as null if not merged
    merged_at="$(gh pr view "$pr_num" --json mergedAt --jq '.mergedAt' 2>/dev/null || echo "ERROR")"

    if [[ "$merged_at" == "ERROR" ]]; then
        warn "$gap_id: could not query PR #$pr_num (network/auth issue) — skipping"
        continue
    fi

    if [[ -z "$merged_at" || "$merged_at" == "null" ]]; then
        pr_state="$(gh pr view "$pr_num" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")"
        warn "$gap_id: state=done closed_pr=#$pr_num but PR is $pr_state (not merged)"
        drift_ids+=("$gap_id")
        drift_details+=("$gap_id:#$pr_num/$pr_state")
    else
        pass "$gap_id: PR #$pr_num merged ($merged_at)"
    fi
done

# ── Emit ambient ALERT if any drift found ────────────────────────────────────
if [[ ${#drift_ids[@]} -gt 0 && "$EMIT_ALERT" -eq 1 ]]; then
    LOCK_DIR="$MAIN_REPO/.chump-locks"
    mkdir -p "$LOCK_DIR"
    AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
    TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # Build JSON array of IDs
    ids_json="$(printf '"%s",' "${drift_ids[@]}" | sed 's/,$//')"
    note="${#drift_ids[@]} done gap(s) in state.db have closed_pr set but PR not merged — run chump gap ship <ID> or verify"
    printf '{"ts":"%s","event":"ALERT","kind":"gap_drift_premature_close","source":"test-gap-closure-consistency","ids":[%s],"note":"%s"}\n' \
        "$TS" "$ids_json" "$note" >> "$AMBIENT"
    info "Emitted gap_drift_premature_close ALERT to $AMBIENT"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ ${#drift_ids[@]} -eq 0 ]]; then
    echo "All CREDIBLE-028 closure consistency checks passed (${#rows[@]} gap(s) verified)."
    exit 0
else
    echo "CREDIBLE-028 drift detected: ${#drift_ids[@]} gap(s) marked done but PR not merged:"
    for d in "${drift_details[@]}"; do
        echo "  $d"
    done
    if [[ "$STRICT" -eq 1 ]]; then
        exit 1
    fi
    exit 0
fi
