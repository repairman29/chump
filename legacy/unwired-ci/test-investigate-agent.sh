#!/usr/bin/env bash
# INFRA-2357 (META-269 sub-8): smoke test for investigate-agent dispatcher.
#
# Validates:
#   1. Dryrun mode prints a properly-formed brief and emits investigate_dryrun.
#   2. Signal mode writes a pending-signal file under .chump-locks/.
#   3. The brief contains all 4 required sections (SCOPE, DURATION, OUTPUT, CONSTRAINTS).
#   4. Bad topic-slug rejected.
#   5. Missing topic-slug rejected (usage).
#
# Uses a tmpdir for the synthetic ambient.jsonl so we don't pollute the real one.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SCRIPT="$REPO_ROOT/scripts/dispatch/investigate-agent.sh"
TEMPLATE="$REPO_ROOT/docs/process/INVESTIGATE_AGENT_TEMPLATE.md"

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: dispatch script not executable: $SCRIPT" >&2
  exit 1
fi
if [ ! -f "$TEMPLATE" ]; then
  echo "FAIL: template doc missing: $TEMPLATE" >&2
  exit 1
fi

TMPDIR=$(mktemp -d -t investigate-agent-test-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

errors=0

# ── 1. Dryrun mode prints brief ──────────────────────────────────────────────
mkdir -p "$TMPDIR/locks"
SYNTH_AMBIENT="$TMPDIR/locks/ambient.jsonl"
touch "$SYNTH_AMBIENT"

OUT_DRY=$(CHUMP_INVESTIGATE_MODE=dryrun \
  CHUMP_INVESTIGATE_AMBIENT_PATH="$SYNTH_AMBIENT" \
  bash "$SCRIPT" auto-processor-silent 2>&1) || true

# Check: brief contains all 4 required sections.
for section in "SCOPE:" "DURATION:" "OUTPUT:" "CONSTRAINTS (HARD):"; do
  if ! echo "$OUT_DRY" | grep -qF "$section"; then
    echo "FAIL test 1: brief missing section '$section'" >&2
    echo "$OUT_DRY" >&2
    errors=$((errors + 1))
  fi
done

# Check: investigate_dryrun event emitted.
if grep -q '"kind":"investigate_dryrun"' "$SYNTH_AMBIENT" \
  && grep -q '"topic":"auto-processor-silent"' "$SYNTH_AMBIENT"; then
  echo "PASS test 1: dryrun mode prints brief + emits investigate_dryrun"
else
  echo "FAIL test 1: investigate_dryrun event not emitted to ambient" >&2
  cat "$SYNTH_AMBIENT" >&2
  errors=$((errors + 1))
fi

# ── 2. Signal mode writes pending-signal file ────────────────────────────────
mkdir -p "$TMPDIR/repo/.chump-locks"
mkdir -p "$TMPDIR/repo/docs/process"
cd "$TMPDIR/repo"
git init -q . >/dev/null 2>&1
cp "$SCRIPT" "$TMPDIR/repo/investigate-agent.sh"
cp "$TEMPLATE" "$TMPDIR/repo/docs/process/INVESTIGATE_AGENT_TEMPLATE.md"

SYNTH_AMBIENT_2="$TMPDIR/repo/.chump-locks/ambient.jsonl"
touch "$SYNTH_AMBIENT_2"

OUT_SIG=$(CHUMP_INVESTIGATE_MODE=signal \
  CHUMP_INVESTIGATE_AMBIENT_PATH="$SYNTH_AMBIENT_2" \
  bash "$TMPDIR/repo/investigate-agent.sh" daemon-silent-fix-trunk-dispatcher 2>&1) || true

# Check: signal file written.
if ls "$TMPDIR/repo/.chump-locks/investigate-pending-daemon-silent-fix-trunk-dispatcher-"*.json >/dev/null 2>&1; then
  echo "PASS test 2: signal mode writes pending-signal file"
else
  echo "FAIL test 2: signal file not written" >&2
  ls -la "$TMPDIR/repo/.chump-locks/" >&2
  echo "stdout: $OUT_SIG" >&2
  errors=$((errors + 1))
fi

# Check: investigate_dispatched event emitted with mode=signal.
if grep -q '"kind":"investigate_dispatched"' "$SYNTH_AMBIENT_2" \
  && grep -q '"mode":"signal"' "$SYNTH_AMBIENT_2"; then
  echo "PASS test 3: signal mode emits investigate_dispatched"
else
  echo "FAIL test 3: investigate_dispatched not emitted" >&2
  cat "$SYNTH_AMBIENT_2" >&2
  errors=$((errors + 1))
fi

cd "$REPO_ROOT"

# ── 4. Bad topic-slug rejected ───────────────────────────────────────────────
if bash "$SCRIPT" "INVALID UPPERCASE" >/dev/null 2>&1; then
  echo "FAIL test 4: bad slug should be rejected" >&2
  errors=$((errors + 1))
else
  echo "PASS test 4: bad topic-slug rejected"
fi

# ── 5. Missing topic-slug rejected ───────────────────────────────────────────
if bash "$SCRIPT" >/dev/null 2>&1; then
  echo "FAIL test 5: missing slug should be rejected" >&2
  errors=$((errors + 1))
else
  echo "PASS test 5: missing topic-slug rejected with usage"
fi

if [ "$errors" -gt 0 ]; then
  echo "test-investigate-agent: $errors check(s) failed" >&2
  exit 1
fi

echo "test-investigate-agent: PASS — all 5 checks validated"
