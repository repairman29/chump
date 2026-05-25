#!/usr/bin/env bash
# test-md-links-loop.sh — INFRA-1925: smoke test for scripts/coord/md-links-loop.sh.
#
# Exercises each subcommand on a synthetic happy path and asserts the
# documented exit codes (0 = actionable/ok, 1 = clean, 2 = bad input,
# 3 = missing path). Also validates the ambient emission lands in
# CHUMP_AMBIENT_LOG with the right kind tag (md_links_heartbeat).
# Bonus: creates a tiny tmp docs tree with one broken link and one clean
# file, runs scan against it, and asserts the broken link is reported.

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
LOOP_SCRIPT="$REPO_ROOT/scripts/coord/md-links-loop.sh"

if [[ ! -f "$LOOP_SCRIPT" ]]; then
    printf 'FAIL: %s not found\n' "$LOOP_SCRIPT" >&2
    exit 1
fi

# Ensure the script is executable
chmod +x "$LOOP_SCRIPT"

_pass=0
_fail=0

_ok()  { printf '  ok  %s\n' "$*"; _pass=$((_pass + 1)); }
_bad() { printf '  FAIL: %s\n' "$*" >&2; _fail=$((_fail + 1)); }

# ── Test 1: bash -n syntax check ─────────────────────────────────────────────
printf 'Test 1: bash -n syntax check...\n'
if bash -n "$LOOP_SCRIPT" 2>/dev/null; then
    _ok "bash -n passes"
else
    _bad "bash -n failed — syntax error in $LOOP_SCRIPT"
fi

# ── Test 2: help exits 0 ─────────────────────────────────────────────────────
printf 'Test 2: help subcommand...\n'
_rc=0
"$LOOP_SCRIPT" help >/dev/null 2>&1 || _rc=$?
if (( _rc == 0 )); then
    _ok "help exits 0"
else
    _bad "help should exit 0, got $_rc"
fi

# ── Test 3: --help alias exits 0 ─────────────────────────────────────────────
printf 'Test 3: --help alias...\n'
_rc=0
"$LOOP_SCRIPT" --help >/dev/null 2>&1 || _rc=$?
if (( _rc == 0 )); then
    _ok "--help exits 0"
else
    _bad "--help should exit 0, got $_rc"
fi

# ── Test 4: heartbeat exits 0 + emits kind ───────────────────────────────────
printf 'Test 4: heartbeat subcommand...\n'
_dir4="$(mktemp -d)"
_amb4="$_dir4/ambient.jsonl"
_rc=0
CHUMP_AMBIENT_LOG="$_amb4" \
CHUMP_SESSION_ID="test-md-links-heartbeat" \
"$LOOP_SCRIPT" heartbeat >/dev/null 2>&1 || _rc=$?

if (( _rc == 0 )); then
    _ok "heartbeat exits 0"
else
    _bad "heartbeat should exit 0, got $_rc"
fi

if grep -q '"kind":"md_links_heartbeat"' "$_amb4" 2>/dev/null; then
    _ok "heartbeat emits md_links_heartbeat kind"
else
    _bad "heartbeat should emit md_links_heartbeat to ambient log"
fi
rm -rf "$_dir4"

# ── Test 5: unknown subcommand exits 2 ───────────────────────────────────────
printf 'Test 5: unknown subcommand exits 2...\n'
_rc=0
"$LOOP_SCRIPT" __no_such_command__ >/dev/null 2>&1 || _rc=$?
if (( _rc == 2 )); then
    _ok "unknown subcommand exits 2"
else
    _bad "unknown subcommand should exit 2, got $_rc"
fi

# ── Test 6: scan on missing path exits 3 ─────────────────────────────────────
printf 'Test 6: scan on missing path exits 3...\n'
_rc=0
CHUMP_AMBIENT_LOG="/dev/null" \
"$LOOP_SCRIPT" scan /tmp/__no_such_dir_xyz_1925__ >/dev/null 2>&1 || _rc=$?
if (( _rc == 3 )); then
    _ok "scan missing path exits 3"
else
    _bad "scan missing path should exit 3, got $_rc"
fi

