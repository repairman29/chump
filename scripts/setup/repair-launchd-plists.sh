#!/usr/bin/env bash
# repair-launchd-plists.sh — INFRA-221
#
# Audit + repair every chump-prefixed launchd plist in ~/Library/LaunchAgents/.
# Detects the failure mode that broke 11 of 12 chump auto-ops on this machine:
# scripts moved from `scripts/` flat into `scripts/{ops,dev,eval}/`, but the
# installed plists kept pointing at the old locations. launchd kept invoking
# them hourly, every run exit-127 (file not found), nothing ever got cleaned
# up. ~85 GB of stale worktrees accumulated.
#
# Behavior:
#   1. Lists every ~/Library/LaunchAgents/{ai.openclaw.chump-*,ai.chump.*,com.chump.*}.plist
#   2. For each, extracts every <string>/path/to/script.sh</string>.
#   3. If the script doesn't exist at the cited path, searches the repo by
#      basename (excluding target/ and .claude/worktrees/) for the new home.
#   4. If exactly one match: rewrites the plist (with .bak), reloads.
#      If zero or multiple: reports the conflict, leaves the plist alone.
#   5. Always reports each plist's current launchctl exit status.
#
# Usage:
#   scripts/setup/repair-launchd-plists.sh             # repair + reload
#   scripts/setup/repair-launchd-plists.sh --dry-run   # report only, no changes
#   scripts/setup/repair-launchd-plists.sh --audit     # alias for --dry-run
#
# Exit codes:
#   0  all chump plists either healthy or repaired
#   1  one or more plists couldn't be auto-repaired (manual intervention needed)

set -euo pipefail

DRY_RUN=0
case "${1:-}" in
    --dry-run|--audit) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    "") ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
esac

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi

LAUNCHAGENTS="$HOME/Library/LaunchAgents"

say()  { printf '\033[1;36m[repair-launchd]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[repair-launchd]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[repair-launchd]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m[repair-launchd]\033[0m %s\n' "$*"; }

UNFIXED=0

shopt -s nullglob
PLISTS=()
# All ai.openclaw.* plists (chump-prefixed AND siblings like farmer-brown that
# coexist on the same machine and share the same broken-path failure mode),
# plus ai.chump.* / com.chump.* legacy labels.
for p in "$LAUNCHAGENTS"/ai.openclaw.*.plist \
         "$LAUNCHAGENTS"/ai.chump.*.plist \
         "$LAUNCHAGENTS"/com.chump.*.plist; do
    PLISTS+=("$p")
done
shopt -u nullglob

if [[ "${#PLISTS[@]}" -eq 0 ]]; then
    say "no chump-prefixed plists installed in $LAUNCHAGENTS"
    exit 0
fi

say "auditing ${#PLISTS[@]} chump plist(s)..."

for plist in "${PLISTS[@]}"; do
    label="$(basename "$plist" .plist)"
    echo
    say "=== $label ==="

    # Extract every absolute script path referenced inside <string>...</string>.
    SCRIPTS=()
    while IFS= read -r path; do
        [[ -n "$path" ]] && SCRIPTS+=("$path")
    done < <(grep -oE '/[^<>"[:space:]]+\.sh' "$plist" | sort -u)

    if [[ "${#SCRIPTS[@]}" -eq 0 ]]; then
        say "  no .sh references — skip"
        continue
    fi

    PLIST_CHANGED=0
    for old_path in "${SCRIPTS[@]}"; do
        if [[ -f "$old_path" ]]; then
            ok "  ✓ $old_path exists"
            continue
        fi

        warn "  ✗ $old_path missing — searching for replacement"
        basename="$(basename "$old_path")"
        # Find script under MAIN_REPO, excluding target/ and worktree mirrors.
        # Use a portable while-read loop instead of bash-only `readarray`.
        MATCHES=()
        while IFS= read -r match; do
            [[ -n "$match" ]] && MATCHES+=("$match")
        done < <(
            find "$MAIN_REPO" -name "$basename" -type f \
                -not -path '*/target/*' \
                -not -path '*/.claude/worktrees/*' \
                -not -path '*/.chump/worktrees/*' \
                -not -path '*/node_modules/*' \
                2>/dev/null
        )

        if [[ "${#MATCHES[@]}" -eq 0 ]]; then
            err "    no candidates found in $MAIN_REPO — manual fix needed"
            UNFIXED=$((UNFIXED + 1))
            continue
        fi
        if [[ "${#MATCHES[@]}" -gt 1 ]]; then
            err "    ${#MATCHES[@]} candidates found — pick one manually:"
            printf '      %s\n' "${MATCHES[@]}" >&2
            UNFIXED=$((UNFIXED + 1))
            continue
        fi

        new_path="${MATCHES[0]}"
        ok "    → $new_path"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            say "    (dry-run; no changes written)"
            continue
        fi
        # In-place sed; .bak preserved beside the plist.
        /usr/bin/sed -i.bak "s|${old_path}|${new_path}|g" "$plist"
        PLIST_CHANGED=1
    done

    # WorkingDirectory check: when a plist was installed from a linked worktree,
    # WorkingDirectory captures that worktree's path. If the worktree was reaped,
    # launchctl silently fails to start the job. Rewrite to MAIN_REPO when the
    # captured path is a missing /.../{.claude,.chump}/worktrees/<name> subpath.
    wd="$(plutil -extract WorkingDirectory xml1 -o - "$plist" 2>/dev/null \
              | grep -oE '<string>[^<]+</string>' | head -1 | sed 's/<[^>]*>//g')"
    if [[ -n "$wd" && ! -d "$wd" ]]; then
        if echo "$wd" | grep -qE '/\.(claude|chump)/worktrees/'; then
            warn "  ✗ WorkingDirectory $wd missing (reaped worktree) — rewriting to $MAIN_REPO"
            if [[ "$DRY_RUN" -eq 1 ]]; then
                say "    (dry-run; no changes written)"
            else
                /usr/bin/sed -i.bak "s|<string>${wd}</string>|<string>${MAIN_REPO}</string>|" "$plist"
                PLIST_CHANGED=1
            fi
        else
            err "    WorkingDirectory $wd missing — manual fix needed"
            UNFIXED=$((UNFIXED + 1))
        fi
    fi

    # Reload only if we changed anything (and not dry-run).
    if [[ "$PLIST_CHANGED" -eq 1 && "$DRY_RUN" -eq 0 ]]; then
        launchctl unload "$plist" 2>/dev/null || true
        if launchctl load "$plist" 2>/dev/null; then
            ok "  reloaded"
        else
            err "  reload failed — check 'launchctl load $plist' manually"
            UNFIXED=$((UNFIXED + 1))
        fi
    fi

    # Report current exit status (informational; non-zero = last run failed).
    status_line="$(launchctl list 2>/dev/null | awk -v lbl="$label" '$3 == lbl {print "exit=" $2}' | head -1)"
    [[ -n "$status_line" ]] && say "  launchctl: $status_line"
done

echo
if [[ "$UNFIXED" -gt 0 ]]; then
    err "${UNFIXED} plist(s) could not be auto-repaired — manual intervention needed"
    exit 1
fi
ok "all chump plists healthy"
