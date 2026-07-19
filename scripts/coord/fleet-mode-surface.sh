#!/usr/bin/env bash
# scripts/coord/fleet-mode-surface.sh — INFRA-1718
#
# SessionStart hook: prints the one-line auth + backend + cost-ceiling
# surface (`chump fleet mode`) so every session opens knowing which
# credential/backend/spend-cap it will actually hit, instead of an agent
# discovering a broken cascade or a depleted credential mid-spawn.
#
# Called by .claude/settings.json -> hooks.SessionStart. Best-effort:
# never blocks session startup — falls through silently if the `chump`
# binary isn't built yet or the check fails.
#
# Exit: always 0.

set -uo pipefail

REPO="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
[[ -z "$REPO" ]] && exit 0

CHUMP_BIN="$(command -v chump 2>/dev/null || echo "/opt/homebrew/bin/chump")"
[[ -x "$CHUMP_BIN" ]] || exit 0

"$CHUMP_BIN" fleet mode 2>/dev/null || true
exit 0
