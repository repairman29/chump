#!/usr/bin/env bash
# scripts/ops/node-refresh-chump.sh — RESILIENT-200
#
# Linux-node counterpart of scripts/setup/refresh-runner-binary.sh (which is the
# macOS launchd auto-deploy path). Keeps a fleet node's installed `chump` binary
# current with origin/main by rebuilding from a local mirror checkout and
# installing to the node's chump path.
#
# WHY a separate script: refresh-runner-binary.sh hardcodes macOS assumptions —
# /opt/homebrew/bin target, codesign-before-swap (syspolicyd), aarch64 cargo
# paths. The Linux fleet nodes (closetjunky, Helsinki) have none of those: no
# codesign, x86_64, and a per-user ~/.local/bin (or root /usr/local/bin) target.
# This script is the Linux-shaped equivalent, driven by a systemd --user timer
# (see scripts/setup/install-node-refresh-systemd.sh).
#
# PAUSE SAFETY (RESILIENT-073): this script ONLY refreshes the binary. It never
# reads, writes, or bumps ~/.chump/AUTONOMY_LEVEL, and never starts fleet work.
# A paused node (AUTONOMY_LEVEL=0) stays paused across refreshes — the binary
# gets current, the fleet stays off until the operator flips the switch.
#
# Idempotent: if the installed binary's build SHA already matches the
# green-main pointer, skips the rebuild entirely (fast no-op, no cargo
# invocation).
#
# Emits (appended to $NODE_AMBIENT if it exists, else logfile only):
#   node_binary_refreshed         — successful rebuild + install
#   node_binary_refresh_skipped   — binary already current (no-op)
#   node_binary_refresh_failed    — build or install error
#
# Bypass: CHUMP_SKIP_NODE_REFRESH=1 short-circuits to exit 0.
#
# GREEN-MAIN PIN (RESILIENT-327): this script does NOT advance the live node
# to raw origin/main HEAD. It advances to the last commit that passed the
# full CI gate (the "green-main pointer"), found the same way
# scripts/coord/blame-bot.sh finds its baseline: most-recent SUCCESS run of
# the required workflow on branch main. A bad HEAD (red main) never reaches
# the live node — the node just stays pinned at the last-known-green sha
# until CI goes green again. Workers that branch off this node's mirror
# checkout therefore branch off the pinned green base, not a shifting HEAD.
#
# Env overrides:
#   CHUMP_NODE_REPO   repo mirror to build from   (default: first of
#                     ~/chump-host, ~/Projects/Chump, ~/chump that exists)
#   CHUMP_NODE_BIN    install destination         (default: ~/.local/bin/chump)
#   NODE_AMBIENT      ambient stream to append to (default: <repo>/.chump-locks/ambient.jsonl)
#   CHUMP_NODE_REFRESH_CI_WORKFLOW      required-gate workflow file (default: ci.yml)
#   CHUMP_NODE_REFRESH_GREEN_LOOKBACK   runs to scan for the green sha (default: 30)
#   CHUMP_NODE_REFRESH_TEST_GREEN_SHA   test injection: skip gh lookup, use this sha

set -uo pipefail

# --- sanctioned gh wrapper (INFRA-1274) --------------------------------------
# Route every GitHub call through chump_gh (scripts/coord/lib/github.sh) so it
# inherits the fleet's throttle + secondary-rate-limit backoff + criticality
# tagging, instead of a raw `gh` that the raw-gh-lint hot-path gate forbids.
_NODE_REFRESH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../coord/lib/github.sh
source "$_NODE_REFRESH_DIR/../coord/lib/github.sh" 2>/dev/null || true

# --- resolve the mirror checkout to build from -------------------------------
REPO_ROOT="${CHUMP_NODE_REPO:-}"
if [[ -z "$REPO_ROOT" ]]; then
    for candidate in "$HOME/chump-host" "$HOME/Projects/Chump" "$HOME/chump"; do
        if [[ -d "$candidate/.git" ]]; then REPO_ROOT="$candidate"; break; fi
    done