# ── Test 7: scan clean dir exits 1 ───────────────────────────────────────────
printf 'Test 7: scan clean doc tree exits 1 (no broken links)...\n'
_dir7="$(mktemp -d)"
_amb7="$_dir7/ambient.jsonl"
# Create two files with a valid cross-reference
mkdir -p "$_dir7/docs/sub"
cat > "$_dir7/docs/foo.md" <<'MD'
# Foo

See [bar](sub/bar.md) for details.
MD
cat > "$_dir7/docs/sub/bar.md" <<'MD'
# Bar

This file exists.
MD

_rc=0
CHUMP_AMBIENT_LOG="$_amb7" \
CHUMP_SESSION_ID="test-md-links-clean" \
CHUMP_MD_LINKS_DOCS="$_dir7/docs" \
"$LOOP_SCRIPT" scan "$_dir7/docs" >/dev/null 2>&1 || _rc=$?

if (( _rc == 1 )); then
    _ok "clean scan exits 1"
else
    _bad "clean scan should exit 1 (no broken links), got $_rc"
fi
rm -rf "$_dir7"

# ── Test 8: scan dir with broken link exits 0 + reports it ──────────────────
printf 'Test 8: scan doc tree with broken link exits 0 + reports broken link...\n'
_dir8="$(mktemp -d)"
_amb8="$_dir8/ambient.jsonl"
mkdir -p "$_dir8/docs"
# This file references a file that does NOT exist
cat > "$_dir8/docs/broken.md" <<'MD'
# Broken

See [missing file](nonexistent.md) for details.
MD

_rc=0
_out8="$(
    CHUMP_AMBIENT_LOG="$_amb8" \
    CHUMP_SESSION_ID="test-md-links-broken" \
    CHUMP_MD_LINKS_DOCS="$_dir8/docs" \
    "$LOOP_SCRIPT" scan "$_dir8/docs" 2>/dev/null
)" || _rc=$?

if (( _rc == 0 )); then
    _ok "scan with broken link exits 0"
else
    _bad "scan with broken link should exit 0, got $_rc"
fi

if printf '%s\n' "$_out8" | grep -q 'BROKEN'; then
    _ok "scan reports BROKEN line for missing target"
else
    _bad "scan should report BROKEN line; got: $_out8"
fi

if printf '%s\n' "$_out8" | grep -q 'nonexistent.md'; then
    _ok "scan names the broken target file"
else
    _bad "scan should name nonexistent.md in output; got: $_out8"
fi
rm -rf "$_dir8"

# ── Test 9: scan emits md_links_scan_done to ambient ─────────────────────────
printf 'Test 9: scan emits md_links_scan_done to ambient...\n'
_dir9="$(mktemp -d)"
_amb9="$_dir9/ambient.jsonl"
mkdir -p "$_dir9/docs"
printf '# Simple\n\nNo links here.\n' > "$_dir9/docs/simple.md"

CHUMP_AMBIENT_LOG="$_amb9" \
CHUMP_SESSION_ID="test-md-links-emit" \
CHUMP_MD_LINKS_DOCS="$_dir9/docs" \
"$LOOP_SCRIPT" scan "$_dir9/docs" >/dev/null 2>&1 || true

if grep -q '"kind":"md_links_scan_done"' "$_amb9" 2>/dev/null; then
    _ok "scan emits md_links_scan_done kind"
else
    _bad "scan should emit md_links_scan_done to ambient log"
fi
rm -rf "$_dir9"

# ── Test 10: tick subcommand recognized (exits 0 or 1, not 2) ────────────────
printf 'Test 10: tick subcommand recognized...\n'
_dir10="$(mktemp -d)"
_rc=0
CHUMP_AMBIENT_LOG="/dev/null" \
CHUMP_MD_LINKS_DOCS="$_dir10" \
"$LOOP_SCRIPT" tick >/dev/null 2>&1 || _rc=$?
rm -rf "$_dir10"
if (( _rc != 2 )); then
    _ok "tick subcommand recognized (exit $_rc, not 2)"
else
    _bad "tick should not exit 2 (bad subcommand); got $_rc"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$_pass" "$_fail"
if (( _fail > 0 )); then
    exit 1
fi
exit 0
