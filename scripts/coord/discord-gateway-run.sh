#!/usr/bin/env bash
# discord-gateway-run.sh — RESILIENT-266: the launchd entrypoint for the
# Discord gateway.
#
# Thin on purpose. launchd's KeepAlive handles restarts; this script's only jobs
# are (a) refuse to start a SECOND instance, and (b) load .env so the token is
# present.
#
# THE DUPLICATE-INSTANCE GUARD IS NOT DEFENSIVE PADDING. run-discord.sh's own
# header warns: "Only one instance should run; multiple instances cause
# duplicate replies to every message." With KeepAlive plus a manual `run.sh
# discord` during debugging, two instances is the easy accident — and the
# symptom (Chump answering everything twice) reads like a model bug, not an ops
# mistake, so it wastes real time to diagnose.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

LOCK_DIR="${HOME}/.chump"
mkdir -p "$LOCK_DIR" 2>/dev/null || true
PIDFILE="${LOCK_DIR}/discord-gateway.pid"

# Refuse to start if a live instance already holds the pidfile. Verify the PID
# is actually alive — a stale pidfile is exactly what made operator-recall look
# healthy while dead (it pointed at PID 2407 from May with nothing running).
if [[ -f "$PIDFILE" ]]; then
    old="$(cat "$PIDFILE" 2>/dev/null || echo '')"
    if [[ "$old" =~ ^[0-9]+$ ]] && kill -0 "$old" 2>/dev/null; then
        echo "[discord-gateway] refusing to start: PID $old already running" >&2
        exit 0   # exit 0 so launchd does not treat this as a crash loop
    fi
    echo "[discord-gateway] clearing stale pidfile (PID ${old:-<empty>} not alive)" >&2
    rm -f "$PIDFILE"
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT INT TERM

# Load .env for DISCORD_TOKEN / CHUMP_READY_DM_USER_ID. Never echo it.
# Uses the shared resolver: .env is gitignored and lives ONLY in the main
# checkout, while this daemon usually runs from a claim worktree. Sourcing
# "$REPO_ROOT/.env" directly is what made the first launch die with
# "DISCORD_TOKEN unset" while the token was set all along.
# shellcheck source=lib/resolve-env.sh
if [[ -f "$REPO_ROOT/scripts/coord/lib/resolve-env.sh" ]]; then
    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/coord/lib/resolve-env.sh"
    chump_env_load || echo "[discord-gateway] WARN: no .env found in any candidate location" >&2
elif [[ -f "$REPO_ROOT/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$REPO_ROOT/.env" 2>/dev/null || true
    set +a
fi

if [[ -z "${DISCORD_TOKEN:-}" ]]; then
    echo "[discord-gateway] FATAL: DISCORD_TOKEN unset — nothing to connect with" >&2
    exit 1
fi

# Same shared-target-dir resolution as the installer (INFRA-3517): the repo's
# .cargo/config.toml redirects builds to ~/.cargo/chump-shared-target, so
# $REPO_ROOT/target is a symlink on the main checkout and absent in worktrees.
# Run the helper in a SUBSHELL, never source it. discover-chump-bin.sh:57 calls
# `exit 1` when it cannot find a binary — and `exit` inside a sourced file
# terminates the PARENT. Sourcing it killed this daemon with exit 1 and ZERO log
# output, which under launchd looks identical to "started and vanished". The
# `|| true` that used to be here cannot help: exit is not a failing command, it
# is the shell leaving.
if [[ -z "${CHUMP_BIN:-}" && -f "$REPO_ROOT/scripts/ci/lib/discover-chump-bin.sh" ]]; then
    CHUMP_BIN="$(REPO_ROOT="$REPO_ROOT" bash -c '
        source "$REPO_ROOT/scripts/ci/lib/discover-chump-bin.sh" >/dev/null 2>&1
        printf "%s" "${CHUMP_BIN:-}"
    ' 2>/dev/null || true)"
fi
# Fallback chain. The helper needs `cargo` on PATH (it shells out to
# `cargo metadata`), and cargo lives in ~/.cargo/bin under rustup — NOT in
# /opt/homebrew/bin. launchd's minimal PATH therefore silently defeats it, so
# check the shared target dir directly too. ZERO-WASTE-029 points all local
# builds at ~/.cargo/chump-shared-target, and $REPO_ROOT/target is a symlink to
# it on the main checkout and absent in worktrees.
if [[ -z "${CHUMP_BIN:-}" ]]; then
    # The STABLE COPY comes first, deliberately. The shared target dir is
    # rebuilt constantly by the fleet (ZERO-WASTE-029, ~145 workers), so a
    # daemon pointed there loses its --discord binary without warning.
    for _cand in \
        "$HOME/.chump/bin/chump-discord" \
        "$HOME/.cargo/chump-shared-target/release/chump" \
        "$REPO_ROOT/target/release/chump"
    do
        [[ -x "$_cand" ]] && { CHUMP_BIN="$_cand"; break; }
    done
fi
BIN="${CHUMP_BIN:-$REPO_ROOT/target/release/chump}"
[[ -x "$BIN" ]] || { echo "[discord-gateway] FATAL: $BIN missing (build with --features discord)" >&2; exit 1; }

# PRODUCT-014: Discord mode is gated behind CHUMP_DISCORD_ENABLED on TOP of the
# `discord` cargo feature and the --discord flag. Three independent opt-ins, and
# only the third one tells you it exists — the first two fail with unrelated
# messages. This daemon exists to run the gateway, so it sets it explicitly
# rather than making the operator discover the layering.
export CHUMP_DISCORD_ENABLED="${CHUMP_DISCORD_ENABLED:-1}"

echo "[discord-gateway] starting at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
exec "$BIN" --discord
