#!/usr/bin/env bash
# test-curator-liveness.sh — RESILIENT-246
#
# Regression coverage for the twelve-day curator outage.
#
# What actually happened: com.chump.curator-supervisor.plist put a cargo build
# artifact (target/release/chump-curator-supervisor) in ProgramArguments. When
# that path was reclaimed, launchd could not spawn the job and returned exit
# status 78 (EX_CONFIG) on every 300s interval. Because launchd fails BEFORE
# the process exists, it never opened StandardOutPath/StandardErrorPath — both
# logs stayed empty. There was no error anywhere; the logs simply stopped.
# Nothing graded the curator, so the silence lasted twelve days.
#
# The tests below pin each link of that chain:
#   1. plist never points ProgramArguments at a target/ build artifact
#   2. plist is well-formed for STRICT parsers (the old one was not)
#   3. the runner exists, is executable, and resolves a stable binary first
#   4. LIVE: a runner that cannot find its binary REPORTS (non-zero exit +
#      ALERT + artifact) instead of being silently skipped  ← the core AC
#   5. LIVE: a runner that CAN start writes the .chump-locks/curator-* artifact
#   6. the existing reaper watchdog grades curator-supervisor
#   7. fleet-brief prints curator liveness UNCONDITIONALLY
#   8. the installer refuses a target/-based plist and treats loaded-but-
#      failing as failure

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLIST="$REPO_ROOT/scripts/setup/launchd/com.chump.curator-supervisor.plist"
RUNNER="$REPO_ROOT/scripts/ops/curator-supervisor-run.sh"
WATCHDOG="$REPO_ROOT/scripts/ops/reaper-heartbeat-watchdog.sh"
BRIEF="$REPO_ROOT/scripts/dispatch/fleet-brief.sh"
INSTALLER="$REPO_ROOT/scripts/setup/install-curator-supervisor.sh"

echo "=== RESILIENT-246 curator liveness test ==="
echo

for f in "$PLIST" "$RUNNER" "$WATCHDOG" "$BRIEF" "$INSTALLER"; do
    [[ -f "$f" ]] || { echo "FATAL: missing $f"; exit 2; }
done

# ── 1. plist must not reference a build artifact ──────────────────────────
echo "[plist: no disposable build path]"
# Inspect the PARSED values, not the raw text: the file documents the old bad
# path inside an XML comment on purpose, and a raw grep would flag that.
if python3 - "$PLIST" <<'PY' 2>/dev/null
import sys, plistlib
raw = open(sys.argv[1], 'rb').read()
for ph, val in ((b'CHUMP_REPO_ROOT_PLACEHOLDER', b'/tmp/x'),
                (b'CHUMP_LOG_DIR_PLACEHOLDER', b'/tmp/l'),
                (b'CHUMP_HOME_PLACEHOLDER', b'/tmp/h')):
    raw = raw.replace(ph, val)
d = plistlib.loads(raw)
vals = list(d.get('ProgramArguments') or [])
vals.append(d.get('WorkingDirectory') or '')
vals.extend((d.get('EnvironmentVariables') or {}).values())
bad = [v for v in vals if '/target/release/' in str(v) or '/target/debug/' in str(v)]
sys.exit(0 if bad else 1)
PY
then
    fail "plist VALUES reference a target/ build artifact — this is the exit-78 config"
else
    ok "no parsed plist value points into target/{release,debug}"
fi

# ProgramArguments[0] must be an interpreter that always exists.
PA0="$(python3 - "$PLIST" <<'PY' 2>/dev/null
import sys, plistlib
raw = open(sys.argv[1], 'rb').read()
for ph, val in ((b'CHUMP_REPO_ROOT_PLACEHOLDER', b'/tmp/x'),
                (b'CHUMP_LOG_DIR_PLACEHOLDER', b'/tmp/l'),
                (b'CHUMP_HOME_PLACEHOLDER', b'/tmp/h')):
    raw = raw.replace(ph, val)
d = plistlib.loads(raw)
print((d.get('ProgramArguments') or [''])[0])
PY
)"
if [[ "$PA0" == "/bin/bash" || "$PA0" == "/bin/sh" ]]; then
    ok "ProgramArguments[0] is a always-present interpreter ($PA0)"
else
    fail "ProgramArguments[0] is '$PA0' — must be /bin/bash so launchd can always spawn"
fi

