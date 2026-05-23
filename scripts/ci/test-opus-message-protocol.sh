#!/usr/bin/env bash
# scripts/ci/test-opus-message-protocol.sh — INFRA-1798
#
# Verifies docs/process/OPUS_MESSAGE_PROTOCOL.md exists and consistently
# cross-references the rest of the opus-message v0 stack. Pairs with the
# CLAUDE.md addendum that mandates the protocol in MANDATORY pre-flight.
#
# Static-only assertions; no runtime behavior to verify here (the runtime
# is covered by test-opus-message.sh + test-opus-message-hook.sh).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC="$REPO_ROOT/docs/process/OPUS_MESSAGE_PROTOCOL.md"
CLAUDE="$REPO_ROOT/CLAUDE.md"

failures=0

assert_grep() {
    local file="$1" pattern="$2" desc="$3"
    if ! grep -qE -- "$pattern" "$file" 2>/dev/null; then
        echo "FAIL: $desc"
        echo "       file: ${file#"$REPO_ROOT/"}"
        echo "       pattern: $pattern"
        failures=$((failures + 1))
    fi
}

# ── 1. doc exists ───────────────────────────────────────────────────────────
if [[ ! -f "$DOC" ]]; then
    echo "FAIL: $DOC not found"
    exit 1
fi

# ── 2. doc references the CLI by path ───────────────────────────────────────
assert_grep "$DOC" \
    "scripts/coord/opus-message.sh" \
    "protocol doc references the CLI script path"

# ── 3. doc names the three send modes ───────────────────────────────────────
assert_grep "$DOC" \
    "session:<sender-id>|session:<me>" \
    "protocol doc names session: addressing"
assert_grep "$DOC" \
    "gap:<X>|gap:INFRA-" \
    "protocol doc names gap: addressing"
assert_grep "$DOC" \
    "all-opus" \
    "protocol doc names all-opus broadcast"

# ── 4. doc cites the foundation gap IDs ─────────────────────────────────────
assert_grep "$DOC" "INFRA-1796" "protocol doc cites INFRA-1796 (CLI gap)"
assert_grep "$DOC" "INFRA-1797" "protocol doc cites INFRA-1797 (hook gap)"
assert_grep "$DOC" "INFRA-1759" "protocol doc cites INFRA-1759 (RPC successor)"

# ── 5. doc includes all three send patterns ─────────────────────────────────
assert_grep "$DOC" "hand-off" "protocol doc shows Pattern 1: hand-off"
assert_grep "$DOC" "broadcast warning" "protocol doc shows Pattern 2: broadcast warning"
assert_grep "$DOC" "RFC" "protocol doc shows Pattern 3: RFC/design review"

# ── 6. doc documents the read/process/mark-read sequence ────────────────────
assert_grep "$DOC" "mark-read" "protocol doc documents mark-read step"
assert_grep "$DOC" "never .*mark-read.* before processing" \
    "protocol doc enforces never-mark-read-before-processing rule"

# ── 7. CLAUDE.md mandates the inbox check in pre-flight ─────────────────────
if [[ ! -f "$CLAUDE" ]]; then
    echo "FAIL: $CLAUDE not found"
    failures=$((failures + 1))
else
    assert_grep "$CLAUDE" \
        "opus-message.sh list --unread" \
        "CLAUDE.md pre-flight includes opus-message.sh inbox check"
    assert_grep "$CLAUDE" \
        "OPUS_MESSAGE_PROTOCOL.md" \
        "CLAUDE.md references the protocol doc"
fi

if [[ $failures -gt 0 ]]; then
    echo ""
    echo "FAIL INFRA-1798: $failures assertion(s) failed"
    exit 1
fi

echo "OK INFRA-1798: opus-message protocol doc + CLAUDE.md mandate consistent"
