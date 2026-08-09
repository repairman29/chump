#!/usr/bin/env bash
# install-git-guard-hook.sh — RESILIENT-256 (2026-08-09)
#
# Wire the destructive-git guard into every Claude Code session on this
# machine, fleet-wide, by writing PreToolUse hooks into the USER-scope
# ~/.claude/settings.json.
#
# Why user scope and not just chump's repo-local .claude/settings.json: the
# 2026-08-09 loss happened in ALMANAC, not chump. A guard that only protects
# the repo it was written in protects the one repo that didn't need it. The
# repo-local wiring ships too (see .claude/settings.json) — this installer is
# what makes the other ~95 checkouts safe.
#
#   PreToolUse Bash        → chump git-guard --hook
#       Refuses `git reset --hard` / `checkout -- .` / `restore` /
#       `clean -f` / `worktree remove --force` when the target checkout
#       carries uncommitted changes, naming every file it would destroy.
#
#   PreToolUse Edit|Write  → chump git-guard --hook-write
#       Refuses writes into a PRIMARY checkout that live linked worktrees
#       share. The primary is read-mostly; agents get their own worktree.
#
# Both hooks FAIL OPEN when the chump binary is missing. A seatbelt that
# jams the door shut is worse than no seatbelt, and a hook that errors on
# every Bash call is the fastest way to get the whole hook system disabled.
#
# Usage:
#   scripts/setup/install-git-guard-hook.sh                    # install
#   scripts/setup/install-git-guard-hook.sh --dry-run          # show the diff
#   scripts/setup/install-git-guard-hook.sh --uninstall        # remove ours
#   scripts/setup/install-git-guard-hook.sh --user-settings-path PATH
#   scripts/setup/install-git-guard-hook.sh --no-write-guard   # Bash hook only
#
# Exit codes:
#   0  installed (or already current)
#   1  jq not available
#   3  --dry-run; nothing written

set -euo pipefail

DRY_RUN=0
UNINSTALL=0
WRITE_GUARD=1
TARGET="${HOME}/.claude/settings.json"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)            DRY_RUN=1; shift ;;
        --uninstall)          UNINSTALL=1; shift ;;
        --no-write-guard)     WRITE_GUARD=0; shift ;;
        --user-settings-path) TARGET="$2"; shift 2 ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -E 's/^#[[:space:]]?//'; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

say()  { printf '\033[1;36m[install-git-guard]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[install-git-guard]\033[0m %s\n' "$*" >&2; exit "${2:-1}"; }

command -v jq >/dev/null || die "jq is required (brew install jq)" 1

mkdir -p "$(dirname "$TARGET")"
[[ -f "$TARGET" ]] || echo '{}' > "$TARGET"

TAG="resilient-256-git-guard"

# The hook command. `command -v chump` keeps it fail-open, and the payload is
# piped straight through: the guard parses the tool_input itself so the hook
# line stays free of quoting that jq, bash and JSON would each mangle.
GUARD_CMD='command -v chump >/dev/null 2>&1 && exec chump git-guard --hook || exit 0'
WRITE_CMD='command -v chump >/dev/null 2>&1 && exec chump git-guard --hook-write || exit 0'

DESIRED="$(jq -n --arg tag "$TAG" --arg guard "$GUARD_CMD" --arg write "$WRITE_CMD" \
    --argjson want_write "$WRITE_GUARD" '
{
    PreToolUse: (
        [ { "_chump_tag": $tag, matcher: "Bash",
            hooks: [{ type: "command", command: $guard, async: false }] } ]
        + (if $want_write == 1 then
            [ { "_chump_tag": $tag, matcher: "Edit|Write|NotebookEdit",
                hooks: [{ type: "command", command: $write, async: false }] } ]
          else [] end)
    )
}')"

if [[ "$UNINSTALL" -eq 1 ]]; then
    NEW="$(jq --arg tag "$TAG" '
        if .hooks then
            .hooks |= with_entries(
                .value |= map(select(._chump_tag != $tag))
                | if (.value | length) == 0 then empty else . end
            )
        else . end
        | if (.hooks // {}) == {} then del(.hooks) else . end
    ' "$TARGET")"
else
    NEW="$(jq --argjson desired "$DESIRED" --arg tag "$TAG" '
        .hooks //= {}
        | reduce ($desired | to_entries[]) as $kv (
            .;
            .hooks[$kv.key] = (
                ((.hooks[$kv.key] // []) | map(select(._chump_tag != $tag)))
                + $kv.value
            )
        )
    ' "$TARGET")"
fi

OLD="$(cat "$TARGET")"
if [[ "$OLD" == "$NEW" ]]; then
    say "no changes needed (already current)"
    exit 0
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
    say "dry-run; would write this diff to $TARGET"
    diff <(printf '%s\n' "$OLD" | jq -S .) <(printf '%s\n' "$NEW" | jq -S .) || true
    exit 3
fi

cp "$TARGET" "$TARGET.bak.$(date +%s)"
tmp="$TARGET.tmp.$$"
printf '%s\n' "$NEW" > "$tmp"
jq . "$tmp" >/dev/null || { rm -f "$tmp"; die "generated invalid JSON; aborting"; }
mv "$tmp" "$TARGET"

if [[ "$UNINSTALL" -eq 1 ]]; then
    say "uninstalled RESILIENT-256 git-guard hooks from $TARGET"
else
    say "installed RESILIENT-256 git-guard hooks into $TARGET"
    say "  PreToolUse Bash              → chump git-guard --hook"
    [[ "$WRITE_GUARD" -eq 1 ]] && \
    say "  PreToolUse Edit|Write        → chump git-guard --hook-write"
    say ""
    say "Verify without waiting for a session:"
    say "  chump git-guard --check 'git reset --hard' --cwd <a dirty checkout>  # exit 2"
    say "  chump git-guard --check 'git reset --hard' --cwd <a clean checkout>  # exit 0"
    say ""
    say "Escape hatches: CHUMP_ALLOW_DESTRUCTIVE_GIT=1 (audited),"
    say "                CHUMP_PRIMARY_WRITE_GUARD=warn|off"
fi

exit 0