fi
# --- resolve the install destination (RESILIENT-378) -------------------------
# CRITICAL: install where the FLEET's PATH actually resolves `chump`, not a
# fixed ~/.local/bin that the PATH may shadow. The original RESILIENT-200
# default (~/.local/bin/chump) silently rotted the fleet on closetjunky: the
# organ rebuilt a CURRENT binary into ~/.local/bin every cycle, but the
# workers (cj-worker-run.sh) run PATH=~/.cargo/bin:...:target/release, so they
# executed a STALE ~/.cargo/bin/chump — 5 days behind origin/main — and drained
# the gap queue on old code. The refresh "ran" but did not do its job.
# Resolution order:
#   1. explicit CHUMP_NODE_BIN override (operator / unit Environment)
#   2. the chump already on PATH — the exact binary the fleet runs — unless it
#      is the repo's own target/release build (never install onto the build out)
#   3. ~/.cargo/bin/chump if it exists (cargo-install canonical on Linux nodes)
#   4. ~/.local/bin/chump (last resort, original default)
_resolve_target_bin() {
    if [[ -n "${CHUMP_NODE_BIN:-}" ]]; then printf '%s' "$CHUMP_NODE_BIN"; return; fi
    local onpath; onpath="$(command -v chump 2>/dev/null || true)"
    if [[ -n "$onpath" && "$onpath" != *"/target/release/chump" && "$onpath" != *"/target/debug/chump" ]]; then
        printf '%s' "$onpath"; return
    fi
    if [[ -x "$HOME/.cargo/bin/chump" ]]; then printf '%s' "$HOME/.cargo/bin/chump"; return; fi
    printf '%s' "$HOME/.local/bin/chump"
}
TARGET_BIN="$(_resolve_target_bin)"
NODE_AMBIENT="${NODE_AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

LOG_DIR="${CHUMP_NODE_REFRESH_LOGDIR:-$HOME/.chump/node-refresh-logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/refresh-$(date -u +%Y%m%dT%H%M%SZ).log"

emit() {
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    [[ -d "$(dirname "$NODE_AMBIENT")" ]] && printf '%s\n' "$line" >> "$NODE_AMBIENT" 2>/dev/null || true
    printf '[%s] %s\n' "$ts" "$kind" >> "$LOG"
}
log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

# --- RESILIENT-327: last-GREEN main pointer, not raw HEAD --------------------
# Returns the full sha of the most-recent SUCCESS run of the required-gate
# workflow on branch main. Falls back to raw origin/main HEAD (old behavior,
# logged loudly) when gh is unavailable or no green run can be found — a node
# with no way to know what's green must still be able to refresh, but the
# fallback is explicit rather than silent so it's auditable in the log/ambient.
CI_WORKFLOW="${CHUMP_NODE_REFRESH_CI_WORKFLOW:-ci.yml}"
GREEN_LOOKBACK="${CHUMP_NODE_REFRESH_GREEN_LOOKBACK:-30}"
_find_green_main_sha() {
    if [[ -n "${CHUMP_NODE_REFRESH_TEST_GREEN_SHA:-}" ]]; then
        echo "$CHUMP_NODE_REFRESH_TEST_GREEN_SHA"
        return
    fi
    if ! command -v gh >/dev/null 2>&1; then
        echo ""
        return
    fi
    # INFRA-1274: raw `gh` is banned in hot-path scripts — route through the
    # sanctioned chump_gh wrapper. Fall back to raw gh only if the lib failed to
    # source (chump_gh undefined), so a node with a partial checkout still works.
    local _gh_cmd="gh"
    command -v chump_gh >/dev/null 2>&1 && _gh_cmd="chump_gh"
    CHUMP_GH_CALL_CRITICALITY=background "$_gh_cmd" api \
        "repos/{owner}/{repo}/actions/workflows/${CI_WORKFLOW}/runs?branch=main&status=success&per_page=${GREEN_LOOKBACK}" \
        --jq '[.workflow_runs[] | select(.conclusion=="success")][0].head_sha' 2>/dev/null \
        | grep -vE '^(null|)$' || echo ""
}

