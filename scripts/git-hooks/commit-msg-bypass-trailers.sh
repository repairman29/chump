#!/usr/bin/env bash
#
# commit-msg-bypass-trailers.sh — INFRA-2407
#
# Validates that any commit containing a bypass token in its body declares
# all 4 required structured trailers per docs/process/BYPASS_TRAILER_SCHEMA.md.
#
# The 4 required trailers (when any *Bypass* token is present in body):
#   Bypass-Tier:     one of T0 T1 T2 T3 T4
#   Bypass-Class:    free-form string (e.g. preflight-skip, proof-of-merge)
#   Bypass-Reason:   ≥10 words
#   Bypass-Followup: INFRA-NNNN
#
# Invocation: called by commit-msg git hook as:
#   scripts/git-hooks/commit-msg-bypass-trailers.sh "$1"
# where $1 is the path to the in-progress commit message file.
#
# Bypass this validator itself: CHUMP_BYPASS_TRAILER_CHECK=0
#
# Legacy grandfather list: scripts/ci/legacy-bypass-trailer-allowlist.txt
# Commits whose SHA is in that list skip validation (pre-schema legacy commits).
#
# Pattern: INFRA-1658 — NO `printf|grep -q` under pipefail. Use `case`
# or assign-then-check patterns throughout.

set -euo pipefail

# ── Self-bypass ─────────────────────────────────────────────────────────────
if [ "${CHUMP_BYPASS_TRAILER_CHECK:-1}" = "0" ]; then
    echo "[commit-msg-bypass] CHUMP_BYPASS_TRAILER_CHECK=0 — skipping bypass-trailer validation" >&2
    exit 0
fi

# ── Args ─────────────────────────────────────────────────────────────────────
MSG_FILE="${1:?commit-msg-bypass-trailers.sh: \$1 (commit message file path) is required}"
if [ ! -f "$MSG_FILE" ]; then
    echo "[commit-msg-bypass] WARNING: \$1 ($MSG_FILE) is not a file; skipping." >&2
    exit 0
fi

MSG="$(cat "$MSG_FILE")"

# ── Fast-path: does the commit body contain any bypass token? ─────────────────
# Check case-insensitively for any word containing "Bypass" or "Bypass-".
# Use `case` pattern — no pipefail race (INFRA-1658).
MSG_UPPER="$(echo "$MSG" | tr '[:lower:]' '[:upper:]')"
case "$MSG_UPPER" in
    *BYPASS*)
        # Fall through to validation below.
        ;;
    *)
        # No bypass token → nothing to validate.
        exit 0
        ;;
esac

# ── Legacy grandfather check ─────────────────────────────────────────────────
# If the current commit SHA (if available) is in the allowlist, skip.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
ALLOWLIST="${REPO_ROOT:+$REPO_ROOT/}scripts/ci/legacy-bypass-trailer-allowlist.txt"

if [ -f "$ALLOWLIST" ]; then
    # Try to get the current commit SHA. During `git commit`, HEAD hasn't moved
    # yet — ORIG_HEAD or the previous HEAD is the parent. The new commit SHA
    # doesn't exist yet. So allowlist check is done at pre-push time, not here.
    # Here we only check ORIG_HEAD as a heuristic for --amend workflows.
    CURRENT_SHA="$(git rev-parse ORIG_HEAD 2>/dev/null || echo "")"
    if [ -n "$CURRENT_SHA" ]; then
        # Assign-then-check: no printf|grep -q (INFRA-1658).
        _match="$(grep -xF "$CURRENT_SHA" "$ALLOWLIST" 2>/dev/null || true)"
        case "$_match" in
            ?*)
                # SHA is in the allowlist — skip validation.
                exit 0
                ;;
        esac
        unset _match
    fi
    unset CURRENT_SHA
fi

# ── Parse the 4 required trailers ────────────────────────────────────────────
# Each extractor uses grep + sed; assign result first, then check (INFRA-1658).

# Bypass-Tier: T0|T1|T2|T3|T4
_tier_line="$(grep -iE '^Bypass-Tier:[[:space:]]*' "$MSG_FILE" 2>/dev/null | head -1 || true)"
_tier="$(echo "$_tier_line" | sed -E 's/^[Bb]ypass-[Tt]ier:[[:space:]]*//' | tr -d '[:space:]' || true)"
unset _tier_line

# Bypass-Class: free-form non-empty
_class_line="$(grep -iE '^Bypass-Class:[[:space:]]*' "$MSG_FILE" 2>/dev/null | head -1 || true)"
_class="$(echo "$_class_line" | sed -E 's/^[Bb]ypass-[Cc]lass:[[:space:]]*//' | sed 's/[[:space:]]*$//' || true)"
unset _class_line

