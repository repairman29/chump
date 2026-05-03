#!/usr/bin/env bash
# test-recycled-id-guard.sh — unit tests for the INFRA-014 recycled-ID
# pre-commit guard.
#
# Acceptance criteria verified:
#   (1) Hook rejects a commit that flips a gap from status: done (on
#       origin/main) back to status: open under the same id.
#   (2) Hook allows legitimate done -> done diffs (e.g. adding closed_pr,
#       closed_date, resolution_notes — INFRA-234 false-positive class).
#   (3) Hook allows a new open gap with a genuinely new id.
#   (4) CHUMP_GAPS_LOCK=0 bypasses the check.
#   (5) Both the per-file (docs/gaps/<ID>.yaml) canonical format AND the
#       legacy monolithic (docs/gaps.yaml) fallback path are exercised.
#   (6) Quoted status values (`status: "done"`) parse identically to
#       unquoted (INFRA-234 parser hardening).
#
# Run:
#   ./scripts/ci/test-recycled-id-guard.sh
#
# Exits non-zero on any check failure.

set -euo pipefail

PASS=0
FAIL=0
FAILS=()

ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-014 recycled-ID guard unit tests ==="
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit"

if [ ! -x "$HOOK" ]; then
    echo "FATAL: pre-commit hook not found or not executable: $HOOK"
    exit 2
