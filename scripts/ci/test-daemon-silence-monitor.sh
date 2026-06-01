#!/usr/bin/env bash
# INFRA-2352 (META-269 sub-3): integration test for daemon-silent meta-monitor.
#
# Validates the silence-detection logic with a synthetic ambient.jsonl
# + synthetic launchctl output:
#
#   Scenario A: fix-trunk-dispatcher LOADED + 0 expected emissions in 1h
#       → must emit kind=daemon_silent for that daemon.
#
#   Scenario B: fix-trunk-dispatcher LOADED + recent fix_trunk_dispatched
#       → must NOT emit kind=daemon_silent (healthy).
#
#   Scenario C: daemon not LOADED at all
#       → must NOT emit kind=daemon_silent (skipped).
#
# Skip the test when bash 4+ semantics aren't available (older bash on
# macOS host bash 3 still works because we use POSIX-friendly code).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
MONITOR="$REPO_ROOT/scripts/coord/daemon-silence-monitor.sh"
EXPECTATIONS="$REPO_ROOT/scripts/coord/daemon-expectations.yaml"

if [ ! -x "$MONITOR" ]; then
  echo "FAIL: monitor not executable: $MONITOR" >&2
  exit 1
fi
if [ ! -f "$EXPECTATIONS" ]; then
  echo "FAIL: expectations missing: $EXPECTATIONS" >&2
  exit 1
fi

TMPDIR=$(mktemp -d -t daemon-silence-test-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

errors=0

# ── Scenario A: silent dispatcher ────────────────────────────────────────────
mkdir -p "$TMPDIR/A"
SYNTH_AMBIENT_A="$TMPDIR/A/ambient.jsonl"
cat > "$SYNTH_AMBIENT_A" <<EOF
{"ts":"2024-01-01T00:00:00Z","kind":"trunk_sentinel_tick","source":"sentinel"}
EOF

SYNTH_LAUNCHCTL_A=$(printf "PID\tStatus\tLabel\n12345\t0\tcom.chump.fix-trunk-dispatcher\n9876\t0\tdev.chump.trunk-sentinel\n")

OUT_A=$(CHUMP_DAEMON_SILENCE_AMBIENT_PATH="$SYNTH_AMBIENT_A" \
  CHUMP_DAEMON_SILENCE_LAUNCHCTL_LIST="$SYNTH_LAUNCHCTL_A" \
  CHUMP_DAEMON_SILENCE_WINDOW_SECS=3600 \
  bash "$MONITOR" 2>&1) || true

# Check: ambient.jsonl now contains daemon_silent for com.chump.fix-trunk-dispatcher
if grep -q '"kind":"daemon_silent"' "$SYNTH_AMBIENT_A" \
  && grep -q '"daemon":"com.chump.fix-trunk-dispatcher"' "$SYNTH_AMBIENT_A"; then
  echo "PASS scenario A: dispatcher silent → daemon_silent emitted"
else
  echo "FAIL scenario A: expected daemon_silent for fix-trunk-dispatcher; got:" >&2
  cat "$SYNTH_AMBIENT_A" >&2
  echo "stderr:" >&2
  echo "$OUT_A" >&2
  errors=$((errors + 1))
fi

# ── Scenario B: healthy dispatcher ───────────────────────────────────────────
mkdir -p "$TMPDIR/B"
SYNTH_AMBIENT_B="$TMPDIR/B/ambient.jsonl"
RECENT_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$SYNTH_AMBIENT_B" <<EOF
{"ts":"$RECENT_TS","kind":"fix_trunk_dispatched","source":"dispatcher","pr":1234}
{"ts":"$RECENT_TS","kind":"trunk_sentinel_tick","source":"sentinel"}
EOF

OUT_B=$(CHUMP_DAEMON_SILENCE_AMBIENT_PATH="$SYNTH_AMBIENT_B" \
  CHUMP_DAEMON_SILENCE_LAUNCHCTL_LIST="$SYNTH_LAUNCHCTL_A" \
  CHUMP_DAEMON_SILENCE_WINDOW_SECS=3600 \
  bash "$MONITOR" 2>&1) || true

# Check: NO daemon_silent for fix-trunk-dispatcher in the appended events.
if grep -q '"kind":"daemon_silent".*"daemon":"com.chump.fix-trunk-dispatcher"' "$SYNTH_AMBIENT_B"; then
  echo "FAIL scenario B: dispatcher healthy but daemon_silent fired:" >&2
  cat "$SYNTH_AMBIENT_B" >&2
  errors=$((errors + 1))
else
  echo "PASS scenario B: healthy dispatcher → no false positive"
fi

# ── Scenario C: daemon not LOADED ────────────────────────────────────────────
mkdir -p "$TMPDIR/C"
SYNTH_AMBIENT_C="$TMPDIR/C/ambient.jsonl"
echo "{}" > "$SYNTH_AMBIENT_C"
# Launchctl output WITHOUT the dispatcher.
SYNTH_LAUNCHCTL_C=$(printf "PID\tStatus\tLabel\n9876\t0\tdev.chump.trunk-sentinel\n")

OUT_C=$(CHUMP_DAEMON_SILENCE_AMBIENT_PATH="$SYNTH_AMBIENT_C" \
  CHUMP_DAEMON_SILENCE_LAUNCHCTL_LIST="$SYNTH_LAUNCHCTL_C" \
  CHUMP_DAEMON_SILENCE_WINDOW_SECS=3600 \
  bash "$MONITOR" 2>&1) || true

if grep -q '"kind":"daemon_silent".*"daemon":"com.chump.fix-trunk-dispatcher"' "$SYNTH_AMBIENT_C"; then
  echo "FAIL scenario C: not-LOADED daemon should be skipped:" >&2
  cat "$SYNTH_AMBIENT_C" >&2
  errors=$((errors + 1))
else
  echo "PASS scenario C: not-LOADED daemon → skipped (no daemon_silent)"
fi

if [ "$errors" -gt 0 ]; then
  echo "test-daemon-silence-monitor: $errors scenario(s) failed" >&2
  exit 1
fi

echo "test-daemon-silence-monitor: PASS — all 3 scenarios validated"
