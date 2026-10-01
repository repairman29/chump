#!/usr/bin/env bash
# scripts/ci/test-gonogo.sh — INFRA-3481 AC3/AC4
#
# Smoke test for `chump gonogo` and its wiring into `chump bootstrap`.
# Asserts:
#   1. `chump gonogo "<vision>" --json` prints verdict/reason/cost_estimate_usd/
#      tier_ceiling_usd keys and exits non-zero for NO-GO / NO-GO-ON-COST, 0 for
#      GO / NEEDS-NARROWING — driven deterministically via CHUMP_GONOGO_FORCE_VERDICT.
#   2. With CHUMP_GONOGO_FORCE_VERDICT=NO-GO, `chump bootstrap` exits non-zero and
#      creates no .git/ or Cargo.toml in the target dir.
#   3. With CHUMP_GONOGO_SKIP=1, `chump bootstrap` scaffolds exactly as today.
#
# Pure local, no network, no LLM credentials needed (CHUMP_GONOGO_FORCE_VERDICT
# bypasses the real judge entirely).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# RESILIENT-090: scrub GIT_* env vars so `git init` inside the test creates a
# truly isolated repo, not a commit in the operator's worktree.
# shellcheck source=scripts/lib/scrub-git-env.sh
source "$REPO_ROOT/scripts/lib/scrub-git-env.sh"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# ── Locate chump binary ───────────────────────────────────────────────────────
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    if [[ -f "$REPO_ROOT/target/debug/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    elif command -v chump &>/dev/null; then
        CHUMP_BIN="$(command -v chump)"
    else
        echo "SKIP: chump binary not found (set CHUMP_BIN or run cargo build first)" >&2
        exit 0
    fi
fi

# ── Phase 0: binary present ───────────────────────────────────────────────────
echo "── Phase 0: binary present ──"
[[ -x "$CHUMP_BIN" ]] && ok "chump binary executable at $CHUMP_BIN" || { fail "chump binary not executable"; exit 1; }

# ── Phase 1: --help exits 0 ──────────────────────────────────────────────────
echo "── Phase 1: --help ──"
if "$CHUMP_BIN" gonogo --help &>/dev/null; then
    ok "chump gonogo --help exits 0"
else
    fail "chump gonogo --help failed"
fi

# ── Phase 2: exit codes + JSON keys via CHUMP_GONOGO_FORCE_VERDICT ───────────
echo "── Phase 2: exit codes + JSON shape ──"
assert_gonogo_exit() {
    local forced="$1" want_exit="$2"
    local out
    set +e
    out=$(CHUMP_GONOGO_FORCE_VERDICT="$forced" "$CHUMP_BIN" gonogo "a vision" --json 2>&1)
    local got_exit=$?
    set -e
    if [[ "$got_exit" -eq "$want_exit" ]]; then
        ok "FORCE_VERDICT=$forced exits $want_exit"
    else
        fail "FORCE_VERDICT=$forced exited $got_exit, want $want_exit (output: $out)"
    fi
    for key in verdict reason cost_estimate_usd tier_ceiling_usd; do
        if echo "$out" | grep -q "\"$key\""; then
            ok "FORCE_VERDICT=$forced JSON has key '$key'"
        else
            fail "FORCE_VERDICT=$forced JSON missing key '$key' (output: $out)"
        fi
    done
}
assert_gonogo_exit "GO" 0
assert_gonogo_exit "NO-GO" 1
assert_gonogo_exit "NEEDS-NARROWING" 0
assert_gonogo_exit "NO-GO-ON-COST" 1

# ── Phase 3: bootstrap blocked on NO-GO, no mutation ─────────────────────────
echo "── Phase 3: bootstrap blocked on NO-GO ──"
BLOCKED_DIR=$(mktemp -d)
rm -rf "$BLOCKED_DIR"
set +e
CHUMP_GONOGO_FORCE_VERDICT="NO-GO" "$CHUMP_BIN" bootstrap "a vision nobody asked for" \
    --dir "$BLOCKED_DIR" --skip-arch-decision --no-umbrella-gap >/tmp/gonogo-blocked-out.$$ 2>&1
blocked_exit=$?
set -e
if [[ "$blocked_exit" -ne 0 ]]; then
    ok "bootstrap exits non-zero under forced NO-GO"
else
    fail "bootstrap should have exited non-zero under forced NO-GO"
fi
if grep -qi "no-go" /tmp/gonogo-blocked-out.$$; then
    ok "bootstrap prints the plain-language NO-GO reason"
else
    fail "bootstrap did not print a NO-GO reason (output: $(cat /tmp/gonogo-blocked-out.$$))"
fi
rm -f /tmp/gonogo-blocked-out.$$
if [[ ! -d "$BLOCKED_DIR/.git" ]]; then
    ok "no .git/ created under forced NO-GO"
else
    fail ".git/ was created despite forced NO-GO — gate ran after mutation"
fi
if [[ ! -f "$BLOCKED_DIR/Cargo.toml" ]]; then
    ok "no Cargo.toml created under forced NO-GO"
else
    fail "Cargo.toml was created despite forced NO-GO"
fi
rm -rf "$BLOCKED_DIR"

# ── Phase 4: CHUMP_GONOGO_SKIP=1 scaffolds exactly as today ──────────────────
echo "── Phase 4: CHUMP_GONOGO_SKIP=1 unchanged behavior ──"
SKIP_DIR=$(mktemp -d)
rm -rf "$SKIP_DIR"
if CHUMP_GONOGO_FORCE_VERDICT="NO-GO" CHUMP_GONOGO_SKIP=1 "$CHUMP_BIN" bootstrap "a vision nobody asked for" \
    --dir "$SKIP_DIR" --skip-arch-decision --no-umbrella-gap &>/dev/null; then
    ok "bootstrap exits 0 with CHUMP_GONOGO_SKIP=1 even under forced NO-GO"
else
    fail "bootstrap should exit 0 with CHUMP_GONOGO_SKIP=1"
fi
if [[ -d "$SKIP_DIR/.git" ]]; then
    ok ".git/ created with CHUMP_GONOGO_SKIP=1"
else
    fail ".git/ missing with CHUMP_GONOGO_SKIP=1 — gate should have been bypassed"
fi
rm -rf "$SKIP_DIR"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "── Results: $PASS passed, $FAIL failed ──"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
