#!/usr/bin/env bash
# INFRA-200: regression test for the raw-YAML-edit pre-commit guard
# (INFRA-094 in advisory mode since 2026-04-29 → INFRA-200 blocking
# since 2026-05-02). Cold Water Issue #9 measured 33/50 commits
# (66%) hand-editing docs/gaps.yaml under the advisory mode; this
# guard's blocking behavior is what arrests that pattern.
#
# Run from repo root: bash scripts/ci/test-raw-yaml-guard.sh

set -e
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# ── Sandbox setup ────────────────────────────────────────────────────────────
git init -q -b main "$SANDBOX"
mkdir -p "$SANDBOX/scripts/git-hooks" "$SANDBOX/docs" "$SANDBOX/.chump"
cp "$REPO_ROOT/scripts/git-hooks/pre-commit" "$SANDBOX/scripts/git-hooks/pre-commit"
chmod +x "$SANDBOX/scripts/git-hooks/pre-commit"
cat > "$SANDBOX/docs/gaps.yaml" <<'EOF'
gaps:
- id: TEST-001
  domain: TEST
  status: open
EOF
echo "init" > "$SANDBOX/README.md"
git -C "$SANDBOX" -c user.email=t@t -c user.name=t add -A >/dev/null
git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m seed
git -C "$SANDBOX" config core.hooksPath scripts/git-hooks

# Disable sibling guards that would interfere on this minimal sandbox.
# Single-line: multi-line continuations injected literal newlines into the
# env-var list when expanded as `env $SANDBOX_ENV cmd`, which Linux CI's
# bash interpreted differently from macOS, breaking case 4/5/6.
SANDBOX_ENV='CHUMP_LEASE_CHECK=0 CHUMP_STOMP_WARN=0 CHUMP_GAPS_LOCK=0 CHUMP_PREREG_CHECK=0 CHUMP_CROSS_JUDGE_CHECK=0 CHUMP_SUBMODULE_CHECK=0 CHUMP_CHECK_BUILD=0 CHUMP_DOCS_DELTA_CHECK=0 CHUMP_CREDENTIAL_CHECK=0 CHUMP_PREREG_CONTENT_CHECK=0 CHUMP_BOOK_SYNC_CHECK=0'

# ── case 1: raw YAML edit without marker → guard BLOCKS ──────────────────────
cat >> "$SANDBOX/docs/gaps.yaml" <<'EOF'
- id: TEST-002
  status: open
EOF
git -C "$SANDBOX" add docs/gaps.yaml
if env $SANDBOX_ENV \
    git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "raw add" >/dev/null 2>&1; then
    fail "raw YAML edit without marker unexpectedly committed"
else
    pass "raw YAML edit without marker blocked by guard"
fi

# ── case 2: fresh chump-gap marker → guard PASSES ────────────────────────────
git -C "$SANDBOX" reset HEAD docs/gaps.yaml >/dev/null 2>&1 || true
git -C "$SANDBOX" checkout -- docs/gaps.yaml >/dev/null 2>&1 || true
cat >> "$SANDBOX/docs/gaps.yaml" <<'EOF'
- id: TEST-003
  status: open
EOF
touch "$SANDBOX/.chump/.last-yaml-op"  # fresh marker (mtime = now)
git -C "$SANDBOX" add docs/gaps.yaml
if env $SANDBOX_ENV \
    git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "with marker" >/dev/null 2>&1; then
    pass "fresh .chump/.last-yaml-op marker allows edit"
else
    fail "fresh marker was rejected; should pass"
fi

# ── case 3: stale marker (>5 min) → guard BLOCKS ─────────────────────────────
cat >> "$SANDBOX/docs/gaps.yaml" <<'EOF'
- id: TEST-004
  status: open
