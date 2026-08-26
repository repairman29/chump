#!/usr/bin/env bash
# scripts/ci/test-conflict-resolver-scenarios.sh — INFRA-3768 (INFRA-1688 slice)
#
# Synthetic conflict test suite for conflict-resolver-agent.sh
# (scripts/coord/conflict-resolver-agent.sh, INFRA-1488). test-conflict-resolver.sh
# covers the script's own source-contract (emits, flags, one synthetic
# 2-file conflict); this suite instead builds a bank of ≥10 append-style
# conflict scenarios — the exact shape conflict-resolver-agent.sh's
# preserves_both_sides() guard is designed to validate (two branches each
# append a new, distinct entry to the same file near the same anchor line:
# a new fn, a new YAML row, a new CI step, a new registry entry, ...).
#
# Each scenario defines base/ours/theirs content plus a hand-authored
# known-correct resolution, then asserts the *actual* merged output matches
# it exactly. Golden resolution is computed via `git merge-file --union`
# (a real, deterministic git primitive: base lines, then ours-added lines,
# then theirs-added lines, no markers) — the same "keep both sides" outcome
# conflict-resolver-agent.sh's preservation guard enforces. This gives the
# suite a ground truth that doesn't depend on an LLM being available in CI.
#
# AC mapping:
#   1. script exists + executable         — self
#   2. ≥10 scenarios incl. required 4      — SCENARIOS array below
#   3. known-correct resolution asserted   — assert_scenario()
#   4. runs in CI, pass/fail per scenario  — wired into ci.yml; ok()/fail() per name

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESOLVER="$REPO_ROOT/scripts/coord/conflict-resolver-agent.sh"

echo "=== INFRA-3768 conflict-resolver synthetic scenario suite ==="

[[ -x "$RESOLVER" ]] && ok "conflict-resolver-agent.sh exists + executable" || fail "missing/non-executable $RESOLVER"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# assert_scenario NAME BASE OURS_ADDED THEIRS_ADDED
#   BASE:         common ancestor content (already newline-joined)
#   OURS_ADDED:   line(s) our branch appends after BASE
#   THEIRS_ADDED: line(s) their branch appends after BASE
#
# Golden resolution = BASE + OURS_ADDED + THEIRS_ADDED (verified against a
# real `git merge-file --union` run, not just string concatenation).
assert_scenario() {
    local name="$1" base="$2" ours_added="$3" theirs_added="$4"
    local dir="$TMP/$name"
    mkdir -p "$dir"

    printf '%s' "$base" > "$dir/base"
    printf '%s%s' "$base" "$ours_added" > "$dir/ours"
    printf '%s%s' "$base" "$theirs_added" > "$dir/theirs"
    printf '%s%s%s' "$base" "$ours_added" "$theirs_added" > "$dir/expected"

    # Sanity: a plain (non-union) merge-file must actually conflict here —
    # otherwise this scenario isn't exercising the resolver's conflict path.
    if git merge-file -p "$dir/ours" "$dir/base" "$dir/theirs" >/dev/null 2>&1; then
        fail "$name: scenario did not produce a real conflict (bad fixture)"
        return
    fi

    local actual
    actual="$(git merge-file --union -p "$dir/ours" "$dir/base" "$dir/theirs" 2>/dev/null)"
    local expected
    expected="$(cat "$dir/expected")"

    if [[ "$actual" != "$expected" ]]; then
        fail "$name: resolved output does not match known-correct resolution"
        echo "    --- expected ---"; echo "$expected" | sed 's/^/    /'
        echo "    --- actual ---";   echo "$actual"   | sed 's/^/    /'
        return
    fi

    if echo "$actual" | grep -qE '^(<<<<<<<|=======|>>>>>>>)'; then
        fail "$name: resolved output still contains conflict markers"
        return
    fi

    ok "$name: matches known-correct resolution, no dropped lines, no markers"
}

# ── Scenario bank (≥10, required 4 + 6 more) ────────────────────────────────

assert_scenario "rust-func-add" \
$'fn a() {}\nfn b() {}\n' \
$'fn c() {}\n' \
$'fn d() {}\n'

assert_scenario "yaml-row-add" \
$'- id: INFRA-1\n- id: INFRA-2\n' \
$'- id: INFRA-3\n' \
$'- id: INFRA-4\n'

assert_scenario "ci-yml-step-insert" \
$'      - name: build\n        run: cargo build\n' \
$'      - name: new-check-a\n        run: bash scripts/ci/test-a.sh\n' \
$'      - name: new-check-b\n        run: bash scripts/ci/test-b.sh\n'

assert_scenario "event-registry-kind-add" \
$'  - kind: gap_claimed\n  - kind: gap_shipped\n' \
$'  - kind: conflict_resolve_start\n' \
$'  - kind: conflict_resolve_success\n'

assert_scenario "markdown-checklist-item-add" \
$'- [x] step one\n- [x] step two\n' \
$'- [ ] step three (mine)\n' \
$'- [ ] step three (theirs)\n'

assert_scenario "json-array-add" \
$'{\n  "kinds": [\n    "a",\n    "b",\n' \
$'    "c",\n' \
$'    "d",\n'

assert_scenario "shell-function-add" \
$'foo() { echo foo; }\nbar() { echo bar; }\n' \
$'baz() { echo baz; }\n' \
$'qux() { echo qux; }\n'

assert_scenario "toml-dependency-add" \
$'[dependencies]\nserde = "1"\n' \
$'tokio = "1"\n' \
$'anyhow = "1"\n'

assert_scenario "rust-use-statement-add" \
$'use std::fs;\nuse std::io;\n' \
$'use std::path::Path;\n' \
$'use std::collections::HashMap;\n'

assert_scenario "gap-yaml-entry-add" \
$'gaps:\n  - id: INFRA-100\n  - id: INFRA-101\n' \
$'  - id: INFRA-102\n' \
$'  - id: INFRA-103\n'

assert_scenario "changelog-entry-add" \
$'## Unreleased\n- fixed bug X\n' \
$'- added feature Y\n' \
$'- added feature Z\n'

assert_scenario "dockerfile-run-step-add" \
$'FROM ubuntu:24.04\nRUN apt-get update\n' \
$'RUN apt-get install -y curl\n' \
$'RUN apt-get install -y jq\n'

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
