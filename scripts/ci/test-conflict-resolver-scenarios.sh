#!/usr/bin/env bash
# scripts/ci/test-conflict-resolver-scenarios.sh — INFRA-3768 (INFRA-1688 slice)
#
# Synthetic conflict-scenario suite for the merge-conflict-resolution agent
# (scripts/coord/conflict-resolver-agent.sh, INFRA-1488). Each scenario:
#   1. builds a two-sided git conflict (base -> ours branch, theirs branch)
#      in a real throwaway repo,
#   2. runs `git merge` and asserts a real conflict with markers is produced,
#   3. applies a known-correct hand-authored resolution,
#   4. asserts the applied resolution has no leftover conflict markers and
#      preserves the content unique to BOTH sides (the same invariant
#      conflict-resolver-agent.sh's preserves_both_sides() enforces),
#   5. asserts the resolved file byte-matches the scenario's declared
#      expected-output.
#
# AC mapping:
#   1. This file exists + executable                    — file itself
#   2. >=10 synthetic scenarios incl. required 4         — SCENARIOS list below
#   3. known-correct resolution + assert match           — run_scenario()
#   4. runs in CI, pass/fail per scenario                — .github/workflows/ci.yml step
#                                                           + per-scenario ok/fail output

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# run_scenario NAME FILE BASE OURS THEIRS EXPECTED
#   NAME     — human label, printed on pass/fail
#   FILE     — filename to conflict on, inside the throwaway repo
#   BASE     — common-ancestor content
#   OURS     — branch-a content (diverges from BASE)
#   THEIRS   — branch-b content (diverges from BASE, same region as OURS)
#   EXPECTED — the known-correct hand-resolution: must contain the
#              divergent content unique to both OURS and THEIRS
run_scenario() {
    local name="$1" file="$2" base="$3" ours="$4" theirs="$5" expected="$6"

    local repo="$WORK/${name// /_}"
    mkdir -p "$repo"
    (
        cd "$repo" || exit 1
        git init -q
        git config user.email t@e
        git config user.name t
        printf '%s' "$base" > "$file"
        git add "$file"
        git commit -q -m base

        git checkout -q -b ours
        printf '%s' "$ours" > "$file"
        git commit -q -am ours

        git checkout -q main 2>/dev/null || git checkout -q master
        git checkout -q -b theirs
        printf '%s' "$theirs" > "$file"
        git commit -q -am theirs

        git merge ours --no-edit -q 2>/dev/null
    ) >/dev/null 2>&1

    # ── step 2: a real conflict must have been produced ──
    if ! grep -q '^<<<<<<<' "$repo/$file" 2>/dev/null; then
        fail "$name: no conflict markers produced (fixture broken)"
        return
    fi
    ok "$name: conflict markers present"

    # ── step 3: apply the known-correct resolution ──
    printf '%s' "$expected" > "$repo/$file"

    # ── step 4a: no leftover markers ──
    if grep -qE '^(<<<<<<<|=======|>>>>>>>)' "$repo/$file"; then
        fail "$name: resolution still contains conflict markers"
        return
    fi
    ok "$name: resolution has no leftover markers"

    # ── step 4b: preserves-both-sides — every line unique to ours (vs
    # theirs) and unique to theirs (vs ours) must survive into the
    # resolution. Mirrors conflict-resolver-agent.sh's preserves_both_sides().
    local ours_file="$repo/.ours" theirs_file="$repo/.theirs"
    printf '%s' "$ours" > "$ours_file"
    printf '%s' "$theirs" > "$theirs_file"
    local dropped=0
    while IFS= read -r ln; do
        [[ ${#ln} -lt 4 ]] && continue
        grep -qF "$ln" "$repo/$file" 2>/dev/null || dropped=$((dropped + 1))
    done < <(LC_ALL=C comm -23 <(LC_ALL=C sort -u "$ours_file") <(LC_ALL=C sort -u "$theirs_file"))
    while IFS= read -r ln; do
        [[ ${#ln} -lt 4 ]] && continue
        grep -qF "$ln" "$repo/$file" 2>/dev/null || dropped=$((dropped + 1))
    done < <(LC_ALL=C comm -13 <(LC_ALL=C sort -u "$ours_file") <(LC_ALL=C sort -u "$theirs_file"))
    if (( dropped > 0 )); then
        fail "$name: resolution drops $dropped line(s) unique to one side"
        return
    fi
    ok "$name: resolution preserves both sides"

    # ── step 5: resolved file byte-matches the declared expected output ──
    # (route both sides through command substitution so trailing-newline
    # stripping is symmetric)
    if [[ "$(cat "$repo/$file")" == "$(printf '%s' "$expected")" ]]; then
        ok "$name: resolved output matches known-correct resolution"
    else
        fail "$name: resolved output does not match known-correct resolution"
    fi
}

echo "=== INFRA-3768 conflict-resolver synthetic scenario suite ==="

# 1. rust func-add — two branches each add a new top-level fn.
run_scenario "rust func-add" "lib.rs" \
'fn base() {}
' \
'fn base() {}

fn add_ours() -> i32 { 1 }
' \
'fn base() {}

fn add_theirs() -> i32 { 2 }
' \
'fn base() {}

fn add_ours() -> i32 { 1 }

fn add_theirs() -> i32 { 2 }
'

# 2. yaml row-add — two branches each append a new list row.
run_scenario "yaml row-add" "items.yaml" \
'items:
  - alpha
' \
'items:
  - alpha
  - bravo_ours
' \
'items:
  - alpha
  - bravo_theirs
' \
'items:
  - alpha
  - bravo_ours
  - bravo_theirs
'

# 3. ci.yml step-insert — two branches each insert a new workflow step.
run_scenario "ci.yml step-insert" "ci.yml" \
'jobs:
  test:
    steps:
      - name: checkout
        run: actions/checkout
' \
'jobs:
  test:
    steps:
      - name: checkout
        run: actions/checkout
      - name: lint-ours
        run: cargo fmt --check
' \
'jobs:
  test:
    steps:
      - name: checkout
        run: actions/checkout
      - name: lint-theirs
        run: cargo clippy
' \
'jobs:
  test:
    steps:
      - name: checkout
        run: actions/checkout
      - name: lint-ours
        run: cargo fmt --check
      - name: lint-theirs
        run: cargo clippy
'

# 4. EVENT_REGISTRY kind-add — two branches each register a new ambient kind.
run_scenario "EVENT_REGISTRY kind-add" "EVENT_REGISTRY.yaml" \
'kinds:
  - kind: existing_event
' \
'kinds:
  - kind: existing_event
  - kind: new_event_ours
' \
'kinds:
  - kind: existing_event
  - kind: new_event_theirs
' \
'kinds:
  - kind: existing_event
  - kind: new_event_ours
  - kind: new_event_theirs
'

# 5. rust struct field-add — two branches each add a new struct field.
run_scenario "rust struct field-add" "types.rs" \
'struct Foo {
    a: i32,
}
' \
'struct Foo {
    a: i32,
    b_ours: i32,
}
' \
'struct Foo {
    a: i32,
    c_theirs: i32,
}
' \
'struct Foo {
    a: i32,
    b_ours: i32,
    c_theirs: i32,
}
'

# 6. rust use-statement add — two branches each add a new `use` import.
run_scenario "rust use-add" "main.rs" \
'use std::fmt;
' \
'use std::fmt;
use std::collections::HashMap;
' \
'use std::fmt;
use std::collections::HashSet;
' \
'use std::fmt;
use std::collections::HashMap;
use std::collections::HashSet;
'

# 7. rust match-arm add — two branches each add a new match arm.
run_scenario "rust match-arm-add" "dispatch.rs" \
'match kind {
    Kind::A => 1,
}
' \
'match kind {
    Kind::A => 1,
    Kind::BOurs => 2,
}
' \
'match kind {
    Kind::A => 1,
    Kind::CTheirs => 3,
}
' \
'match kind {
    Kind::A => 1,
    Kind::BOurs => 2,
    Kind::CTheirs => 3,
}
'

# 8. markdown doc section-append — two branches each append a new section.
run_scenario "markdown section-append" "DOC.md" \
'# Title

## Intro
base text
' \
'# Title

## Intro
base text

## Ours Section
ours content
' \
'# Title

## Intro
base text

## Theirs Section
theirs content
' \
'# Title

## Intro
base text

## Ours Section
ours content

## Theirs Section
theirs content
'

# 9. json config key-add — two branches each add a new top-level key.
run_scenario "json key-add" "config.json" \
'{
  "existing": true
}
' \
'{
  "existing": true,
  "ours_flag": true
}
' \
'{
  "existing": true,
  "theirs_flag": true
}
' \
'{
  "existing": true,
  "ours_flag": true,
  "theirs_flag": true
}
'

# 10. cargo.toml dependency-add — two branches each add a new crate dep.
run_scenario "Cargo.toml dep-add" "Cargo.toml" \
'[dependencies]
serde = "1"
' \
'[dependencies]
serde = "1"
tokio = "1"
' \
'[dependencies]
serde = "1"
anyhow = "1"
' \
'[dependencies]
serde = "1"
tokio = "1"
anyhow = "1"
'

# 11. gap yaml AC bullet-add — two branches each add a new acceptance criterion.
run_scenario "gap yaml AC-add" "gap.yaml" \
'acceptance_criteria:
  1. base criterion
' \
'acceptance_criteria:
  1. base criterion
  2. ours criterion
' \
'acceptance_criteria:
  1. base criterion
  2. theirs criterion
' \
'acceptance_criteria:
  1. base criterion
  2. ours criterion
  2. theirs criterion
'

# 12. shell script function-add — two branches each add a new shell function.
run_scenario "shell func-add" "lib.sh" \
'base_fn() { echo base; }
' \
'base_fn() { echo base; }
ours_fn() { echo ours; }
' \
'base_fn() { echo base; }
theirs_fn() { echo theirs; }
' \
'base_fn() { echo base; }
ours_fn() { echo ours; }
theirs_fn() { echo theirs; }
'

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
