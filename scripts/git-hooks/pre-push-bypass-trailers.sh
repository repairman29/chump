#!/usr/bin/env bash
#
# pre-push-bypass-trailers.sh — INFRA-2407
#
# Pre-push companion to commit-msg-bypass-trailers.sh. Scans every commit
# being pushed and applies the same bypass-trailer validation to any commit
# whose body contains a *Bypass* token.
#
# Called from the pre-push hook with the same $1/$2 args (remote, url).
# Git provides the refs being pushed on stdin: lines of:
#   <local_ref> <local_sha> <remote_ref> <remote_sha>
#
# Bypass: CHUMP_BYPASS_TRAILER_CHECK=0
#
# Pattern: INFRA-1658 — NO `printf|grep -q` under pipefail. Use `case`
# or assign-then-check patterns throughout.

set -euo pipefail

# ── Self-bypass ─────────────────────────────────────────────────────────────
if [ "${CHUMP_BYPASS_TRAILER_CHECK:-1}" = "0" ]; then
    exit 0
fi

# ── Load stdin (pre-push protocol: caller must pass already-cached stdin) ────
# When called from the main pre-push hook, stdin was already cached into
# _HOOK_STDIN. When called standalone, read it fresh.
if [ -n "${_HOOK_STDIN+x}" ]; then
    PUSH_STDIN="$_HOOK_STDIN"
else
    PUSH_STDIN="$(cat || true)"
fi

if [ -z "$PUSH_STDIN" ]; then
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
ALLOWLIST="${REPO_ROOT:+$REPO_ROOT/}scripts/ci/legacy-bypass-trailer-allowlist.txt"
VALIDATOR="${REPO_ROOT:+$REPO_ROOT/}scripts/git-hooks/commit-msg-bypass-trailers.sh"

_any_error=0

while IFS=' ' read -r local_ref local_sha remote_ref remote_sha; do
    [ -z "$local_sha" ] && continue
    # Skip branch deletions.
    case "$local_sha" in
        000000000000000000000000000000000000000000) continue ;;
        0000000000000000000000000000000000000000)   continue ;;
    esac

    # Determine the range of new commits being pushed.
    case "$remote_sha" in
        000000000000000000000000000000000000000000|\
        0000000000000000000000000000000000000000)
            # New branch — compare against merge-base with origin/main.
            _base="$(git merge-base "$local_sha" origin/main 2>/dev/null || echo "")"
            if [ -z "$_base" ]; then
                _base="$(git rev-list --max-parents=0 "$local_sha" 2>/dev/null | head -1 || true)"
            fi
            ;;
        *)
            _base="$remote_sha"
            ;;
    esac

    if [ -z "$_base" ]; then
        continue
    fi

    # Iterate over each new commit in the push range.
    _commits="$(git rev-list "${_base}..${local_sha}" 2>/dev/null || true)"
    if [ -z "$_commits" ]; then
        continue
    fi

    while IFS= read -r _commit_sha; do
        [ -z "$_commit_sha" ] && continue

        # Legacy grandfather check — allowlisted SHAs skip validation.
        if [ -f "$ALLOWLIST" ]; then
            _match="$(grep -xF "$_commit_sha" "$ALLOWLIST" 2>/dev/null || true)"
            case "$_match" in
                ?*)
                    continue
                    ;;
            esac
            unset _match
        fi

        # Get commit body (body = everything after the first blank line after subject).
        _body="$(git log -1 --format='%b' "$_commit_sha" 2>/dev/null || true)"

        # RESILIENT-150: only validate commits that USE the INFRA-2407 4-trailer
        # schema (^Bypass-Tier/Class/Reason/Followup:), not any "bypass" substring.
        # Prose mentions + the 12 sanctioned single-line *-Bypass: trailers
        # (Rust-First-Bypass, Test-Gate-Bypass, …) are not this validator's concern.
        # here-string (no pipe) → no pipefail race (INFRA-1658).
        if ! grep -qiE '^[[:space:]]*Bypass-(Tier|Class|Reason|Followup):' <<<"$_body"; then
            continue
        fi

        # Write commit message (subject + body) to a temp file and run the validator.
        _tmpfile="$(mktemp -t bypass-trailer-check.XXXXXX)"
        # shellcheck disable=SC2064
        trap "rm -f '$_tmpfile'" EXIT

        git log -1 --format='%s%n%n%b' "$_commit_sha" > "$_tmpfile" 2>/dev/null || true

        _short="$(git log -1 --format='%h %s' "$_commit_sha" 2>/dev/null || echo "$_commit_sha")"

        if [ -x "$VALIDATOR" ]; then
            if ! CHUMP_BYPASS_TRAILER_CHECK=1 bash "$VALIDATOR" "$_tmpfile" 2>&1; then
                echo "" >&2
                echo "[pre-push-bypass] BLOCKED on commit: $_short" >&2
                echo "[pre-push-bypass] Fix the commit (git rebase -i to edit the commit body)," >&2
                echo "[pre-push-bypass] or bypass: CHUMP_BYPASS_TRAILER_CHECK=0 git push" >&2
                echo "" >&2
                _any_error=1
            fi
        else
            echo "[pre-push-bypass] WARNING: validator script not found at $VALIDATOR" >&2
        fi

        rm -f "$_tmpfile"
    done <<< "$_commits"
done <<< "$PUSH_STDIN"

if [ "$_any_error" -ne 0 ]; then
    exit 1
fi

exit 0
