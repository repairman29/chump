#!/usr/bin/env bash
# rebase-daemon.sh — INFRA-1405
#
# Event-driven auto-rebase, replacing the 2h pr-rescue.sh cron with a
# same-second reaction to "main moved" — without hard-coupling to GitHub.
#
# Two equivalent triggers both produce ambient kind=branch_rebase_needed:
#   TRIGGER_LOCAL   — a local git hook (post-commit/post-merge on main, or a
#                      bare-repo post-receive) fires whenever local main's
#                      HEAD moves. Works fully offline (Pi-mesh / single-
#                      machine case). See `install-hook` below.
#   TRIGGER_WEBHOOK — scripts/ops/github-webhook-receiver.py emits the same
#                      event kind on `push` to main or `pull_request.synchronize`.
#
# This daemon subscribes to kind=branch_rebase_needed (via `tick`, called
# from the hook or the webhook receiver, or via `watch`, which tails
# ambient.jsonl) and rebases every open local feature branch that is behind
# the trigger's base branch, in a throwaway worktree (never touches the
# caller's working directory), then fast-forwards the real branch ref.
#
# Usage:
#   rebase-daemon.sh emit-local-trigger [--base <branch>]
#       Append a kind=branch_rebase_needed event (trigger=local_hook). Called
#       by the installed git hook — cheap, no rebase work itself.
#   rebase-daemon.sh tick [--base <branch>] [--only <branch>]
#       Process one sweep: rebase every open branch behind <base> (default:
#       main). Safe to call repeatedly (idempotent — already-rebased branches
#       are a fast no-op).
#   rebase-daemon.sh watch [--base <branch>]
#       Tail ambient.jsonl; call `tick` whenever a fresh branch_rebase_needed
#       event appears. Runs until killed.
#   rebase-daemon.sh install-hook [--repo <path>]
#       Install a post-commit hook on the given repo (default: this repo)
#       that calls `emit-local-trigger` whenever HEAD moves on main.
#
# Env:
#   CHUMP_REPO_ROOT      — repo to operate on (default: this repo's toplevel)
#   CHUMP_AMBIENT_LOG    — ambient.jsonl path (default: $REPO_ROOT/.chump-locks/ambient.jsonl)
#   CHUMP_GITHUB_MODE    — "offline" disables any gh/network fallback path
#   REBASE_DAEMON_RETRY  — TRANSIENT-failure retry count (default: 2)
#   REBASE_DAEMON_RETRY_BACKOFF_S — seconds between retries (default: 2)
#
# Exit: 0 always (per-branch failures are soft — see failure-class taxonomy
# in the gap AC; a daemon that dies on one bad branch stops rebasing every
# other branch, which is worse than the stale-rebase problem it's fixing).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)}"

AMBIENT_LIB="${SCRIPT_DIR}/lib/ambient-write.sh"
if [[ -f "$AMBIENT_LIB" ]]; then
    # shellcheck source=scripts/coord/lib/ambient-write.sh disable=SC1091
    source "$AMBIENT_LIB"
else
    _ambient_write() { printf '%s\n' "$2" >> "$1" 2>/dev/null || true; }
fi

AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"
GITHUB_MODE="${CHUMP_GITHUB_MODE:-auto}"
RETRY_N="${REBASE_DAEMON_RETRY:-2}"
RETRY_BACKOFF_S="${REBASE_DAEMON_RETRY_BACKOFF_S:-2}"

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_emit() {
    # $1 = kind, $2.. = extra "key":val pairs already JSON-escaped by caller
    local kind="$1"; shift
    local extra="${1:-}"
    local line
    if [[ -n "$extra" ]]; then
        line="$(printf '{"ts":"%s","kind":"%s",%s}' "$(_now_iso)" "$kind" "$extra")"
    else
        line="$(printf '{"ts":"%s","kind":"%s"}' "$(_now_iso)" "$kind")"
    fi
    mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
    _ambient_write "$AMBIENT_LOG" "$line"
}

_jesc() {
    # Minimal JSON-string escape for interpolated values.
    printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' 2>/dev/null \
        || printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# ── emit-local-trigger ──────────────────────────────────────────────────────
cmd_emit_local_trigger() {
    local base="main"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base) base="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    local sha
    sha="$(git -C "$REPO_ROOT" rev-parse "$base" 2>/dev/null || echo unknown)"
    _emit "branch_rebase_needed" "$(printf '"trigger":"local_hook","base":"%s","sha":"%s"' \
        "$(_jesc "$base")" "$(_jesc "$sha")")"
    echo "rebase-daemon: emitted branch_rebase_needed (local_hook, base=$base sha=${sha:0:12})"
}

# ── Per-branch rebase (throwaway worktree, never touches caller's tree) ────
# Echoes one of: succeeded|blocked|transient|noop
_rebase_one_branch() {
    local branch="$1" base="$2"
    local base_sha branch_sha
    base_sha="$(git -C "$REPO_ROOT" rev-parse "$base" 2>/dev/null)" || { echo "transient"; return; }
    branch_sha="$(git -C "$REPO_ROOT" rev-parse "$branch" 2>/dev/null)" || { echo "transient"; return; }

    if git -C "$REPO_ROOT" merge-base --is-ancestor "$base_sha" "$branch_sha" 2>/dev/null; then
        echo "noop"
        return
    fi

    local wt
    wt="$(mktemp -d "${TMPDIR:-/tmp}/rebase-daemon-XXXXXX")"
    if ! git -C "$REPO_ROOT" worktree add --detach --quiet "$wt" "$branch" >/dev/null 2>&1; then
        rm -rf "$wt" 2>/dev/null || true
        echo "transient"
        return
    fi

    local rc=0
    ( cd "$wt" && git rebase "$base_sha" >/dev/null 2>&1 ) || rc=$?

    if [[ $rc -eq 0 ]]; then
        local new_sha
        new_sha="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
        # Fast-forward the real branch ref onto the rebased tip.
        if git -C "$REPO_ROOT" branch -f "$branch" "$new_sha" >/dev/null 2>&1; then
            echo "succeeded"
        else
            echo "transient"
        fi
    else
        ( cd "$wt" && git rebase --abort >/dev/null 2>&1 ) || true
        echo "blocked"
    fi

    git -C "$REPO_ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt" 2>/dev/null || true
}

