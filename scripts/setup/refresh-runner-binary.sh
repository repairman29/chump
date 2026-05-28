#!/usr/bin/env bash
# scripts/setup/refresh-runner-binary.sh — CREDIBLE-076
#
# Rebuild the chump binary from current origin/main and hardcopy it to
# /opt/homebrew/bin/chump so the 4 self-hosted CI runners always run against
# a current binary. Without this, every fast-checks test that greps `chump`
# subcommand output fails because the runner's binary lags origin/main.
#
# Designed for launchd; runs every 30 minutes via
# scripts/setup/install-refresh-runner-binary-launchd.sh.
#
# Idempotent: if the installed binary's build SHA matches origin/main's HEAD,
# skips the rebuild entirely (fast no-op, no cargo invocation).
#
# Emits ambient kinds:
#   runner_binary_refreshed         — successful rebuild + install
#   runner_binary_refresh_skipped   — binary already current (no-op)
#   runner_binary_refresh_failed    — build or install error
#
# Bypass: CHUMP_SKIP_BINARY_REFRESH=1 short-circuits to exit 0.

set -uo pipefail

REPO_ROOT="${CHUMP_REPO_ROOT:-/Users/jeffadkins/Projects/Chump}"
TARGET_BIN="${CHUMP_RUNNER_BIN:-/opt/homebrew/bin/chump}"
CARGO_BIN="${CHUMP_CARGO_BIN:-$HOME/.cargo/bin/chump}"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
LOG_DIR="$REPO_ROOT/.chump-locks/binary-refresh-logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/refresh-$(date -u +%Y%m%dT%H%M%SZ).log"

emit() {
    local kind="$1" extra="${2:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || true
    printf '[%s] %s\n' "$ts" "$kind" >> "$LOG"
}

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

# Bypass for forensics
if [[ "${CHUMP_SKIP_BINARY_REFRESH:-0}" == "1" ]]; then
    log "BYPASS: CHUMP_SKIP_BINARY_REFRESH=1"
    exit 0
fi

cd "$REPO_ROOT" || { log "FATAL: cannot cd to $REPO_ROOT"; emit runner_binary_refresh_failed "\"reason\":\"cwd_failed\""; exit 1; }

# Fetch latest main without disturbing the working tree
git fetch origin main --quiet 2>/dev/null || {
    log "WARN: git fetch failed (offline?); proceeding with local main"
}

MAIN_SHA="$(git rev-parse --short=12 origin/main 2>/dev/null || git rev-parse --short=12 HEAD)"
log "origin/main = $MAIN_SHA"

# Check installed binary build SHA (chump prints 'chump 0.1.2 (<sha> built <date>)')
INSTALLED_SHA="none"
if [[ -x "$TARGET_BIN" ]]; then
    INSTALLED_SHA="$("$TARGET_BIN" --version 2>/dev/null | grep -oE '\(([a-f0-9]+) built' | head -1 | sed 's/[( ]//g;s/built//' || echo unknown)"
    log "installed $TARGET_BIN sha = $INSTALLED_SHA"
fi

# Idempotency: if SHAs match, skip
if [[ "$INSTALLED_SHA" == "$MAIN_SHA"* || "$MAIN_SHA" == "$INSTALLED_SHA"* ]] && [[ "$INSTALLED_SHA" != "none" && "$INSTALLED_SHA" != "unknown" ]]; then
    log "SKIP: binary already current ($INSTALLED_SHA matches main $MAIN_SHA)"
    emit runner_binary_refresh_skipped "\"reason\":\"already_current\",\"sha\":\"$INSTALLED_SHA\""
    exit 0
fi

# Resolve cargo on PATH
CARGO=""
for candidate in "$HOME/.cargo/bin/cargo" "$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin/cargo" "$(command -v cargo)"; do
    if [[ -x "$candidate" ]]; then
        CARGO="$candidate"
        break
    fi
done
if [[ -z "$CARGO" ]]; then
    log "FATAL: cargo not found in PATH or known locations"
    emit runner_binary_refresh_failed "\"reason\":\"no_cargo\""
    exit 1
fi
log "using cargo: $CARGO"

