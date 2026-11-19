#!/usr/bin/env bash
# test-fleet-bootstrap-coverage.sh — INFRA-1594
#
# Verifies the REQUIRED_DAEMONS registry inside chump-fleet-bootstrap.sh
# stays in sync with the actual install-*.sh scripts on disk for known
# fleet-critical daemons (paramedic, bot-merge-watchdog, pr-rebase-daemon).
#
# Why: 2026-05-16 M4 incident — host was running runner plists but no
# paramedic, so PRs got stuck DIRTY for hours. The bootstrap script must
# explicitly enforce these labels are registered + active, and this test
# guards against quietly dropping a daemon from the registry.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOOTSTRAP="$REPO_ROOT/scripts/setup/chump-fleet-bootstrap.sh"

echo "=== INFRA-1594 chump-fleet-bootstrap daemon coverage ==="

[[ -f "$BOOTSTRAP" ]] || { fail "bootstrap missing at $BOOTSTRAP"; exit 1; }
ok "bootstrap present"

# 1. REQUIRED_DAEMONS array must be defined.
if grep -q '^REQUIRED_DAEMONS=(' "$BOOTSTRAP"; then
    ok "REQUIRED_DAEMONS array defined"
else
    fail "REQUIRED_DAEMONS array missing from bootstrap script"
    exit 1
fi

# 2. Every fleet-critical daemon whose install script EXISTS in this repo must
#    be referenced in the REQUIRED_DAEMONS array. Add new daemons here as the
#    fleet grows.
KNOWN_DAEMONS=(
    "com.chump.paramedic|scripts/setup/install-paramedic.sh"
    "com.chump.bot-merge-watchdog|scripts/setup/install-bot-merge-watchdog.sh"
    "com.chump.pr-rebase-daemon|scripts/setup/install-pr-rebase-daemon.sh"
)

for entry in "${KNOWN_DAEMONS[@]}"; do
    label="${entry%%|*}"
    installer="${entry##*|}"
    if [[ ! -f "$REPO_ROOT/$installer" ]]; then
        # Install script doesn't exist yet — registry is allowed to omit.
        echo "  INFO: skipping $label (installer $installer not in repo)"
        continue
    fi
    if grep -qF "$label" "$BOOTSTRAP" && grep -qF "$installer" "$BOOTSTRAP"; then
        ok "REQUIRED_DAEMONS references $label (installer present)"
    else
        fail "REQUIRED_DAEMONS missing $label (installer $installer exists but not registered)"
    fi
done

# 3. The fleet_bootstrap_incomplete event kind must be emitted somewhere in the script.
if grep -q 'fleet_bootstrap_incomplete' "$BOOTSTRAP"; then
    ok "fleet_bootstrap_incomplete emission present"
else
    fail "fleet_bootstrap_incomplete not emitted from bootstrap script"
fi

# 4. The script must use launchctl print to verify daemon registration (active check).
if grep -q 'launchctl print' "$BOOTSTRAP"; then
    ok "bootstrap uses launchctl print for daemon verification"
else
    fail "bootstrap does not use launchctl print — daemon check may be weak"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
exit 0
