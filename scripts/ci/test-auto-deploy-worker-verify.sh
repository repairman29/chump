#!/usr/bin/env bash
# scripts/ci/test-auto-deploy-worker-verify.sh — RESILIENT-408
#
# Verifies the PATH-resolved-worker-binary verification gate added to
# scripts/ops/auto-deploy.sh: deploy success can no longer be reported when
# the binary the fleet workers actually exec (e.g. ~/.cargo/bin/chump, first
# on a worker's PATH) still lags origin/main, even though the install-target
# binary (TARGET_BIN / CHUMP_RUNNER_BIN) rebuilt successfully. Precedent:
# 2026-08-24 05:50 — auto-deploy reported binary_auto_deployed and advanced
# auto-deploy-last-sha.txt while the running CJ worker executed a 04:49
# build with 0 EFFECTIVE-465 markers (merged-not-running on the deploy side).
#
# Acceptance criteria verified (RESILIENT-408):
#   (1) auto-deploy resolves a worker binary distinct from TARGET_BIN via
#       CHUMP_WORKER_BIN (the ~/.cargo/bin/chump PATH-resolution stand-in).
#   (2)+(3) A stale PATH-resolved worker binary (sha != origin/main HEAD)
#       after a successful refresh causes the deploy to:
#         - exit non-zero
#         - emit kind=binary_auto_deploy_failed reason=worker_binary_sha_mismatch
#         - NOT emit kind=binary_auto_deployed
#         - NOT advance auto-deploy-last-sha.txt
#   (4) A worker binary that DOES match origin/main HEAD after refresh lets
#       the deploy succeed: emits binary_auto_deployed, advances the sha file.
#
# We never build the real binary or hit the network: refresh-runner-binary.sh
# and both "installed chump" binaries (TARGET_BIN, worker bin) are stubs.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AUTO_DEPLOY="$REPO_ROOT/scripts/ops/auto-deploy.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -x "$AUTO_DEPLOY" ]] || fail "auto-deploy.sh missing or not executable"
grep -q '^resolve_worker_bin()' "$AUTO_DEPLOY" || fail "resolve_worker_bin() missing"
grep -q 'CHUMP_WORKER_BIN' "$AUTO_DEPLOY" || fail "CHUMP_WORKER_BIN override wiring missing"
grep -q 'worker_binary_sha_mismatch' "$AUTO_DEPLOY" || fail "worker_binary_sha_mismatch reason missing"
ok "worker-binary verification wiring present"

FAKE_REFRESH="$TMP/fake-refresh.sh"
cat >"$FAKE_REFRESH" <<'EOF'
#!/usr/bin/env bash
# Stands in for scripts/setup/refresh-runner-binary.sh: pretend TARGET_BIN's
# own rebuild+install always succeeds instantly.
exit 0
EOF
chmod +x "$FAKE_REFRESH"

# make_fake_bin <path> <sha> — a stub `chump` whose --version reports a
# fixed, caller-chosen build sha (independent of any real git commit).
make_fake_bin() {
    local path="$1" sha="$2"
    cat >"$path" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "health" && "\${2:-}" == "--slo-check" ]]; then
    exit 0
fi
echo "chump 0.0.0 ($sha built 2026-01-01)"
EOF
    chmod +x "$path"
}

# make_fake_repo <dir> — minimal git repo with one commit on main, and an
# origin/main ref so `git rev-parse origin/main` resolves without a real
# remote.
make_fake_repo() {
    local dir="$1"
    mkdir -p "$dir"
    (
        cd "$dir" || exit 1
        git init -q
        git checkout -q -b main
        git config user.email "test@example.com"
        git config user.name "Test"
        echo hello >f.txt
        git add f.txt
        git commit -q -m init
        git remote add origin "file:///nonexistent-$(basename "$dir")-origin"
        git update-ref refs/remotes/origin/main HEAD
    )
}

