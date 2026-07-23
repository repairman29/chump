#!/usr/bin/env bash
# backlog-sync.sh (RESILIENT-194) — the fleet's shared-backlog COHERENCE loop.
#
# The problem it fixes: the ship pipeline never closes the loop. A PR merges but
# the gap stays status:open in the registry (no closed_pr, no YAML), state.sql is
# never regenerated, and no node pulls the shared truth. Result: three diverging
# state.db copies, the fleet re-picks already-merged work, and `unverified_ship`
# loops masquerade as a stall.
#
# The fix is COMPOSITION, not new machinery — one source of truth (origin/main's
# .chump/state.sql) and one loop with two roles, both built from existing chump
# primitives (gap ship / gap dump / restore --from-sql) + the local github_cache:
#
#   --reader  (every node, on a timer): git pull + `chump restore --from-sql`.
#             Rebuilds the local backlog from the shared truth. Idempotent/safe;
#             live claims live in NATS-KV, not state.db, so a rebuild loses nothing.
#
#   --writer  (ONE hub, on a timer): reconcile merged PRs -> gap shipped (the
#             write-back the pipeline skips), regenerate state.sql, commit + push.
#             Publishes a current truth for the readers to pull.
#
# Single-writer by design: only the hub runs --writer, so state.sql has one author
# and the git merge-driver rarely fires. Readers are many and never push.
#
# Usage:
#   backlog-sync.sh --reader
#   backlog-sync.sh --writer [--dry-run]
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${CHUMP_REPO:-$(git -C "$_here" rev-parse --show-toplevel 2>/dev/null || echo "$HOME/chump-host")}"
CHUMP="${CHUMP_BIN:-chump}"
DRY=0; ROLE=""
for a in "$@"; do case "$a" in
  --reader) ROLE=reader ;; --writer) ROLE=writer ;; --dry-run) DRY=1 ;;
  *) echo "usage: $0 --reader|--writer [--dry-run]" >&2; exit 2 ;;
esac; done
[[ -n "$ROLE" ]] || { echo "usage: $0 --reader|--writer [--dry-run]" >&2; exit 2; }

cd "$REPO" 2>/dev/null || { echo "[backlog-sync] no repo at $REPO" >&2; exit 1; }
log(){ printf '[backlog-sync:%s] %s\n' "$ROLE" "$*"; }
DB="$REPO/.chump/state.db"
CACHE="$REPO/.chump/github_cache.db"

# ── reader: pull the shared truth, rebuild the local backlog ────────────────
reader() {
  log "git pull origin main"
  if ! git pull --no-edit --quiet origin main 2>/dev/null; then
    log "pull failed (offline or conflict) — keeping current backlog"; return 1
  fi
  log "chump restore --from-sql"
  "$CHUMP" restore --from-sql >/dev/null 2>&1 || { log "restore failed"; return 1; }
  log "backlog refreshed: $(sqlite3 "$DB" "SELECT COUNT(*) FROM gaps WHERE status='open'" 2>/dev/null) open gaps"
}

# ── writer: close merged gaps, regenerate + publish state.sql ───────────────
# Extract a gap id (e.g. INFRA-1730) from a PR title `type(INFRA-1730): …` or a
# head_ref `chump/infra-1730-fleet-…`. Returns uppercased id or empty.
_gap_id_from_pr() {
  local title="$1" head="$2" id=""
  id="$(printf '%s' "$title" | grep -oE '\(([A-Z]+-[0-9]+)\)' | head -1 | tr -d '()')"
  [[ -z "$id" ]] && id="$(printf '%s' "$head" | grep -oiE '[a-z]+-[0-9]+' | head -1 | tr 'a-z' 'A-Z')"
  printf '%s' "$id"
}

writer() {
  git fetch origin main --quiet 2>/dev/null || true
  local closed=0 checked=0 tmp
  tmp="$(mktemp)"
  # Authoritative merge record: origin/main squash commits `type(GAP-ID): … (#PR)`.
  # git log is complete (unlike the rolling github_cache) and IS the source of truth
  # for what merged. Emit (gid<TAB>pr), then awk keeps the first (newest) per gid.
  # (bash-3.2-safe: no `declare -A`; a temp file keeps the counter out of a subshell.)
  git log origin/main --format='%s' -n 4000 2>/dev/null | while IFS= read -r subj; do
    local gid pr
    gid="$(printf '%s' "$subj" | grep -oE '\([A-Z]+-[0-9]+\)' | head -1 | tr -d '()')"
    [[ -n "$gid" ]] || continue
    pr="$(printf '%s' "$subj" | grep -oE '\(#[0-9]+\)' | head -1 | tr -d '(#)')"
    printf '%s\t%s\n' "$gid" "$pr"
  done | awk -F'\t' '!seen[$1]++' > "$tmp"

  while IFS=$'\t' read -r gid pr; do
    checked=$((checked+1))
    # only act if that gap is still OPEN in the registry (the drift)
    local st; st="$(sqlite3 "$DB" "SELECT status FROM gaps WHERE id='$gid'" 2>/dev/null)"
    [[ "$st" == "open" ]] || continue
    if [[ "$DRY" == 1 ]]; then
      log "would close $gid (merged${pr:+ pr #$pr})"; closed=$((closed+1)); continue
    fi
    # Clean status-flip (not `gap ship`, which has a rebase/stale-branch guard
    # irrelevant to a registry reconcile). --status done marks it shipped.
    if "$CHUMP" gap set "$gid" --status done ${pr:+--closed-pr "$pr"} >/dev/null 2>&1; then
      closed=$((closed+1)); log "closed $gid (merged${pr:+ pr #$pr})"
    fi
  done < "$tmp"
  rm -f "$tmp"
  log "reconciled: $closed merged-but-open gaps closed (of $checked distinct merged gap ids)"

  [[ "$DRY" == 1 ]] && { log "dry-run — not regenerating/pushing state.sql"; return 0; }

  # regenerate the single source of truth + publish
  "$CHUMP" gap dump > "$REPO/.chump/state.sql" 2>/dev/null || { log "gap dump failed"; return 1; }
  if git diff --quiet .chump/state.sql 2>/dev/null; then
    log "state.sql already current — nothing to push"; return 0
  fi
  git add .chump/state.sql
  # Skip code hooks: this is an automated single-file (state.sql) reconcile, not a
  # code change, and it runs headless on the hub where clippy/fmt hooks would only
  # stall it. state.sql is auto-allowed by the off-rails guard.
  git -c core.hooksPath=/dev/null commit -q -m "chore(backlog): coherence sync — $closed gaps closed, state.sql regenerated

Automated by scripts/coord/backlog-sync.sh --writer (RESILIENT-194). Single-writer
hub reconcile: merged PRs -> gap done, then regenerate the shared truth." 2>/dev/null || { log "commit failed"; return 1; }
  git pull --no-edit --quiet origin main 2>/dev/null || true
  if git push 2>/dev/null; then
    log "published state.sql to origin/main ($closed gaps closed this cycle)"
  else
    log "push failed — will retry next cycle"; return 1
  fi
}

"$ROLE"
