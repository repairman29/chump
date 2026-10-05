#!/usr/bin/env bash
# test-shared-service-gate.sh — INFRA-3463
#
# Exercises the shared-service pre-commit gate against synthetic diffs. Verifies:
#   - new bespoke LLM call (x-api-key / api.anthropic.com) in a normal file:
#       * default → WARN, exit 0 (nudge, never blocks)
#       * CHUMP_SHARED_SERVICE_BLOCK=1, no trailer → BLOCKED, exit 1
#       * CHUMP_SHARED_SERVICE_BLOCK=1, Shared-Service-Bypass trailer → allowed
#   - allowlisted file (src/provider_cascade.rs) with the pattern → silent
#   - .md file with the pattern → silent (docs describe, don't call)
#   - file with no LLM pattern → silent
#   - CHUMP_SHARED_SERVICE_CHECK=0 → silent

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok() {
    echo "  PASS: $1"
    PASS=$((PASS + 1))
}
fail() {
    echo "  FAIL: $1"
    FAIL=$((FAIL + 1))
    FAILS+=("$1")
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="$REPO_ROOT/scripts/git-hooks/pre-commit-shared-service.sh"

echo "=== INFRA-3463 shared-service gate tests ==="
[[ -x "$GATE" ]] || {
    fail "gate not executable at $GATE"
    echo "FAIL"
    exit 1
}
ok "gate present + executable"

mk_repo() {
    local d
    d="$(mktemp -d -t shared-svc-gate.XXXXXX)"
    (
        cd "$d"
        git init -q
        git config user.email test@test.local
        git config user.name test
        git commit --allow-empty -q -m "init"
    )
    printf '%s\n' "$d"
}

# stage_file <repo> <relpath> <content>
stage_file() {
    local repo="$1" rel="$2" content="$3"
    (
        cd "$repo"
        mkdir -p "$(dirname "$rel")"
        printf '%s\n' "$content" > "$rel"
        git add -A 2>/dev/null
    )
}

# run_gate <repo> <commit-msg> [ENV=val ...] → prints combined output; sets rc via return
run_gate() {
    local repo="$1" msg="$2"
    shift 2
    (
        cd "$repo"
        printf '%s\n' "$msg" > "$(git rev-parse --git-common-dir)/COMMIT_EDITMSG"
        env "$@" bash "$GATE" 2>&1
    )
}

BESPOKE='  let r = curl_post("https://api.anthropic.com/v1/messages", "x-api-key: $KEY");'

# 1. Default: bespoke call → WARN + exit 0.
R="$(mk_repo)"; stage_file "$R" "src/foo.rs" "$BESPOKE"
out="$(run_gate "$R" "add foo")"; rc=$?
if [[ $rc -eq 0 ]] && echo "$out" | grep -q 'WARN'; then ok "default: bespoke call warns, does not block"; else fail "default warn (rc=$rc): $out"; fi
rm -rf "$R"

# 2. Block mode, no trailer → exit 1.
R="$(mk_repo)"; stage_file "$R" "src/foo.rs" "$BESPOKE"
out="$(run_gate "$R" "add foo" CHUMP_SHARED_SERVICE_BLOCK=1)"; rc=$?
if [[ $rc -eq 1 ]] && echo "$out" | grep -q 'BLOCKED'; then ok "block mode w/o trailer: blocked"; else fail "block-no-trailer (rc=$rc): $out"; fi
rm -rf "$R"

# 3. Block mode WITH bypass trailer → allowed (exit 0).
R="$(mk_repo)"; stage_file "$R" "src/foo.rs" "$BESPOKE"
out="$(run_gate "$R" "add foo

Shared-Service-Bypass: legacy probe, migrating next sprint" CHUMP_SHARED_SERVICE_BLOCK=1)"; rc=$?
if [[ $rc -eq 0 ]]; then ok "block mode w/ Shared-Service-Bypass trailer: allowed"; else fail "block-with-trailer (rc=$rc): $out"; fi
rm -rf "$R"

# 4. Allowlisted file (provider_cascade.rs) with the pattern → silent.
R="$(mk_repo)"; stage_file "$R" "src/provider_cascade.rs" "$BESPOKE"
out="$(run_gate "$R" "cascade" CHUMP_SHARED_SERVICE_BLOCK=1)"; rc=$?
if [[ $rc -eq 0 ]] && ! echo "$out" | grep -q 'BLOCKED\|WARN'; then ok "allowlisted (provider_cascade.rs): silent even in block mode"; else fail "allowlist (rc=$rc): $out"; fi
rm -rf "$R"

# 5. .md file with the pattern → silent (docs describe, don't call).
R="$(mk_repo)"; stage_file "$R" "docs/notes.md" "$BESPOKE"
out="$(run_gate "$R" "docs" CHUMP_SHARED_SERVICE_BLOCK=1)"; rc=$?
if [[ $rc -eq 0 ]] && ! echo "$out" | grep -q 'BLOCKED\|WARN'; then ok ".md allowlisted: silent"; else fail ".md (rc=$rc): $out"; fi
rm -rf "$R"

# 6. File with no LLM pattern → silent.
R="$(mk_repo)"; stage_file "$R" "src/bar.rs" "fn main() { println!(\"hi\"); }"
out="$(run_gate "$R" "bar" CHUMP_SHARED_SERVICE_BLOCK=1)"; rc=$?
if [[ $rc -eq 0 ]] && ! echo "$out" | grep -q 'BLOCKED\|WARN'; then ok "no-pattern file: silent"; else fail "no-pattern (rc=$rc): $out"; fi
rm -rf "$R"

# 7b. Audited intentional-direct sites (INFRA-3465): adversary_llm.rs +
# screen_vision_tool.rs must be silent even in block mode.
R="$(mk_repo)"; stage_file "$R" "src/adversary_llm.rs" "$BESPOKE"
out="$(run_gate "$R" "adversary" CHUMP_SHARED_SERVICE_BLOCK=1)"; rc=$?
if [[ $rc -eq 0 ]] && ! echo "$out" | grep -q 'BLOCKED\|WARN'; then ok "allowlisted (adversary_llm.rs): silent even in block mode"; else fail "adversary_llm allowlist (rc=$rc): $out"; fi
rm -rf "$R"

R="$(mk_repo)"; stage_file "$R" "src/screen_vision_tool.rs" "$BESPOKE"
out="$(run_gate "$R" "screen vision" CHUMP_SHARED_SERVICE_BLOCK=1)"; rc=$?
if [[ $rc -eq 0 ]] && ! echo "$out" | grep -q 'BLOCKED\|WARN'; then ok "allowlisted (screen_vision_tool.rs): silent even in block mode"; else fail "screen_vision_tool allowlist (rc=$rc): $out"; fi
rm -rf "$R"

# 7. CHUMP_SHARED_SERVICE_CHECK=0 → silent even with a bespoke call in block mode.
R="$(mk_repo)"; stage_file "$R" "src/foo.rs" "$BESPOKE"
out="$(run_gate "$R" "add foo" CHUMP_SHARED_SERVICE_CHECK=0 CHUMP_SHARED_SERVICE_BLOCK=1)"; rc=$?
if [[ $rc -eq 0 ]] && ! echo "$out" | grep -q 'BLOCKED\|WARN'; then ok "CHUMP_SHARED_SERVICE_CHECK=0: fully disabled"; else fail "disabled (rc=$rc): $out"; fi
rm -rf "$R"

echo ""
if [[ $FAIL -eq 0 ]]; then
    echo "PASS ($PASS assertions)"
    exit 0
else
    echo "FAIL ($FAIL of $((PASS + FAIL)))"
    printf '  - %s\n' "${FAILS[@]}"
    exit 1
fi
