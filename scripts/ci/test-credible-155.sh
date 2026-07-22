#!/usr/bin/env bash
# scripts/ci/test-credible-155.sh — CREDIBLE-155 `chump verify` end-to-end.
#
# Exercises the unified policy engine against throwaway fixture git repos:
#   1. docs-delta: net-new doc + no trailer -> commit-msg stage exits 1
#   2. docs-delta: adequate Net-new-docs trailer -> exits 0
#   3. Verify-Bypass trailer flips a failing rule to bypassed (exit 0) AND
#      appends one kind=verify_bypassed line to the ambient log
#   4. no-new-bypass-env-vars: staged bypass-class var -> exits 1;
#      comment-only mention -> exits 0
#   5. pre-commit stage is a preview (exit 0); --strict makes it exit 1
#   6. --json emits machine-readable verdicts
#   7. --stage ci reads trailers from the commit range
#   8. pipefail-race: printf|grep -q in a hot-path script -> blocked;
#      '# pipefail-sweep-allowed' marker -> passes (CREDIBLE-157 batch)
#   9. path-filter-allowlist: file under a top-level dir missing from the
#      ci.yml code: block -> blocked; after adding the pattern -> passes
#  10. install-manifest: unmapped scripts/setup/install-*.sh -> blocked;
#      after mapping in the optional allowlist -> passes
#  11. event-registry: unregistered kind literal in a prod path -> blocked;
#      registered -> passes; orphan registry entry (no emit) -> blocked
#
# Rule-level semantics are covered by Rust unit tests in src/verify/.
# Depth: happy-path + edge (bypass, comment-exemption, strict). Gap: no
# adversarial fuzzing of diff parsing.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ok()   { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; exit 1; }
skip() { printf 'SKIP %s\n' "$*"; exit 0; }

CHUMP="${CHUMP_BIN:-}"
if [[ -z "$CHUMP" ]]; then
    for cand in "$REPO_ROOT/target-local/debug/chump" "$REPO_ROOT/target/debug/chump" "$(command -v chump 2>/dev/null || true)"; do
        if [[ -n "$cand" && -x "$cand" ]]; then CHUMP="$cand"; break; fi
    done
fi
[[ -n "$CHUMP" && -x "$CHUMP" ]] || skip "chump binary not found (set CHUMP_BIN); skipping verify e2e"

# Old binaries lack the subcommand — probe help, never run blind (INFRA-1238).
_help="$(CHUMP_BINARY_STALENESS_CHECK=0 "$CHUMP" --help 2>/dev/null || true)"
case "$_help" in
    *"verify --stage"*) : ;;
    *) skip "installed chump predates 'verify' subcommand; skipping" ;;
esac

export CHUMP_BINARY_STALENESS_CHECK=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
AMBIENT="$TMP/ambient.jsonl"
export CHUMP_AMBIENT_LOG="$AMBIENT"

new_fixture_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "root"
}

run_verify() { # dir, then args...
    local dir="$1"; shift
    (cd "$dir" && CHUMP_BINARY_STALENESS_CHECK=0 "$CHUMP" verify "$@")
}

# ── Case 1+2: docs-delta at commit-msg stage ─────────────────────────────────
R1="$TMP/r1"
new_fixture_repo "$R1"
mkdir -p "$R1/docs"
echo "hello" > "$R1/docs/new-doc.md"
git -C "$R1" add docs/new-doc.md

printf 'feat: add doc\n' > "$R1/msg"
if run_verify "$R1" --stage commit-msg --msg-file "$R1/msg" >/dev/null 2>&1; then
    fail "case1: net-new doc without trailer should exit 1"
fi
ok "case1: docs-delta blocks missing trailer"

printf 'feat: add doc\n\nNet-new-docs: +1\n' > "$R1/msg"
run_verify "$R1" --stage commit-msg --msg-file "$R1/msg" >/dev/null 2>&1 \
    || fail "case2: adequate trailer should exit 0"
ok "case2: docs-delta passes with adequate trailer"

# ── Case 3: Verify-Bypass trailer -> bypassed + audited ambient line ─────────
printf 'feat: add doc\n\nVerify-Bypass: docs-delta: scratch fixture doc for e2e\n' > "$R1/msg"
out="$(run_verify "$R1" --stage commit-msg --msg-file "$R1/msg" 2>&1)" \
    || fail "case3: Verify-Bypass trailer should flip to exit 0. output: $out"
case "$out" in
    *BYPASSED*) : ;;
    *) fail "case3: expected BYPASSED verdict in output: $out" ;;
esac
grep -c '"kind":"verify_bypassed"' "$AMBIENT" >/dev/null 2>&1 \
    || fail "case3: no verify_bypassed line in ambient log"
_line="$(grep '"kind":"verify_bypassed"' "$AMBIENT" | head -1)"
case "$_line" in
    *'"rule":"docs-delta"'*'"stage":"commit-msg"'*) : ;;
    *) fail "case3: ambient line missing rule/stage fields: $_line" ;;
esac
ok "case3: bypass audited to ambient (rule + stage present)"

