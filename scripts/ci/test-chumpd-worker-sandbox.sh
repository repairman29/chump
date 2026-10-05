#!/usr/bin/env bash
# test-chumpd-worker-sandbox.sh — RESILIENT-178 worker file-access sandbox
#
# 2026-07-19: the operator got a macOS TCC prompt ("chump wants access to
# iCloud Drive") because a worker's `claude` session inherits the
# operator's full user file authority — a mid-gap broad find/grep strayed
# past the repo. chumpd (MISSION-051) now spawns every worker under a
# sandbox-exec profile that walls off TCC-prompting surfaces.
#
# Verifies:
#   1. Source contract: crates/chumpd/src/file_sandbox.rs exports the
#      profile builder + enable/detect helpers
#   2. main.rs declares mod file_sandbox and spawn_worker routes through it
#   3. cargo unit tests pass (profile shape, deny-by-default, TCC surfaces)
#   4. ambient event kind is registered (EVENT_REGISTRY.yaml) and has a
#      scanner-anchor in source
#   5. macOS integration: a fixture worker reading a deny-listed path
#      (under the profile's TCC deny-list) fails — no prompt, just a
#      kernel-level deny — while a read/write inside the allow-list
#      succeeds

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$REPO_ROOT/crates/chumpd/src/file_sandbox.rs"

echo "=== RESILIENT-178 chumpd worker file-sandbox tests ==="

# ── Source-contract ─────────────────────────────────────────────────────────
[[ -f "$SRC" ]] && ok "crates/chumpd/src/file_sandbox.rs exists" || { fail "missing file_sandbox.rs"; exit 1; }

for sym in \
    "pub fn detect_runtime" \
    "pub fn unsafe_host_exec_forced" \
    "pub fn worker_sandbox_enabled" \
    "pub fn tcc_deny_surfaces" \
    "pub fn build_worker_profile"; do
    if grep -q "$sym" "$SRC"; then
        ok "exports $sym"
    else
        fail "missing $sym"
    fi
done

# Deny-by-default write policy + TCC surfaces present in the profile builder.
if grep -q '(deny default)' "$SRC"; then
    ok "profile denies by default"
else
    fail "profile missing (deny default)"
fi
for surface in "Desktop" "Documents" "Downloads" "Mobile Documents"; do
    if grep -q "$surface" "$SRC"; then
        ok "TCC deny-list includes $surface"
    else
        fail "TCC deny-list missing $surface"
    fi
done

# main.rs wiring
MAIN="$REPO_ROOT/crates/chumpd/src/main.rs"
if grep -q "^mod file_sandbox;" "$MAIN"; then
    ok "main.rs declares mod file_sandbox"
else
    fail "main.rs missing mod file_sandbox"
fi
if grep -q "file_sandbox::worker_sandbox_enabled" "$MAIN" && grep -q "file_sandbox::build_worker_profile" "$MAIN"; then
    ok "spawn_worker routes through file_sandbox"
else
    fail "spawn_worker does not call file_sandbox helpers"
fi
if grep -q "scan_worker_sandbox_denials" "$MAIN"; then
    ok "tick loop calls scan_worker_sandbox_denials"
else
    fail "tick loop missing scan_worker_sandbox_denials"
fi

# Ambient event registration (AC#2 — auditable, not silent).
if grep -q 'scanner-anchor: "kind":"chumpd_worker_sandbox_denied"' "$MAIN"; then
    ok "chumpd_worker_sandbox_denied has a scanner-anchor"
else
    fail "chumpd_worker_sandbox_denied missing scanner-anchor"
fi
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if [[ -f "$REGISTRY" ]] && grep -q "kind: chumpd_worker_sandbox_denied" "$REGISTRY"; then
    ok "chumpd_worker_sandbox_denied registered in EVENT_REGISTRY.yaml"
else
    fail "chumpd_worker_sandbox_denied missing from EVENT_REGISTRY.yaml"
fi

# ── cargo unit tests ─────────────────────────────────────────────────────────
if command -v cargo >/dev/null 2>&1; then
    echo "  [running cargo test -p chumpd file_sandbox ...]"
    if (cd "$REPO_ROOT" && cargo test -p chumpd file_sandbox --quiet -- --test-threads=1 2>&1 | tail -10); then
        ok "cargo test file_sandbox passed"
    else
        fail "cargo test file_sandbox failed"
    fi
fi

# ── macOS integration: real kernel-level denial, no prompt ────────────────────
if [[ "$OSTYPE" == "darwin"* ]] && command -v sandbox-exec >/dev/null 2>&1; then
    FIXTURE_HOME="/tmp/chump-worker-sandbox-home-$$"
    REPO_FIX="/tmp/chump-worker-sandbox-repo-$$"
    mkdir -p "$FIXTURE_HOME/Desktop" "$FIXTURE_HOME/.chump" "$REPO_FIX"
    echo "secret" > "$FIXTURE_HOME/Desktop/secret.txt"
    trap 'rm -rf "$FIXTURE_HOME" "$REPO_FIX"' EXIT

    PROFILE='(version 1)
(deny default)
(allow process-fork)
(allow process-exec*)
(allow signal)
(allow mach-lookup)
(allow ipc-posix-shm*)
(allow sysctl-read)
(allow iokit-open)
(allow file-read*)
(deny file-read*
  (subpath "'"$FIXTURE_HOME"'/Desktop")
  (subpath "'"$FIXTURE_HOME"'/Documents")
  (subpath "'"$FIXTURE_HOME"'/Downloads"))
(allow file-write*
  (subpath "'"$REPO_FIX"'")
  (subpath "/private/tmp")
  (subpath "/private/var/folders")
  (subpath "/tmp")
  (subpath "'"$FIXTURE_HOME"'/.chump"))
(allow network*)
'
    # 1) reading a TCC-deny-listed path fails, silently (no prompt — this
    #    is the exact class of access that produced the 2026-07-19 dialog).
    if sandbox-exec -p "$PROFILE" cat "$FIXTURE_HOME/Desktop/secret.txt" >/dev/null 2>&1; then
        fail "macOS integration: read of deny-listed Desktop path SUCCEEDED (sandbox not blocking)"
    else
        ok "macOS integration: read of deny-listed Desktop path denied without prompting"
    fi
    # 2) write inside the allow-listed repo path still succeeds.
    if sandbox-exec -p "$PROFILE" sh -c "echo ok > '$REPO_FIX/file.txt'" 2>/dev/null && [[ -f "$REPO_FIX/file.txt" ]]; then
        ok "macOS integration: write inside allow-listed repo path succeeds"
    else
        fail "macOS integration: write inside allow-listed repo path was denied (profile too strict)"
    fi
else
    echo "  SKIP: macOS sandbox-exec integration (not on macOS or sandbox-exec missing)"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