# ── Scenario A: TARGET_BIN rebuilt fine, but the PATH-resolved worker
#    binary is STALE (does not match origin/main HEAD) ─────────────────────
REPO_A="$TMP/repo-a"
make_fake_repo "$REPO_A"
MAIN_SHA_A="$(git -C "$REPO_A" rev-parse --short=12 origin/main)"
TARGET_BIN_A="$TMP/target-chump-a"
make_fake_bin "$TARGET_BIN_A" "$MAIN_SHA_A"
WORKER_BIN_A="$TMP/worker-chump-a"
make_fake_bin "$WORKER_BIN_A" "0000stalesha"

CHUMP_REPO_ROOT="$REPO_A" \
    CHUMP_REFRESH_RUNNER_SCRIPT="$FAKE_REFRESH" \
    CHUMP_RUNNER_BIN="$TARGET_BIN_A" \
    CHUMP_WORKER_BIN="$WORKER_BIN_A" \
    CHUMP_AUTODEPLOY_SMOKE=0 \
    bash "$AUTO_DEPLOY" >"$TMP/out-a.log" 2>&1
RC=$?
[[ "$RC" -ne 0 ]] || fail "scenario A: deploy must exit non-zero when the worker-resolved binary is stale: $(cat "$TMP/out-a.log")"
grep -q '"kind":"binary_auto_deploy_failed"' "$REPO_A/.chump-locks/ambient.jsonl" \
    || fail "scenario A: binary_auto_deploy_failed not emitted"
grep -q '"reason":"worker_binary_sha_mismatch"' "$REPO_A/.chump-locks/ambient.jsonl" \
    || fail "scenario A: reason=worker_binary_sha_mismatch not emitted"
if grep -q '"kind":"binary_auto_deployed"' "$REPO_A/.chump-locks/ambient.jsonl"; then
    fail "scenario A: binary_auto_deployed MUST NOT be emitted when the worker binary is stale"
fi
[[ ! -s "$REPO_A/.chump-locks/auto-deploy-last-sha.txt" ]] \
    || fail "scenario A: auto-deploy-last-sha.txt MUST NOT advance when the worker binary is stale"
ok "stale PATH-resolved worker binary blocks the deploy: exit non-zero, binary_auto_deploy_failed emitted, no binary_auto_deployed, sha file untouched"

# ── Scenario B: worker-resolved binary MATCHES origin/main HEAD -> success ──
REPO_B="$TMP/repo-b"
make_fake_repo "$REPO_B"
MAIN_SHA_B="$(git -C "$REPO_B" rev-parse --short=12 origin/main)"
TARGET_BIN_B="$TMP/target-chump-b"
make_fake_bin "$TARGET_BIN_B" "$MAIN_SHA_B"
WORKER_BIN_B="$TMP/worker-chump-b"
make_fake_bin "$WORKER_BIN_B" "$MAIN_SHA_B"

CHUMP_REPO_ROOT="$REPO_B" \
    CHUMP_REFRESH_RUNNER_SCRIPT="$FAKE_REFRESH" \
    CHUMP_RUNNER_BIN="$TARGET_BIN_B" \
    CHUMP_WORKER_BIN="$WORKER_BIN_B" \
    CHUMP_AUTODEPLOY_SMOKE=0 \
    bash "$AUTO_DEPLOY" >"$TMP/out-b.log" 2>&1
RC=$?
[[ "$RC" -eq 0 ]] || fail "scenario B: deploy should exit 0 when the worker binary matches origin/main: $(cat "$TMP/out-b.log")"
grep -q '"kind":"binary_auto_deployed"' "$REPO_B/.chump-locks/ambient.jsonl" \
    || fail "scenario B: binary_auto_deployed not emitted despite a matching worker binary"
[[ -s "$REPO_B/.chump-locks/auto-deploy-last-sha.txt" ]] \
    || fail "scenario B: auto-deploy-last-sha.txt should advance on a verified deploy"
ok "matching PATH-resolved worker binary lets the deploy succeed: binary_auto_deployed emitted, sha file advances"

echo
echo "All RESILIENT-408 worker-binary-verification tests passed."
