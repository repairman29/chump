#!/usr/bin/env bash
# CI gate for INFRA-399: subagent transcript archival.
# Tests archive-subagent-transcripts.sh and inspect-subagent.sh with
# a synthetic JSONL output file in a temp directory.
set -e
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  PASS: $desc"; (( PASS++ )) || true
  else
    echo "  FAIL: $desc"; (( FAIL++ )) || true
  fi
}

echo "=== INFRA-399: subagent transcript archival ==="

ARCHIVE_SCRIPT="$REPO_ROOT/scripts/dev/archive-subagent-transcripts.sh"
INSPECT_SCRIPT="$REPO_ROOT/scripts/dev/inspect-subagent.sh"

# 1. Scripts exist and are executable
check "archive-subagent-transcripts.sh exists and is executable" test -x "$ARCHIVE_SCRIPT"
check "inspect-subagent.sh exists and is executable" test -x "$INSPECT_SCRIPT"

# 2. Key structural checks on archive script
check "archive script: finds .output files via find" \
  grep -q '\.output' "$ARCHIVE_SCRIPT"
check "archive script: copies to archive dir" \
  grep -q 'cp ' "$ARCHIVE_SCRIPT"
check "archive script: 30-day compression" \
  grep -q 'COMPRESS_DAYS\|30' "$ARCHIVE_SCRIPT"
check "archive script: 90-day deletion" \
  grep -q 'DELETE_DAYS\|90' "$ARCHIVE_SCRIPT"
check "archive script: dry-run flag" \
  grep -q 'dry.run\|DRY_RUN' "$ARCHIVE_SCRIPT"
check "archive script: --tmp-base override for testing" \
  grep -q 'tmp.base\|TMP_OVERRIDE\|tmp_base' "$ARCHIVE_SCRIPT"

# 3. worker.sh has archival hook
check "worker.sh calls archive-subagent-transcripts.sh" \
  grep -q 'archive-subagent-transcripts.sh' "$REPO_ROOT/scripts/dispatch/worker.sh"
check "worker.sh: INFRA-399 comment present" \
  grep -q 'INFRA-399' "$REPO_ROOT/scripts/dispatch/worker.sh"
check "worker.sh: CHUMP_SKIP_SUBAGENT_ARCHIVE bypass" \
  grep -q 'CHUMP_SKIP_SUBAGENT_ARCHIVE' "$REPO_ROOT/scripts/dispatch/worker.sh"

# 4. Functional test: create synthetic output file, archive, inspect
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

FAKE_PROJECT_SLUG="$(basename "$TMPDIR_TEST")"
FAKE_TMP="$TMPDIR_TEST/private/tmp/claude-501/${FAKE_PROJECT_SLUG}/session-abc123/tasks"
FAKE_ARCHIVE_BASE="$TMPDIR_TEST/home/.claude/projects/${FAKE_PROJECT_SLUG}/notes/subagent-archive"
mkdir -p "$FAKE_TMP"
mkdir -p "$FAKE_ARCHIVE_BASE"

AGENT_ID="testagent9876"
printf '{"type":"message","role":"assistant","content":"hello from test agent"}\n{"type":"result","subtype":"success"}\n' \
  > "$FAKE_TMP/${AGENT_ID}.output"

# Override HOME and tmp base for isolated functional test
TEST_OUTPUT=$(
  HOME="$TMPDIR_TEST/home" \
    bash "$ARCHIVE_SCRIPT" \
      --project-slug "$FAKE_PROJECT_SLUG" \
      --tmp-base "$TMPDIR_TEST/private/tmp/claude-501" \
      --since-secs 86400 2>&1
) || true

check "archive: output file is copied to archive" \
  test -f "$FAKE_ARCHIVE_BASE/${AGENT_ID}.jsonl"

# inspect-subagent.sh should find the archived file
check "inspect: finds archived file and prints content" bash -c \
  "HOME='$TMPDIR_TEST/home' bash '$INSPECT_SCRIPT' '$AGENT_ID' 2>&1 | grep -q 'hello from test agent'"

check "inspect: grep filter works" bash -c \
  "HOME='$TMPDIR_TEST/home' bash '$INSPECT_SCRIPT' '$AGENT_ID' --grep 'result' 2>&1 | grep -q 'result'"

# inspect with unknown ID exits non-zero
if HOME="$TMPDIR_TEST/home" bash "$INSPECT_SCRIPT" "UNKNOWN_ID_XYZ" 2>/dev/null; then
  echo "  FAIL: inspect should exit non-zero for unknown agent ID"; (( FAIL++ )) || true
else
  echo "  PASS: inspect exits non-zero for unknown agent ID"; (( PASS++ )) || true
fi

# dry-run: does not copy files
FAKE_TMP2="$TMPDIR_TEST/private/tmp/claude-501/${FAKE_PROJECT_SLUG}/session-xyz/tasks"
mkdir -p "$FAKE_TMP2"
printf '{"type":"message"}\n' > "$FAKE_TMP2/dryrunagent.output"
HOME="$TMPDIR_TEST/home" bash "$ARCHIVE_SCRIPT" \
  --project-slug "$FAKE_PROJECT_SLUG" \
  --tmp-base "$TMPDIR_TEST/private/tmp/claude-501" \
  --since-secs 86400 --dry-run >/dev/null 2>&1 || true
check "dry-run: new file NOT copied to archive" \
  test ! -f "$FAKE_ARCHIVE_BASE/dryrunagent.jsonl"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