if [[ "${CHUMP_SKIP_NODE_REFRESH:-0}" == "1" ]]; then
    log "BYPASS: CHUMP_SKIP_NODE_REFRESH=1"; exit 0
fi

if [[ -z "$REPO_ROOT" || ! -d "$REPO_ROOT/.git" ]]; then
    log "FATAL: no chump mirror checkout found (set CHUMP_NODE_REPO)"
    emit node_binary_refresh_failed "\"reason\":\"no_repo\""
    exit 1
fi
cd "$REPO_ROOT" || { log "FATAL: cannot cd $REPO_ROOT"; emit node_binary_refresh_failed "\"reason\":\"cwd_failed\""; exit 1; }

# --- fetch + advance the mirror to the last-GREEN main, not raw HEAD --------
# These nodes are pure BUILD MIRRORS (no operator WIP), so a hard reset to the
# green pointer is the correct "make current" operation. If a node ever grows
# a real working tree, guard this behind a clean-tree check.
git fetch origin main --quiet 2>>"$LOG" || log "WARN: git fetch failed (offline?); building local main"

RAW_HEAD_SHA="$(git rev-parse --short=12 origin/main 2>/dev/null || git rev-parse --short=12 HEAD)"
GREEN_SHA="$(_find_green_main_sha)"
if [[ -n "$GREEN_SHA" ]]; then
    RESET_TARGET="$GREEN_SHA"
    MAIN_SHA="$(git rev-parse --short=12 "$GREEN_SHA" 2>/dev/null || echo "${GREEN_SHA:0:12}")"
    log "green-main = $MAIN_SHA  (raw origin/main HEAD = $RAW_HEAD_SHA, repo: $REPO_ROOT)"
    if [[ "$RAW_HEAD_SHA" != "$MAIN_SHA"* ]]; then
        log "PIN: raw HEAD ($RAW_HEAD_SHA) is ahead of green-main ($MAIN_SHA) — staying pinned at green"
        emit node_refresh_green_pin_behind_head "\"green_sha\":\"$MAIN_SHA\",\"raw_head_sha\":\"$RAW_HEAD_SHA\""
    fi
else
    RESET_TARGET="origin/main"
    MAIN_SHA="$RAW_HEAD_SHA"
    log "WARN: no green-main sha found (gh unavailable or no successful $CI_WORKFLOW run); falling back to raw origin/main HEAD = $MAIN_SHA"
    emit node_refresh_green_lookup_failed "\"fallback_sha\":\"$MAIN_SHA\""
fi

INSTALLED_SHA="none"
if [[ -x "$TARGET_BIN" ]]; then
    INSTALLED_SHA="$("$TARGET_BIN" --version 2>/dev/null | grep -oE '\(([a-f0-9]+) built' | head -1 | sed 's/[( ]//g;s/built//' || echo unknown)"
    log "installed $TARGET_BIN sha = $INSTALLED_SHA"
fi

# Idempotency: SHAs match → skip (no cargo).
if [[ "$INSTALLED_SHA" == "$MAIN_SHA"* || "$MAIN_SHA" == "$INSTALLED_SHA"* ]] \
   && [[ "$INSTALLED_SHA" != "none" && "$INSTALLED_SHA" != "unknown" ]]; then
    log "SKIP: binary already current ($INSTALLED_SHA)"
    emit node_binary_refresh_skipped "\"reason\":\"already_current\",\"sha\":\"$INSTALLED_SHA\""
    exit 0
fi

