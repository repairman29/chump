#!/usr/bin/env bash
# pr-approval-surface-beat.sh — RESILIENT-265 "approve-from-phone" DETECT+SURFACE.
#
# THE ATC ORGAN. ChumpOS now opens real PRs against PRODUCT repos itself (proof:
# repairman29/olive#19, an OS-authored ROADMAP-cleanup PR). Unlike internal chump
# PRs — which auto-merge through the gate gauntlet — a product-repo change needs
# Jeff's approval, and until now those PRs just sat until he went to GitHub. This
# beat kills that bottleneck: it detects OS-authored PRs that need a human
# decision and DMs them to the operator's phone with tap-to-merge / tap-to-reject
# buttons. Jeff just taps; ATC does the legwork (detect here, act in the gateway).
#
# SCOPE (needs-approval definition — a deliberate default, tell Jeff if wrong):
#   * OPEN, non-draft
#   * mergeable (no conflicts) — mergeStateStatus is surfaced but not required,
#     so an UNSTABLE-but-mergeable PR (non-required check pending) still reaches
#     the phone; the merge itself honors branch protection at tap time.
#   * authored by the OS account (the gh-authed user, e.g. repairman29)
#   * on an EXTERNAL PRODUCT repo from the allowlist below (chump is EXCLUDED —
#     it auto-merges; a phone tap must never squash an internal chump PR).
#
# Repos: CHUMP_PR_APPROVAL_REPOS (space/comma-separated), default repairman29/olive.
#
# DEDUPE: every surfaced PR is recorded in .chump-locks/pr-approval-surfaced.txt
# (survives the deploy mirror's ff-sync — .chump-locks is gitignored runtime
# state). A PR is DM'd at most once while it sits open, so the beat can run every
# few minutes without ever double-pinging. (A merged/rejected PR drops out of the
# open-mergeable query, so the acted set self-cleans.)
#
# Runs on the always-on primary node (helsinki) via chump-pr-approval.timer.
# Idempotent, read-only against GitHub except for sending the DM.
#
# Usage:
#   bash scripts/dispatch/pr-approval-surface-beat.sh            # detect + DM
#   bash scripts/dispatch/pr-approval-surface-beat.sh --dry-run  # detect + print, no DM, no dedupe write
#   CHUMP_PR_APPROVAL_FORCE=1 ...                                # ignore dedupe (re-surface)
#
# Off-switch: CHUMP_PR_APPROVAL_ENABLED=0 (default on).
set -uo pipefail

[[ "${CHUMP_PR_APPROVAL_ENABLED:-1}" == "0" ]] && { echo "[pr-approval] disabled via CHUMP_PR_APPROVAL_ENABLED=0 — exit"; exit 0; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
NOTIFY_LIB="$REPO_ROOT/scripts/coord/lib/notify-operator.sh"

DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1
FORCE="${CHUMP_PR_APPROVAL_FORCE:-0}"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '[pr-approval %s] %s\n' "$(ts)" "$*"; }

STATE_FILE="${CHUMP_PR_APPROVAL_STATE:-$REPO_ROOT/.chump-locks/pr-approval-surfaced.txt}"
mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
touch "$STATE_FILE" 2>/dev/null || true

# EVENT_REGISTRY scanner-anchors (INFRA-754): emit() builds "kind" from a
# variable, invisible to the grep-based event-registry rule. These literal
# anchors keep register-and-emit in sync (all registered in
# docs/observability/EVENT_REGISTRY.yaml):
#   scanner-anchor: "kind":"pr_approval_surfaced"
#   scanner-anchor: "kind":"pr_approval_beat"
#   scanner-anchor: "kind":"pr_approval_beat_error"
emit() {  # kind, extra-json (no leading/trailing comma)
  local log_dir kind="$1" extra="${2:-}" line
  log_dir="$REPO_ROOT/.chump-locks"; mkdir -p "$log_dir" 2>/dev/null || true
  if [[ -n "$extra" ]]; then line="{\"ts\":\"$(ts)\",\"kind\":\"$kind\",$extra}"
  else line="{\"ts\":\"$(ts)\",\"kind\":\"$kind\"}"; fi
  printf '%s\n' "$line" >> "$log_dir/ambient.jsonl" 2>/dev/null || true
}

