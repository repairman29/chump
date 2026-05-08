#!/usr/bin/env bash
# test-gap-divergence-guard.sh — INFRA-783 fixture tests.
#
# Cases:
#   1. Clean: YAML matches state.db → guard passes silently
#   2. Title diverges → guard blocks with diagnostic citing both values
#   3. Priority diverges → guard blocks
#   4. Filename != yaml id → guard blocks
#   5. YAML for a gap not in state.db → warns but does not block
#   6. CHUMP_GAP_DIVERGE_CHECK=0 → guard skips silently
#   7. Multiple staged YAMLs, mixed clean+diverge → guard blocks listing only the diverged

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-783 gap-divergence guard tests ==="
echo

# Unset caller-set git env vars so the isolated fake repo's git
# invocations work cleanly.
unset GIT_WORK_TREE GIT_DIR GIT_COMMON_DIR

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit-gap-divergence.sh"

if [[ ! -x "$HOOK" ]]; then
    echo "FATAL: hook not executable: $HOOK"
    exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE="$TMP/repo"
mkdir -p "$FAKE/docs/gaps" "$FAKE/.chump"
git -C "$FAKE" init -q -b main
git -C "$FAKE" config user.email t@t && git -C "$FAKE" config user.name t

# Seed state.db with two gaps.
sqlite3 "$FAKE/.chump/state.db" <<'SQL'
CREATE TABLE gaps (
  id TEXT PRIMARY KEY,
  domain TEXT NOT NULL DEFAULT '',
  title TEXT NOT NULL DEFAULT '',
  priority TEXT NOT NULL DEFAULT '',
  effort TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'open'
);
INSERT INTO gaps (id, domain, title, priority, effort, status)
  VALUES ('TEST-1', 'INFRA', 'first canonical gap', 'P1', 's', 'open');
INSERT INTO gaps (id, domain, title, priority, effort, status)
  VALUES ('TEST-2', 'INFRA', 'second canonical gap', 'P2', 'xs', 'open');
SQL

# Seed matching YAMLs and an initial commit so we can git diff cached.
cat > "$FAKE/docs/gaps/TEST-1.yaml" <<'YAML'
- id: TEST-1
  domain: INFRA
  title: "first canonical gap"
  priority: P1
  effort: s
  status: open
YAML
cat > "$FAKE/docs/gaps/TEST-2.yaml" <<'YAML'
- id: TEST-2
  domain: INFRA
  title: "second canonical gap"
  priority: P2
  effort: xs
  status: open
YAML
git -C "$FAKE" add . && git -C "$FAKE" commit -q -m "seed"

run_hook() {
    cd "$FAKE" || return 2
    OUT=$("$HOOK" 2>&1)
    RC=$?
    cd - >/dev/null || true
    echo "$OUT"
    return "$RC"
}

# ── Test 1: clean staged YAML matches DB ───────────────────────────────────
echo "--- Test 1: matching YAML+DB → passes ---"
# Stage a no-op modification (touch the file content trivially).
echo "# no-op comment" >> "$FAKE/docs/gaps/TEST-1.yaml"
git -C "$FAKE" add docs/gaps/TEST-1.yaml
OUT=$(run_hook 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]] && [[ -z "$OUT" ]]; then
    ok "matching YAML/DB allowed silently"
else
    fail "expected silent pass (rc=$RC, out=$OUT)"
fi
git -C "$FAKE" reset -q HEAD docs/gaps/TEST-1.yaml
git -C "$FAKE" checkout -q docs/gaps/TEST-1.yaml

# ── Test 2: title diverges ──────────────────────────────────────────────────
echo "--- Test 2: YAML title diverges → blocks ---"
sed -i.bak 's/first canonical gap/divergent title here/' "$FAKE/docs/gaps/TEST-1.yaml"
rm -f "$FAKE/docs/gaps/TEST-1.yaml.bak"
git -C "$FAKE" add docs/gaps/TEST-1.yaml
OUT=$(run_hook 2>&1)
RC=$?
if [[ "$RC" -ne 0 ]] \
   && echo "$OUT" | grep -q "title diverges" \
   && echo "$OUT" | grep -q "divergent title here" \
   && echo "$OUT" | grep -q "first canonical gap"; then
    ok "title divergence blocked with both values cited"
else
    fail "expected title divergence (rc=$RC, out=$OUT)"
fi
git -C "$FAKE" reset -q HEAD docs/gaps/TEST-1.yaml
git -C "$FAKE" checkout -q docs/gaps/TEST-1.yaml

