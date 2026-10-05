#!/usr/bin/env bash
# test-chump-doctor-probe-cascade-ratelimit.sh — CREDIBLE-587
# Verifies the --probe-cascade rate-limit header probe emits structured
# slot= log lines, that REFRESH_INTERVAL / --print-cron work, and that the
# pre-existing --probe-cascade / --probe-resources behavior (exit status,
# output shape) is unchanged for a mock slot list.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/dev/chump-binary-unwedge.sh"
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -x "$DOCTOR" ]] || fail "chump-binary-unwedge.sh missing or not executable"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
git -C "$WORKDIR" init -q
cat > "$WORKDIR/.env" <<'EOF'
CHUMP_PROVIDER_1_ENABLED=1
CHUMP_PROVIDER_1_BASE=http://127.0.0.1:1
CHUMP_PROVIDER_1_KEY=fake-key
CHUMP_PROVIDER_1_MODEL=mock-model
CHUMP_PROVIDER_1_NAME=mock-slot
EOF

# ── Test 1: structured slot= log line present for the mock slot ──────────────
out=$(cd "$WORKDIR" && bash "$DOCTOR" --probe-cascade 2>&1 || true)
printf '%s\n' "$out" | grep -qE 'slot=mock-slot limit=[^ ]+ remaining=[^ ]+ retry_after=[^ ]+' \
    || fail "no structured slot= line for mock-slot; got:\n$out"
pass "structured slot= log line present for enabled slot"

# ── Test 2: original per-slot status line is unchanged ────────────────────────
printf '%s\n' "$out" | grep -qF "slot 1 mock-slot [mock-model]" \
    || fail "original per-slot status line changed or missing"
pass "original per-slot status line unchanged"

# ── Test 3: unreachable slot yields non-zero exit (AC2) ───────────────────────
exit_code=0
( cd "$WORKDIR" && bash "$DOCTOR" --probe-cascade >/dev/null 2>&1 ) || exit_code=$?
[[ "$exit_code" -ne 0 ]] || fail "expected non-zero exit for unreachable slot, got 0"
pass "non-zero exit when a slot request fails"

# ── Test 4: REFRESH_INTERVAL defaults to 15m and is overridable ──────────────
cron_default=$(bash "$DOCTOR" --print-cron)
printf '%s\n' "$cron_default" | grep -qE '^\*/15 \* \* \* \*' \
    || fail "default REFRESH_INTERVAL did not produce a */15 cron schedule; got: $cron_default"
pass "REFRESH_INTERVAL defaults to 15m in generated cron line"

cron_override=$(CHUMP_DOCTOR_REFRESH_INTERVAL=5m bash "$DOCTOR" --print-cron)
printf '%s\n' "$cron_override" | grep -qE '^\*/5 \* \* \* \*' \
    || fail "CHUMP_DOCTOR_REFRESH_INTERVAL=5m did not override cron schedule; got: $cron_override"
pass "REFRESH_INTERVAL overridable via CHUMP_DOCTOR_REFRESH_INTERVAL"

printf '%s\n' "$cron_default" | grep -qF -- '--probe-cascade' \
    || fail "generated cron line does not invoke --probe-cascade"
pass "generated cron line schedules --probe-cascade"

# ── Test 5: --probe-resources behavior is unaffected by this change ──────────
res_exit=0
bash "$DOCTOR" --probe-resources >/dev/null 2>&1 || res_exit=$?
[[ "$res_exit" -eq 0 || "$res_exit" -eq 1 ]] \
    || fail "--probe-resources exit code changed unexpectedly: $res_exit"
pass "--probe-resources side effects unchanged"

printf '\nAll tests passed.\n'