# ── Case 4: no-new-bypass-env-vars ───────────────────────────────────────────
R2="$TMP/r2"
new_fixture_repo "$R2"
mkdir -p "$R2/scripts"
# Split literal so THIS script never contains a contiguous bypass-class token
# (the INFRA-2429 diff lint + EFFECTIVE-094 ceiling both scan scripts/).
_suffix="BY""PASS"
_var="CHUMP_FIXTURE_${_suffix}"
printf 'export %s=1\n' "$_var" > "$R2/scripts/naughty.sh"
git -C "$R2" add scripts/naughty.sh
printf 'feat: naughty\n' > "$R2/msg"
if run_verify "$R2" --stage commit-msg --msg-file "$R2/msg" >/dev/null 2>&1; then
    fail "case4a: new bypass-class var should exit 1"
fi
ok "case4a: no-new-bypass-env-vars blocks new var"

printf '# %s is deleted, documenting only\n' "$_var" > "$R2/scripts/naughty.sh"
git -C "$R2" add scripts/naughty.sh
run_verify "$R2" --stage commit-msg --msg-file "$R2/msg" >/dev/null 2>&1 \
    || fail "case4b: comment-only mention should exit 0 (INFRA-2438)"
ok "case4b: comment-only mention exempt"

# ── Case 5: pre-commit preview vs --strict ───────────────────────────────────
git -C "$R1" add docs/new-doc.md
run_verify "$R1" --stage pre-commit >/dev/null 2>&1 \
    || fail "case5a: pre-commit stage is a preview and should exit 0"
ok "case5a: pre-commit preview exits 0"
if run_verify "$R1" --stage pre-commit --strict >/dev/null 2>&1; then
    fail "case5b: --strict preview with would-fail should exit 1"
fi
ok "case5b: --strict preview exits 1"

# ── Case 6: --json shape ─────────────────────────────────────────────────────
json="$(run_verify "$R1" --stage pre-commit --json 2>/dev/null)" \
    || fail "case6: --json preview should exit 0"
case "$json" in
    *'"rule_id":"docs-delta"'*'"verdict":"fail"'*) : ;;
    *) fail "case6: JSON missing expected verdict fields: $json" ;;
esac
ok "case6: --json emits rule_id/verdict/remediation"

# ── Case 7: --stage ci reads trailers from the commit range ──────────────────
R3="$TMP/r3"
new_fixture_repo "$R3"
git -C "$R3" checkout -q -b feature
mkdir -p "$R3/docs"
echo "ci doc" > "$R3/docs/ci-doc.md"
git -C "$R3" add docs/ci-doc.md
git -C "$R3" -c user.email=t@t -c user.name=t commit -q -m "feat: ci doc (no trailer)"
if run_verify "$R3" --stage ci --base main >/dev/null 2>&1; then
    fail "case7a: ci stage should exit 1 when range lacks the trailer"
fi
ok "case7a: ci stage blocks missing trailer"

git -C "$R3" -c user.email=t@t -c user.name=t commit -q --allow-empty \
    -m "chore: declare docs" -m "Net-new-docs: +1"
run_verify "$R3" --stage ci --base main >/dev/null 2>&1 \
    || fail "case7b: trailer in commit range should satisfy ci stage"
ok "case7b: ci stage reads trailers from merge-base..HEAD"

# ═══ CREDIBLE-157 batch: pipefail-race / path-filter-allowlist /
# ═══ install-manifest / event-registry ═══════════════════════════════════════

# ── Case 8: pipefail-race in a hot-path script ───────────────────────────────
R4="$TMP/r4"
new_fixture_repo "$R4"
mkdir -p "$R4/scripts/coord"
printf 'if printf %%s "$x" | grep -q y; then :; fi\n' > "$R4/scripts/coord/racy.sh"
git -C "$R4" add scripts/coord/racy.sh
printf 'fix: racy\n' > "$R4/msg"
if run_verify "$R4" --stage commit-msg --msg-file "$R4/msg" >/dev/null 2>&1; then
    fail "case8a: printf|grep -q in scripts/coord should exit 1"
fi
ok "case8a: pipefail-race blocks hot-path printf|grep -q"

printf 'if printf %%s "$x" | grep -q y; then :; fi  # pipefail-sweep-allowed\n' \
    > "$R4/scripts/coord/racy.sh"
git -C "$R4" add scripts/coord/racy.sh
run_verify "$R4" --stage commit-msg --msg-file "$R4/msg" >/dev/null 2>&1 \
    || fail "case8b: pipefail-sweep-allowed marker should exit 0"
ok "case8b: allowlist marker exempts the line"

# ── Case 9: path-filter-allowlist against a fixture ci.yml ───────────────────
R5="$TMP/r5"
new_fixture_repo "$R5"
mkdir -p "$R5/.github/workflows" "$R5/new-feature-dir"
cat > "$R5/.github/workflows/ci.yml" <<'YAML'
jobs:
  changes:
    steps:
      - uses: dorny/paths-filter@v4
        with:
          filters: |
            code:
              - 'src/**'
              - '.github/workflows/**'