# Repo allowlist → array (accept space or comma separators).
RAW_REPOS="${CHUMP_PR_APPROVAL_REPOS:-repairman29/olive}"
RAW_REPOS="${RAW_REPOS//,/ }"
read -r -a REPOS <<< "$RAW_REPOS"

# The OS account whose PRs need approval = the gh-authed user.
OS_LOGIN="$(gh api user -q .login 2>/dev/null)"
[[ -z "$OS_LOGIN" ]] && { log "cannot resolve gh user (gh not authed?) — exit"; emit pr_approval_beat_error '"reason":"gh_user_unresolved"'; exit 0; }

already_surfaced() { grep -qxF "$1" "$STATE_FILE" 2>/dev/null; }
mark_surfaced() { grep -qxF "$1" "$STATE_FILE" 2>/dev/null || printf '%s\n' "$1" >> "$STATE_FILE"; }

surfaced_count=0
scanned=0

for repo in "${REPOS[@]}"; do
  [[ -n "$repo" ]] || continue
  # Guard: never surface the internal chump repo even if mis-listed.
  case "$repo" in */chump|*/Chump) log "skip $repo (internal chump auto-merges)"; continue;; esac

  # Open, non-draft PRs authored by the OS account. gh returns JSON we filter.
  prs_json="$(gh pr list -R "$repo" --state open --author "$OS_LOGIN" --limit 30 \
      --json number,title,url,isDraft,mergeable,mergeStateStatus 2>/dev/null)" || {
    log "gh pr list failed for $repo"; emit pr_approval_beat_error "\"repo\":\"$repo\",\"reason\":\"pr_list_failed\""; continue
  }

  # Emit one line per actionable PR: "<number>\t<mergeable>\t<title>\t<url>"
  while IFS=$'\t' read -r num mergeable msstatus title url; do
    [[ -n "$num" ]] || continue
    scanned=$((scanned+1))
    key="$repo#$num"

    if [[ "$FORCE" != "1" ]] && already_surfaced "$key"; then
      log "skip $key (already surfaced)"; continue
    fi

    log "NEEDS APPROVAL: $key ($mergeable/$msstatus) — $title"

    # Build the DM content + button components (custom_ids the gateway parses).
    content="$(printf '**PR needs your approval** — %s\n\n%s\n%s\n\nmergeable: %s (%s)\n\nTap ✅ to squash-merge, ❌ to reject.' \
        "$repo" "$title" "$url" "$mergeable" "$msstatus")"
    # Discord action row: green success (style 3) Merge, red danger (style 4) Reject.
    components="$(python3 -c '
import json,sys
repo,num=sys.argv[1],sys.argv[2]
print(json.dumps([{"type":1,"components":[
  {"type":2,"style":3,"label":"✅ Merge","custom_id":f"mergepr:{repo}/{num}"},
  {"type":2,"style":4,"label":"❌ Reject","custom_id":f"rejectpr:{repo}/{num}"},
]}]))' "$repo" "$num")"

    if [[ "$DRY" == 1 ]]; then
      log "[dry-run] would DM operator with buttons: mergepr:$repo/$num | rejectpr:$repo/$num"
      continue
    fi

    # Source the SEND half lazily (only when we actually have something to send).
    # shellcheck disable=SC1090
    source "$NOTIFY_LIB"
    if notify_operator_buttons "$content" "$components"; then
      mark_surfaced "$key"
      surfaced_count=$((surfaced_count+1))
      emit pr_approval_surfaced "\"repo\":\"$repo\",\"number\":$num,\"mergeable\":\"$mergeable\""
      log "surfaced $key to operator Discord ✅"
    else
      log "FAILED to DM $key — will retry next beat (not marked surfaced)"
      emit pr_approval_beat_error "\"repo\":\"$repo\",\"number\":$num,\"reason\":\"dm_failed\""
    fi
  done < <(printf '%s' "$prs_json" | python3 -c '
import sys,json
for pr in json.load(sys.stdin):
    if pr.get("isDraft"):            # drafts are not ready for a decision
        continue
    if pr.get("mergeable") == "CONFLICTING":   # conflicted → not approvable yet
        continue
    print("\t".join(str(pr.get(k,"")) for k in ("number","mergeable","mergeStateStatus","title","url")))
' 2>/dev/null)
done

emit pr_approval_beat "\"scanned\":$scanned,\"surfaced\":$surfaced_count,\"node\":\"$(hostname -s 2>/dev/null || echo node)\""
log "beat done — scanned=$scanned surfaced=$surfaced_count"
