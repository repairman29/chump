#!/usr/bin/env bash
# scripts/coord/lib/peer-guardrails.sh — RESILIENT-1497
#
# The free Opus peer (duty-officer-loop.sh judgment-tick, discord-command-
# agent.sh) works freely on non-gated fleet work but must SURFACE, never
# execute, a fixed set of risky action categories (META-901): repo
# visibility flips, spend, credential rotation, deletes, and outward sends
# outside the one approved reply channel (notify_operator). The peer is
# NEVER an approver of its own risky actions — this lib is the one place
# that list of categories lives, so both callers agree on it.
#
# shellcheck shell=bash

# Each pattern is an ERE matched case-insensitively against a free-text
# description of an action (or the literal shell command about to run).
# Keep this list narrow and explicit rather than a vague "looks risky" --
# a false negative here is a guardrail bypass, a false positive just means
# an extra ping to the operator.
PEER_GATED_ACTION_PATTERNS=(
    'repo (edit|set).*(visibility|public|private)'
    'gh repo (edit|create).*--visibility'
    '(billing|spend|budget).*(increase|raise|approve|override)'
    'stripe|payment|invoice'
    '(credential|token|secret|api[-_ ]?key).*(rotate|revoke|regenerate|create)'
    '(rotate|revoke|regenerate).*(credential|token|secret|api[-_ ]?key)'
    'ssh-keygen|gpg --gen-key'
    'rm -rf|DROP TABLE|DELETE FROM .*(;|$)|git branch -D|git push.*--force'
    '(tweet|post to twitter|send email|email .*@|slack (post|send)|dm .*(outside|external))'
)

# peer_guardrail_is_gated <action-text> — returns 0 (gated, must surface not
# execute) or 1 (clear, may act freely).
peer_guardrail_is_gated() {
    local text="${1:-}"
    local pat
    for pat in "${PEER_GATED_ACTION_PATTERNS[@]}"; do
        if grep -qiE "$pat" <<< "$text"; then
            return 0
        fi
    done
    return 1
}

# peer_guardrail_surface <action-text> <signal-tag> — logs + pages the
# operator through notify-operator.sh instead of running the action. Never
# executes anything itself.
peer_guardrail_surface() {
    local text="${1:?action text required}" sig="${2:-peer_gated_action}"
    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd)"
    local ambient="${CHUMP_AMBIENT_LOG:-$repo_root/.chump-locks/ambient.jsonl}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local esc; esc="$(printf '%s' "$text" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    # scanner-anchor: "kind":"peer_gated_action_surfaced"
    printf '{"ts":"%s","kind":"peer_gated_action_surfaced","signal":"%s","action":"%s"}\n' \
        "$ts" "$sig" "$esc" >> "$ambient" 2>/dev/null || true
    if [[ -f "$repo_root/scripts/coord/lib/notify-operator.sh" ]]; then
        # shellcheck disable=SC1091
        source "$repo_root/scripts/coord/lib/notify-operator.sh"
        CHUMP_NOTIFY_KIND="$sig" notify_operator "GATED (needs Jeff/first-mate approval, peer will not self-approve): ${text}" 2>/dev/null || true
    fi
}
