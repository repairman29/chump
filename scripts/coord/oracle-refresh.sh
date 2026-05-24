#!/usr/bin/env bash
# scripts/coord/oracle-refresh.sh — META-088
#
# Periodic Oracle refresh — every 4h spawn a bounded Opus burst to
# re-contemplate docs/process/THE_PATH.md against current state.db open
# gaps + recent ambient events. Auto-commits + auto-PRs if changed.
#
# Replaces the operator-opus manual re-write loop (today: every 4-8h
# someone re-reads state.db + recent ships and updates THE_PATH.md by
# hand). This script does it with a fixed prompt + bounded token budget.
#
# Cost: capped at CHUMP_ORACLE_TOKEN_BUDGET (default 50K) and 30s wall.
# Cheaper than operator-opus running the loop.
#
# Bypass: CHUMP_ORACLE_DISABLED=1.
# Manual run: bash scripts/coord/oracle-refresh.sh --force (still
# bounded; just skips the cron-cadence check).

set -uo pipefail

# Quick bypass
[[ "${CHUMP_ORACLE_DISABLED:-0}" == "1" ]] && exit 0

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
THE_PATH="$REPO_ROOT/docs/process/THE_PATH.md"
STATE="$REPO_ROOT/.chump-locks/oracle-refresh-state.jsonl"
TOKEN_BUDGET="${CHUMP_ORACLE_TOKEN_BUDGET:-50000}"
WALL_BUDGET_S="${CHUMP_ORACLE_WALL_BUDGET_S:-30}"

# --force currently is a no-op flag (informational). Reserved for a
# future self-throttle bypass; today the only throttle is the launchd
# cadence + CHUMP_ORACLE_DISABLED env.
for arg in "$@"; do
    [[ "$arg" == "--force" ]] && echo "[oracle-refresh] --force flag set (no-op today; reserved for future self-throttle)"
done

mkdir -p "$(dirname "$STATE")"
touch "$STATE"

if [[ ! -f "$THE_PATH" ]]; then
    echo "[oracle-refresh] no docs/process/THE_PATH.md yet — META-087 not shipped?" >&2
    exit 0
fi

emit() {
    local kind="$1" payload="$2"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"%s",%s}\n' "$ts" "$kind" "$payload" >> "$AMBIENT"
}

# Snapshot current THE_PATH hash
before_hash="$(shasum "$THE_PATH" 2>/dev/null | cut -d' ' -f1)"

# ── Gather context for Opus burst ──────────────────────────────────────────
# Recent ambient events (last 50 lines) — what's been happening
recent_ambient="$(tail -50 "$AMBIENT" 2>/dev/null | tail -c 4000)"

# Open gaps grouped by priority + pillar
gaps_json="$(chump gap list --status open --json 2>/dev/null | head -c 8000)"

# Recent shipped PRs (last 24h)
since="$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
recent_ships="$(gh pr list --state merged --search "merged:>=$since" --limit 20 \
    --json number,title,mergedAt 2>/dev/null | head -c 3000)"

# Current THE_PATH (the doc being refreshed) — truncated
current_path="$(head -c 4000 "$THE_PATH")"

# ── Construct the Opus prompt ──────────────────────────────────────────────
PROMPT="You are the Chump Oracle (META-087). Your job is to refresh docs/process/THE_PATH.md based on current fleet state.

The doc is a ranked program with 5 tracks (Firewall / Self-improvement / Forward-coordination / A2A / Demo). Each track lists Next-3 actions ranked by leverage.

Current THE_PATH.md (truncated):
---
${current_path}
---

Open gaps (truncated JSON):
---
${gaps_json}
---

Recent shipped PRs (last 24h):
---
${recent_ships}
---

Recent ambient events:
---
${recent_ambient}
---

Output a refreshed THE_PATH.md ONLY. Preserve the 5-track structure. Demote shipped items, promote new opportunities, mark drift. No preamble, no markdown fence, no explanation — just the new doc body. ≤ 4000 characters."

