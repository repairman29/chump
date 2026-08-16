#!/usr/bin/env bash
# test-bash-portability-lint.sh — INFRA-2351 (META-269 sub-2)
#
# Smoke test for scripts/ci/bash-portability-lint.sh. Builds synthetic
# fixture files with known non-portable anti-patterns and asserts the lint
# catches them, plus asserts a clean file passes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
LINT="$REPO_ROOT/scripts/ci/bash-portability-lint.sh"

PASS=0
FAIL=0
ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-2351 bash-portability-lint smoke test ==="
echo

[[ -x "$LINT" ]] && ok "lint script exists and is executable" \
  || fail "lint script missing or not executable at $LINT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── 1. GNU-only 'sed -i' without backup suffix → flagged ────────────────────
cat > "$TMP/gnu-sed-i.sh" <<'EOF'
#!/usr/bin/env bash
sed -i 's/foo/bar/' somefile.txt
EOF
if OUT="$(bash "$LINT" "$TMP/gnu-sed-i.sh" 2>&1)"; then
    fail "GNU-only 'sed -i' should be flagged (exit 0 seen)"
else
    if echo "$OUT" | grep -q "sed -i"; then
        ok "GNU-only 'sed -i' without backup suffix is flagged"
    else
        fail "lint exited non-zero but did not mention 'sed -i': $OUT"
    fi
fi

# ── 2. GNU-only 'date -d' → flagged ──────────────────────────────────────────
cat > "$TMP/gnu-date.sh" <<'EOF'
#!/usr/bin/env bash
NOW="$(date -d '1 hour ago' +%s)"
EOF
if OUT="$(bash "$LINT" "$TMP/gnu-date.sh" 2>&1)"; then
    fail "GNU-only 'date -d' should be flagged (exit 0 seen)"
else
    if echo "$OUT" | grep -q "date"; then
        ok "GNU-only 'date -d' is flagged"
    else
        fail "lint exited non-zero but did not mention 'date': $OUT"
    fi
fi

# ── 3. bashism '[[' in a #!/bin/sh script → flagged ──────────────────────────
cat > "$TMP/sh-bashism.sh" <<'EOF'
#!/bin/sh
if [[ "$1" == "x" ]]; then
    echo yes
fi
EOF
if OUT="$(bash "$LINT" "$TMP/sh-bashism.sh" 2>&1)"; then
    fail "bashism '[[' in #!/bin/sh script should be flagged (exit 0 seen)"
else
    if echo "$OUT" | grep -q "bashism"; then
        ok "bashism '[[' in a #!/bin/sh script is flagged"
    else
        fail "lint exited non-zero but did not mention 'bashism': $OUT"
    fi
fi

# ── 4. Clean, portable file → not flagged ────────────────────────────────────
cat > "$TMP/clean.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sed -i.bak 's/foo/bar/' somefile.txt
NOW="$(date +%s)"
if [[ "$1" == "x" ]]; then
    echo yes
fi
EOF
if OUT="$(bash "$LINT" "$TMP/clean.sh" 2>&1)"; then
    ok "clean/portable file passes with no violations"
else
    fail "clean file was incorrectly flagged: $OUT"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
