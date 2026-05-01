#!/usr/bin/env bash
# install-ambient-hooks.sh — FLEET-022
#
# Idempotent one-command installer that wires every Claude Code session on
# this machine into the ambient peripheral-vision stream:
#
#   SessionStart  → scripts/coord/ambient-context-inject.sh SessionStart
#                   (auto-injects last 30 events + active leases as system
#                    context — replaces the manual `tail -30` step in CLAUDE.md)
#   PreToolUse    → scripts/coord/ambient-context-inject.sh PreToolUse
#                   (re-injects on flow-point commands: git commit, gh pr,
#                    chump gap claim, bot-merge.sh — catches siblings who
#                    started after our SessionStart)
#   PostToolUse   → scripts/dev/ambient-emit.sh
#                   (writes the agent's own actions to the stream — already
#                    shipped under FLEET-004c; we re-assert it here so the
#                    matrix is whole regardless of prior state)
#   Stop          → scripts/coord/ambient-session-end.sh
#                   (emits session_end + best-effort lease release)
#
# Usage:
#   scripts/setup/install-ambient-hooks.sh             # write hooks
#   scripts/setup/install-ambient-hooks.sh --dry-run   # print planned diff
#   scripts/setup/install-ambient-hooks.sh --user-settings-path PATH
#                                                      # override target file
#   scripts/setup/install-ambient-hooks.sh --uninstall  # remove our hooks
#                                                      # (preserves non-ambient hooks)
#
# Exit codes:
#   0  installed (or already current)
#   1  jq not available
#   2  target settings file not writable
#   3  user passed --dry-run; no changes written

set -euo pipefail

DRY_RUN=0
UNINSTALL=0
TARGET="${HOME}/.claude/settings.json"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)               DRY_RUN=1; shift ;;
        --uninstall)             UNINSTALL=1; shift ;;
        --user-settings-path)    TARGET="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Repo-relative script paths. Hooks resolve $REPO at fire time via
# `git rev-parse --show-toplevel` so the same settings.json keeps working
# whether the user opened the main checkout or a linked worktree.
INJECT_REL="scripts/coord/ambient-context-inject.sh"
EMIT_REL="scripts/dev/ambient-emit.sh"
SESSION_END_REL="scripts/coord/ambient-session-end.sh"

say()  { printf '\033[1;36m[install-ambient-hooks]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install-ambient-hooks]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[install-ambient-hooks]\033[0m %s\n' "$*" >&2; exit "${2:-1}"; }

command -v jq >/dev/null || die "jq is required (brew install jq)" 1

# ── Ensure target exists ──────────────────────────────────────────────────────
mkdir -p "$(dirname "$TARGET")"
if [[ ! -f "$TARGET" ]]; then
    echo '{}' > "$TARGET"
fi

# ── Verify our scripts are present in the current checkout ───────────────────
# This proves the worktree we're installing from will, after merge, satisfy
# every hook reference. Hooks themselves resolve $REPO at fire time.
for rel in "$INJECT_REL" "$EMIT_REL" "$SESSION_END_REL"; do
    [[ -f "$REPO_ROOT/$rel" ]] || die "missing script in this checkout: $rel" 1
    chmod +x "$REPO_ROOT/$rel" 2>/dev/null || true
done

# ── Build the desired hooks block ─────────────────────────────────────────────
# Marker tag lets us identify and replace our own entries idempotently.
TAG="fleet-019-ambient"

DESIRED_HOOKS_JSON="$(jq -n \
    --arg inject_rel  "$INJECT_REL" \
    --arg emit_rel    "$EMIT_REL" \
    --arg sessend_rel "$SESSION_END_REL" \
    --arg tag         "$TAG" '
def cmd_inject(ev): "REPO=$(git rev-parse --show-toplevel 2>/dev/null) && [ -x \"$REPO/\($inject_rel)\" ] && \"$REPO/\($inject_rel)\" \(ev) 2>/dev/null || true";
def cmd_emit(kind; field):
    "REPO=$(git rev-parse --show-toplevel 2>/dev/null) && [ -x \"$REPO/\($emit_rel)\" ] && jq -r ''\(field) // \"\"'' | { read -r v; [ -n \"$v\" ] && \"$REPO/\($emit_rel)\" \(kind) \"\(if kind == "file_edit" then "path" else "cmd" end)=${v:0:80}\"; } 2>/dev/null || true";
