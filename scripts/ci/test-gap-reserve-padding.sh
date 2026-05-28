#!/usr/bin/env bash
# INFRA-080: regression — gap-reserve.sh must zero-pad the new ID to the
# prevailing width of the domain's existing IDs (3 digits is the
# established convention across every domain in the repo). EVAL-88 was
# observed in PR #554 because the shell path emitted the bare integer.
# Run from repo root: bash scripts/ci/test-gap-reserve-padding.sh

set -e
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# Build a sandbox repo so we don't touch the real lease dir or gaps.yaml.
sandbox_setup() {
    local sandbox="$1"
    local fixture_yaml="$2"
    git init -q -b main "$sandbox"
    mkdir -p "$sandbox/docs" "$sandbox/.chump-locks" "$sandbox/scripts/coord" "$sandbox/scripts/lib" "$sandbox/bin"
    cp "$REPO_ROOT/scripts/coord/gap-reserve.sh" "$sandbox/scripts/coord/gap-reserve.sh"
    chmod +x "$sandbox/scripts/coord/gap-reserve.sh"
    # INFRA-109: gap-reserve.sh now sources scripts/lib/repo-paths.sh for
    # main-repo-vs-linked-worktree resolution. Sandbox needs the same lib.
    cp "$REPO_ROOT/scripts/lib/repo-paths.sh" "$sandbox/scripts/lib/repo-paths.sh"
    # INFRA-383: gap-reserve.sh now also sources scripts/lib/chump-preflight.sh
    # (chump-doctor preflight). Sandbox needs this lib too or the source line
    # at the top of gap-reserve.sh aborts under set -euo pipefail.
    cp "$REPO_ROOT/scripts/lib/chump-preflight.sh" "$sandbox/scripts/lib/chump-preflight.sh"
    # Create mock flock for systems that don't have it (e.g., macOS)
    cat > "$sandbox/bin/flock" <<'FLOCK_EOF'
#!/bin/bash
while getopts "xsu" opt; do
    shift
done
fd=$1
shift
if [ $# -eq 0 ]; then
    exit 0
fi
exec "$@"
FLOCK_EOF
    chmod +x "$sandbox/bin/flock"
    printf '%s' "$fixture_yaml" > "$sandbox/docs/gaps.yaml"
    git -C "$sandbox" -c user.email=t@t -c user.name=t add -A >/dev/null
    git -C "$sandbox" -c user.email=t@t -c user.name=t commit -q -m "seed"
    # Add a fake `origin/main` ref so the script's `git show origin/main:` works.
    git -C "$sandbox" branch -q origin/main main 2>/dev/null || \
        git -C "$sandbox" update-ref refs/heads/origin/main HEAD
    # The script uses `git show origin/main:docs/gaps.yaml`. Easier: configure
    # a remote pointing back at this sandbox (so origin/main resolves).
    git -C "$sandbox" remote add origin "$sandbox" 2>/dev/null || true
    git -C "$sandbox" fetch -q origin 2>/dev/null || true
    # INFRA-2080: gap-reserve.sh was migrated from docs/gaps.yaml to state.db
    # (INFRA-2000 / PR #2637). Seed the sandbox's own state.db with the fixture
    # YAML so `chump gap reserve` reads the sandbox data, not the real repo's db.
    # CHUMP_GAP_IMPORT_NO_SIMILARITY=1 bypasses the title-dedup check that would
    # otherwise open and compare against the real db.
    CHUMP_HOME="$sandbox" \
    CHUMP_REPO="$sandbox" \
    CHUMP_GAP_IMPORT_NO_SIMILARITY=1 \
    chump gap import --yaml "$sandbox/docs/gaps.yaml" >/dev/null 2>&1 || true
}

reserve_in_sandbox() {
    local sandbox="$1"
    local domain="$2"
    local title="$3"
    (
        cd "$sandbox"
        export PATH="$sandbox/bin:$PATH"
        # INFRA-2080: point CHUMP_HOME and CHUMP_REPO at the sandbox so that
        # `chump gap reserve` (invoked by gap-reserve.sh) resolves its state.db
        # to $sandbox/.chump/state.db rather than the real repo's db.
        CHUMP_HOME="$sandbox" \
        CHUMP_REPO="$sandbox" \
        CHUMP_GAP_RESERVE_SKIP_PR=1 \
        CHUMP_RESERVE_SCAN_OPEN_PRS=0 \
        CHUMP_SESSION_ID="test-pad-$$" \
        CHUMP_ALLOW_MAIN_WORKTREE=1 \
        CHUMP_LOCK_DIR="$sandbox/.chump-locks" \
        FLEET_029_AMBIENT_GLANCE_SKIP=1 \
        scripts/coord/gap-reserve.sh "$domain" "$title" 2>/dev/null
    )
}

# ── case 1: 3-digit prevailing → next ID is 3-digit padded ───────────────────
SANDBOX1="$TMPROOT/case1"
sandbox_setup "$SANDBOX1" "$(cat <<'EOF'
gaps:
- id: EVAL-085
  status: open
- id: EVAL-086
  status: done
- id: EVAL-087
  status: done
EOF
)"
got=$(reserve_in_sandbox "$SANDBOX1" EVAL "first padded reserve")
if [ "$got" = "EVAL-088" ]; then
    pass "EVAL after 087 → EVAL-088 (got $got)"
else
    fail "expected EVAL-088, got $got"
fi

# ── case 2: empty domain → first reserve still 3-digit padded ────────────────
SANDBOX2="$TMPROOT/case2"
sandbox_setup "$SANDBOX2" "$(cat <<'EOF'
gaps:
- id: INFRA-001
  status: done
EOF
)"
got=$(reserve_in_sandbox "$SANDBOX2" NEWDOMAIN "first ID for new domain")
if [ "$got" = "NEWDOMAIN-001" ]; then
    pass "first reserve in empty domain → NEWDOMAIN-001 (got $got)"
else
    fail "expected NEWDOMAIN-001, got $got"
fi

# ── case 3: domain that already has 4-digit IDs stays 4-digit ────────────────
SANDBOX3="$TMPROOT/case3"
sandbox_setup "$SANDBOX3" "$(cat <<'EOF'
gaps:
- id: BIG-9998
  status: done
- id: BIG-9999
  status: done
EOF
)"
got=$(reserve_in_sandbox "$SANDBOX3" BIG "wide domain")
if [ "$got" = "BIG-10000" ]; then
    pass "domain with 4-digit IDs → BIG-10000 (got $got)"
else
    fail "expected BIG-10000, got $got"
fi

# ── case 4: under-3-digit existing IDs still pad to floor of 3 ───────────────
SANDBOX4="$TMPROOT/case4"
sandbox_setup "$SANDBOX4" "$(cat <<'EOF'
gaps:
- id: TINY-1
  status: done
- id: TINY-2
  status: done
EOF
)"
got=$(reserve_in_sandbox "$SANDBOX4" TINY "narrow domain rounds up")
if [ "$got" = "TINY-003" ]; then
    pass "domain with 1-digit legacy IDs → floor 3-digit (got $got)"
else
    fail "expected TINY-003, got $got"
fi

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
