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

# ── Test: sla-scorecard unit has WorkingDirectory (INFRA-3598) ─────────────
# merge-sla-scorecard.sh resolves its target repo via `gh repo view`, which
# is cwd-based. Without WorkingDirectory, systemd's default cwd (/) makes
# the unit fail every cycle with "no repo nwo; skip" regardless of any
# CHUMP_REPO_ROOT env var (the script never reads that var for gh calls).
grep -q '^WorkingDirectory=' "$REPO_ROOT/scripts/dispatch/chump-sla-scorecard.service" \
    || fail "chump-sla-scorecard.service missing WorkingDirectory= (gh repo view is cwd-based; INFRA-3598)"
ok "chump-sla-scorecard.service sets WorkingDirectory so gh repo view resolves"

# ── Test: --auto from an ephemeral worktree must NOT bake that path into ───
# the persisted node-refresh unit's CHUMP_NODE_REPO (INFRA-3598). Simulate by
# copying the script tree into a fake ".claude/worktrees/<gap>/" path and
# running --check-propagation (a lightweight dry-run stub) — since the real
# script requires root + a live systemd bus for the full --auto path, this
# test instead asserts the source-level guard exists and covers the exact
# path shape node-refresh sessions run from.
grep -q '/.claude/worktrees/' "$SCRIPT" \
    || fail "install-helsinki-atc.sh missing the ephemeral-worktree guard for CHUMP_NODE_REPO"
grep -q 'Not propagating it as CHUMP_NODE_REPO' "$SCRIPT" \
    || fail "install-helsinki-atc.sh guard doesn't skip CHUMP_NODE_REPO propagation for worktree paths"
ok "install-helsinki-atc.sh guards against baking an ephemeral worktree into CHUMP_NODE_REPO"

# ── Test: --auto must NOT abort the roster on a single unit enable failure
#       (RESILIENT-347) ─────────────────────────────────────────────────────
# Before RESILIENT-347, `systemctl enable --now $t` failing for ANY one timer
# under --auto exited the whole script immediately (`exit 0`) — later timers
# in the roster never even got an enable attempt, and the ORGAN_RECONCILE
# call (which backs a structurally-broken organ off cleanly instead of
# re-churning it every cycle) never ran. This is the exact real-world failure
# named in the gap: chump-integrator/sla-scorecard/backlog-sync-writer/farmer
# failing on a node missing that organ's binary/deps must not take the rest
# of the ATC roster down with it.
mkdir -p "$TMP/atc-dest" "$TMP/atc-bins" "$TMP/atc-cargo-bin" "$TMP/atc-locks"
cat > "$TMP/atc-bins/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$ATC_CALL_LOG"
case "$1" in
    enable)
        unit="${@: -1}"
        grep -qxF "$unit" "$ATC_ENABLE_FAIL_FILE" 2>/dev/null && exit 1
        exit 0
        ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$TMP/atc-bins/systemctl"
# chump-integrator's own binary build path is unrelated to this test — stub
# CARGO_BIN_DIR with a pre-existing fake binary so the script's "build it if
# missing" branch (which needs a real cargo/network) never triggers.
cat > "$TMP/atc-cargo-bin/chump-integrator" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/atc-cargo-bin/chump-integrator"

ATC_CALL_LOG="$TMP/atc-calls.log"
ATC_ENABLE_FAIL_FILE="$TMP/atc-enable-fail.txt"
: > "$ATC_CALL_LOG"
echo "chump-farmer.timer" > "$ATC_ENABLE_FAIL_FILE"

ATC_CALL_LOG="$ATC_CALL_LOG" ATC_ENABLE_FAIL_FILE="$ATC_ENABLE_FAIL_FILE" \
    CHUMP_INSTALL_ATC_ALLOW_NONROOT=1 \
    CHUMP_INSTALL_ATC_SYSTEMD_DIR="$TMP/atc-dest" \
    CHUMP_INSTALL_ATC_SYSTEMCTL_BIN="$TMP/atc-bins/systemctl" \
    CARGO_BIN_DIR="$TMP/atc-cargo-bin" \
    NODE_AMBIENT="$TMP/atc-locks/ambient.jsonl" \
    bash "$SCRIPT" --auto >"$TMP/atc-out.log" 2>&1
atc_rc=$?
[ "$atc_rc" -eq 0 ] || fail "--auto with one failing unit must still exit 0 (non-fatal); got $atc_rc: $(cat "$TMP/atc-out.log")"
grep -q '"kind":"organ_units_deploy_failed".*"unit":"chump-farmer.timer"' "$TMP/atc-locks/ambient.jsonl" \
    || fail "expected organ_units_deploy_failed for chump-farmer.timer: $(cat "$TMP/atc-locks/ambient.jsonl" 2>/dev/null)"
