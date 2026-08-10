#!/usr/bin/env bash
# scripts/ci/test-gonogo.sh — INFRA-3481
#
# Asserts:
#   1. `chump gonogo "<vision>" --json` prints verdict/reason/cost_estimate_usd/
#      tier_ceiling_usd and exits non-zero for NO-GO / NO-GO-ON-COST, 0 for
#      GO / NEEDS-NARROWING — driven via CHUMP_GONOGO_FORCE_VERDICT.
#   2. `chump bootstrap` honors CHUMP_GONOGO_FORCE_VERDICT=NO-GO: exits
#      non-zero, creates no .git/ or Cargo.toml, prints the reason.
#   3. `chump bootstrap` with CHUMP_GONOGO_SKIP=1 scaffolds exactly as today
#      (gate bypassed entirely).
#
# Pure local, no network needed (force-verdict / skip seams avoid the live
# `chump llm-complete` rail entirely).
# SOURCE scrub-git-env.sh (RESILIENT-090) to isolate from pre-push hook env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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
    elif [[ -f "$HOME/.cargo/chump-shared-target/debug/chump" ]]; then
        CHUMP_BIN="$HOME/.cargo/chump-shared-target/debug/chump"
    elif command -v chump &>/dev/null; then
        CHUMP_BIN="$(command -v chump)"
    else
        echo "SKIP: chump binary not found (set CHUMP_BIN or run cargo build first)" >&2
        exit 0
    fi
fi

# ── Phase 0: binary present + --help ─────────────────────────────────────────
echo "── Phase 0: binary present ──"
[[ -x "$CHUMP_BIN" ]] && ok "chump binary executable at $CHUMP_BIN" || { fail "chump binary not executable"; exit 1; }

if "$CHUMP_BIN" gonogo --help &>/dev/null; then
    ok "chump gonogo --help exits 0"
else
    fail "chump gonogo --help failed"
fi

# ── Phase 1: --json exit codes per forced verdict ────────────────────────────
echo "── Phase 1: gonogo --json exit codes ──"

assert_gonogo_exit() {
    local forced="$1" expect_exit="$2"
    local out exit_code
    out=$(CHUMP_GONOGO_FORCE_VERDICT="$forced" "$CHUMP_BIN" gonogo "a vision" --json 2>&1) && exit_code=0 || exit_code=$?
    if [[ "$exit_code" -eq "$expect_exit" ]]; then
        ok "CHUMP_GONOGO_FORCE_VERDICT=$forced -> exit $expect_exit"
    else
        fail "CHUMP_GONOGO_FORCE_VERDICT=$forced -> expected exit $expect_exit, got $exit_code (output: $out)"
    fi
    for key in verdict reason cost_estimate_usd tier_ceiling_usd; do
        if echo "$out" | grep -q "\"$key\""; then
            ok "  json has key '$key'"
        else
            fail "  json missing key '$key' (output: $out)"
        fi
    done
}

assert_gonogo_exit "GO" 0
assert_gonogo_exit "NEEDS-NARROWING" 0
assert_gonogo_exit "NO-GO" 1
assert_gonogo_exit "NO-GO-ON-COST" 1

# ── Phase 2: bootstrap gate blocks on forced NO-GO ───────────────────────────
echo "── Phase 2: bootstrap gate blocks build ──"
BLOCK_DIR=$(mktemp -d)
rm -rf "$BLOCK_DIR"
if output=$(CHUMP_GONOGO_FORCE_VERDICT="NO-GO" "$CHUMP_BIN" bootstrap "a vision nobody asked for" \
    --dir "$BLOCK_DIR" --skip-arch-decision --no-umbrella-gap 2>&1); then
    fail "bootstrap should have exited non-zero when gate forced NO-GO"
else
    ok "bootstrap exits non-zero when gate forced NO-GO"
fi
if [[ -d "$BLOCK_DIR/.git" ]]; then
    fail "bootstrap created .git/ despite NO-GO gate"
else
    ok "no .git/ created when gate blocked the build"
fi
if [[ -f "$BLOCK_DIR/Cargo.toml" ]]; then
    fail "bootstrap created Cargo.toml despite NO-GO gate"
else
    ok "no Cargo.toml created when gate blocked the build"
fi
if echo "$output" | grep -qi "NO-GO"; then
    ok "bootstrap prints the plain-language NO-GO reason"
else
    fail "bootstrap did not print a NO-GO reason (output: $output)"
fi
rm -rf "$BLOCK_DIR"

# ── Phase 3: CHUMP_GONOGO_SKIP=1 bypasses the gate entirely ──────────────────
echo "── Phase 3: CHUMP_GONOGO_SKIP bypass ──"
SKIP_DIR=$(mktemp -d)
rm -rf "$SKIP_DIR"
if CHUMP_GONOGO_FORCE_VERDICT="NO-GO" CHUMP_GONOGO_SKIP=1 "$CHUMP_BIN" bootstrap "another vision" \
    --dir "$SKIP_DIR" --skip-arch-decision --no-umbrella-gap &>/dev/null; then
    ok "bootstrap exits 0 with CHUMP_GONOGO_SKIP=1 even though force-verdict is NO-GO"
else
    fail "bootstrap should exit 0 with CHUMP_GONOGO_SKIP=1"
fi
if [[ -d "$SKIP_DIR/.git" ]]; then
    ok ".git/ created — gate was bypassed as today"
else
    fail ".git/ missing — CHUMP_GONOGO_SKIP=1 should scaffold exactly as today"
fi
rm -rf "$SKIP_DIR"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "── Results: $PASS passed, $FAIL failed ──"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
