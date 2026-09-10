#!/usr/bin/env bash
# scripts/ci/test-a2a-capability-registry.sh — INFRA-1945 (slice B of INFRA-1862)
#
# Smoke test: publish-capability.sh / capability-lookup.sh role-based
# capability discovery. Verifies:
#   (a) publish-capability.sh writes a manifest to
#       .chump-locks/capabilities/<session>.json with role + skills
#   (b) capability-lookup.sh --skill <skill> finds a session that
#       advertises it
#   (c) capability-lookup.sh --skill <skill> --role <role> filters by role
#   (d) a skill nobody advertises returns no match (exit 1)
#   (e) a manifest older than CHUMP_CAPABILITY_STALE_MIN is excluded

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
PUBLISH="$REPO_ROOT/scripts/coord/publish-capability.sh"
LOOKUP="$REPO_ROOT/scripts/coord/capability-lookup.sh"

[[ -x "$PUBLISH" ]] || { echo "[FAIL] publish-capability.sh not executable at $PUBLISH" >&2; exit 1; }
[[ -x "$LOOKUP" ]] || { echo "[FAIL] capability-lookup.sh not executable at $LOOKUP" >&2; exit 1; }

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_LOCK_DIR="$TMP/.chump-locks"

"$PUBLISH" --session curator-opus-ci-audit --role curator-opus-ci-audit --skills rust,docs,sql,a2a
[[ -f "$CHUMP_LOCK_DIR/capabilities/curator-opus-ci-audit.json" ]] || fail "manifest file not written"
grep -q '"role": "curator-opus-ci-audit"' "$CHUMP_LOCK_DIR/capabilities/curator-opus-ci-audit.json" || fail "manifest missing role field"
ok "publish-capability.sh writes a manifest with role + skills"

"$PUBLISH" --session curator-opus-handoff --role curator-opus-handoff --skills rust,handoff

MATCH="$("$LOOKUP" --skill a2a)"
echo "$MATCH" | grep -q "curator-opus-ci-audit" || fail "expected curator-opus-ci-audit in lookup for skill=a2a, got: $MATCH"
ok "capability-lookup.sh finds the session advertising a skill"

MATCH2="$("$LOOKUP" --skill rust --role curator-opus-handoff)"
if echo "$MATCH2" | grep -q "curator-opus-ci-audit"; then
    fail "role filter should have excluded curator-opus-ci-audit"
fi
echo "$MATCH2" | grep -q "curator-opus-handoff" || fail "expected curator-opus-handoff in role-filtered lookup, got: $MATCH2"
ok "capability-lookup.sh --role filters to the matching role"

if "$LOOKUP" --skill nonexistent-skill >/dev/null 2>/dev/null; then
    fail "lookup for an unadvertised skill should exit non-zero"
fi
ok "lookup for an unadvertised skill returns no match"

# (e) stale manifest excluded
STALE_JSON="$CHUMP_LOCK_DIR/capabilities/stale-session.json"
python3 -c "
import json
doc = {'session': 'stale-session', 'role': 'ghost', 'skills': ['ghost-skill'], 'updated_at': '2000-01-01T00:00:00Z'}
open('$STALE_JSON', 'w').write(json.dumps(doc))
"
if CHUMP_CAPABILITY_STALE_MIN=60 "$LOOKUP" --skill ghost-skill >/dev/null 2>/dev/null; then
    fail "stale manifest should have been excluded"
fi
ok "stale manifests are excluded from lookup"

echo "[test-a2a-capability-registry] all checks passed"
