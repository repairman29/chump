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

# Build via cargo install (writes to ~/.cargo/bin/chump)
log "cargo install --path . --bin chump --force …"
if ! PATH="$(dirname "$CARGO"):$PATH" "$CARGO" install --path "$REPO_ROOT" --bin chump --force >>"$LOG" 2>&1; then
    log "FATAL: cargo install failed; see $LOG"
    emit runner_binary_refresh_failed "\"reason\":\"cargo_install_failed\""
    exit 1
fi

if [[ ! -x "$CARGO_BIN" ]]; then
    log "FATAL: $CARGO_BIN missing after cargo install"
    emit runner_binary_refresh_failed "\"reason\":\"binary_missing_post_build\""
    exit 1
fi

# Hardcopy (not symlink) to /opt/homebrew/bin so cargo cleanups don't break runners
log "hardcopy $CARGO_BIN → $TARGET_BIN"
if ! cp -f "$CARGO_BIN" "$TARGET_BIN.new" 2>>"$LOG"; then
    log "FATAL: cp to $TARGET_BIN.new failed"
    emit runner_binary_refresh_failed "\"reason\":\"cp_failed\""
    exit 1
fi
chmod +x "$TARGET_BIN.new"
mv -f "$TARGET_BIN.new" "$TARGET_BIN"

NEW_SHA="$("$TARGET_BIN" --version 2>/dev/null | grep -oE '\(([a-f0-9]+) built' | head -1 | sed 's/[( ]//g;s/built//' || echo unknown)"
log "OK: $TARGET_BIN now at sha $NEW_SHA (origin/main = $MAIN_SHA)"
emit runner_binary_refreshed "\"prev_sha\":\"$INSTALLED_SHA\",\"new_sha\":\"$NEW_SHA\",\"main_sha\":\"$MAIN_SHA\""

# Prune old logs (keep last 24)
ls -t "$LOG_DIR"/refresh-*.log 2>/dev/null | tail -n +25 | xargs -I{} rm -f {} 2>/dev/null || true

exit 0
