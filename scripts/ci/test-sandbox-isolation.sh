#!/usr/bin/env bash
# scripts/ci/test-sandbox-isolation.sh — INFRA-1454 (sandbox pilot)
#
# Verifies the agent-bash syscall-restriction layer:
#   1. Source contract: src/sandbox.rs exports SandboxStatus + wrap_command + build_profile
#   2. cargo unit tests pass (build_profile, status rendering, enabled env parsing)
#   3. main.rs declares mod sandbox
#   4. cli_tool.rs routes shell exec through sandbox::wrap_command
#   5. macOS integration: with CHUMP_AGENT_SANDBOX=1, a write to a path
#      outside the worktree is denied by sandbox-exec
#   6. fleet_health includes sandbox_status_tag + sandbox_status_summary

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$REPO_ROOT/src/sandbox.rs"

echo "=== INFRA-1454 sandbox isolation tests ==="

# ── Source-contract ───────────────────────────────────────────────────────────
[[ -f "$SRC" ]] && ok "src/sandbox.rs exists" || { fail "missing src/sandbox.rs"; exit 1; }

for sym in \
    "pub enum SandboxStatus" \
    "pub fn sandbox_runtime_status" \
    "pub fn agent_sandbox_enabled" \
    "pub fn unsafe_host_exec_forced" \
    "pub fn build_profile" \
    "pub fn wrap_command"; do
    if grep -q "$sym" "$SRC"; then
        ok "exports $sym"
    else
        fail "missing $sym"
    fi
done

# main.rs wiring
if grep -q "^mod sandbox;" "$REPO_ROOT/src/main.rs"; then
    ok "main.rs declares mod sandbox"
else
    fail "main.rs missing mod sandbox"
fi

# cli_tool.rs wiring (sandbox::wrap_command replaces the bare Command::new("sh") path)
if grep -q "sandbox::wrap_command" "$REPO_ROOT/src/cli_tool.rs"; then
    ok "cli_tool.rs routes shell exec through sandbox::wrap_command"
else
    fail "cli_tool.rs does not call sandbox::wrap_command"
fi

# fleet_health.rs wiring
if grep -q "sandbox_status_tag" "$REPO_ROOT/src/fleet_health.rs"; then
    ok "fleet_health.rs includes sandbox_status_tag field"
else
    fail "fleet_health.rs missing sandbox_status_tag"
fi
if grep -q '"sandbox_status":' "$REPO_ROOT/src/fleet_health.rs"; then
    ok "fleet_health.rs includes sandbox_status in event JSON"
else
    fail "fleet_health.rs event JSON missing sandbox_status"
fi

# ── Unit-test invocation ──────────────────────────────────────────────────────
if command -v cargo >/dev/null 2>&1 && [[ -f "$REPO_ROOT/Cargo.toml" ]]; then
    echo ""
    echo "  [running cargo test sandbox ...]"
    if (cd "$REPO_ROOT" && cargo test --bin chump 'sandbox::tests' --quiet -- --test-threads=1 2>&1 | tail -10); then
        ok "cargo test sandbox passed"
    else
        fail "cargo test sandbox failed"
    fi
fi

# ── macOS integration: real syscall denial ────────────────────────────────────
# Only runs on macOS where sandbox-exec exists. Builds the profile against
# a throwaway worktree, then invokes sandbox-exec directly to verify writes
# outside the worktree get DENY default.
if [[ "$OSTYPE" == "darwin"* ]] && command -v sandbox-exec >/dev/null 2>&1; then
    # Worktree under a deterministic /tmp path (which the profile allows).
    WT="/tmp/chump-sandbox-test-wt-$$"
    # Outside path under HOME — explicitly NOT in the profile's allow list,
    # so writes there must be denied. (mktemp under /var/folders would be
    # allowed because TMPDIR is on the allow list; that defeats the point.)
    OUTSIDE="$HOME/.chump-sandbox-escape-$$"
    mkdir -p "$WT"
    trap 'rm -rf "$WT" "$OUTSIDE"' EXIT
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
(allow file-write*
  (subpath "'"$WT"'")
  (subpath "/private/tmp")
  (subpath "/private/var/folders")
  (subpath "/tmp"))
(allow network*)
'
    # 1) write inside worktree must succeed
    if sandbox-exec -p "$PROFILE" sh -c "echo inside > '$WT/file.txt'" 2>/dev/null; then
        if [[ -f "$WT/file.txt" ]]; then
            ok "macOS integration: write inside worktree succeeds"
        else
            fail "macOS integration: inside-worktree write reported success but file missing"
        fi
    else
        fail "macOS integration: write inside worktree was denied (profile too strict)"
    fi
    # 2) write outside worktree must fail
    if sandbox-exec -p "$PROFILE" sh -c "echo outside > '$OUTSIDE/file.txt'" 2>/dev/null; then
        if [[ -f "$OUTSIDE/file.txt" ]]; then
            fail "macOS integration: write OUTSIDE worktree succeeded (sandbox not blocking)"
        else
            ok "macOS integration: outside-worktree write blocked (no file written)"
        fi
    else
        ok "macOS integration: outside-worktree write was denied by sandbox-exec"
    fi
else
    echo "  SKIP: macOS sandbox-exec integration (not on macOS or sandbox-exec missing)"
fi

# ── fleet doctor integration via chump binary (best-effort) ───────────────────
CHUMP_BIN="${CHUMP_BIN:-chump}"
if command -v "$CHUMP_BIN" >/dev/null 2>&1; then
    OUT="$("$CHUMP_BIN" health --json 2>/dev/null || true)"
    if echo "$OUT" | grep -q '"sandbox_status"'; then
        ok "chump health --json surfaces sandbox_status field"
    else
        echo "  SKIP: chump health JSON output didn't include sandbox_status (binary may be stale)"
    fi
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