# Bypass-Reason: ≥10 words
_reason_line="$(grep -iE '^Bypass-Reason:[[:space:]]*' "$MSG_FILE" 2>/dev/null | head -1 || true)"
_reason="$(echo "$_reason_line" | sed -E 's/^[Bb]ypass-[Rr]eason:[[:space:]]*//' | sed 's/[[:space:]]*$//' || true)"
unset _reason_line

# Bypass-Followup: INFRA-NNNN
_followup_line="$(grep -iE '^Bypass-Followup:[[:space:]]*' "$MSG_FILE" 2>/dev/null | head -1 || true)"
_followup="$(echo "$_followup_line" | sed -E 's/^[Bb]ypass-[Ff]ollowup:[[:space:]]*//' | tr -d '[:space:]' || true)"
unset _followup_line

# ── Validate each field ───────────────────────────────────────────────────────
_errors=0
_msgs=""

# 1. Bypass-Tier must be present and in {T0,T1,T2,T3,T4}
case "$_tier" in
    T0|T1|T2|T3|T4)
        # Valid.
        ;;
    "")
        _errors=$(( _errors + 1 ))
        _msgs="${_msgs}  • Bypass-Tier is MISSING (required: T0 T1 T2 T3 T4)\n"
        ;;
    *)
        _errors=$(( _errors + 1 ))
        _msgs="${_msgs}  • Bypass-Tier='$_tier' is INVALID (must be one of: T0 T1 T2 T3 T4)\n"
        ;;
esac

# 2. Bypass-Class must be non-empty
case "$_class" in
    "")
        _errors=$(( _errors + 1 ))
        _msgs="${_msgs}  • Bypass-Class is MISSING (e.g. preflight-skip, proof-of-merge, obs-budget, test-gate)\n"
        ;;
esac

# 3. Bypass-Reason must be ≥10 words
_word_count="$(echo "$_reason" | wc -w | tr -d ' ')"
if [ -z "$_reason" ]; then
    _errors=$(( _errors + 1 ))
    _msgs="${_msgs}  • Bypass-Reason is MISSING (must be ≥10 words describing why the bypass was necessary)\n"
elif [ "$_word_count" -lt 10 ]; then
    _errors=$(( _errors + 1 ))
    _msgs="${_msgs}  • Bypass-Reason has only $_word_count word(s); minimum is 10 words. Current: '$_reason'\n"
fi

# 4. Bypass-Followup must match INFRA-NNNN
case "$_followup" in
    INFRA-[0-9]*)
        # Valid — starts with INFRA- followed by digits. Assign-check with case:
        # extract digits portion and verify all chars are digits.
        _digits="${_followup#INFRA-}"
        case "$_digits" in
            *[!0-9]*)
                _errors=$(( _errors + 1 ))
                _msgs="${_msgs}  • Bypass-Followup='$_followup' is INVALID (must be INFRA-NNNN with only digits after the dash)\n"
                ;;
            "")
                _errors=$(( _errors + 1 ))
                _msgs="${_msgs}  • Bypass-Followup='$_followup' is INVALID (must be INFRA-NNNN)\n"
                ;;
        esac
        unset _digits
        ;;
    "")
        _errors=$(( _errors + 1 ))
        _msgs="${_msgs}  • Bypass-Followup is MISSING (must be INFRA-NNNN — file a gap for the root cause)\n"
        ;;
    *)
        _errors=$(( _errors + 1 ))
        _msgs="${_msgs}  • Bypass-Followup='$_followup' is INVALID (must match INFRA-NNNN, e.g. INFRA-2407)\n"
        ;;
esac

# ── Report ────────────────────────────────────────────────────────────────────
if [ "$_errors" -gt 0 ]; then
    echo "" >&2
    echo "✖  bypass-trailer (INFRA-2407): commit body contains a bypass token but trailers are missing/invalid." >&2
    echo "" >&2
    echo "   Violations ($_errors):" >&2
    printf "%b" "$_msgs" >&2
    echo "" >&2
    echo "   All 4 trailers are required when any *Bypass* token appears in the commit body:" >&2
    echo "     Bypass-Tier:     T0 | T1 | T2 | T3 | T4" >&2
    echo "     Bypass-Class:    preflight-skip | proof-of-merge | obs-budget | test-gate | ..." >&2
    echo "     Bypass-Reason:   <≥10 word description of why this bypass was necessary>" >&2
    echo "     Bypass-Followup: INFRA-NNNN" >&2
    echo "" >&2
    echo "   Schema: docs/process/BYPASS_TRAILER_SCHEMA.md" >&2
    echo "   Bypass this validator: CHUMP_BYPASS_TRAILER_CHECK=0 git commit ..." >&2
    echo "" >&2
    exit 1
fi

exit 0