# INFRA-2101 fix: build from a detached worktree at origin/main HEAD instead of
# the operator's local working tree. Pre-fix, `cargo install --path "$REPO_ROOT"`
# built from the local checkout — when the operator had WIP and main was 100+
# commits behind origin/main (the operationalization-debt case), the "refresh"
# emitted prev_sha==new_sha forever. Operator's installed binary stuck at the
# stale local sha while origin/main advanced. Wizard-retirement criterion #1
# was met on paper, broken in production.
BUILD_WORKTREE="${CHUMP_BINARY_REFRESH_WORKTREE:-/tmp/chump-binary-refresh-$$}"
log "creating detached worktree at origin/main ($MAIN_SHA) → $BUILD_WORKTREE"
if ! git -C "$REPO_ROOT" worktree add -d -f "$BUILD_WORKTREE" "origin/main" >>"$LOG" 2>&1; then
    log "FATAL: failed to create build worktree at $BUILD_WORKTREE"
    emit runner_binary_refresh_failed "\"reason\":\"worktree_add_failed\""
    exit 1
fi
# Always tear down the worktree on exit (success OR failure path)
trap 'git -C "$REPO_ROOT" worktree remove --force "$BUILD_WORKTREE" >>"$LOG" 2>&1 || true' EXIT

# Build --release in the detached worktree. Use cargo build (not cargo install)
# so we write to BUILD_WORKTREE/target/release/chump and nothing else.
log "cargo build --release --bin chump (in $BUILD_WORKTREE) …"
if ! PATH="$(dirname "$CARGO"):$PATH" \
     "$CARGO" build --release --bin chump --manifest-path "$BUILD_WORKTREE/Cargo.toml" >>"$LOG" 2>&1; then
    log "FATAL: cargo build failed; see $LOG"
    emit runner_binary_refresh_failed "\"reason\":\"cargo_build_failed\""
    exit 1
fi

BUILT_BIN="$BUILD_WORKTREE/target/release/chump"
if [[ ! -x "$BUILT_BIN" ]]; then
    log "FATAL: $BUILT_BIN missing after cargo build"
    emit runner_binary_refresh_failed "\"reason\":\"binary_missing_post_build\""
    exit 1
fi

# Hardcopy build artifact → /opt/homebrew/bin (atomic via tempfile + rename).
log "hardcopy $BUILT_BIN → $TARGET_BIN"
if ! cp -f "$BUILT_BIN" "$TARGET_BIN.new" 2>>"$LOG"; then
    log "FATAL: cp to $TARGET_BIN.new failed"
    emit runner_binary_refresh_failed "\"reason\":\"cp_failed\""
    exit 1
fi
chmod +x "$TARGET_BIN.new"
mv -f "$TARGET_BIN.new" "$TARGET_BIN"

NEW_SHA="$("$TARGET_BIN" --version 2>/dev/null | grep -oE '\(([a-f0-9]+) built' | head -1 | sed 's/[( ]//g;s/built//' || echo unknown)"

# INFRA-2101 guard: detect the silent-failure mode (prev_sha == new_sha despite
# origin/main advance). If we built from origin/main and new_sha STILL matches
# the prior installed sha, something is wrong — either:
#   - origin/main didn't actually advance (no commits since last run; OK)
#   - the build produced the same artifact (genuinely no source change; OK)
#   - the cp/mv silently no-op'd (BAD; new file should win)
# Emit a separate kind=runner_binary_advance with delta_commits so the
# operator can audit whether the daemon is making forward progress.
DELTA_COMMITS="$(git -C "$REPO_ROOT" rev-list --count "${INSTALLED_SHA}..origin/main" 2>/dev/null || echo unknown)"
if [[ "$NEW_SHA" == "$INSTALLED_SHA" && "$DELTA_COMMITS" != "0" && "$DELTA_COMMITS" != "unknown" ]]; then
    log "WARN: prev_sha == new_sha ($NEW_SHA) despite $DELTA_COMMITS commits on origin/main since last install — possible silent staleness"
    emit runner_binary_refresh_failed "\"reason\":\"silent_staleness\",\"prev_sha\":\"$INSTALLED_SHA\",\"main_sha\":\"$MAIN_SHA\",\"delta_commits\":$DELTA_COMMITS"
    exit 1
fi

log "OK: $TARGET_BIN now at sha $NEW_SHA (origin/main = $MAIN_SHA, delta_commits=$DELTA_COMMITS)"
emit runner_binary_refreshed "\"prev_sha\":\"$INSTALLED_SHA\",\"new_sha\":\"$NEW_SHA\",\"main_sha\":\"$MAIN_SHA\""
emit runner_binary_advance "\"prev_sha\":\"$INSTALLED_SHA\",\"new_sha\":\"$NEW_SHA\",\"main_sha\":\"$MAIN_SHA\",\"delta_commits\":\"$DELTA_COMMITS\""

# Prune old logs (keep last 24)
ls -t "$LOG_DIR"/refresh-*.log 2>/dev/null | tail -n +25 | xargs -I{} rm -f {} 2>/dev/null || true

exit 0
