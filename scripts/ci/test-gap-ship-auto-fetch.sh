#!/usr/bin/env bash
# scripts/ci/test-gap-ship-auto-fetch.sh — INFRA-2423
#
# Smoke-tests for chump gap ship's origin/main read path (INFRA-2423, made
# fetch-ONLY by RESILIENT-1645 — PHASE-R R4). Verifies that:
#   A) clean local main N commits behind origin → ship succeeds off the fetched
#      origin/main WITHOUT fast-forwarding the checkout (HEAD unchanged)
#   B) dirty local main N commits behind origin → ship STILL succeeds (the old
#      dirty-tree bail is gone because ship never pulls) and leaves the tree put
#   C) clean local main up-to-date → ship proceeds normally (no noise)
#   D) CHUMP_BYPASS_PROOF_OF_MERGE env var is NOT consulted
#
# All tests are pure-Rust unit tests triggered via `cargo test`; this wrapper
# runs them and checks exit codes. It also does source-level verification that
# the bypass var is absent from the gap-store crate.
#
# Run:
#   bash scripts/ci/test-gap-ship-auto-fetch.sh
#
# CI: wired in .github/workflows/ci.yml (INFRA-2423)

set -uo pipefail

PASS=0; FAIL=0; FAILS=()
ok()   { printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$REPO_ROOT/crates/chump-gap-store/src/lib.rs"

echo "=== INFRA-2423: gap ship auto-fetch smoke tests ==="

# ── Source-level invariant checks ────────────────────────────────────────────
echo ""
echo "-- Source-level invariants --"

if grep -q "CHUMP_BYPASS_PROOF_OF_MERGE" "$SRC"; then
    fail "CHUMP_BYPASS_PROOF_OF_MERGE still present in $SRC (must be deleted per INFRA-2423)"
else
    ok "CHUMP_BYPASS_PROOF_OF_MERGE absent from gap-store source"
fi

if grep -q "INFRA-2423" "$SRC"; then
    ok "INFRA-2423 auto-fetch implementation present in $SRC"
else
    fail "INFRA-2423 auto-fetch implementation missing from $SRC"
fi

if grep -q '"fetch".*"origin".*"main"\|fetch.*origin.*main' "$SRC"; then
    ok "git fetch origin main call found in $SRC"
else
    fail "git fetch origin main call not found in $SRC"
fi

# RESILIENT-1645 (PHASE-R R4): ship() is now fetch-ONLY. Scope the grep to the
# ship() body so a mention in an unrelated helper/doc comment does not false-fail.
SHIP_BODY="$(awk '/pub fn ship\(&self, gap_id: &str, session_id: &str, closed_pr: Option<i64>\) -> Result<\(\)> \{/{f=1} f{print} /DoneExtras::ShipCeremony,/{if(f)exit}' "$SRC")"

if grep -qE '"pull"|--ff-only' <<<"$SHIP_BODY"; then
    fail "ship() still contains git pull / --ff-only (RESILIENT-1645: must be fetch-only)"
else
    ok "ship() contains no git pull / --ff-only (fetch-only)"
fi

if grep -qE '"build", *"--release"|"hakari"' <<<"$SHIP_BODY"; then
    fail "ship() still runs cargo build --release / cargo hakari (RESILIENT-1645: both removed)"
else
    ok "ship() runs no cargo build --release / cargo hakari"
fi

# ── Cargo unit tests ──────────────────────────────────────────────────────────
echo ""
echo "-- Cargo unit tests (chump-gap-store auto_fetch) --"

if ! command -v cargo >/dev/null 2>&1; then
    echo "  SKIP: cargo not available"
else
    if (cd "$REPO_ROOT" && \
        PATH="$HOME/.cargo/bin:$PATH" \
        cargo test -p chump-gap-store auto_fetch --quiet -- --test-threads=1 2>&1 | tail -15
    ); then
        ok "cargo test auto_fetch tests passed"
    else
        fail "cargo test auto_fetch tests failed"
    fi
fi

# ── Integration: chump binary end-to-end (optional, requires built binary) ───
echo ""
echo "-- Binary integration (scenario C: up-to-date, proof satisfied) --"

CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" || ! -x "$CHUMP_BIN" ]]; then
    CHUMP_BIN="$REPO_ROOT/target/debug/chump"
fi
if [[ ! -x "$CHUMP_BIN" ]]; then
    CHUMP_BIN="${HOME}/.cargo/bin/chump"
fi
if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "  SKIP: chump binary not found (run 'cargo build --bin chump' or set CHUMP_BIN)"
else
    TMP="$(mktemp -d -t test-infra-2423.XXXXXX)"
    cleanup() { rm -rf "$TMP"; }
    trap cleanup EXIT

    # Set up an isolated git repo with a 'main' branch (simulates origin in sync)
    SHIP_REPO="$TMP/ship-repo"
    mkdir -p "$SHIP_REPO"
    git -C "$SHIP_REPO" init -q
    git -C "$SHIP_REPO" config user.email "test@integration.local"
    git -C "$SHIP_REPO" config user.name "Integration Test"

    # Reserve a test gap so we have a real gap ID
    export CHUMP_STATE_DB="$TMP/state.db"
    gap_id=$(
        FLEET_029_AMBIENT_GLANCE_SKIP=1 \
        "$CHUMP_BIN" gap reserve \
            --domain TEST \
            --title "TEST: INFRA-2423 auto-fetch smoke fixture" \
            --priority P3 --force 2>&1 | grep '^TEST-' | tail -1
    ) || true

    if [[ -z "$gap_id" ]]; then
        echo "  SKIP: could not reserve test gap for binary integration test"
    else
        # Add commit mentioning gap_id to SHIP_REPO main branch
        echo "marker" > "$SHIP_REPO/marker.txt"
        git -C "$SHIP_REPO" add marker.txt
        git -C "$SHIP_REPO" commit -q -m "feat(${gap_id}): INFRA-2423 auto-fetch test marker"
        mkdir -p "$SHIP_REPO/docs/gaps"
        yaml_src="$REPO_ROOT/docs/gaps/${gap_id}.yaml"
        [[ -f "$yaml_src" ]] && cp "$yaml_src" "$SHIP_REPO/docs/gaps/${gap_id}.yaml"

        SHIP_OUT=$(
            CHUMP_REPO="$SHIP_REPO" \
            CHUMP_SKIP_SUPERSEDED_CLOSE=1 \
            CHUMP_SHIP_NO_AUTOSTAGE=1 \
            CHUMP_ALLOW_STALE_DESTRUCTIVE=1 \
            CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 \
            "$CHUMP_BIN" gap ship "$gap_id" --closed-pr 9999 2>&1
        )
        SHIP_RC=$?
        if [[ $SHIP_RC -eq 0 ]]; then
            ok "Scenario C: up-to-date clean repo — ship succeeded for $gap_id"
        else
            fail "Scenario C: ship exited $SHIP_RC; output: ${SHIP_OUT:0:200}"
        fi

        # Verify bypass var is NOT consulted: set it and scenario should still work
        # (it has no effect — the var is gone from the binary)
        BYPASS_OUT=$(
            CHUMP_REPO="$SHIP_REPO" \
            CHUMP_BYPASS_PROOF_OF_MERGE=1 \
            CHUMP_SKIP_SUPERSEDED_CLOSE=1 \
            CHUMP_SHIP_NO_AUTOSTAGE=1 \
            CHUMP_ALLOW_STALE_DESTRUCTIVE=1 \
            CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 \
            "$CHUMP_BIN" gap ship "$gap_id" --closed-pr 9999 2>&1
        )
        BYPASS_RC=$?
        # The gap is already done, so this should fail with "not found or already done"
        # What matters is the exit code is NOT 0 AND the reason is "already done", not
        # a bypass-consulted message. We just verify the binary didn't emit bypass text.
        if echo "$BYPASS_OUT" | grep -q "CHUMP_BYPASS_PROOF_OF_MERGE"; then
            fail "Scenario D: binary still references CHUMP_BYPASS_PROOF_OF_MERGE in output"
        else
            ok "Scenario D: binary does not reference deleted bypass var in output"
        fi

        # Clean up test gap YAML from real repo
        [[ -f "$yaml_src" ]] && rm -f "$yaml_src" || true
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