# ── 2. plist must parse under a STRICT xml parser ─────────────────────────
# The pre-RESILIENT-246 file contained a literal double-hyphen inside an XML
# comment. plutil/CoreFoundation tolerate that; python plistlib does not. That
# made the plist unverifiable by exactly the tooling that would have caught it.
echo
echo "[plist: strict XML validity]"
if python3 - "$PLIST" <<'PY' 2>/dev/null
import sys, plistlib
raw = open(sys.argv[1], 'rb').read()
for ph, val in ((b'CHUMP_REPO_ROOT_PLACEHOLDER', b'/tmp/x'),
                (b'CHUMP_LOG_DIR_PLACEHOLDER', b'/tmp/l'),
                (b'CHUMP_HOME_PLACEHOLDER', b'/tmp/h')):
    raw = raw.replace(ph, val)
plistlib.loads(raw)
PY
then
    ok "plist parses under strict XML (python plistlib)"
else
    fail "plist is not well-formed XML (a '--' inside a comment will do this)"
fi

# ── 3. runner shape ───────────────────────────────────────────────────────
echo
echo "[runner]"
[[ -x "$RUNNER" ]] && ok "runner is executable" || fail "runner is not executable"
bash -n "$RUNNER" 2>/dev/null && ok "runner passes bash -n" || fail "runner has a syntax error"
if grep -q '\.cargo/bin/chump-curator-supervisor' "$RUNNER"; then
    ok "runner prefers the stable ~/.cargo/bin path"
else
    fail "runner does not look for the stable ~/.cargo/bin path"
fi

# ── 4. THE CORE AC: cannot-start is REPORTED, not silently skipped ────────
echo
echo "[live: a curator that cannot start is REPORTED]"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# Give the runner a repo-shaped sandbox with its own .chump-locks so the real
# ambient.jsonl is never touched, and point it at a binary that does not exist.
git -C "$SANDBOX" init -q 2>/dev/null
mkdir -p "$SANDBOX/.chump-locks" "$SANDBOX/scripts/ops" "$SANDBOX/scripts/lib"
cp "$RUNNER" "$SANDBOX/scripts/ops/"
cp "$REPO_ROOT/scripts/lib/reaper-instrumentation.sh" "$SANDBOX/scripts/lib/"

MISSING_OUT="$SANDBOX/missing.out"
set +e
( cd "$SANDBOX" && \
  CHUMP_CURATOR_SUPERVISOR_BIN="$SANDBOX/definitely-not-a-real-binary" \
  bash scripts/ops/curator-supervisor-run.sh ) >"$MISSING_OUT" 2>&1
MISSING_RC=$?
set -e

if [[ "$MISSING_RC" -ne 0 ]]; then
    ok "runner exits non-zero when the binary is missing (rc=$MISSING_RC)"
else
    fail "runner exited 0 with a missing binary — silently skipped"
fi

if grep -q 'curator_cannot_start' "$MISSING_OUT"; then
    ok "runner prints an ALERT to stderr when it cannot start"
else
    fail "runner printed no cannot-start ALERT (output: $(head -3 "$MISSING_OUT"))"
fi

if grep -q '"kind":"curator_cannot_start"' "$SANDBOX/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "runner emits curator_cannot_start into ambient.jsonl"
else
    fail "runner did not emit curator_cannot_start into ambient.jsonl"
fi

if grep -q '"status":"cannot_start"' "$SANDBOX/.chump-locks/curator-supervisor-last-pass.json" 2>/dev/null; then
    ok "runner records cannot_start in the curator-* artifact"
else
    fail "runner left no curator-* artifact describing the failure"
fi

# ── 5. a runner that CAN start writes the artifact ────────────────────────
echo
echo "[live: a healthy pass leaves a curator-* artifact]"
rm -f "$SANDBOX/.chump-locks/curator-supervisor-last-pass.json"
: > "$SANDBOX/.chump-locks/ambient.jsonl"
FAKE_BIN="$SANDBOX/fake-supervisor"
printf '#!/bin/bash\necho "fake supervisor pass"\nexit 0\n' > "$FAKE_BIN"
chmod +x "$FAKE_BIN"

set +e
( cd "$SANDBOX" && \
  CHUMP_CURATOR_SUPERVISOR_BIN="$FAKE_BIN" \
  bash scripts/ops/curator-supervisor-run.sh ) >"$SANDBOX/ok.out" 2>&1
OK_RC=$?
set -e

[[ "$OK_RC" -eq 0 ]] && ok "runner exits 0 on a successful pass" \
                     || fail "runner exited $OK_RC on a successful pass ($(tail -3 "$SANDBOX/ok.out"))"

