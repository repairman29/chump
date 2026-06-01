#!/usr/bin/env bash
# scripts/ci/test-chump-config.sh — INFRA-2371 smoke test
#
# Asserts that `chump config` (and `chump config show`, `chump config --json`)
# produces the expected diagnostic sections without invoking an LLM. Replaces
# the broken behavior where bare `chump config` fell through to the LLM gen
# path and 400'd from Gemini.
#
# Run locally:
#   scripts/ci/test-chump-config.sh
#
# Exit codes: 0 = pass; 1 = test failed; 2 = build failed.

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# Build the binary (Rust build is the slow path — only do it once per run).
if ! cargo build -p chump --bin chump --quiet 2>&1 | tail -20; then
  echo "build failed — cannot run test-chump-config.sh"
  exit 2
fi

CHUMP="${CHUMP_BIN:-$ROOT/target/debug/chump}"
if [[ ! -x "$CHUMP" ]]; then
  echo "binary not found at $CHUMP"
  exit 2
fi

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Run with a clean-ish env so we exercise the missing-token branches too.
# Keep PATH + HOME (test still wants the nudge branch tested separately).
out=$("$CHUMP" config show 2>&1)
status=$?

if [[ $status -ne 0 ]]; then
  echo "$out" >&2
  fail "chump config show exited non-zero ($status)"
fi

# Expected sections — confirm each is in the output. Order matters for the
# human-readable mode (snapshot prints CONFIG FILE, PRIVACY, AUTH, PROVIDER
# CASCADE, MCP SERVERS in that order).
for section in "chump config snapshot" "CONFIG FILE" "PRIVACY" "AUTH" "PROVIDER CASCADE" "MCP SERVERS" "(no LLM call was made"; do
  if ! grep -qF "$section" <<<"$out"; then
    echo "$out" >&2
    fail "missing section '$section' in chump config output"
  fi
done

# Order check — CONFIG FILE before PRIVACY before AUTH before PROVIDER CASCADE
# before MCP SERVERS.
cfg_line=$(grep -n "CONFIG FILE" <<<"$out" | head -1 | cut -d: -f1)
priv_line=$(grep -n "^PRIVACY" <<<"$out" | head -1 | cut -d: -f1)
auth_line=$(grep -n "^AUTH" <<<"$out" | head -1 | cut -d: -f1)
casc_line=$(grep -n "^PROVIDER CASCADE" <<<"$out" | head -1 | cut -d: -f1)
mcp_line=$(grep -n "^MCP SERVERS" <<<"$out" | head -1 | cut -d: -f1)
if [[ -z "$cfg_line" || -z "$priv_line" || -z "$auth_line" || -z "$casc_line" || -z "$mcp_line" ]]; then
  echo "$out" >&2
  fail "could not locate all expected section line numbers"
fi
if ! (( cfg_line < priv_line && priv_line < auth_line && auth_line < casc_line && casc_line < mcp_line )); then
  echo "$out" >&2
  fail "section order wrong: CONFIG=$cfg_line PRIV=$priv_line AUTH=$auth_line CASC=$casc_line MCP=$mcp_line"
fi

# --json mode: must produce a single-line JSON object (or empty + valid JSON)
# with the expected top-level keys.
json_out=$("$CHUMP" config --json 2>&1)
status=$?
if [[ $status -ne 0 ]]; then
  echo "$json_out" >&2
  fail "chump config --json exited non-zero ($status)"
fi

# Basic structural sanity — must start with '{' and end with '}', and contain
# the expected top-level keys.
if [[ "${json_out:0:1}" != "{" || "${json_out: -1}" != "}" ]]; then
  echo "$json_out" >&2
  fail "chump config --json did not produce a JSON object"
fi
for key in '"config_toml"' '"round_privacy"' '"auth"' '"slots"' '"mcp"'; do
  if ! grep -qF "$key" <<<"$json_out"; then
    echo "$json_out" >&2
    fail "missing key $key in chump config --json output"
  fi
done

# `chump config bogus` must exit 2 (usage error), not 0 or 1.
if "$CHUMP" config bogus >/dev/null 2>&1; then
  fail "chump config bogus should have exited non-zero"
fi
"$CHUMP" config bogus >/dev/null 2>&1
rc=$?
if [[ $rc -ne 2 ]]; then
  fail "chump config bogus exited $rc, expected 2"
fi

# --help works and exits 0.
help_out=$("$CHUMP" config --help 2>&1)
help_status=$?
if [[ $help_status -ne 0 ]]; then
  echo "$help_out" >&2
  fail "chump config --help exited non-zero ($help_status)"
fi
if ! grep -qF "chump config" <<<"$help_out"; then
  echo "$help_out" >&2
  fail "chump config --help did not include 'chump config'"
fi

echo "PASS: chump config smoke test (INFRA-2371)"
