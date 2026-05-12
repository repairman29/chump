#!/usr/bin/env bash
# test-credential-sanitization.sh — INFRA-871
#
# Exercises scripts/coord/scrub-credential-logs.sh on synthetic ambient
# fixtures. Asserts known credential patterns are flagged and allowlisted
# placeholders are not.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRUB="$REPO_ROOT/scripts/coord/scrub-credential-logs.sh"

[[ -x "$SCRUB" ]] || { echo "FAIL: $SCRUB not executable"; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
AMB="$TMP/ambient.jsonl"

run_scrub() {
  CHUMP_AMBIENT_LOG="$AMB" \
  CHUMP_SCRUB_PATHS="$AMB" \
  REPO_ROOT="$REPO_ROOT" \
  bash "$SCRUB" "$@" 2>&1
}

# ── Scenario 1: clean log → exit 0 ──────────────────────────────────────────
: > "$AMB"
echo '{"ts":"2026-05-12T00:00:00Z","kind":"session_start","gap":"INFRA-871"}' >> "$AMB"
out=$(run_scrub) || fail "clean log should pass (out: $out)"
echo "$out" | grep -q "0 leaks" || fail "clean log: missing '0 leaks' confirmation"
ok "scenario 1: clean log → exit 0"

# ── Scenario 2: ghp_ token leaked → exit non-zero ───────────────────────────
: > "$AMB"
echo 'leaked GH_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789AB visible in stdout' >> "$AMB"
if out=$(run_scrub 2>&1); then
  fail "ghp_ token should fail the scrub (out: $out)"
fi
echo "$out" | grep -q "github_classic" || fail "ghp_ token: missing pattern name 'github_classic'"
ok "scenario 2: ghp_ token detected"

# ── Scenario 3: sk-ant-api token leaked → exit non-zero ─────────────────────
: > "$AMB"
echo 'header Authorization=Bearer sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' >> "$AMB"
if out=$(run_scrub 2>&1); then
  fail "anthropic API key should fail the scrub"
fi
echo "$out" | grep -q "anthropic_api" || fail "anthropic key: missing pattern name"
ok "scenario 3: anthropic_api token detected"

# ── Scenario 4: REDACTED placeholder NOT flagged (allowlist) ────────────────
: > "$AMB"
echo 'note GH_TOKEN=ghp_REDACTEDREDACTEDREDACTEDREDACTEDREDACTEDREDACTED visible' >> "$AMB"
out=$(run_scrub) || fail "REDACTED placeholder should not fail (out: $out)"
ok "scenario 4: REDACTED placeholder allowlisted"

# ── Scenario 5: --report emits credential_scrub_run event ───────────────────
: > "$AMB"
echo 'leak ghp_abcdefghijklmnopqrstuvwxyz0123456789AB' >> "$AMB"
out=$(run_scrub --report 2>&1 || true)
grep -q '"kind":"credential_scrub_run"' "$AMB" \
  || fail "report mode: credential_scrub_run event not emitted"
ok "scenario 5: --report emits credential_scrub_run event"

# ── Scenario 6: AWS access key leaked ──────────────────────────────────────
: > "$AMB"
echo 'aws AKIAABCDEFGHIJKLMNOP creds' >> "$AMB"
if out=$(run_scrub 2>&1); then
  fail "AWS access key should fail the scrub"
fi
echo "$out" | grep -q "aws_access_key" || fail "AWS key: missing pattern name"
ok "scenario 6: AWS access key detected"

echo
echo "=== test-credential-sanitization.sh PASSED ==="