def cmd_sessend: "REPO=$(git rev-parse --show-toplevel 2>/dev/null) && [ -x \"$REPO/\($sessend_rel)\" ] && \"$REPO/\($sessend_rel)\" 2>/dev/null || true";
{
    SessionStart: [
        {
            "_chump_tag": $tag,
            hooks: [{
                type: "command",
                command: cmd_inject("SessionStart"),
                async: false
            }]
        }
    ],
    PreToolUse: [
        {
            "_chump_tag": $tag,
            matcher: "Bash",
            hooks: [{
                type: "command",
                command: ("jq -r .tool_input.command 2>/dev/null | grep -qE \"^(git commit|gh pr |chump gap claim|.*bot-merge\\\\.sh)\" && " + cmd_inject("PreToolUse")),
                async: false
            }]
        }
    ],
    PostToolUse: [
        {
            "_chump_tag": $tag,
            matcher: "Edit|Write",
            hooks: [{
                type: "command",
                command: cmd_emit("file_edit"; ".tool_input.file_path // .tool_input.path"),
                async: true
            }]
        },
        {
            "_chump_tag": $tag,
            matcher: "Bash",
            hooks: [{
                type: "command",
                command: cmd_emit("bash_call"; ".tool_input.command"),
                async: true
            }]
        }
    ],
    Stop: [
        {
            "_chump_tag": $tag,
            hooks: [{
                type: "command",
                command: cmd_sessend,
                async: true
            }]
        }
    ]
}
')"

# ── Compute new settings.json content ────────────────────────────────────────
# Strategy: drop any existing entries marked _chump_tag == $TAG, then append our
# desired entries. Preserves all unrelated hooks (and non-hooks fields).
# Detector for "this entry is one of ours" — by tag OR by referenced script
# path. Catches pre-FLEET-019 inline hooks the user installed by hand so a
# single `install-ambient-hooks.sh` run leaves them with exactly our set.
OWNED_PATTERN='ambient-emit\.sh|ambient-context-inject\.sh|ambient-session-end\.sh'

if [[ "$UNINSTALL" -eq 1 ]]; then
    NEW="$(jq --arg tag "$TAG" --arg pat "$OWNED_PATTERN" '
        def is_ours: (._chump_tag == $tag)
            or ((.hooks // []) | any(.command // "" | test($pat)));
        if .hooks then
            .hooks |= with_entries(
                .value |= (map(select((is_ours) | not)))
                | if (.value | length) == 0 then empty else . end
            )
        else . end
        | if (.hooks // {}) == {} then del(.hooks) else . end
    ' "$TARGET")"
else
    NEW="$(jq --argjson desired "$DESIRED_HOOKS_JSON" --arg tag "$TAG" --arg pat "$OWNED_PATTERN" '
        def is_ours: (._chump_tag == $tag)
            or ((.hooks // []) | any(.command // "" | test($pat)));
        .hooks //= {}
        | reduce ($desired | to_entries[]) as $kv (
            .;
            .hooks[$kv.key] = (
                ((.hooks[$kv.key] // []) | map(select((is_ours) | not)))
                + $kv.value
            )
        )
    ' "$TARGET")"
fi

# ── Compare + write ──────────────────────────────────────────────────────────
OLD="$(cat "$TARGET")"
if [[ "$OLD" == "$NEW" ]]; then
    say "no changes needed (already current)"
    exit 0
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
    say "dry-run; would write the following diff to $TARGET"
    diff <(printf '%s\n' "$OLD" | jq -S .) <(printf '%s\n' "$NEW" | jq -S .) || true
    exit 3
fi

# Backup before writing
cp "$TARGET" "$TARGET.bak.$(date +%s)"

# Atomic write
tmp="$TARGET.tmp.$$"
printf '%s\n' "$NEW" > "$tmp"
# Validate JSON before overwriting
jq . "$tmp" >/dev/null || { rm -f "$tmp"; die "generated invalid JSON; aborting"; }
mv "$tmp" "$TARGET"

if [[ "$UNINSTALL" -eq 1 ]]; then
    say "uninstalled FLEET-019 ambient hooks from $TARGET"
else
    say "installed FLEET-019 ambient hooks into $TARGET"
    say "  SessionStart → \$REPO/$INJECT_REL SessionStart"
    say "  PreToolUse   → \$REPO/$INJECT_REL PreToolUse  (Bash matcher on commit/pr/claim/bot-merge)"
    say "  PostToolUse  → \$REPO/$EMIT_REL  (Edit|Write|Bash)"
    say "  Stop         → \$REPO/$SESSION_END_REL"
    say ""
    say "Verify: open a new Claude session in this repo. The first turn should see"
    say "        an 'Ambient stream (FLEET-019 matrix wiring, hook=SessionStart)' block"
    say "        injected as system context. Disable per-session with"
    say "        CHUMP_AMBIENT_INJECT=0 in the environment."
fi

exit 0
