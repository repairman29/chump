#!/usr/bin/env bash
# post-rebase-verify.sh — INFRA-1526
#
# Post-rebase hunk-drop detector.
#
# After a successful git rebase, compare per-file addition counts between the
# original commits (pre-rebase tip = ORIG_HEAD) and the rebased commits (HEAD).
# If any file had >DROP_THRESHOLD added lines in the original but has 0 added
# lines in the rebased tip, the hunk was silently dropped.
#
# On drop detection:
#   - Emits kind=rebase_hunk_dropped to ambient.jsonl (one event per file)
#   - Prints a human-readable warning to stderr
#   - Exits non-zero so the caller (bot-merge.sh) can abort before pushing
#
# Usage:
#   post-rebase-verify.sh [--orig-head <sha>] [--base <ref>]
#                         [--repo <path>] [--ambient <path>]
#
# Defaults:
#   --orig-head  reads .git/ORIG_HEAD (set by git rebase)
#   --base       origin/main
#   --repo       two dirs above this script (the chump repo root)
#   --ambient    ${CHUMP_AMBIENT_LOG:-<repo>/.chump-locks/ambient.jsonl}
#
# Environment:
#   CHUMP_AMBIENT_LOG        override ambient log path
#   CHUMP_REBASE_DROP_LINES  override the drop threshold (default 50)
#
# Requires: bash 3.2+, git, awk (POSIX)

set -uo pipefail

_DEFAULT_REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

ORIG_HEAD_SHA=""
BASE_REF="origin/main"
REPO_ROOT="${_DEFAULT_REPO_ROOT}"
AMBIENT_OVERRIDE=""
DROP_THRESHOLD="${CHUMP_REBASE_DROP_LINES:-50}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --orig-head) ORIG_HEAD_SHA="$2"; shift 2 ;;
        --base)      BASE_REF="$2";      shift 2 ;;
        --repo)      REPO_ROOT="$2";     shift 2 ;;
        --ambient)   AMBIENT_OVERRIDE="$2"; shift 2 ;;
        *) echo "post-rebase-verify: unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ -n "$AMBIENT_OVERRIDE" ]]; then
    AMBIENT="$AMBIENT_OVERRIDE"
else
    AMBIENT="${CHUMP_AMBIENT_LOG:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"
fi

# ── Read ORIG_HEAD ────────────────────────────────────────────────────────────

if [[ -z "$ORIG_HEAD_SHA" ]]; then
    ORIG_HEAD_FILE="${REPO_ROOT}/.git/ORIG_HEAD"
    if [[ ! -f "$ORIG_HEAD_FILE" ]]; then
        echo "post-rebase-verify: no .git/ORIG_HEAD found — skipping (no rebase in progress)" >&2
        exit 0
    fi
    ORIG_HEAD_SHA="$(cat "$ORIG_HEAD_FILE")"
fi

if [[ -z "$ORIG_HEAD_SHA" ]]; then
    echo "post-rebase-verify: ORIG_HEAD is empty — skipping" >&2
    exit 0
fi

CURRENT_HEAD="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)" || {
    echo "post-rebase-verify: could not determine HEAD — skipping" >&2
    exit 0
}

if [[ "$ORIG_HEAD_SHA" == "$CURRENT_HEAD" ]]; then
    echo "post-rebase-verify: HEAD unchanged after rebase — nothing to check" >&2
    exit 0
fi

# ── Find the old fork point ───────────────────────────────────────────────────

OLD_BASE="$(git -C "$REPO_ROOT" merge-base "$ORIG_HEAD_SHA" "$BASE_REF" 2>/dev/null)" || {
    echo "post-rebase-verify: could not determine merge-base for $ORIG_HEAD_SHA and $BASE_REF — skipping" >&2
    exit 0
}

if [[ "$OLD_BASE" == "$ORIG_HEAD_SHA" ]]; then
    echo "post-rebase-verify: branch was at base before rebase — nothing to check" >&2
    exit 0
fi

# ── Detect drops with awk (bash 3.2 compatible — no declare -A) ──────────────
#
# Feed both diffs to a single awk pass using section markers.  awk's native
# associative arrays handle the file→lines lookup without bash 4+ required.
#
# Output format (one line per dropped file):
#   <file>\t<original_additions>

dropped_output="$(
    {
        printf '%s\n' '=ORIG='
        git -C "$REPO_ROOT" diff --numstat "$OLD_BASE" "$ORIG_HEAD_SHA" 2>/dev/null
        printf '%s\n' '=REBASED='
        git -C "$REPO_ROOT" diff --numstat "$BASE_REF" "$CURRENT_HEAD" 2>/dev/null
    } | awk -v threshold="$DROP_THRESHOLD" '
        /^=ORIG=$/    { section = "orig";    next }
        /^=REBASED=$/ { section = "rebased"; next }
        $1 ~ /^[0-9]+$/ {
            if (section == "orig" && ($1 + 0) > threshold)
                orig[$3] = $1 + 0
            else if (section == "rebased")
                rebased[$3] = $1 + 0
        }
        END {
            for (f in orig) {
                r = (f in rebased) ? rebased[f] + 0 : 0
                if (r == 0)
                    print f "\t" orig[f]
            }
        }
    '
)"

# ── Result ────────────────────────────────────────────────────────────────────

if [[ -z "$dropped_output" ]]; then
    echo "post-rebase-verify: OK — no hunk drops detected (threshold=${DROP_THRESHOLD})" >&2
    exit 0
fi

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
drop_count=0
while IFS=$'\t' read -r file orig_lines; do
    [[ -z "$file" ]] && continue
    drop_count=$((drop_count + 1))
    echo "post-rebase-verify: HUNK DROP: $file — $orig_lines lines in original, 0 lines in rebased tip" >&2
    # scanner-anchor: "kind":"rebase_hunk_dropped"
    printf '{"ts":"%s","kind":"rebase_hunk_dropped","file":"%s","lines_dropped":%d,"original_commit":"%s","rebased_commit":"%s","base_ref":"%s","threshold":%d,"note":"INFRA-1526: silent hunk drop detected after git rebase; abort before push"}\n' \
        "$TS" "$file" "$orig_lines" "$ORIG_HEAD_SHA" "$CURRENT_HEAD" "$BASE_REF" "$DROP_THRESHOLD" \
        >> "$AMBIENT" 2>/dev/null || true
done <<< "$dropped_output"

echo "post-rebase-verify: $drop_count file(s) with silent hunk drops — aborting to prevent data loss" >&2
echo "post-rebase-verify: inspect with: git diff $OLD_BASE $ORIG_HEAD_SHA -- <file>  vs  git diff $BASE_REF $CURRENT_HEAD -- <file>" >&2
exit 1
