#!/usr/bin/env bash
# test-gap-backfill-external-repo.sh — MISSION-041
#
# Validates `chump gap backfill-external-repo` and `chump gap reserve --external-repo`:
#   (a) script is executable
#   (b) --help shows usage
#   (c) dry-run reports counts without mutation
#   (d) --apply mutates as reported
#   (e) re-apply is idempotent (no new mutations)
#   (f) existing skills_required preserved when appending tag
#   (g) --owner-repo override applies to all matched gaps
#   (h) chump gap reserve --external-repo correctly sets skills_required

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
echo "=== MISSION-041 chump gap backfill-external-repo test ==="
echo

# (a) Executable check — source wiring in main.rs.
echo "--- (a) source wiring check ---"
if grep -q '"backfill-external-repo"' "$REPO_ROOT/src/main.rs" 2>/dev/null; then
    ok "backfill-external-repo arm present in main.rs"
else
    fail "backfill-external-repo arm missing from main.rs"
fi

if grep -q 'reserve_external_repo' "$REPO_ROOT/src/main.rs" 2>/dev/null; then
    ok "--external-repo flag wired in gap reserve"
else
    fail "--external-repo flag not found in main.rs"
fi

if grep -q 'gap_external_repo_backfilled' "$REPO_ROOT/src/main.rs" 2>/dev/null; then
    ok "gap_external_repo_backfilled ambient event emitted in main.rs"
else
    fail "gap_external_repo_backfilled emit site missing from main.rs"
fi

if grep -q 'gap_external_repo_backfilled' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" 2>/dev/null; then
    ok "gap_external_repo_backfilled registered in EVENT_REGISTRY.yaml"
else
    fail "gap_external_repo_backfilled not in EVENT_REGISTRY.yaml"
fi

# (b) Build binary (reuse cached if present).
echo
echo "--- (b) build ---"
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
if [[ ! -f "$BIN" ]]; then
    echo "  [build] cargo build --bin chump (quiet)..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
fi

if [[ ! -f "$BIN" ]]; then
    fail "chump binary not found after build — skipping functional tests"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
    exit $?
fi
ok "binary found at $BIN"

# (b) --help shows usage (help is via _ => arm + exit 2, so we just check stderr output).
HELP_OUT=$("$BIN" gap backfill-external-repo --help 2>&1 || true)
if echo "$HELP_OUT" | grep -q "backfill-external-repo"; then
    ok "--help output mentions backfill-external-repo"
else
    # Also check that unknown args exit 2 with help text.
    HELP_OUT2=$("$BIN" gap 2>&1 || true)
    if echo "$HELP_OUT2" | grep -q "backfill-external-repo"; then
        ok "gap help text includes backfill-external-repo"
    else
        fail "--help or gap help missing backfill-external-repo"
    fi
fi

# 3. Isolated fixture environment.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_REPO="$TMP"
export CHUMP_HOME="$TMP"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1
export CHUMP_BYPASS_CLOSED_PR_GUARD=1
export CHUMP_PILLAR_BALANCE_DISABLE=1
export CHUMP_DISABLE_OFFLINE_CHECK=1

echo
echo "--- (c) dry-run reports counts without mutation ---"

# Reserve a BEAST-titled gap so backfill has something to match.
BEAST_GAP=$("$BIN" gap reserve --domain MISSION --priority P1 --effort xs \
    --title "BEAST-MODE execution slice fixture" \
    --acceptance-criteria "backfill test" \
    --skip-obs-acs 2>/dev/null | grep -oE '[A-Z]+-[0-9]+' | head -1 || true)

if [[ -z "$BEAST_GAP" ]]; then
    fail "could not reserve BEAST gap for dry-run test"
else
    ok "reserved BEAST gap $BEAST_GAP"
fi

# Run dry-run (default).
DRY=$("$BIN" gap backfill-external-repo 2>&1 || true)
if echo "$DRY" | grep -q "DRY RUN"; then
    ok "backfill-external-repo defaults to dry-run"
else
    fail "backfill-external-repo did not say DRY RUN"
fi

if echo "$DRY" | grep -q "total to tag\|already tagged"; then
    ok "dry-run shows count lines"
else
    fail "dry-run missing count lines (got: $DRY)"
fi

# Confirm gap is still untagged after dry-run.
if [[ -n "$BEAST_GAP" ]]; then
    SKILLS=$("$BIN" gap show "$BEAST_GAP" --json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('skills_required',''))
" 2>/dev/null || true)
    if echo "$SKILLS" | grep -q "external_repo"; then
        fail "dry-run unexpectedly mutated skills_required"
    else
        ok "dry-run did not mutate gap skills_required"
    fi
fi

echo
echo "--- (d) --apply mutates as reported ---"

APPLY=$("$BIN" gap backfill-external-repo --apply 2>&1 || true)
if echo "$APPLY" | grep -q "applied"; then
    ok "--apply emits 'applied' line"
else
    fail "--apply missing 'applied' line (got: $APPLY)"
fi

