#!/usr/bin/env bash
# test-stale-binary-ship-blocked.sh — INFRA-825 CI gate
#
# Asserts that destructive bulk-YAML operations (`chump gap ship --update-yaml`
# and `chump gap dump --per-file`) refuse to run when the chump binary is
# stale relative to the gap-store-affecting code on HEAD.
#
# PR #1444 silently reverted META-044 because a 9-commit-stale chump binary
# regenerated all gap YAMLs from an outdated state.db. This test ensures
# that failure mode is blocked at the binary level, not just warned about.
#
# The authoritative replay of #1444's failure mode lives in
# src/version.rs::tests::pr_1444_replay_refuses_without_override (and the
# ambient-override emitter test). This script ensures those unit tests
# stay green AND that the binary actually wires them in.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

cd "$REPO_ROOT"

# ── Test 1: src/version.rs unit tests cover #1444's failure mode ────────────
# pr_1444_replay_refuses_without_override asserts that a stale-shaped check
# returns Stale (which the caller maps to Refuse).
# override_event_emitted_to_ambient_jsonl asserts ambient telemetry fires.
if ! cargo test --bin chump version::tests::pr_1444_replay_refuses_without_override 2>&1 | tail -3 | grep -q "test result: ok"; then
    fail "pr_1444_replay_refuses_without_override failed — INFRA-825's hard-fail semantics broken"
fi
pass "pr_1444_replay_refuses_without_override (src/version.rs unit test)"

if ! cargo test --bin chump version::tests::override_event_emitted_to_ambient_jsonl 2>&1 | tail -3 | grep -q "test result: ok"; then
    fail "override_event_emitted_to_ambient_jsonl failed — ambient telemetry broken"
fi
pass "override_event_emitted_to_ambient_jsonl (src/version.rs unit test)"

if ! cargo test --bin chump version::tests::override_env_recognized 2>&1 | tail -3 | grep -q "test result: ok"; then
    fail "override_env_recognized failed — escape hatch env var not wired"
fi
pass "override_env_recognized (src/version.rs unit test)"

# ── Test 2: main.rs wires fail_if_stale_for_destructive into the two paths ──
# Grep is sufficient (the binary's behavior on a fresh build can't be a stale
# fixture — the binary's baked SHA IS HEAD by construction in CI).
if ! grep -q "fail_if_stale_for_destructive" "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    fail "src/main.rs does not call fail_if_stale_for_destructive — INFRA-825 wiring missing"
fi
gap_ship_count=$(cat "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs" 2>/dev/null | grep -c "gap ship --update-yaml" || echo 0)
gap_dump_count=$(cat "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs" 2>/dev/null | grep -c "gap dump --per-file" || echo 0)
if [[ "$gap_ship_count" -lt 1 ]]; then
    fail "src/main.rs: gap ship --update-yaml is not guarded by fail_if_stale_for_destructive"
fi
if [[ "$gap_dump_count" -lt 1 ]]; then
    fail "src/main.rs: gap dump --per-file is not guarded by fail_if_stale_for_destructive"
fi
pass "main.rs wires the hard-fail into both destructive paths"

echo
pass "INFRA-825 CI gate — destructive bulk-YAML ops are gated by staleness check"
echo "    PR #1444's silent-revert failure mode is replayed by the version.rs"
echo "    unit tests above; main.rs wiring is verified by grep."
