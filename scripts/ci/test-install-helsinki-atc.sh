#!/usr/bin/env bash
# scripts/ci/test-install-helsinki-atc.sh — INFRA-3593
#
# Smoke-tests the merge-triggered auto-deploy path added to
# install-helsinki-atc.sh: --auto must degrade gracefully (exit 0, emit
# organ_units_deploy_failed) when not root, since CI and most worker
# contexts cannot write /etc/systemd/system.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/setup/install-helsinki-atc.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
[ -x "$SCRIPT" ] || fail "missing or not executable"

bash -n "$SCRIPT" || fail "syntax error"
ok "bash -n passes"

# ── Test: --auto as non-root exits 0 and emits organ_units_deploy_failed ───
# Shim `id` so the assertion holds even when the test runner itself is root
# (some worker sandboxes run as root) — this test must NEVER touch the real
# /etc/systemd/system, so it forces the not-root branch unconditionally.
mkdir -p "$TMP/.chump-locks" "$TMP/bin"
cat > "$TMP/bin/id" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "-u" ] && { echo 1000; exit 0; }
exit 1
EOF
chmod +x "$TMP/bin/id"
NODE_AMBIENT="$TMP/.chump-locks/ambient.jsonl" PATH="$TMP/bin:$PATH" bash "$SCRIPT" --auto \
    >"$TMP/out.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "--auto (non-root) must exit 0 (non-fatal), got $rc"
grep -q 'without root' "$TMP/out.log" \
    || fail "expected a not-root warning on stdout/stderr: $(cat "$TMP/out.log")"
grep -q '"kind":"organ_units_deploy_failed"' "$TMP/.chump-locks/ambient.jsonl" \
    || fail "expected organ_units_deploy_failed emitted to ambient: $(cat "$TMP/.chump-locks/ambient.jsonl" 2>/dev/null)"
grep -q '"reason":"not_root"' "$TMP/.chump-locks/ambient.jsonl" \
    || fail "expected reason=not_root in the emitted event"
ok "--auto (non-root) is non-fatal and emits organ_units_deploy_failed reason=not_root"

# ── Test: the roster references files that actually exist ──────────────────
for unit in chump-pr-lander chump-armed-rebaser chump-board-cycle chump-sla-scorecard chump-organ-watchdog; do
    [ -f "$REPO_ROOT/scripts/dispatch/${unit}.service" ] || fail "missing scripts/dispatch/${unit}.service"
    [ -f "$REPO_ROOT/scripts/dispatch/${unit}.timer" ] || fail "missing scripts/dispatch/${unit}.timer"
done
ok "all 5 system-unit organs (pr-lander, armed-rebaser, board-cycle, sla-scorecard, organ-watchdog) have tracked .service+.timer pairs"

echo "ALL PASS"
