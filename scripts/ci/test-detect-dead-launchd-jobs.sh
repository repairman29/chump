#!/usr/bin/env bash
# scripts/ci/test-detect-dead-launchd-jobs.sh — CREDIBLE-1020
#
# Verifies scripts/coord/detect-dead-launchd-jobs.sh:
#   1. is executable
#   2. finds a dummy plist under a fixture scripts/launchd dir whose
#      Label has no matching running process, and reports it
#   3. does NOT report a plist whose Label matches a currently-running
#      process (false-positive guard)
#   4. always prints a "Total dead launchd jobs: N" summary line

set -uo pipefail
PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DETECTOR="$REPO_ROOT/scripts/coord/detect-dead-launchd-jobs.sh"

echo "=== CREDIBLE-1020 detect-dead-launchd-jobs tests ==="

echo ""
echo "--- 1. Script exists and is executable ---"
if [[ -x "$DETECTOR" ]]; then
    ok "detect-dead-launchd-jobs.sh is executable"
else
    fail "detect-dead-launchd-jobs.sh is not executable at $DETECTOR"
fi

FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
mkdir -p "$FIXTURE_DIR/scripts/launchd"

DEAD_LABEL="com.chump.test-dummy-nonexistent-job-credible-1020"
cat > "$FIXTURE_DIR/scripts/launchd/com.chump.dummy.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${DEAD_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/path/to/nonexistent-script.sh</string>
    </array>
</dict>
</plist>
EOF

echo ""
echo "--- 2. Dummy plist with no matching process is reported ---"
OUT="$("$DETECTOR" "$FIXTURE_DIR" 2>&1)"
if echo "$OUT" | grep -q "com.chump.dummy.plist" && echo "$OUT" | grep -q "$DEAD_LABEL"; then
    ok "dead dummy plist reported with path + label"
else
    fail "dummy plist not reported. Output:
$OUT"
fi

echo ""
echo "--- 3. A plist whose label matches a running process is NOT reported ---"
# Use this test script's own long-lived-enough invocation as the "running
# process": spawn a background sleep tagged with a unique label-shaped
# marker via -f matching on the command line (pgrep -f fallback path).
LIVE_LABEL="com.chump.test-live-marker-credible-1020"
( exec -a "$LIVE_LABEL" sleep 5 ) &
LIVE_PID=$!
# Give pgrep a moment to be able to see the new process.
for _ in 1 2 3 4 5; do
    pgrep -f -- "$LIVE_LABEL" >/dev/null 2>&1 && break
    sleep 0.2
done

cat > "$FIXTURE_DIR/scripts/launchd/com.chump.live.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LIVE_LABEL}</string>
</dict>
</plist>
EOF

OUT2="$("$DETECTOR" "$FIXTURE_DIR" 2>&1)"
kill "$LIVE_PID" >/dev/null 2>&1 || true
wait "$LIVE_PID" 2>/dev/null || true

if echo "$OUT2" | grep -q "com.chump.live.plist"; then
    fail "live-process plist was incorrectly reported as dead. Output:
$OUT2"
else
    ok "live-process plist correctly excluded"
fi

echo ""
echo "--- 4. Summary line is always printed ---"
if echo "$OUT2" | grep -qE "^Total dead launchd jobs: [0-9]+$"; then
    ok "summary line present"
else
    fail "summary line missing. Output:
$OUT2"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    printf 'Failures:\n'
    printf ' - %s\n' "${FAILS[@]}"
    exit 1
fi
exit 0
