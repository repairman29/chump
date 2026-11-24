#!/usr/bin/env bash
# migrate-openclaw-launchd.sh — INFRA-323: rename installed launchd Labels
# from the legacy `ai.openclaw.*` prefix to project-owned `dev.chump.*`.
#
# Idempotent. Safe to re-run on a machine that's already migrated.
#
# What this does (per discovered ai.openclaw.* label):
#   1. Read the existing plist at ~/Library/LaunchAgents/ai.openclaw.<X>.plist
#   2. Compute new label: dev.chump.<X-without-leading-chump-> (e.g.
#      ai.openclaw.chump-gap-doctor-cron → dev.chump.gap-doctor-cron;
#      ai.openclaw.farmer-brown          → dev.chump.farmer-brown).
#   3. Re-run the corresponding scripts/setup/install-*-launchd.sh which now
#      ships the new label, OR if no installer exists, copy the plist with
#      Label rewritten.
#   4. launchctl unload old, launchctl load new.
#   5. Move old plist file aside as .old (not deleted in case of issues).
#
# After successful migration `launchctl list | grep dev.chump` should show
# all of the previously-loaded openclaw jobs.
#
# Disable / dry-run: CHUMP_MIGRATE_DRY_RUN=1 ./scripts/setup/migrate-openclaw-launchd.sh

set -euo pipefail

LAUNCHAGENTS="$HOME/Library/LaunchAgents"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DRY="${CHUMP_MIGRATE_DRY_RUN:-0}"

[[ "$DRY" == "1" ]] && echo "[migrate] DRY RUN — no changes will be applied" >&2

# Discover all installed plists matching the legacy prefix.
shopt -s nullglob
OLD_PLISTS=("$LAUNCHAGENTS"/ai.openclaw.*.plist)
shopt -u nullglob

if [[ ${#OLD_PLISTS[@]} -eq 0 ]]; then
    echo "[migrate] no ai.openclaw.* plists found in $LAUNCHAGENTS — nothing to do."
    exit 0
fi

echo "[migrate] found ${#OLD_PLISTS[@]} legacy ai.openclaw.* plist(s):"
for p in "${OLD_PLISTS[@]}"; do echo "  - $(basename "$p")"; done
echo ""

migrated=0
for old_plist in "${OLD_PLISTS[@]}"; do
    [[ "$old_plist" == *.bak ]] && continue
    [[ "$old_plist" == *.old ]] && continue

    old_label_full="$(basename "$old_plist" .plist)"               # ai.openclaw.chump-foo
    suffix="${old_label_full#ai.openclaw.}"                         # chump-foo OR farmer-brown
    new_suffix="${suffix#chump-}"                                   # foo OR farmer-brown
    new_label="dev.chump.$new_suffix"                               # dev.chump.foo
    new_plist="$LAUNCHAGENTS/$new_label.plist"
    installer="$REPO/scripts/setup/install-${new_suffix}-launchd.sh"

    echo "[migrate] $old_label_full → $new_label"

    if [[ "$DRY" == "1" ]]; then
        if [[ -x "$installer" ]]; then
            echo "  would: launchctl unload $old_plist; mv $old_plist ${old_plist}.old; bash $installer"
        else
            echo "  would: launchctl unload $old_plist; sed Label rewrite $old_plist → $new_plist; launchctl load $new_plist; mv $old_plist ${old_plist}.old"
        fi
        continue
    fi

    # Unload old
    launchctl unload "$old_plist" 2>/dev/null || true

    if [[ -x "$installer" ]]; then
        # Preferred path: re-run installer; it'll write fresh plist with new Label.
        bash "$installer" >/dev/null 2>&1
        echo "  ✓ re-installed via $installer"
    else
        # Fallback: rewrite Label in-place to a new file.
        sed -e "s|ai.openclaw.chump-|dev.chump.|g" -e "s|ai.openclaw.|dev.chump.|g" \
            "$old_plist" > "$new_plist"
        launchctl load "$new_plist"
        echo "  ✓ rewrote + loaded $new_plist (no installer found for $new_suffix — fallback path)"
    fi

    # Archive the old plist so we can roll back if needed.
    mv "$old_plist" "${old_plist}.old"
    migrated=$((migrated + 1))
done

echo ""
echo "[migrate] migrated $migrated plist(s)."
echo "[migrate] verify: launchctl list | grep dev.chump"
echo "[migrate] rollback: mv ~/Library/LaunchAgents/ai.openclaw.*.plist.old → .plist + launchctl unload/load"