_list_open_branches() {
    local base="$1"
    git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' refs/heads/ \
        | grep -vx "$base" || true
}

# ── tick ─────────────────────────────────────────────────────────────────
cmd_tick() {
    local base="main" only=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base) base="$2"; shift 2 ;;
            --only) only="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    # DEGRADED: local hook missing entirely (no post-commit hook on main and
    # no webhook receiver configured) — surface it so an operator falls back
    # to opportunistic rebase-on-claim instead of assuming this daemon covers it.
    local hooks_dir
    hooks_dir="$(git -C "$REPO_ROOT" rev-parse --git-path hooks 2>/dev/null || echo "")"
    if [[ -n "$hooks_dir" && ! -x "${REPO_ROOT}/${hooks_dir#"$REPO_ROOT"/}/post-commit" && ! -x "${hooks_dir}/post-commit" ]]; then
        _emit "rebase_signal_degraded" '"reason":"local_hook_missing"'
    fi

    local branches
    if [[ -n "$only" ]]; then
        branches="$only"
    else
        branches="$(_list_open_branches "$base")"
    fi

    local started_n=0 ok_n=0 blocked_n=0
    while IFS= read -r branch; do
        [[ -z "$branch" ]] && continue
        local t0 status attempt
        t0="$(date +%s)"
        _emit "branch_rebase_started" "$(printf '"branch":"%s","base":"%s"' "$(_jesc "$branch")" "$(_jesc "$base")")"
        started_n=$((started_n + 1))

        attempt=0
        status="transient"
        while :; do
            status="$(_rebase_one_branch "$branch" "$base")"
            [[ "$status" != "transient" ]] && break
            attempt=$((attempt + 1))
            [[ $attempt -gt "$RETRY_N" ]] && break
            sleep "$RETRY_BACKOFF_S"
        done

        local dt=$(( $(date +%s) - t0 ))
        case "$status" in
            succeeded)
                ok_n=$((ok_n + 1))
                _emit "branch_rebase_succeeded" "$(printf '"branch":"%s","duration_s":%d,"conflicts_auto_resolved":0' \
                    "$(_jesc "$branch")" "$dt")"
                ;;
            blocked)
                blocked_n=$((blocked_n + 1))
                _emit "branch_rebase_blocked" "$(printf '"branch":"%s","reason":"rebase_conflict_unresolvable_by_drivers"' \
                    "$(_jesc "$branch")")"
                if [[ "$GITHUB_MODE" != "offline" ]] && command -v gh >/dev/null 2>&1; then
                    gh pr edit "$branch" --add-label needs-human >/dev/null 2>&1 || true
                fi
                ;;
            transient)
                _emit "branch_rebase_blocked" "$(printf '"branch":"%s","reason":"network_blip_during_fetch"' "$(_jesc "$branch")")"
                ;;
            noop) ;;
        esac
    done <<< "$branches"

    echo "rebase-daemon: tick base=$base started=$started_n succeeded=$ok_n blocked=$blocked_n"
}

# ── watch ────────────────────────────────────────────────────────────────
cmd_watch() {
    local base="main"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base) base="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
    touch "$AMBIENT_LOG"
    echo "rebase-daemon: watching $AMBIENT_LOG for kind=branch_rebase_needed (base=$base)"
    tail -n0 -F "$AMBIENT_LOG" 2>/dev/null | while IFS= read -r line; do
        case "$line" in
            *'"kind":"branch_rebase_needed"'*) cmd_tick --base "$base" ;;
        esac
    done
}

# ── install-hook ─────────────────────────────────────────────────────────
cmd_install_hook() {
    local target="$REPO_ROOT"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) target="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    local hooks_dir
    hooks_dir="$(git -C "$target" rev-parse --git-path hooks 2>/dev/null)" || { echo "rebase-daemon: not a git repo: $target" >&2; return 1; }
    local hook_path="${target}/${hooks_dir#"$target"/}/post-commit"
    [[ "$hooks_dir" = /* ]] && hook_path="${hooks_dir}/post-commit"
    cat > "$hook_path" <<HOOK
#!/usr/bin/env bash
# Installed by rebase-daemon.sh install-hook (INFRA-1405). Fires whenever
# HEAD moves on the checked-out branch. Cheap: only emits an event, the
# daemon (watch/tick) does the actual rebase work.
branch="\$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
[[ "\$branch" == "main" ]] || exit 0
"${SCRIPT_DIR}/rebase-daemon.sh" emit-local-trigger --base main >/dev/null 2>&1 &
disown 2>/dev/null || true
exit 0
HOOK
    chmod +x "$hook_path"
    echo "rebase-daemon: installed post-commit hook at $hook_path"
}

# ── dispatch ─────────────────────────────────────────────────────────────
sub="${1:-}"; shift || true
case "$sub" in
    emit-local-trigger) cmd_emit_local_trigger "$@" ;;
    tick)               cmd_tick "$@" ;;
    watch)              cmd_watch "$@" ;;
    install-hook)       cmd_install_hook "$@" ;;
    ""|-h|--help)
        sed -n '1,40p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "rebase-daemon: unknown subcommand '$sub'" >&2
        exit 2
        ;;
esac