YAML
echo "x" > "$R5/new-feature-dir/thing.rs"
git -C "$R5" add .github/workflows/ci.yml new-feature-dir/thing.rs
printf 'feat: new dir\n' > "$R5/msg"
out="$(run_verify "$R5" --stage commit-msg --msg-file "$R5/msg" 2>&1)" && \
    fail "case9a: uncovered new-feature-dir should exit 1"
case "$out" in
    *"- 'new-feature-dir/**'"*) : ;;
    *) fail "case9a: remediation must name the exact allowlist line. got: $out" ;;
esac
ok "case9a: path-filter blocks + names the exact - 'dir/**' line"

cat > "$R5/.github/workflows/ci.yml" <<'YAML'
jobs:
  changes:
    steps:
      - uses: dorny/paths-filter@v4
        with:
          filters: |
            code:
              - 'src/**'
              - '.github/workflows/**'
              - 'new-feature-dir/**'
YAML
git -C "$R5" add .github/workflows/ci.yml
run_verify "$R5" --stage commit-msg --msg-file "$R5/msg" >/dev/null 2>&1 \
    || fail "case9b: covered dir should exit 0"
ok "case9b: passes once the pattern is added"

# ── Case 10: install-manifest mapping ────────────────────────────────────────
R6="$TMP/r6"
new_fixture_repo "$R6"
mkdir -p "$R6/scripts/setup"
printf 'REQUIRED_DAEMONS=(\n)\n' > "$R6/scripts/setup/chump-fleet-bootstrap.sh"
printf '# optional\n' > "$R6/scripts/setup/optional-installers-allowlist.txt"
printf '# deprecated\n' > "$R6/scripts/setup/deprecated-installers-allowlist.txt"
printf '#!/bin/bash\n' > "$R6/scripts/setup/install-fixture-daemon.sh"
git -C "$R6" add scripts/setup
printf 'feat: installer\n' > "$R6/msg"
if run_verify "$R6" --stage commit-msg --msg-file "$R6/msg" >/dev/null 2>&1; then
    fail "case10a: unmapped installer should exit 1"
fi
ok "case10a: install-manifest blocks unmapped installer"

printf '# optional\ninstall-fixture-daemon.sh\n' \
    > "$R6/scripts/setup/optional-installers-allowlist.txt"
git -C "$R6" add scripts/setup/optional-installers-allowlist.txt
run_verify "$R6" --stage commit-msg --msg-file "$R6/msg" >/dev/null 2>&1 \
    || fail "case10b: optional-allowlist mapping should exit 0"
ok "case10b: passes once mapped in optional allowlist"

# ── Case 11: event-registry pairing ──────────────────────────────────────────
# Kind-literal fragments are split so THIS script never contains a contiguous
# "kind":"..." literal (the legacy staged-diff gate scans *.sh).
_KQ='"ki'
_KQ="${_KQ}nd\""
R7="$TMP/r7"
new_fixture_repo "$R7"
mkdir -p "$R7/docs/observability" "$R7/scripts/coord" "$R7/scripts/ci"
printf 'events:\n' > "$R7/docs/observability/EVENT_REGISTRY.yaml"
printf '# reserved\n' > "$R7/scripts/ci/event-registry-reserved.txt"
printf 'printf %%s '\''{%s:"fixture_rogue"}'\'' >> log\n' "$_KQ" \
    > "$R7/scripts/coord/emit.sh"
git -C "$R7" add .
printf 'feat: emit\n' > "$R7/msg"
if run_verify "$R7" --stage commit-msg --msg-file "$R7/msg" >/dev/null 2>&1; then
    fail "case11a: unregistered kind literal should exit 1"
fi
ok "case11a: event-registry blocks emit-without-register"

printf 'events:\n  - %s: fixture_rogue\n' 'ki''nd' \
    > "$R7/docs/observability/EVENT_REGISTRY.yaml"
git -C "$R7" add docs/observability/EVENT_REGISTRY.yaml
run_verify "$R7" --stage commit-msg --msg-file "$R7/msg" >/dev/null 2>&1 \
    || fail "case11b: registered kind should exit 0"
ok "case11b: passes once the kind is registered"

# Orphan direction: commit the emit first, then stage ONLY a registry entry
# for a kind with no emit anywhere.
git -C "$R7" -c user.email=t@t -c user.name=t commit -q -m "seed" >/dev/null 2>&1
printf 'events:\n  - %s: fixture_rogue\n  - %s: fixture_orphan\n' 'ki''nd' 'ki''nd' \
    > "$R7/docs/observability/EVENT_REGISTRY.yaml"
git -C "$R7" add docs/observability/EVENT_REGISTRY.yaml
printf 'docs: register orphan\n' > "$R7/msg"
out="$(run_verify "$R7" --stage commit-msg --msg-file "$R7/msg" 2>&1)" && \
    fail "case11c: orphan registry entry should exit 1"
case "$out" in
    *register-without-emit*fixture_orphan*) : ;;
    *) fail "case11c: expected register-without-emit diagnostic. got: $out" ;;
esac
ok "case11c: event-registry blocks register-without-emit"

echo
echo "All CREDIBLE-155 chump-verify e2e tests passed."
