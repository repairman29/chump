#!/usr/bin/env bash
# close-gaps-from-commit-subjects.sh — INFRA-236
#
# Authoritative gap-closure path: scan commit subjects on a range and flip
# matching open per-file gap YAMLs to status:done with closed_pr + closed_date.
#
# Why: prior closure paths (INFRA-154 bot-merge.sh auto-close, INFRA-194
# closer-pr-batcher polling, manual chump gap ship) all leak ghosts in
# different ways. Commit subjects on origin/main are immutable + machine-
# parseable + already follow the "INFRA-XXX: <description>" convention; using
# them as the source of truth eliminates the ghost class at its source.
#
# Usage:
#   close-gaps-from-commit-subjects.sh <git-revision-range> <pr-number>
# Example:
#   close-gaps-from-commit-subjects.sh origin/main..HEAD 793
#
# Behavior:
#   - Extracts ^[A-Z]+-\d+ from each commit subject in the range
#   - For each match, if docs/gaps/<ID>.yaml has status:open, flip to:
#       status: done
#       closed_pr: <pr-number>
#       closed_date: <today UTC>
#   - Skips gaps whose YAML is missing OR already done OR whose subject
#     contains [no-close] (intentional partial-progress)
#   - Skips filing PRs entirely (subject starts with "chore(gaps): file"
#     OR matches "^file " — never close on a filing commit)
#
# Exit codes:
#   0 = success (zero or more gaps closed)
#   1 = error (bad input, missing files)

set -euo pipefail

REV_RANGE="${1:?usage: $0 <revision-range> <pr-number>}"
PR_NUMBER="${2:?usage: $0 <revision-range> <pr-number>}"

# Validate PR number is numeric.
if ! echo "$PR_NUMBER" | grep -qE '^[0-9]+$'; then
    echo "[close-gaps] ERROR: pr-number must be numeric, got: $PR_NUMBER" >&2
    exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GAPS_DIR="$REPO_ROOT/docs/gaps"
TODAY="$(date -u +%Y-%m-%d)"

if [ ! -d "$GAPS_DIR" ]; then
    echo "[close-gaps] ERROR: $GAPS_DIR not found" >&2
    exit 1
fi

# Pull every commit subject in the range.
subjects="$(git log --format='%s' "$REV_RANGE" 2>/dev/null || true)"
if [ -z "$subjects" ]; then
    echo "[close-gaps] no commits in range $REV_RANGE — nothing to do"
    exit 0
fi

closed=0
skipped_missing=0
skipped_already_done=0
skipped_filing=0
skipped_no_close=0

while IFS= read -r subject; do
    [ -n "$subject" ] || continue

    # Filing-PR safety: never close on a filing commit. The closer-pr-batcher
    # bug INFRA-219 was exactly this — closed PRs that were filing new gaps,
    # treating their reserved IDs as duplicates.
    if echo "$subject" | grep -qE '^chore\(gaps\):[[:space:]]*file ' \
       || echo "$subject" | grep -qE '^file [A-Z]+-[0-9]+'; then
        skipped_filing=$((skipped_filing + 1))
        continue
    fi

    # Opt-out tag: [no-close] in subject means "this PR touches a gap but
    # intentionally does not close it". Partial-progress / staged-rollout PRs.
    if echo "$subject" | grep -qE '\[no-close\]'; then
        skipped_no_close=$((skipped_no_close + 1))
        continue
    fi

    # Extract every gap ID from the subject. Real gap IDs are
    # <DOMAIN>-<NUMBER> where DOMAIN is uppercase letters. We accept both
    # leading "INFRA-XXX:" and inline "...closes INFRA-XXX" patterns.
    gap_ids="$(echo "$subject" | grep -oE '[A-Z]+-[0-9]+' | sort -u || true)"
    [ -n "$gap_ids" ] || continue

    for gap_id in $gap_ids; do
        yaml_path="$GAPS_DIR/$gap_id.yaml"

        if [ ! -f "$yaml_path" ]; then
            skipped_missing=$((skipped_missing + 1))
            continue
        fi

        # Read current status — only act on open gaps. Idempotency: skip
        # already-done gaps without complaint (pattern is normal: PR title
        # references an already-closed sibling gap).
        current_status="$(awk '/^[[:space:]]*status:/ {print $2; exit}' "$yaml_path" 2>/dev/null || true)"
        if [ "$current_status" != "open" ]; then
            skipped_already_done=$((skipped_already_done + 1))
            continue
        fi

        # Surgical edit: flip status:open to status:done; insert closed_pr
        # and closed_date right after status. We use awk to preserve the
        # rest of the file byte-for-byte (no YAML reformatting).
        tmp="$yaml_path.tmp.$$"
        awk -v pr="$PR_NUMBER" -v today="$TODAY" '
            BEGIN { inserted=0 }
            /^[[:space:]]*status:[[:space:]]*open[[:space:]]*$/ && !inserted {
                # Capture leading whitespace to match indentation.
                match($0, /^[[:space:]]*/)
                indent = substr($0, RSTART, RLENGTH)
                print indent "status: done"
                print indent "closed_pr: " pr
                print indent "closed_date: " "'\''" today "'\''"
                inserted = 1
                next
            }
            { print }
        ' "$yaml_path" > "$tmp"

        # Sanity check: the new file must have exactly two more lines than
        # the original (status flipped + 2 new fields = +2 net since status
        # was already there). Otherwise something went wrong.
        old_lines="$(wc -l < "$yaml_path")"
        new_lines="$(wc -l < "$tmp")"
        if [ "$((new_lines - old_lines))" -ne 2 ]; then
            echo "[close-gaps] WARN: line-count check failed for $gap_id (old=$old_lines new=$new_lines), skipping" >&2
            rm -f "$tmp"
            continue
        fi

        mv "$tmp" "$yaml_path"
        echo "[close-gaps] closed $gap_id (PR #$PR_NUMBER, $TODAY) — subject: $subject"
        closed=$((closed + 1))
    done
done <<< "$subjects"

echo "[close-gaps] summary: closed=$closed skipped_missing=$skipped_missing already_done=$skipped_already_done filing=$skipped_filing no_close=$skipped_no_close"
exit 0
