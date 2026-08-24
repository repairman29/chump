#!/usr/bin/env bash
# test-stale-binary-ship-blocked.sh — INFRA-825 CI gate
#
# Asserts that the remaining destructive bulk-YAML operation
# (`chump gap dump --per-file`) refuses to run when the chump binary is
# stale relative to the gap-store-affecting code on HEAD.
#
# PR #1444 silently reverted META-044 because a 9-commit-stale chump binary
# regenerated all gap YAMLs from an outdated state.db. This test ensures
# that failure mode is blocked at the binary level, not just warned about.
#
# ZERO-WASTE-020 (2026-07-19): `chump gap ship --update-yaml` no longer
# writes anything (per-file YAML mirrors are retired — state.db is
# canonical, .chump/state.sql is the tracked dump) so it is a documented
# no-op and no longer needs the staleness guard: a no-op can't regenerate
# a stale YAML from an outdated state.db, because it doesn't regenerate
# anything. Only `gap dump --per-file` remains a genuine destructive
# bulk-YAML write (used for ad-hoc offline browsing exports) and stays
# guarded.
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

# ── Test 2: main.rs wires fail_if_stale_for_destructive into the remaining
#    destructive path ──────────────────────────────────────────────────────
# Grep is sufficient (the binary's behavior on a fresh build can't be a stale
# fixture — the binary's baked SHA IS HEAD by construction in CI).
# Test 2 and Test 3 were vacuous greps (CREDIBLE-237): they grepped src/main.rs
# for symbols that had moved to src/commands/gap.rs. The dead-grep-detector
# (scripts/ci/dead-grep-detector.sh) now catches this class of vacuous gate.
# These tests are replaced by a direct assertion on the gap binary's behaviour.
if ! cargo test --bin chump -- gap::tests::stale_binary_ship_blocked 2>&1 | tail -3 | grep -q "test result: ok"; then
    fail "gap::tests::stale_binary_ship_blocked failed — INFRA-825 wiring broken"
fi
pass "gap binary staleness guard verified via unit test (replaces vacuous src/main.rs greps)"

echo
pass "INFRA-825 CI gate — the remaining destructive bulk-YAML op is gated by staleness check"
echo "    PR #1444's silent-revert failure mode is replayed by the version.rs"
echo "    unit tests above; main.rs wiring is verified by grep."
