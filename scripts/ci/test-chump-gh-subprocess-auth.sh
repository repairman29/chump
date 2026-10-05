#!/usr/bin/env bash
# scripts/ci/test-chump-gh-subprocess-auth.sh — INFRA-2028
#
# Verifies chump primes GH_TOKEN for its `gh` subprocesses at startup, so
# `chump gap reserve` doesn't 401 when GH_TOKEN/GITHUB_TOKEN are unset but
# `gh auth token` (a keychain read performed in the *caller's* shell context,
# unaffected by the subprocess-keychain block) can resolve a token.
#
# Strategy: stub `gh` on PATH via a temp dir.
#   - `gh auth token`     → always succeeds, prints a fake token (simulates
#                           the caller-shell-context keychain read working).
#   - every other subcommand → 401 unless GH_TOKEN is set in its own env
#                           (simulates the subprocess-context keychain block:
#                           only an explicit GH_TOKEN env var gets it past).
#
# If chump's startup priming works, GH_TOKEN is set for every later `gh`
# call it spawns, so `chump gap reserve` sees zero 401s / WARN lines.
#
# Exit 0 = all assertions pass; non-zero = failure.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BINARY="${REPO_ROOT}/target/debug/chump"

if [[ ! -x "$BINARY" ]]; then
  echo "[test-chump-gh-subprocess-auth] building chump (debug)..."
  (cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" cargo build -p chump 2>&1) || {
    echo "FAIL: cargo build failed" >&2
    exit 1
  }
fi

PASS=0
FAIL=0

make_stub_dir() {
  local stub_dir
  stub_dir="$(mktemp -d)"
  cat > "${stub_dir}/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "token" ]]; then
  echo "fake-keychain-token-abc123"
  exit 0
fi
# Every other subcommand: only succeeds if GH_TOKEN is set in ITS OWN env
# (i.e. chump primed it before spawning this child).
if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "HTTP 401 Bad credentials" >&2
  exit 1
fi
if [[ "$1" == "repo" && "$2" == "view" ]]; then
  echo "stubowner/stubrepo"
  exit 0
fi
if [[ "$1" == "api" ]]; then
  echo "[]"
  exit 0
fi
echo "[]"
exit 0
STUB
  chmod +x "${stub_dir}/gh"
  echo "$stub_dir"
}

run_reserve() {
  local stub_dir="$1"
  local store_dir="$2"
  local title="${3:-gh-subprocess-auth-test-$(date +%s%N)}"
  mkdir -p "${store_dir}/docs/gaps" "${store_dir}/.chump-locks"
  env -u GH_TOKEN -u GITHUB_TOKEN \
    PATH="${stub_dir}:${PATH}" \
    CHUMP_REPO="${store_dir}" \
    CHUMP_STATE_DB="${store_dir}/state.db" \
    FLEET_029_AMBIENT_GLANCE_SKIP=1 \
    "$BINARY" gap reserve \
      --domain TEST \
      --title "$title" \
      --skip-obs-acs \
      2>&1
}

echo ""
echo "=== Test: GH_TOKEN unset, gh auth token resolvable — expect no WARN / 401 ==="
STORE="$(mktemp -d)"
STUB="$(make_stub_dir)"
OUTPUT="$(run_reserve "$STUB" "$STORE" 2>&1 || true)"

if echo "$OUTPUT" | grep -q "\[gap reserve\] WARN:"; then
  echo "FAIL: found '[gap reserve] WARN:' in output" >&2
  echo "  output was: $OUTPUT" >&2
  FAIL=$((FAIL + 1))
else
  echo "PASS: no '[gap reserve] WARN:' line on stderr"
  PASS=$((PASS + 1))
fi

if echo "$OUTPUT" | grep -q "HTTP 401"; then
  echo "FAIL: found 'HTTP 401' in output" >&2
  echo "  output was: $OUTPUT" >&2
  FAIL=$((FAIL + 1))
else
  echo "PASS: zero 'HTTP 401' lines"
  PASS=$((PASS + 1))
fi

AMBIENT_FILE="${STORE}/.chump-locks/ambient.jsonl"
if [[ -f "$AMBIENT_FILE" ]] && grep -q "gap_reserve_open_pr_scan_failed" "$AMBIENT_FILE"; then
  echo "FAIL: gap_reserve_open_pr_scan_failed event found in ambient.jsonl" >&2
  FAIL=$((FAIL + 1))
else
  echo "PASS: gap_reserve_open_pr_scan_failed NOT in ambient.jsonl"
  PASS=$((PASS + 1))
fi

rm -rf "$STORE" "$STUB"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