if grep -q '"status":"ok"' "$SANDBOX/.chump-locks/curator-supervisor-last-pass.json" 2>/dev/null; then
    ok "successful pass writes .chump-locks/curator-supervisor-last-pass.json"
else
    fail "successful pass wrote no curator-* artifact"
fi

# A non-zero supervisor must also be reported, not swallowed.
printf '#!/bin/bash\necho boom >&2\nexit 3\n' > "$FAKE_BIN"
chmod +x "$FAKE_BIN"
set +e
( cd "$SANDBOX" && \
  CHUMP_CURATOR_SUPERVISOR_BIN="$FAKE_BIN" \
  bash scripts/ops/curator-supervisor-run.sh ) >"$SANDBOX/bad.out" 2>&1
BAD_RC=$?
set -e
if [[ "$BAD_RC" -ne 0 ]] && grep -q 'curator_pass_failed' "$SANDBOX/bad.out"; then
    ok "a supervisor exiting non-zero is reported (rc=$BAD_RC + ALERT)"
else
    fail "a non-zero supervisor exit was not reported (rc=$BAD_RC)"
fi

# ── 6. the existing watchdog grades the curator ───────────────────────────
echo
echo "[watchdog integration]"
if grep -qE 'TARGETS=\(.*curator-supervisor.*\)' "$WATCHDOG"; then
    ok "reaper watchdog default TARGETS includes curator-supervisor"
else
    fail "reaper watchdog does not grade curator-supervisor"
fi
if grep -qE 'curator-supervisor\)[[:space:]]*echo' "$WATCHDOG"; then
    ok "watchdog threshold_secs has an explicit curator-supervisor case"
else
    fail "watchdog threshold_secs missing curator-supervisor case"
fi
if grep -q 'launchd_exit_status' "$WATCHDOG"; then
    ok "watchdog reads the launchd exit status (catches spawn-time 78)"
else
    fail "watchdog cannot see exit 78 — heartbeat freshness alone misses it"
fi

# The runner must stamp the heartbeat path the watchdog actually reads.
if grep -q 'reaper_setup curator-supervisor' "$RUNNER"; then
    ok "runner calls reaper_setup curator-supervisor (stamps the graded path)"
else
    fail "runner does not use reaper instrumentation — watchdog would see nothing"
fi

# ── 7. fleet-brief reports it, ungated ────────────────────────────────────
echo
echo "[fleet-brief]"
if grep -q 'Curator: last pass' "$BRIEF"; then
    ok "fleet-brief prints a Curator line"
else
    fail "fleet-brief has no Curator line"
fi
if grep -q 'CURATOR SILENT' "$BRIEF"; then
    ok "fleet-brief has a loud CURATOR SILENT banner"
else
    fail "fleet-brief has no loud banner for curator silence"
fi
# INFRA-2040's dead-daemon list is ANDed with _merge_stale, so it never fired
# on a busy fleet. The curator line must not inherit that gate. Strip comment
# lines first — the block explains _merge_stale in prose on purpose.
if awk '/RESILIENT-246: curator liveness/,/Auto-fixed counts/' "$BRIEF" \
     | grep -v '^[[:space:]]*#' | grep -q '_merge_stale'; then
    fail "curator liveness CODE is gated on _merge_stale — the bug that hid this"
else
    ok "curator liveness is not gated behind merge staleness"
fi
# And the printed line itself must not sit behind the silent-fleet-death gate.
if awk '/RESILIENT-246: always print curator liveness/,/^fi$/' "$BRIEF" \
     | grep -v '^[[:space:]]*#' | grep -qE '_silent_fleet_dead|_merge_stale'; then
    fail "the Curator render line is conditional on an unrelated signal"
else
    ok "the Curator render line prints unconditionally"
fi

# ── 8. installer guards ───────────────────────────────────────────────────
echo
echo "[installer]"
bash -n "$INSTALLER" 2>/dev/null && ok "installer passes bash -n" || fail "installer has a syntax error"
if grep -q 'Refusing to install' "$INSTALLER"; then
    ok "installer refuses a plist that points at a target/ artifact"
else
    fail "installer has no guard against the exit-78 plist config"
fi
if grep -q 'last_exit_status' "$INSTALLER"; then
    ok "installer verifies the real exit status, not just 'loaded'"
else
    fail "installer still treats 'loaded' as healthy (exit 78 is loaded too)"
fi
if grep -q 'cargo/bin/chump-curator-supervisor' "$INSTALLER"; then
    ok "installer places the binary at the stable ~/.cargo/bin path"
else
    fail "installer does not install to a stable path"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