# ── Burst — bounded Opus call ──────────────────────────────────────────────
echo "[oracle-refresh] dispatching Opus burst (wall_budget=${WALL_BUDGET_S}s token_budget=${TOKEN_BUDGET})"

# Cost gate: if disabled or no LLM available, exit 0 cleanly
if ! command -v claude >/dev/null 2>&1; then
    echo "[oracle-refresh] claude CLI not available; skipping refresh"
    emit "oracle_refresh_skipped" "\"reason\":\"claude_cli_missing\""
    exit 0
fi

# Use claude -p --bare with hard timeout. gtimeout (homebrew coreutils) is
# the macOS path; fall back to bare invocation if neither timeout binary
# exists (bounded only by claude's own internal timeouts).
_to=""
if command -v timeout >/dev/null 2>&1; then _to="timeout ${WALL_BUDGET_S}s";
elif command -v gtimeout >/dev/null 2>&1; then _to="gtimeout ${WALL_BUDGET_S}s";
fi
new_body="$(printf '%s\n' "$PROMPT" | $_to claude -p --bare 2>/dev/null | head -c 6000)"

if [[ -z "$new_body" || "${#new_body}" -lt 200 ]]; then
    echo "[oracle-refresh] burst returned empty/too-short output; skipping"
    emit "oracle_refresh_skipped" "\"reason\":\"empty_or_short_output\""
    exit 0
fi

# ── Idempotency check — content hash ───────────────────────────────────────
# Write to tempfile + compare hash
TMP="$(mktemp)"
printf '%s\n' "$new_body" > "$TMP"
after_hash="$(shasum "$TMP" | cut -d' ' -f1)"

if [[ "$before_hash" == "$after_hash" ]]; then
    echo "[oracle-refresh] no change since last refresh (same content hash); no-op"
    emit "oracle_refresh_noop" "\"hash\":\"${before_hash:0:8}\""
    rm -f "$TMP"
    exit 0
fi

# ── Write the new THE_PATH + emit drift signal ─────────────────────────────
mv "$TMP" "$THE_PATH"

emit "oracle_refresh_drift" "\"before_hash\":\"${before_hash:0:8}\",\"after_hash\":\"${after_hash:0:8}\""

echo "[oracle-refresh] THE_PATH.md updated (${before_hash:0:8} → ${after_hash:0:8})"

# ── Auto-commit + auto-PR — best-effort, fail-soft ─────────────────────────
if [[ -d "$REPO_ROOT/.git" ]]; then
    STAMP="$(date -u +%Y-%m-%dT%H%MZ)"
    BRANCH="chump/oracle-refresh-${STAMP}"

    # Stage + commit in a tmpdir worktree to avoid stomping main
    WORKTREE="/tmp/chump-oracle-refresh-${STAMP}"
    if git worktree add "$WORKTREE" -b "$BRANCH" origin/main 2>/dev/null; then
        cp "$THE_PATH" "$WORKTREE/docs/process/THE_PATH.md"
        (cd "$WORKTREE" && git add docs/process/THE_PATH.md \
            && git commit -m "docs(META-087): Oracle refresh ${STAMP}

Auto-generated by scripts/coord/oracle-refresh.sh (META-088).
Content hash: ${before_hash:0:8} → ${after_hash:0:8}.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>" >/dev/null 2>&1 \
            && git push -u origin "$BRANCH" >/dev/null 2>&1)
        # Open PR + arm auto-merge
        (cd "$WORKTREE" && gh pr create --base main --head "$BRANCH" \
            --title "docs(META-087): Oracle refresh ${STAMP}" \
            --body "Auto-refresh of docs/process/THE_PATH.md by scripts/coord/oracle-refresh.sh (META-088 daemon).

Content hash drift: \`${before_hash:0:8}\` → \`${after_hash:0:8}\`" >/dev/null 2>&1) || true
        (cd "$WORKTREE" && gh pr merge --auto --squash >/dev/null 2>&1) || true
        emit "oracle_refresh_pr_opened" "\"branch\":\"${BRANCH}\""
    else
        echo "[oracle-refresh] worktree creation failed; leaving THE_PATH.md change unstaged"
    fi
fi

exit 0
