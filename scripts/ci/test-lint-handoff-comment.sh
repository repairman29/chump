#!/usr/bin/env bash
# test-lint-handoff-comment.sh — INFRA-769: unit tests for lint-handoff-comment.sh

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LINTER="$REPO_ROOT/scripts/ci/lint-handoff-comment.sh"

if [[ ! -x "$LINTER" ]]; then
    echo "[FAIL] $LINTER not executable"
    exit 1
fi

PASS=0
FAIL=0

check() {
    local desc="$1" expected="$2"
    shift 2
    set +e
    actual_rc=$("$@" 2>/dev/null; echo $?)
    # capture exit code properly
    "$@" >/dev/null 2>&1
    actual_rc=$?
    set -e
    if [[ "$actual_rc" -eq "$expected" ]]; then
        echo "[PASS] $desc"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $desc — expected exit $expected, got $actual_rc"
        FAIL=$((FAIL + 1))
    fi
}

# Build canonical valid handoff comment
VALID_COMMENT='## Failure surface
CI fails on lint step; PR stuck DIRTY.

## Root cause
Missing trailing newline in src/main.rs caused rustfmt to reject the file.

## Apply this diff
```diff
-fn main() {
+fn main() {
+
```

## Verification
Run `cargo fmt --check` locally — exits 0.

[handoff:apply by=reviewer-42 verified=true]'

MISSING_SECTION='## Root cause
Missing trailing newline.

## Apply this diff
```diff
-fn main() {}
+fn main() { }
```

## Verification
Run cargo fmt.

[handoff:apply by=reviewer-1 verified=false]'

MISSING_ANNOTATION='## Failure surface
CI lint failure.

## Root cause
Missing newline.

## Apply this diff
```diff
-fn main() {}
+fn main() { }
```

## Verification
Run cargo fmt.'

EMPTY_DIFF_SECTION='## Failure surface
CI lint failure.

## Root cause
Missing newline.

## Apply this diff

## Verification
Run cargo fmt.

[handoff:apply by=reviewer-1 verified=true]'

BAD_ANNOTATION_FORM='## Failure surface
CI lint failure.

## Root cause
Missing newline.

## Apply this diff
```diff
-x
+y
```

## Verification
Run cargo fmt.

[handoff:apply reviewer-1 verified=yes]'

NON_HANDOFF='## Review comment
This looks good overall but the variable naming could be improved.

Please rename `x` to `result` throughout.'

# ── Test 1: valid handoff comment ────────────────────────────────────────────
echo "Test 1: valid handoff comment → exit 0"
set +e
echo "$VALID_COMMENT" | bash "$LINTER"
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    echo "[PASS] valid comment accepted"
    PASS=$((PASS + 1))
else
    echo "[FAIL] valid comment rejected (exit $rc)"
    FAIL=$((FAIL + 1))
fi

# ── Test 2: non-handoff comment (no [handoff:apply]) ─────────────────────────
echo ""
echo "Test 2: non-handoff comment → exit 0 (passthrough)"
set +e
echo "$NON_HANDOFF" | bash "$LINTER"
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    echo "[PASS] non-handoff passed through"
    PASS=$((PASS + 1))
else
    echo "[FAIL] non-handoff incorrectly rejected (exit $rc)"
    FAIL=$((FAIL + 1))
fi

# ── Test 3: missing required section (## Failure surface) ────────────────────
echo ""
echo "Test 3: missing ## Failure surface → exit 1"
set +e
echo "$MISSING_SECTION" | bash "$LINTER" 2>/dev/null
rc=$?
set -e
if [[ $rc -eq 1 ]]; then
    echo "[PASS] missing section correctly rejected"
    PASS=$((PASS + 1))
else
    echo "[FAIL] expected exit 1 for missing section, got $rc"
    FAIL=$((FAIL + 1))
fi

# ── Test 4: missing [handoff:apply] annotation ───────────────────────────────
echo ""
echo "Test 4: missing [handoff:apply] annotation → exit 1"
set +e
echo "$MISSING_ANNOTATION" | bash "$LINTER" 2>/dev/null
rc=$?
set -e
# This comment has [handoff:apply embedded nowhere → should exit 0 (not a handoff)
# Wait — MISSING_ANNOTATION has no [handoff:apply at all, so it's NOT a handoff → exit 0
if [[ $rc -eq 0 ]]; then
    echo "[PASS] comment without [handoff:apply treated as non-handoff (exit 0)"
    PASS=$((PASS + 1))
else
    echo "[FAIL] expected exit 0 for non-handoff comment, got $rc"
    FAIL=$((FAIL + 1))
fi

# ── Test 4b: has [handoff:apply but annotation is malformed ──────────────────
echo ""
echo "Test 4b: malformed [handoff:apply] annotation (wrong form) → exit 1"
set +e
echo "$BAD_ANNOTATION_FORM" | bash "$LINTER" 2>/dev/null
rc=$?
set -e
if [[ $rc -eq 1 ]]; then
    echo "[PASS] bad annotation form correctly rejected"
    PASS=$((PASS + 1))
else
    echo "[FAIL] expected exit 1 for bad annotation form, got $rc"
    FAIL=$((FAIL + 1))
fi

# ── Test 5: empty ## Apply this diff section ─────────────────────────────────
echo ""
echo "Test 5: empty '## Apply this diff' section → exit 1"
set +e
echo "$EMPTY_DIFF_SECTION" | bash "$LINTER" 2>/dev/null
rc=$?
set -e
if [[ $rc -eq 1 ]]; then
    echo "[PASS] empty diff section correctly rejected"
    PASS=$((PASS + 1))
else
    echo "[FAIL] expected exit 1 for empty diff section, got $rc"
    FAIL=$((FAIL + 1))
fi

# ── Test 6: file argument mode ───────────────────────────────────────────────
echo ""
echo "Test 6: file argument mode works"
TMP_FILE=$(mktemp)
echo "$VALID_COMMENT" > "$TMP_FILE"
set +e
bash "$LINTER" "$TMP_FILE"
rc=$?
set -e
rm -f "$TMP_FILE"
if [[ $rc -eq 0 ]]; then
    echo "[PASS] file argument mode accepted"
    PASS=$((PASS + 1))
else
    echo "[FAIL] file argument mode failed (exit $rc)"
    FAIL=$((FAIL + 1))
fi

# ── Test 7: usage error — too many args ──────────────────────────────────────
echo ""
echo "Test 7: too many arguments → exit 2"
set +e
bash "$LINTER" file1.md file2.md 2>/dev/null
rc=$?
set -e
if [[ $rc -eq 2 ]]; then
    echo "[PASS] usage error correctly returned exit 2"
    PASS=$((PASS + 1))
else
    echo "[FAIL] expected exit 2 for too many args, got $rc"
    FAIL=$((FAIL + 1))
fi

# ── Test 8: file not found ───────────────────────────────────────────────────
echo ""
echo "Test 8: nonexistent file → exit 2"
set +e
bash "$LINTER" /tmp/does-not-exist-infra-769.md 2>/dev/null
rc=$?
set -e
if [[ $rc -eq 2 ]]; then
    echo "[PASS] file-not-found correctly returned exit 2"
    PASS=$((PASS + 1))
else
    echo "[FAIL] expected exit 2 for missing file, got $rc"
    FAIL=$((FAIL + 1))
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
echo "[OK] all INFRA-769 lint-handoff-comment tests passed"