EOF
# Stale-set marker mtime to 10 minutes ago (300s threshold + buffer).
# Try, in order: GNU touch -d (Linux CI), BSD touch -A (macOS local dev),
# python3 os.utime (last-resort portable). We previously relied on python3
# but the GitHub Actions "Free disk space" step deletes
# /opt/hostedtoolcache/Python before our test runs, which left python3
# unreliable on the runner (tests 3/5/6 cascaded as failures because the
# marker stayed fresh). touch -d is built into GNU coreutils so it works
# without any tool cache.
touch -d '10 minutes ago' "$SANDBOX/.chump/.last-yaml-op" 2>/dev/null \
  || touch -A -001000 "$SANDBOX/.chump/.last-yaml-op" 2>/dev/null \
  || python3 -c "import os, time; t = time.time() - 600; os.utime('$SANDBOX/.chump/.last-yaml-op', (t, t))"
# Verify the mtime actually moved — failing loudly here is better than
# the cascade-of-cryptic-failures we'd otherwise see further down the test.
_marker_age=$(( $(date +%s) - $(stat -c %Y "$SANDBOX/.chump/.last-yaml-op" 2>/dev/null || stat -f %m "$SANDBOX/.chump/.last-yaml-op" 2>/dev/null || echo 0) ))
if [ "$_marker_age" -lt 500 ]; then
    echo "FATAL: stale-set failed — marker_age=${_marker_age}s, expected ~600s. \
Cannot proceed; dependent tests would cascade as false failures." >&2
    exit 99
fi
git -C "$SANDBOX" add docs/gaps.yaml
if env $SANDBOX_ENV \
    git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "stale marker" >/dev/null 2>&1; then
    fail "stale marker (>5 min) unexpectedly allowed"
else
    pass "stale .chump/.last-yaml-op marker (>5 min) correctly blocked"
fi

# ── case 4: bypass with CHUMP_RAW_YAML_EDIT="<reason>" → guard PASSES ────────
# INFRA-200 (2026-05-02) changed the bypass to env-only because the
# previous trailer mechanism was unreachable (INFRA-202: pre-commit
# fires before git writes COMMIT_EDITMSG, so message trailers aren't
# visible). The env var must be a non-empty reason string.
git -C "$SANDBOX" reset HEAD docs/gaps.yaml >/dev/null 2>&1 || true
cat >> "$SANDBOX/docs/gaps.yaml" <<'EOF'
- id: TEST-005
  status: open
EOF
git -C "$SANDBOX" add docs/gaps.yaml
if env $SANDBOX_ENV CHUMP_RAW_YAML_EDIT="repairing merge corruption from PR #717/#719" \
    git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "manual edit" >/dev/null 2>&1; then
    pass "CHUMP_RAW_YAML_EDIT=<reason> allows edit"
else
    fail "documented bypass unexpectedly rejected"
fi

# ── case 5: CHUMP_RAW_YAML_EDIT=1 (just the literal '1') → guard BLOCKS ──────
# Reject the legacy "set to 1" pattern — the new bypass requires an
# actual justification string, not a boolean.
cat >> "$SANDBOX/docs/gaps.yaml" <<'EOF'
- id: TEST-006
  status: open
EOF
git -C "$SANDBOX" add docs/gaps.yaml
if env $SANDBOX_ENV CHUMP_RAW_YAML_EDIT=1 \
    git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "1 not reason" >/dev/null 2>&1; then
    fail "CHUMP_RAW_YAML_EDIT=1 (no reason) unexpectedly allowed"
else
    pass "CHUMP_RAW_YAML_EDIT=1 (literal '1', no reason) correctly blocked"
fi

# ── case 6: CHUMP_RAW_YAML_LOCK=0 kill switch bypasses guard entirely ────────
if env $SANDBOX_ENV CHUMP_RAW_YAML_LOCK=0 \
    git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "kill switch" >/dev/null 2>&1; then
    pass "CHUMP_RAW_YAML_LOCK=0 kill switch allows edit"
else
    fail "kill switch unexpectedly rejected"
fi

# ── case 7: commit that doesn't touch docs/gaps.yaml → guard skips silently ──
git -C "$SANDBOX" reset --hard HEAD >/dev/null 2>&1
echo "more" >> "$SANDBOX/README.md"
git -C "$SANDBOX" add README.md
if env $SANDBOX_ENV \
    git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "non-yaml" >/dev/null 2>&1; then
    pass "non-YAML commit skips guard cleanly"
else
    fail "guard incorrectly fired on non-YAML commit"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
