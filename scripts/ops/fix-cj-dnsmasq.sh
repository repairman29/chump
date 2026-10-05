#!/usr/bin/env bash
# scripts/ops/fix-cj-dnsmasq.sh — INFRA-8034
#
# CJ's dnsmasq.service has been in `failed` state since at least 2026-09-26
# (surfaced during a CJ health check). The fleet does not use dnsmasq — it's a
# leftover, likely conflicting with systemd-resolved — so the fix is to
# disable+mask it rather than debug its config. CJ's two OTHER failed units
# (chump-backlog-sync-writer, chump-organ-deploy) are expected/intentional and
# are deliberately left untouched by this script.
#
# dnsmasq.service is a SYSTEM unit (not --user), so disabling/masking it needs
# root. CJ has no passwordless sudo (same constraint that makes
# chump-organ-deploy's failure expected — see INFRA-8034 gap notes), so this
# script cannot silently self-elevate: it runs the sudo commands directly
# (prompting interactively, same as any operator-run maintenance command) and
# prints the exact commands to run by hand if sudo isn't available/non-interactive.
#
# Idempotent: safe to re-run. No-ops cleanly (exit 0) when dnsmasq.service
# doesn't exist on this node at all (e.g. run by mistake on a non-CJ box) or is
# already disabled+masked.
#
# Usage: bash scripts/ops/fix-cj-dnsmasq.sh [--dry-run]

set -uo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

UNIT="dnsmasq.service"

if ! command -v systemctl >/dev/null 2>&1; then
    echo "no systemctl on this host — nothing to do (not a systemd Linux node)"
    exit 0
fi

if ! systemctl list-unit-files "$UNIT" >/dev/null 2>&1 \
    || ! systemctl list-unit-files "$UNIT" 2>/dev/null | grep -q "$UNIT"; then
    echo "$UNIT not installed on this node — nothing to do"
    exit 0
fi

STATE="$(systemctl is-failed "$UNIT" 2>/dev/null || true)"

if [[ "$STATE" != "failed" ]]; then
    MASKED="$(systemctl is-enabled "$UNIT" 2>/dev/null || true)"
    if [[ "$MASKED" == "masked" ]]; then
        echo "$UNIT already masked and not failed — nothing to do"
    else
        echo "$UNIT is not in failed state (is-failed=$STATE) — nothing to do"
    fi
    exit 0
fi

echo "$UNIT is in failed state — disabling + masking (fleet does not use dnsmasq)"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] would run: sudo systemctl disable --now $UNIT"
    echo "[dry-run] would run: sudo systemctl mask $UNIT"
    echo "[dry-run] would run: sudo systemctl reset-failed $UNIT"
    exit 0
fi

if sudo -n true 2>/dev/null; then
    SUDO="sudo -n"
elif [[ -t 0 ]]; then
    SUDO="sudo"
else
    cat <<EOF
No passwordless sudo and no interactive terminal — cannot self-elevate.
Run these commands by hand on closetjunky (CJ) as the operator:

    sudo systemctl disable --now $UNIT
    sudo systemctl mask $UNIT
    sudo systemctl reset-failed $UNIT

Then confirm with: systemctl --failed
EOF
    exit 1
fi

$SUDO systemctl disable --now "$UNIT" || echo "WARN: disable --now $UNIT failed" >&2
$SUDO systemctl mask "$UNIT" || echo "WARN: mask $UNIT failed" >&2
$SUDO systemctl reset-failed "$UNIT" 2>/dev/null || true

echo ""
echo "=== systemctl --failed after fix ==="
systemctl --failed --no-legend 2>/dev/null || true
