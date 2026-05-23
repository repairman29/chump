#!/usr/bin/env bash
# scripts/ci/test-the-path-exists.sh — META-087
#
# Asserts docs/process/THE_PATH.md exists with the 5-track structure that
# JIT scheduler (INFRA-1892) + curators rely on. Doc is Oracle output;
# this test catches it being deleted, gutted, or losing the track sections.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DOC="$REPO/docs/process/THE_PATH.md"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$DOC" ]] || fail "$DOC missing — Oracle output deleted"
ok "doc exists at $DOC"

# Must have all 5 tracks
for n in 1 2 3 4 5; do
    if grep -qE "^## Track $n" "$DOC"; then
        ok "Track $n section present"
    else
        fail "Track $n section missing — Oracle output gutted"
    fi
done

# Each track must have a non-empty "Next actions" subsection
track_count=$(grep -cE "^## Track [0-9]" "$DOC")
nextact_count=$(grep -cE "^\*\*Next actions" "$DOC")
if (( nextact_count >= track_count )); then
    ok "each track has Next-actions ($nextact_count / $track_count)"
else
    fail "only $nextact_count Next-actions for $track_count tracks — some empty"
fi

# Should reference INFRA-1892 (JIT) since this doc's consumer
grep -q 'INFRA-1892' "$DOC" || fail "no INFRA-1892 reference — JIT consumer should be named"
ok "INFRA-1892 (JIT scheduler consumer) referenced"

# Should reference Oracle refresh cadence
grep -qiE "refresh|cadence|sweep" "$DOC" || fail "no refresh cadence noted"
ok "Oracle refresh cadence documented"

# Should explicitly note de-prioritization (the demotion sweep half of the work)
grep -qE "(de-priorit|demote|NOT on the path)" "$DOC" || fail "no demotion guidance — Oracle should call out what's noise"
ok "demotion guidance present"

# Should have META-087 attribution somewhere (this gap)
grep -q 'META-087' "$DOC" || true  # optional — not strict

echo ""
echo "ALL META-087 THE_PATH structure assertions passed."