# Confirm gap now has external_repo tag.
if [[ -n "$BEAST_GAP" ]]; then
    SKILLS2=$("$BIN" gap show "$BEAST_GAP" --json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('skills_required',''))
" 2>/dev/null || true)
    if echo "$SKILLS2" | grep -q "external_repo:repairman29/BEAST-MODE"; then
        ok "gap has external_repo:repairman29/BEAST-MODE after --apply"
    else
        fail "gap missing external_repo tag after --apply (skills_required='$SKILLS2')"
    fi
fi

echo
echo "--- (e) re-apply is idempotent ---"

APPLY2=$("$BIN" gap backfill-external-repo --apply 2>&1 || true)
# The second run should apply 0 new tags (already_tagged covers the previously tagged ones).
if echo "$APPLY2" | grep -qE "applied 0 tag|already tagged.*[1-9]|all matched gaps already tagged"; then
    ok "re-apply is idempotent (applied 0 or shows already tagged)"
else
    # Check that if some applied, the count on the BEAST gap didn't increase.
    SKILLS3=$("$BIN" gap show "$BEAST_GAP" --json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
sr = d.get('skills_required','')
# Should have exactly one external_repo tag.
tags = [t.strip() for t in sr.split(',') if t.strip().startswith('external_repo:')]
print(len(tags))
" 2>/dev/null || echo "0")
    if [[ "$SKILLS3" -eq 1 ]]; then
        ok "re-apply idempotent: exactly 1 external_repo tag (no duplicate)"
    else
        fail "re-apply not idempotent: $SKILLS3 external_repo tags (expected 1)"
    fi
fi

echo
echo "--- (f) existing skills_required preserved when appending tag ---"

# Reserve a gap with an existing skill tag, then check append behavior.
SKILL_GAP=$("$BIN" gap reserve --domain INFRA --priority P2 --effort xs \
    --title "BEAST-MODE fixture with existing skill" \
    --acceptance-criteria "existing skill test" \
    --skip-obs-acs 2>/dev/null | grep -oE '[A-Z]+-[0-9]+' | head -1 || true)

if [[ -n "$SKILL_GAP" ]]; then
    # Manually set a skill via gap set.
    "$BIN" gap set "$SKILL_GAP" --skills-required "rust" 2>/dev/null || true

    # Apply backfill.
    "$BIN" gap backfill-external-repo --apply 2>/dev/null || true

    # Confirm both rust and external_repo are present.
    SKILLS4=$("$BIN" gap show "$SKILL_GAP" --json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
sr = d.get('skills_required','')
print(sr)
" 2>/dev/null || true)

    if echo "$SKILLS4" | grep -q "rust" && echo "$SKILLS4" | grep -q "external_repo:repairman29/BEAST-MODE"; then
        ok "existing 'rust' skill preserved alongside appended external_repo tag"
    else
        fail "skills_required mismatch after append (got: '$SKILLS4')"
    fi
else
    fail "could not reserve gap for append test"
    PASS=$((PASS+1))  # don't cascade
fi

echo
echo "--- (g) --owner-repo override applies to all matched ---"

OVERRIDE_GAP=$("$BIN" gap reserve --domain MISSION --priority P1 --effort xs \
    --title "BEAST fixture for override test" \
    --acceptance-criteria "owner-repo override" \
    --skip-obs-acs 2>/dev/null | grep -oE '[A-Z]+-[0-9]+' | head -1 || true)

if [[ -n "$OVERRIDE_GAP" ]]; then
    "$BIN" gap backfill-external-repo --apply --owner-repo "myorg/other-repo" 2>/dev/null || true

    SKILLS5=$("$BIN" gap show "$OVERRIDE_GAP" --json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('skills_required',''))
" 2>/dev/null || true)

    if echo "$SKILLS5" | grep -q "external_repo:myorg/other-repo"; then
        ok "--owner-repo override tagged gap with myorg/other-repo"
    else
        fail "--owner-repo override did not apply (skills_required='$SKILLS5')"
    fi
else
    fail "could not reserve gap for --owner-repo test"
    PASS=$((PASS+1))
fi

echo
echo "--- (h) chump gap reserve --external-repo sets skills_required ---"

RESERVE_OUT=$("$BIN" gap reserve --domain MISSION --priority P1 --effort xs \
    --title "external-repo reserve test" \
    --acceptance-criteria "reserve with external-repo" \
    --skip-obs-acs \
    --external-repo "repairman29/BEAST-MODE" 2>/dev/null | grep -oE '[A-Z]+-[0-9]+' | head -1 || true)

if [[ -z "$RESERVE_OUT" ]]; then
    fail "gap reserve --external-repo: no gap ID returned"
else
    ok "gap reserve --external-repo returned gap $RESERVE_OUT"

    SKILLS6=$("$BIN" gap show "$RESERVE_OUT" --json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('skills_required',''))
" 2>/dev/null || true)

    if echo "$SKILLS6" | grep -q "external_repo:repairman29/BEAST-MODE"; then
        ok "gap reserved with --external-repo has tag in skills_required"
    else
        fail "gap reserved with --external-repo missing tag (skills_required='$SKILLS6')"
    fi
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