# ── Test 3: priority diverges ───────────────────────────────────────────────
echo "--- Test 3: YAML priority diverges → blocks ---"
sed -i.bak 's/priority: P1/priority: P0/' "$FAKE/docs/gaps/TEST-1.yaml"
rm -f "$FAKE/docs/gaps/TEST-1.yaml.bak"
git -C "$FAKE" add docs/gaps/TEST-1.yaml
OUT=$(run_hook 2>&1)
RC=$?
if [[ "$RC" -ne 0 ]] && echo "$OUT" | grep -q "priority diverges"; then
    ok "priority divergence blocked"
else
    fail "expected priority divergence (rc=$RC, out=$OUT)"
fi
git -C "$FAKE" reset -q HEAD docs/gaps/TEST-1.yaml
git -C "$FAKE" checkout -q docs/gaps/TEST-1.yaml

# ── Test 4: filename != yaml id ─────────────────────────────────────────────
echo "--- Test 4: filename and yaml id mismatch → blocks ---"
cp "$FAKE/docs/gaps/TEST-1.yaml" "$FAKE/docs/gaps/TYPO-1.yaml"
git -C "$FAKE" add docs/gaps/TYPO-1.yaml
OUT=$(run_hook 2>&1)
RC=$?
if [[ "$RC" -ne 0 ]] && echo "$OUT" | grep -qE "filename says TYPO-1.*yaml says id=TEST-1"; then
    ok "filename / yaml-id mismatch blocked"
else
    fail "expected filename mismatch (rc=$RC, out=$OUT)"
fi
git -C "$FAKE" reset -q HEAD docs/gaps/TYPO-1.yaml
rm -f "$FAKE/docs/gaps/TYPO-1.yaml"

# ── Test 5: YAML for unknown gap ID → warn but pass ─────────────────────────
echo "--- Test 5: YAML for ID not in state.db → warns but passes ---"
cat > "$FAKE/docs/gaps/UNKNOWN-99.yaml" <<'YAML'
- id: UNKNOWN-99
  domain: INFRA
  title: "imported from elsewhere"
  priority: P1
  effort: s
YAML
git -C "$FAKE" add docs/gaps/UNKNOWN-99.yaml
OUT=$(run_hook 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]] && echo "$OUT" | grep -q "no state.db row"; then
    ok "unknown gap warns but allows commit"
else
    fail "expected pass with warn (rc=$RC, out=$OUT)"
fi
git -C "$FAKE" reset -q HEAD docs/gaps/UNKNOWN-99.yaml
rm -f "$FAKE/docs/gaps/UNKNOWN-99.yaml"

# ── Test 6: bypass env silently skips ───────────────────────────────────────
echo "--- Test 6: CHUMP_GAP_DIVERGE_CHECK=0 → skip ---"
sed -i.bak 's/first canonical gap/intentionally divergent/' "$FAKE/docs/gaps/TEST-1.yaml"
rm -f "$FAKE/docs/gaps/TEST-1.yaml.bak"
git -C "$FAKE" add docs/gaps/TEST-1.yaml
OUT=$(CHUMP_GAP_DIVERGE_CHECK=0 run_hook 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]] && [[ -z "$OUT" ]]; then
    ok "bypass env silently skipped"
else
    fail "expected silent skip (rc=$RC, out=$OUT)"
fi
git -C "$FAKE" reset -q HEAD docs/gaps/TEST-1.yaml
git -C "$FAKE" checkout -q docs/gaps/TEST-1.yaml

# ── Test 7: mixed staged — clean + diverged → blocks listing only diverged ──
echo "--- Test 7: mixed clean + diverged → blocks, lists diverged only ---"
echo "# trivial" >> "$FAKE/docs/gaps/TEST-2.yaml"  # clean change
sed -i.bak 's/first canonical gap/diverged again/' "$FAKE/docs/gaps/TEST-1.yaml"
rm -f "$FAKE/docs/gaps/TEST-1.yaml.bak"
git -C "$FAKE" add docs/gaps/TEST-1.yaml docs/gaps/TEST-2.yaml
OUT=$(run_hook 2>&1)
RC=$?
if [[ "$RC" -ne 0 ]] \
   && echo "$OUT" | grep -q "TEST-1.yaml" \
   && ! echo "$OUT" | grep -q "TEST-2.yaml: title"; then
    ok "mixed: only diverged YAML cited"
else
    fail "expected only TEST-1 cited, not TEST-2 (rc=$RC, out=$OUT)"
fi
git -C "$FAKE" reset -q HEAD docs/gaps/TEST-1.yaml docs/gaps/TEST-2.yaml

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
