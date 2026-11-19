#!/usr/bin/env bash
# test-voice-banlist-self.sh — INFRA-1728 self-test
#
# Verifies test-voice-banlist.sh behavior using synthetic fixtures:
#   1. Fixture doc with banned word → non-zero exit (violation detected)
#   2. Fixture doc with banned word + bypass trailer → zero exit (bypassed)
#   3. Banned word inside code fence → zero exit (exempt)
#   4. Banned word in inline backtick → zero exit (exempt)
#   5. Clean doc → zero exit (PASS)
#   6. CHUMP_VOICE_LINT_DISABLE=1 → zero exit regardless

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
GATE="$SCRIPT_DIR/test-voice-banlist.sh"

[[ -x "$GATE" ]] || { echo "FAIL: $GATE not executable"; exit 1; }

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Build a fake git repo so the gate can run git diff
FAKE_REPO="$TMP/repo"
mkdir -p "$FAKE_REPO/docs/process"
git -C "$FAKE_REPO" init -q
git -C "$FAKE_REPO" config user.email "test@test.com"
git -C "$FAKE_REPO" config user.name "Test"

# Seed a base commit (acts as "origin/main")
echo "# base" > "$FAKE_REPO/docs/process/base.md"
git -C "$FAKE_REPO" add .
git -C "$FAKE_REPO" commit -q -m "base"
# Tag the base so we can diff against it
git -C "$FAKE_REPO" tag base_commit

_run_gate() {
  local doc_content="$1"
  local commit_msg="${2:-feat: add doc}"
  local extra_env="${3:-}"

  # Write the doc and commit it
  echo "$doc_content" > "$FAKE_REPO/docs/process/subject.md"
  git -C "$FAKE_REPO" add docs/process/subject.md

  # Write commit message (may include trailer)
  git -C "$FAKE_REPO" commit -q --allow-empty -m "$commit_msg"

  # Run the gate pointing at the fake repo
  env $extra_env \
    REPO_ROOT="$FAKE_REPO" \
    CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl" \
    CHUMP_VOICE_LINT_DRY_RUN=1 \
    bash "$GATE" --base=base_commit 2>&1
  return $?
}

_reset_repo() {
  git -C "$FAKE_REPO" reset -q --hard base_commit
}

# ── Test 1: banned word → FAIL ────────────────────────────────────────────────
echo "Test 1: doc with banned word 'synergy' → violation detected"
_reset_repo
if ! _run_gate "This leverages synergy between modules." "feat: add doc" 2>/dev/null; then
  ok "gate exits non-zero on banned word"
else
  fail "gate should have failed on 'synergy'"
fi
_reset_repo

# ── Test 2: banned word + bypass trailer → PASS ───────────────────────────────
echo "Test 2: banned word + Voice-Lint-Bypass trailer → bypass accepted"
_reset_repo
if _run_gate "This leverages synergy between modules." \
    "$(printf 'feat: add doc\n\nVoice-Lint-Bypass: quoting vendor copy for analysis')" \
    2>/dev/null; then
  ok "gate exits zero when bypass trailer present"
else
  fail "gate should have bypassed with trailer"
fi
_reset_repo

# ── Test 3: banned word inside code fence → PASS ─────────────────────────────
echo "Test 3: banned word inside code fence → exempt"
_reset_repo
doc_content="# Guide

Normal content here.

\`\`\`
synergy revolutionary disruptive
\`\`\`

More normal content."
if _run_gate "$doc_content" "feat: add doc" 2>/dev/null; then
  ok "code fence content is exempt"
else
  fail "gate should have passed (word inside code fence)"
fi
_reset_repo

# ── Test 4: banned word in inline backtick → PASS ────────────────────────────
echo "Test 4: banned word in inline backtick → exempt"
_reset_repo
if _run_gate "Use \`synergy\` carefully." "feat: add doc" 2>/dev/null; then
  ok "inline backtick content is exempt"
else
  fail "gate should have passed (word inside backtick)"
fi
_reset_repo

# ── Test 5: clean doc → PASS ─────────────────────────────────────────────────
echo "Test 5: clean doc with no banned words → PASS"
_reset_repo
if _run_gate "# Clean Guide\n\nThis shows how to run the tool efficiently." "feat: add clean doc" 2>/dev/null; then
  ok "clean doc passes lint"
else
  fail "clean doc should have passed lint"
fi
_reset_repo

# ── Test 6: CHUMP_VOICE_LINT_DISABLE=1 → PASS regardless ────────────────────
echo "Test 6: CHUMP_VOICE_LINT_DISABLE=1 → skips lint entirely"
_reset_repo
echo "This leverages synergy between modules." > "$FAKE_REPO/docs/process/subject.md"
git -C "$FAKE_REPO" add docs/process/subject.md
git -C "$FAKE_REPO" commit -q --allow-empty -m "feat: add doc"
if REPO_ROOT="$FAKE_REPO" \
   CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl" \
   CHUMP_VOICE_LINT_DISABLE=1 \
   bash "$GATE" --base=base_commit 2>/dev/null; then
  ok "CHUMP_VOICE_LINT_DISABLE=1 exits zero"
else
  fail "CHUMP_VOICE_LINT_DISABLE=1 should exit zero"
fi
_reset_repo

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "PASS: all voice-banlist self-tests passed"
exit 0
