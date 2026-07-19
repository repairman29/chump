#!/usr/bin/env bash
# test-ingest-artifacts-smoke.sh — INFRA-1783 (Phase 3 Evangelist + Phase 4
# Systematizer of `chump ingest`, per INFRA-1746)
#
# Proves build-hidden-gems.sh and build-capabilities-registry.sh run against
# an ARBITRARY target repo (--repo-root), not just Chump's own checkout —
# the capability `chump ingest <repo-path>` needs to emit HIDDEN_GEMS.md +
# CAPABILITIES_REGISTRY.json into the target repo per INFRA-1746 AC #4/#5.
#
# Verifies:
#   1. build-hidden-gems.sh --repo-root writes <target>/docs/HIDDEN_GEMS.md
#   2. build-capabilities-registry.sh --repo-root writes
#      <target>/docs/CAPABILITIES_REGISTRY.json, valid JSON, repo id != Chump's own
#   3. Neither script mutates Chump's own docs/ when pointed at the fixture

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

FAIL=0
_fail() { echo "FAIL: $1" >&2; FAIL=1; }
_ok() { echo "  ok: $1"; }

FIXTURE="$(mktemp -d -t chump-ingest-fixture-XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/scripts/dev"
(cd "$FIXTURE" && git init -q)
cat > "$FIXTURE/README.md" <<'EOF'
# fixture-target-repo
EOF
cat > "$FIXTURE/scripts/README.md" <<'EOF'
- scripts/dev/hello.sh — says hello
EOF
cat > "$FIXTURE/scripts/dev/hello.sh" <<'EOF'
#!/usr/bin/env bash
echo hello
EOF
chmod +x "$FIXTURE/scripts/dev/hello.sh"

CHUMP_OWN_DOC_HASH_BEFORE="$(md5sum docs/HIDDEN_GEMS.md 2>/dev/null | awk '{print $1}')"
CHUMP_OWN_REGISTRY_HASH_BEFORE="$(md5sum docs/CAPABILITIES_REGISTRY.json 2>/dev/null | awk '{print $1}')"

# ── 1. Phase 3 Evangelist against the target repo ────────────────────────────
if bash scripts/dev/build-hidden-gems.sh --repo-root "$FIXTURE" >/tmp/ingest-hidden-gems.log 2>&1; then
    _ok "build-hidden-gems.sh --repo-root ran"
else
    _fail "build-hidden-gems.sh --repo-root failed: $(cat /tmp/ingest-hidden-gems.log)"
fi

if [[ -f "$FIXTURE/docs/HIDDEN_GEMS.md" ]]; then
    _ok "$FIXTURE/docs/HIDDEN_GEMS.md written"
else
    _fail "$FIXTURE/docs/HIDDEN_GEMS.md was not written"
fi

if grep -q 'scripts/dev/hello.sh' "$FIXTURE/docs/HIDDEN_GEMS.md" 2>/dev/null; then
    _ok "target repo's own scripts/README.md content surfaced (fixture repo, not Chump's)"
else
    _fail "target-repo HIDDEN_GEMS.md did not surface fixture's scripts/README.md entry"
fi

# ── 2. Phase 4 Systematizer against the target repo ──────────────────────────
if bash scripts/dev/build-capabilities-registry.sh --repo-root "$FIXTURE" --quiet >/tmp/ingest-capreg.log 2>&1; then
    _ok "build-capabilities-registry.sh --repo-root ran"
else
    _fail "build-capabilities-registry.sh --repo-root failed: $(cat /tmp/ingest-capreg.log)"
fi

REGISTRY="$FIXTURE/docs/CAPABILITIES_REGISTRY.json"
if [[ -f "$REGISTRY" ]] && python3 -c "import json; json.load(open('$REGISTRY'))" 2>/dev/null; then
    _ok "$REGISTRY exists and parses as JSON"
else
    _fail "$REGISTRY missing or invalid JSON"
fi

FIXTURE_REPO_ID="$(python3 -c "import json; print(json.load(open('$REGISTRY')).get('repo',''))" 2>/dev/null || echo "")"
if [[ "$FIXTURE_REPO_ID" == "$(basename "$FIXTURE")" ]]; then
    _ok "registry repo id ($FIXTURE_REPO_ID) identifies the target repo, not Chump"
else
    _fail "registry repo id unexpected: '$FIXTURE_REPO_ID'"
fi

# ── 3. No mutation of Chump's own docs/ ──────────────────────────────────────
CHUMP_OWN_DOC_HASH_AFTER="$(md5sum docs/HIDDEN_GEMS.md 2>/dev/null | awk '{print $1}')"
CHUMP_OWN_REGISTRY_HASH_AFTER="$(md5sum docs/CAPABILITIES_REGISTRY.json 2>/dev/null | awk '{print $1}')"
if [[ "$CHUMP_OWN_DOC_HASH_BEFORE" == "$CHUMP_OWN_DOC_HASH_AFTER" ]]; then
    _ok "Chump's own docs/HIDDEN_GEMS.md untouched"
else
    _fail "Chump's own docs/HIDDEN_GEMS.md was mutated by a --repo-root run"
fi
if [[ "$CHUMP_OWN_REGISTRY_HASH_BEFORE" == "$CHUMP_OWN_REGISTRY_HASH_AFTER" ]]; then
    _ok "Chump's own docs/CAPABILITIES_REGISTRY.json untouched"
else
    _fail "Chump's own docs/CAPABILITIES_REGISTRY.json was mutated by a --repo-root run"
fi

if [[ "$FAIL" -eq 0 ]]; then
    echo "PASS: ingest Phase 3/4 artifacts smoke test"
    exit 0
fi
exit 1