fi

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Silence unrelated guards (the recycled-ID guard is what we're isolating).
# CHUMP_RAW_YAML_LOCK=0 in particular: post-INFRA-200 the raw-YAML-edit guard
# is blocking on any docs/gaps/*.yaml change without a fresh chump-gap CLI
# marker — but our seed/edit cycle here is intentionally hand-edited fixture
# data. Without the bypass none of the test cases below can even seed.
export CHUMP_LEASE_CHECK=0
export CHUMP_STOMP_WARN=0
export CHUMP_CHECK_BUILD=0
export CHUMP_DOCS_DELTA_CHECK=0
export CHUMP_SUBMODULE_CHECK=0
export CHUMP_PREREG_CHECK=0
export CHUMP_PREREG_CONTENT_CHECK=0
export CHUMP_CROSS_JUDGE_CHECK=0
export CHUMP_CREDENTIAL_CHECK=0
export CHUMP_BOOK_SYNC_CHECK=0
export CHUMP_RAW_YAML_LOCK=0

# Helper: spin up a fresh fake repo with one done gap on "origin/main".
# Args: $1 = which-format ("per-file" | "monolithic")
#       $2 = which-status-style ("plain" | "quoted")
make_repo() {
    local fmt="$1"
    local style="${2:-plain}"
    local repo
    repo="$(mktemp -d -p "$TMPDIR_BASE")"
    mkdir -p "$repo/.git/hooks" "$repo/docs/gaps"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@test.com"
    git -C "$repo" config user.name "Test"
    cp "$HOOK" "$repo/.git/hooks/pre-commit"
    chmod +x "$repo/.git/hooks/pre-commit"

    local s
    if [ "$style" = "quoted" ]; then
        s='"done"'
    else
        s='done'
    fi

    if [ "$fmt" = "per-file" ]; then
        cat >"$repo/docs/gaps/TEST-A.yaml" <<YAML
- id: TEST-A
  domain: TEST
  title: closed gap A
  status: $s
  closed_date: '2026-04-20'
YAML
        cat >"$repo/docs/gaps/TEST-B.yaml" <<YAML
- id: TEST-B
  domain: TEST
  title: open gap B
  status: open
YAML
        git -C "$repo" add docs/gaps/TEST-A.yaml docs/gaps/TEST-B.yaml
    else
        cat >"$repo/docs/gaps.yaml" <<YAML
gaps:
- id: TEST-A
  title: closed gap A
  status: $s
  closed_date: '2026-04-20'
- id: TEST-B
  title: open gap B
  status: open
YAML
        git -C "$repo" add docs/gaps.yaml
    fi
    git -C "$repo" commit -q -m "seed: TEST-A closed (fmt=$fmt style=$style)"
    git -C "$repo" update-ref refs/remotes/origin/main HEAD
    echo "$repo"
}

# ── Test 1: flipping TEST-A done -> open is rejected (per-file canonical) ──
echo "--- Test 1: reopening a done gap is blocked (per-file canonical) ---"
REPO="$(make_repo per-file)"
cat >"$REPO/docs/gaps/TEST-A.yaml" <<'YAML'
- id: TEST-A
  domain: TEST
  title: closed gap A
  status: open
YAML
git -C "$REPO" add docs/gaps/TEST-A.yaml
if out=$(git -C "$REPO" commit -m "reopen TEST-A" 2>&1); then
    fail "hook allowed reopening TEST-A (done -> open) [per-file]"
    echo "      output: $out"
else
    if echo "$out" | grep -q "RECYCLE" && echo "$out" | grep -q "TEST-A"; then
        ok "recycled-ID guard blocked reopen [per-file]"
    else
        fail "hook blocked but wrong message; output: $out"
    fi
fi

# ── Test 2 (was Test 2, repurposed): adding resolution_notes to done gap ──
echo "--- Test 2: done gap stays done with resolution_notes (allowed) ---"
REPO="$(make_repo per-file)"
cat >"$REPO/docs/gaps/TEST-A.yaml" <<'YAML'
- id: TEST-A
  domain: TEST
  title: closed gap A
  status: done
  closed_date: '2026-04-20'
  resolution_notes: minor cleanup
YAML
git -C "$REPO" add docs/gaps/TEST-A.yaml
if git -C "$REPO" commit -q -m "add resolution_notes" 2>/dev/null; then
    ok "benign resolution_notes enrichment allowed"
else
    fail "hook blocked benign done-gap edit (resolution_notes)"
fi

# ── Test 3: fresh new open gap is allowed ────────────────────────────────────
echo "--- Test 3: adding a genuinely new gap is allowed ---"
REPO="$(make_repo per-file)"
cat >"$REPO/docs/gaps/TEST-C.yaml" <<'YAML'
- id: TEST-C
  domain: TEST
  title: brand-new gap
  status: open
YAML
git -C "$REPO" add docs/gaps/TEST-C.yaml
if git -C "$REPO" commit -q -m "add TEST-C" 2>/dev/null; then
    ok "new gap with fresh id accepted"
else
    fail "hook blocked a legitimate new gap"
fi

# ── Test 4: CHUMP_GAPS_LOCK=0 bypasses the guard ─────────────────────────────
echo "--- Test 4: CHUMP_GAPS_LOCK=0 bypasses ---"
REPO="$(make_repo per-file)"
cat >"$REPO/docs/gaps/TEST-A.yaml" <<'YAML'
- id: TEST-A
  domain: TEST
  title: closed gap A
  status: open
YAML
git -C "$REPO" add docs/gaps/TEST-A.yaml
if CHUMP_GAPS_LOCK=0 git -C "$REPO" commit -q -m "force-reopen with bypass" 2>/dev/null; then
    ok "CHUMP_GAPS_LOCK=0 bypass honored"
else
    fail "bypass env var did not work"
fi

# ── Test 5 (INFRA-234 — the headline false-positive): closed_pr enrichment ──
echo "--- Test 5: adding closed_pr to status:done is allowed (INFRA-234) ---"
REPO="$(make_repo per-file)"
cat >"$REPO/docs/gaps/TEST-A.yaml" <<'YAML'
- id: TEST-A
  domain: TEST
  title: closed gap A
  status: done
  closed_date: '2026-04-20'
  closed_pr: 755
YAML
git -C "$REPO" add docs/gaps/TEST-A.yaml
if git -C "$REPO" commit -q -m "enrich done gap with closed_pr" 2>/dev/null; then
    ok "INFRA-234 false-positive case: closed_pr enrichment allowed"
else
    fail "INFRA-234 regressed: closed_pr enrichment blocked on status:done"
fi

# ── Test 6: closed_date enrichment on status:done is allowed ────────────────
echo "--- Test 6: adding closed_date when missing is allowed ---"
REPO="$(make_repo per-file)"
# Re-seed: origin/main has done but no closed_date, then add it.
cat >"$REPO/docs/gaps/TEST-A.yaml" <<'YAML'
- id: TEST-A
  domain: TEST
  title: closed gap A
  status: done
YAML
git -C "$REPO" add docs/gaps/TEST-A.yaml
git -C "$REPO" commit -q --amend --no-edit
git -C "$REPO" update-ref refs/remotes/origin/main HEAD
cat >"$REPO/docs/gaps/TEST-A.yaml" <<'YAML'
- id: TEST-A
  domain: TEST
  title: closed gap A
  status: done
  closed_date: '2026-05-02'
YAML
git -C "$REPO" add docs/gaps/TEST-A.yaml
if git -C "$REPO" commit -q -m "backfill closed_date" 2>/dev/null; then
    ok "closed_date enrichment allowed"
else
    fail "closed_date enrichment blocked on status:done"
fi

# ── Test 7: monolithic fallback path still works ────────────────────────────
echo "--- Test 7: monolithic docs/gaps.yaml fallback still rejects reopen ---"
REPO="$(make_repo monolithic)"
cat >"$REPO/docs/gaps.yaml" <<'YAML'
gaps:
- id: TEST-A
  title: closed gap A
  status: open
- id: TEST-B
  title: open gap B
  status: open
YAML
git -C "$REPO" add docs/gaps.yaml
if out=$(git -C "$REPO" commit -m "reopen via monolithic" 2>&1); then
    fail "hook allowed reopening TEST-A on monolithic path"
    echo "      output: $out"
else
    if echo "$out" | grep -q "RECYCLE" && echo "$out" | grep -q "TEST-A"; then
        ok "monolithic fallback recycled-ID guard fires"
    else
        fail "monolithic blocked but wrong message"
    fi
fi

# ── Test 8: quoted status values parse identically (INFRA-234 hardening) ────
echo "--- Test 8: quoted status: \"done\" parses as done (INFRA-234 hardening) ---"
REPO="$(make_repo per-file quoted)"
# Reopen with unquoted "open" — the guard should still catch it because
# the parser strips quotes before comparing to "done".
cat >"$REPO/docs/gaps/TEST-A.yaml" <<'YAML'
- id: TEST-A
  domain: TEST
  title: closed gap A
  status: open
YAML
git -C "$REPO" add docs/gaps/TEST-A.yaml
if out=$(git -C "$REPO" commit -m "reopen quoted-status gap" 2>&1); then
    fail "hook silently allowed reopen of quoted-status:done gap"
    echo "      output: $out"
else
    if echo "$out" | grep -q "RECYCLE" && echo "$out" | grep -q "TEST-A"; then
        ok "quoted-status hardening: guard fires on \"done\" -> open"
    else
        fail "quoted-status reopen blocked but wrong message"
    fi
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
