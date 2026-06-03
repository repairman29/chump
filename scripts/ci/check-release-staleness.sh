#!/usr/bin/env bash
# check-release-staleness.sh — INFRA-1373
#
# Fails (exit 1) when the latest GitHub release is more than
# CHUMP_RELEASE_STALENESS_DAYS (default 14) days behind main HEAD.
#
# This keeps the release cadence honest: new features shipping to main but
# not yet tagged/released accumulate "invisible" work that users can't install.
#
# AC:
#   1. Compares commit date of main HEAD against the published_at date of
#      the latest GitHub release; exits 1 when gap > CHUMP_RELEASE_STALENESS_DAYS.
#   2. CHUMP_RELEASE_STALENESS_DAYS tunable env var (default 14).
#
# Observability: emits gate_check_start + gate_check_result via gate-emit.sh
# (CREDIBLE-048) so fleet-brief + operator_dashboard see the result.
#
# In CI this step runs with continue-on-error: true (non-blocking P2).
# When the gap exceeds 30d, promote to blocking by removing that flag.
#
# Usage:
#   bash scripts/ci/check-release-staleness.sh
#   CHUMP_RELEASE_STALENESS_DAYS=30 bash scripts/ci/check-release-staleness.sh

set -euo pipefail

# shellcheck source=lib/gate-emit.sh
source "$(dirname "$0")/lib/gate-emit.sh" 2>/dev/null || true
gate_emit_start "INFRA-1373" "$*"

STALENESS_DAYS="${CHUMP_RELEASE_STALENESS_DAYS:-14}"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; }
info() { printf '[INFO] %s\n' "$*"; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

echo "=== INFRA-1373: release staleness check (threshold: ${STALENESS_DAYS}d) ==="
echo

# ── 1. Latest commit date on origin/main ─────────────────────────────────────

git fetch origin main --quiet 2>/dev/null || true

HEAD_DATE_RAW="$(git log -1 --format="%ci" origin/main 2>/dev/null || git log -1 --format="%ci" HEAD)"
HEAD_DATE="${HEAD_DATE_RAW%% *}"   # strip time + tz → YYYY-MM-DD

info "main HEAD commit date : $HEAD_DATE"

# ── 2. Latest GitHub release published_at ────────────────────────────────────

# Derive owner/repo from the git remote (no hardcoded values).
REMOTE_URL="$(git remote get-url origin 2>/dev/null || echo "")"
# Handles both https://github.com/owner/repo.git and git@github.com:owner/repo.git
REPO_SLUG="$(echo "$REMOTE_URL" | sed -E 's|.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$|\1|')"

if [[ -z "$REPO_SLUG" || "$REPO_SLUG" == "$REMOTE_URL" ]]; then
    fail "Could not parse GitHub owner/repo from remote: $REMOTE_URL"
    gate_emit_result "INFRA-1373" "fail" "remote-parse-error" "$REMOTE_URL" 2>/dev/null || true
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

RELEASE_JSON="$(gh api "repos/${REPO_SLUG}/releases/latest" 2>/dev/null || echo "")"

if [[ -z "$RELEASE_JSON" ]]; then
    info "No GitHub release found — treating as no release yet (staleness = infinity)."
    fail "No release found; main HEAD is at $HEAD_DATE with no corresponding release"
    gate_emit_result "INFRA-1373" "fail" "no-release" "repo=$REPO_SLUG" 2>/dev/null || true
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

RELEASE_DATE="$(echo "$RELEASE_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('published_at','')[:10])")"
RELEASE_TAG="$(echo "$RELEASE_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tag_name','?'))")"

if [[ -z "$RELEASE_DATE" ]]; then
    fail "Could not parse published_at from release JSON"
    gate_emit_result "INFRA-1373" "fail" "json-parse-error" "" 2>/dev/null || true
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

info "latest release         : $RELEASE_TAG (published $RELEASE_DATE)"

# ── 3. Compute delta in days ─────────────────────────────────────────────────

GAP_DAYS="$(python3 - <<PYEOF
from datetime import date
head = date.fromisoformat("$HEAD_DATE")
rel  = date.fromisoformat("$RELEASE_DATE")
print(max(0, (head - rel).days))
PYEOF
)"

info "days since last release: $GAP_DAYS"
echo ""

if [[ "$GAP_DAYS" -le "$STALENESS_DAYS" ]]; then
    pass "release is fresh — gap ${GAP_DAYS}d ≤ threshold ${STALENESS_DAYS}d"
    gate_emit_result "INFRA-1373" "pass" "" "tag=$RELEASE_TAG gap_days=$GAP_DAYS" 2>/dev/null || true
    echo ""
    echo "Results: 1 passed, 0 failed"
    exit 0
else
    # INFRA-2475: advisory mode by default — staleness is a signal, not a blocker.
    # A time-based guard must NOT hard-fail a required check and freeze the whole fleet
    # (e.g. after an auth outage that delayed a release cut). Set
    # CHUMP_RELEASE_STALENESS_STRICT=1 to re-enable hard-fail once cadence recovers.
    STRICT="${CHUMP_RELEASE_STALENESS_STRICT:-0}"
    if [[ "$STRICT" == "1" ]]; then
        fail "release is STALE — gap ${GAP_DAYS}d > threshold ${STALENESS_DAYS}d"
        echo "       Latest release: $RELEASE_TAG ($RELEASE_DATE)"
        echo "       main HEAD date: $HEAD_DATE"
        echo "       Action: git tag vX.Y.Z && git push origin vX.Y.Z"
        gate_emit_result "INFRA-1373" "fail" "release-stale" "tag=$RELEASE_TAG gap_days=$GAP_DAYS threshold=$STALENESS_DAYS" 2>/dev/null || true
        echo ""
        echo "Results: 0 passed, 1 failed"
        exit 1
    else
        printf '[WARN] release is STALE — gap %dd > threshold %dd (advisory; CHUMP_RELEASE_STALENESS_STRICT=1 to block)\n' \
            "$GAP_DAYS" "$STALENESS_DAYS"
        echo "       Latest release: $RELEASE_TAG ($RELEASE_DATE)"
        echo "       main HEAD date: $HEAD_DATE"
        echo "       Action: git tag vX.Y.Z && git push origin vX.Y.Z"
        gate_emit_result "INFRA-1373" "warn" "release-stale" "tag=$RELEASE_TAG gap_days=$GAP_DAYS threshold=$STALENESS_DAYS" 2>/dev/null || true
        echo ""
        echo "Results: 1 passed (advisory warning), 0 failed"
        exit 0
    fi
fi