git reset --hard "$RESET_TARGET" >>"$LOG" 2>&1 || {
    log "FATAL: git reset --hard $RESET_TARGET failed"
    emit node_binary_refresh_failed "\"reason\":\"reset_failed\",\"target\":\"$RESET_TARGET\""
    exit 1
}

# --- INFRA-3593: auto-deploy any changed chump-*.service/.timer organ units --
# The mirror just landed whatever merged into origin/main, including any
# chump-*.service/.timer edits (RESILIENT-300 roster). Hand off to
# install-helsinki-atc.sh --auto so a merge auto-installs on helsinki with no
# human step — same "keep current with origin/main" contract this script
# already applies to the binary, extended to the systemd units. Best-effort:
# a failure here must not block the binary refresh above.
DEPLOY_ORGANS="$REPO_ROOT/scripts/setup/install-helsinki-atc.sh"
if [[ -f "$DEPLOY_ORGANS" ]]; then
    NODE_AMBIENT="$NODE_AMBIENT" bash "$DEPLOY_ORGANS" --auto >>"$LOG" 2>&1 \
        || log "WARN: install-helsinki-atc.sh --auto exited non-zero (non-fatal)"
else
    log "WARN: $DEPLOY_ORGANS not found; skipping organ-unit auto-deploy"
fi

# --- resolve cargo -----------------------------------------------------------
CARGO=""
for candidate in "$HOME/.cargo/bin/cargo" "$(command -v cargo 2>/dev/null)" "/usr/local/bin/cargo"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then CARGO="$candidate"; break; fi
done
if [[ -z "$CARGO" ]]; then
    log "FATAL: cargo not found"; emit node_binary_refresh_failed "\"reason\":\"no_cargo\""; exit 1
fi
log "using cargo: $CARGO"

# Build --release into the repo's OWN (warm) target dir. No detached worktree:
# unlike the macOS runner, these nodes have no concurrent self-hosted-runner
# builds racing the tree, and the mirror IS the build tree.
log "cargo build --release --bin chump (warm target $REPO_ROOT/target) …"
if ! PATH="$(dirname "$CARGO"):$PATH" "$CARGO" build --release --bin chump >>"$LOG" 2>&1; then
    log "FATAL: cargo build failed; see $LOG"
    emit node_binary_refresh_failed "\"reason\":\"cargo_build_failed\""
    exit 1
fi
BUILT_BIN="$REPO_ROOT/target/release/chump"
if [[ ! -x "$BUILT_BIN" ]]; then
    log "FATAL: $BUILT_BIN missing after build"
    emit node_binary_refresh_failed "\"reason\":\"binary_missing_post_build\""
    exit 1
fi

# --- atomic install (tempfile + rename); no codesign on Linux ----------------
mkdir -p "$(dirname "$TARGET_BIN")" 2>/dev/null || true
log "install $BUILT_BIN → $TARGET_BIN"
if ! cp -f "$BUILT_BIN" "$TARGET_BIN.new" 2>>"$LOG"; then
    log "FATAL: cp to $TARGET_BIN.new failed"
    emit node_binary_refresh_failed "\"reason\":\"cp_failed\""
    exit 1
fi
chmod +x "$TARGET_BIN.new"
mv -f "$TARGET_BIN.new" "$TARGET_BIN"

NEW_SHA="$("$TARGET_BIN" --version 2>/dev/null | grep -oE '\(([a-f0-9]+) built' | head -1 | sed 's/[( ]//g;s/built//' || echo unknown)"
log "OK: $TARGET_BIN now at sha $NEW_SHA (green-main = $MAIN_SHA)"
emit node_binary_refreshed "\"prev_sha\":\"$INSTALLED_SHA\",\"new_sha\":\"$NEW_SHA\",\"main_sha\":\"$MAIN_SHA\""

# Prune old logs (keep last 24)
ls -t "$LOG_DIR"/refresh-*.log 2>/dev/null | tail -n +25 | xargs -r rm -f 2>/dev/null || true
exit 0
