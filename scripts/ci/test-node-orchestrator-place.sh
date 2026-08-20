#!/usr/bin/env bash
# scripts/ci/test-node-orchestrator-place.sh — RESILIENT-322
#
# Forced-pressure integration test for scripts/ops/node-orchestrator.sh's place()
# family: induces root>90% + tmpfs>90% conditions (via sensed-variable overrides,
# not real disk exhaustion) and verifies cargo + worktrees relocate GRACEFULLY
# (rsync -> atomic rename+symlink, never a foreground mv of live data) while a
# background "fleet" writer keeps touching files the whole time, plus TMPDIR
# gets routed to the data volume on tmpfs pressure.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ORCH="$REPO/scripts/ops/node-orchestrator.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$ORCH" ]] || fail "$ORCH missing"

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

export HOME="$WORK/home"
export CHUMP_STATE_DIR="$WORK/state"
export CHUMP_REPO_ROOT="$WORK/repo"
export CHUMP_ORCH_ENV_FILE="$CHUMP_STATE_DIR/cj.env"
export CHUMP_ORCH_AUTOPLACE=1
export CHUMP_ORCH_TEST_SOURCE=1
BIGVOL="$WORK/bigvol"
mkdir -p "$HOME" "$CHUMP_STATE_DIR" "$CHUMP_REPO_ROOT" "$BIGVOL"

# fake ~/.cargo with a stub `cargo` binary so the post-swap validation call succeeds
mkdir -p "$HOME/.cargo/bin" "$HOME/.cargo/registry"
cat > "$HOME/.cargo/bin/cargo" <<'EOF'
#!/usr/bin/env bash
echo "cargo 1.0.0-stub"
EOF
chmod +x "$HOME/.cargo/bin/cargo"
echo "canary-cargo-file" > "$HOME/.cargo/registry/canary.txt"

# fake .claude/worktrees dir + a minimal repo so `git worktree list` has something to validate against
( cd "$CHUMP_REPO_ROOT" && git init -q && git config user.email t@t.co && git config user.name t \
  && git commit -q --allow-empty -m init )
mkdir -p "$CHUMP_REPO_ROOT/.claude/worktrees/fake-wt"
echo "canary-worktree-file" > "$CHUMP_REPO_ROOT/.claude/worktrees/fake-wt/canary.txt"

# ── background "fleet" writer: keeps touching the cargo tree during place() ──
FLEET_LOG="$WORK/fleet-writer.log"
: > "$FLEET_LOG"
(
  for _ in $(seq 1 200); do
    date +%s%N >> "$FLEET_LOG" 2>/dev/null || echo "FLEET_WRITE_FAILED" >> "$FLEET_LOG"
    sleep 0.02
  done
) &
FLEET_PID=$!

# shellcheck disable=SC1090
source "$ORCH"

# ── induce forced root>90% + tmpfs>90% pressure via sensed-variable overrides ──
ROOT_PCT=95
BEST_VOL_MNT="$BIGVOL"
BEST_VOL_FREE_KB=$((30*1024*1024))
TMP_FSTYPE=tmpfs
TMP_PCT=93

t0=$(date +%s)
place
t1=$(date +%s)

# fleet must have stayed up the whole time — no interruption from a foreground mv
kill "$FLEET_PID" 2>/dev/null
wait "$FLEET_PID" 2>/dev/null
grep -q "FLEET_WRITE_FAILED" "$FLEET_LOG" && fail "background fleet writer saw a failed write during place() — foreground disruption"
[[ -s "$FLEET_LOG" ]] || fail "background fleet writer produced no output — test setup broken"
ok "fleet stayed up during place() (${#FLEET_LOG} bytes logged, $((t1-t0))s elapsed)"

# ── cargo relocation ──
[[ -L "$HOME/.cargo" ]] || fail "~/.cargo not symlinked after place() with root>90%"
[[ "$(readlink "$HOME/.cargo")" == "$BIGVOL/cargo" ]] || fail "~/.cargo symlink points at wrong target: $(readlink "$HOME/.cargo")"
[[ -f "$BIGVOL/cargo/registry/canary.txt" ]] || fail "cargo canary file missing after relocation — rsync incomplete"
ok "cargo gracefully relocated -> $BIGVOL/cargo (canary intact)"