# The two units the gap names as needing more than a path-rewrite
# (chump-integrator.timer, chump-backlog-sync-writer.timer) sit AFTER
# chump-farmer.timer in SYSTEM_TIMERS — proof the loop kept going past the
# failure instead of aborting on it.
grep -q "enable --now chump-integrator.timer" "$TMP/atc-calls.log" \
    || fail "a later timer (chump-integrator.timer) never got an enable attempt — the loop aborted early: $(cat "$TMP/atc-calls.log")"
grep -q "enable --now chump-backlog-sync-writer.timer" "$TMP/atc-calls.log" \
    || fail "a later timer (chump-backlog-sync-writer.timer) never got an enable attempt — the loop aborted early: $(cat "$TMP/atc-calls.log")"
grep -q "== reconciling organ manifest" "$TMP/atc-out.log" \
    || fail "ORGAN_RECONCILE was never reached after the mid-roster enable failure: $(cat "$TMP/atc-out.log")"
ok "--auto with one unit's enable failure continues the roster loop AND still reaches organ-reconcile.sh (RESILIENT-347)"

# ── Test: chump-organ-watchdog.service is host-agnostic (INFRA-3647) ───────
# Before INFRA-3647 the tracked unit hardcoded HOME=/root,
# CHUMP_REPO_ROOT=/root/Projects/chump and source /root/.chump/providers.env
# — the ONLY thing that made it work on an owned node (CJ, non-root) was
# this installer's blanket "/root/" -> $RUN_HOME sed rewrite at copy time.
# The unit now resolves its own paths via the systemd %h specifier, so it's
# correct on ANY node straight from the tracked file, with no rewrite step
# required. Assert both: (a) the tracked source has no absolute /root path,
# and (b) installing it for a non-root run-user still ends up correct (User=
# inserted, no /root path leaked into the installed copy either).
ORGAN_WATCHDOG_SRC="$REPO_ROOT/scripts/dispatch/chump-organ-watchdog.service"
grep -q '/root' "$ORGAN_WATCHDOG_SRC" \
    && fail "chump-organ-watchdog.service still pins an absolute /root path: $(grep -n '/root' "$ORGAN_WATCHDOG_SRC")"
grep -q '%h' "$ORGAN_WATCHDOG_SRC" \
    || fail "chump-organ-watchdog.service should resolve its home dir via the %h systemd specifier"
ok "chump-organ-watchdog.service (tracked source) has no hardcoded /root path"

mkdir -p "$TMP/cj-dest" "$TMP/cj-bins" "$TMP/cj-cargo-bin" "$TMP/cj-locks"
cat > "$TMP/cj-bins/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/cj-bins/systemctl"
cat > "$TMP/cj-cargo-bin/chump-integrator" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/cj-cargo-bin/chump-integrator"

CHUMP_INSTALL_ATC_ALLOW_NONROOT=1 \
    CHUMP_INSTALL_ATC_SYSTEMD_DIR="$TMP/cj-dest" \
    CHUMP_INSTALL_ATC_SYSTEMCTL_BIN="$TMP/cj-bins/systemctl" \
    CHUMP_RUN_USER=jeff \
    CARGO_BIN_DIR="$TMP/cj-cargo-bin" \
    NODE_AMBIENT="$TMP/cj-locks/ambient.jsonl" \
    bash "$SCRIPT" --auto >"$TMP/cj-out.log" 2>&1
cj_rc=$?
[ "$cj_rc" -eq 0 ] || fail "--auto for CHUMP_RUN_USER=jeff must exit 0; got $cj_rc: $(cat "$TMP/cj-out.log")"
CJ_INSTALLED="$TMP/cj-dest/chump-organ-watchdog.service"
[ -f "$CJ_INSTALLED" ] || fail "chump-organ-watchdog.service was not installed to the stubbed dest dir"
grep -q '^User=jeff' "$CJ_INSTALLED" \
    || fail "installed chump-organ-watchdog.service missing User=jeff (host-rewrite): $(cat "$CJ_INSTALLED")"
grep -q '/root' "$CJ_INSTALLED" \
    && fail "installed chump-organ-watchdog.service leaked an absolute /root path for a non-root run-user: $(cat "$CJ_INSTALLED")"
ok "chump-organ-watchdog.service installs for a non-root run-user (CJ shape) with no /root path"

echo "ALL PASS"