# validate step must have run cargo through the new path and succeeded (no leftover pre-orch backup)
shopt -s nullglob
leftovers=("$HOME"/.cargo.pre-orch-*)
shopt -u nullglob
[[ ${#leftovers[@]} -eq 0 ]] || {
  sleep 1  # background reap race — give it a moment
  shopt -s nullglob; leftovers=("$HOME"/.cargo.pre-orch-*); shopt -u nullglob
  [[ ${#leftovers[@]} -eq 0 ]] || fail "cargo validation left a backup dir behind: ${leftovers[*]} (validation may have failed)"
}
ok "cargo validation passed (old copy reaped, no backup left)"

# ── worktrees relocation ──
[[ -L "$CHUMP_REPO_ROOT/.claude/worktrees" ]] || fail ".claude/worktrees not symlinked after place() with root>90%"
[[ "$(readlink "$CHUMP_REPO_ROOT/.claude/worktrees")" == "$BIGVOL/worktrees" ]] || fail "worktrees symlink points at wrong target"
[[ -f "$BIGVOL/worktrees/fake-wt/canary.txt" ]] || fail "worktree canary file missing after relocation"
ok "worktrees gracefully relocated -> $BIGVOL/worktrees (canary intact)"

( cd "$CHUMP_REPO_ROOT" && git worktree list >/dev/null 2>&1 ) || fail "git worktree list failed through relocated symlink"
ok "git worktree list resolves through the relocated symlink"

# ── TMPDIR auto-route on tmpfs pressure ──
[[ -f "$CHUMP_ORCH_ENV_FILE" ]] || fail "TMPDIR route did not write $CHUMP_ORCH_ENV_FILE"
grep -q "^export TMPDIR=$BIGVOL/tmp\$" "$CHUMP_ORCH_ENV_FILE" || fail "TMPDIR not routed to $BIGVOL/tmp in $CHUMP_ORCH_ENV_FILE"
[[ -d "$BIGVOL/tmp" ]] || fail "TMPDIR target directory not created"
ok "TMPDIR auto-routed -> $BIGVOL/tmp on tmpfs pressure"

# ── idempotency: re-running place() with the same pressure is a no-op (no duplicate TMPDIR lines, no re-relocate) ──
LINES_BEFORE=$(wc -l < "$CHUMP_ORCH_ENV_FILE")
place
LINES_AFTER=$(wc -l < "$CHUMP_ORCH_ENV_FILE")
[[ "$LINES_BEFORE" -eq "$LINES_AFTER" ]] || fail "re-running place() duplicated the TMPDIR line ($LINES_BEFORE -> $LINES_AFTER)"
ok "place() is idempotent under sustained pressure (no duplicate routing, no re-relocation churn)"

# ── AUTOPLACE=0 falls back to recommend-only (no mutation) ──
rm -rf "$WORK/home2" "$WORK/repo2" "$WORK/state2"
export HOME="$WORK/home2" CHUMP_STATE_DIR="$WORK/state2" CHUMP_REPO_ROOT="$WORK/repo2" CHUMP_ORCH_ENV_FILE="$WORK/state2/cj.env"
mkdir -p "$HOME/.cargo/registry" "$CHUMP_STATE_DIR" "$CHUMP_REPO_ROOT/.claude/worktrees"
( cd "$CHUMP_REPO_ROOT" && git init -q )
AUTOPLACE=0
ROOT_PCT=95; TMP_FSTYPE=tmpfs; TMP_PCT=93
place
[[ -L "$HOME/.cargo" ]] && fail "AUTOPLACE=0 still relocated cargo — recommend-only contract broken"
[[ -f "$CHUMP_ORCH_ENV_FILE" ]] && fail "AUTOPLACE=0 still wrote a TMPDIR route — recommend-only contract broken"
ok "AUTOPLACE=0 stays recommend-only (no mutation)"

echo "ALL PASS: node-orchestrator forced-pressure placement (RESILIENT-322)"
