#!/usr/bin/env bash
# test-install-script-manifest.sh — INFRA-1810
#
# CI gate: every scripts/setup/install-*.sh must be mapped to one of:
#   (1) REQUIRED_DAEMONS in scripts/setup/chump-fleet-bootstrap.sh
#   (2) scripts/setup/optional-installers-allowlist.txt
#   (3) scripts/setup/deprecated-installers-allowlist.txt
#
# Any installer in none of the above fails CI with a 3-option remediation
# message so the PR author knows exactly how to fix it.
#
# Usage:
#   scripts/ci/test-install-script-manifest.sh           # normal run
#   scripts/ci/test-install-script-manifest.sh --smoke   # subset smoke test
#   REPO_ROOT=/path scripts/ci/test-install-script-manifest.sh

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SETUP_DIR="$REPO_ROOT/scripts/setup"
BOOTSTRAP="$SETUP_DIR/chump-fleet-bootstrap.sh"
OPTIONAL_LIST="$SETUP_DIR/optional-installers-allowlist.txt"
DEPRECATED_LIST="$SETUP_DIR/deprecated-installers-allowlist.txt"

SMOKE="${1:-}"

[[ -f "$BOOTSTRAP" ]]     || { echo "FAIL: $BOOTSTRAP not found"; exit 1; }
[[ -f "$OPTIONAL_LIST" ]] || { echo "FAIL: $OPTIONAL_LIST not found (create it with INFRA-1810)"; exit 1; }
[[ -f "$DEPRECATED_LIST" ]] || { echo "FAIL: $DEPRECATED_LIST not found (create it with INFRA-1810)"; exit 1; }

# Build lookup sets.

# Set 1: installers referenced in REQUIRED_DAEMONS entries.
required_set=$(grep -oE 'install-[^"]+\.sh' "$BOOTSTRAP" 2>/dev/null | sort -u || true)

# Set 2: optional allowlist (strip comments + blank lines).
optional_set=$(grep -v '^#' "$OPTIONAL_LIST" | grep -v '^[[:space:]]*$' | sort -u || true)

# Set 3: deprecated allowlist.
deprecated_set=$(grep -v '^#' "$DEPRECATED_LIST" | grep -v '^[[:space:]]*$' | sort -u || true)

# All known installers.
all_installers=$(ls "$SETUP_DIR"/install-*.sh 2>/dev/null | xargs -n1 basename | sort -u || true)

fail=0
deprecated_warn=0

while IFS= read -r installer; do
    [[ -n "$installer" ]] || continue

    in_required=$(echo "$required_set"   | grep -Fx "$installer" || true)
    in_optional=$(echo "$optional_set"   | grep -Fx "$installer" || true)
    in_deprecated=$(echo "$deprecated_set" | grep -Fx "$installer" || true)

    if [[ -n "$in_deprecated" ]]; then
        echo "WARN [deprecated] $installer — scheduled for removal"
        deprecated_warn=$(( deprecated_warn + 1 ))
    elif [[ -z "$in_required" && -z "$in_optional" ]]; then
        echo "FAIL [unmapped] $installer"
        echo "       Remediation — pick ONE:"
        echo "         (A) Add to REQUIRED_DAEMONS in scripts/setup/chump-fleet-bootstrap.sh:"
        echo "             \"com.chump.<label>|scripts/setup/$installer\""
        echo "         (B) Add to scripts/setup/optional-installers-allowlist.txt (situational/opt-in)"
        echo "         (C) Add to scripts/setup/deprecated-installers-allowlist.txt (about to be removed)"
        fail=$(( fail + 1 ))
    fi
done <<< "$all_installers"

echo
if [[ "$deprecated_warn" -gt 0 ]]; then
    echo "Deprecated installers (scheduled for removal): $deprecated_warn"
fi

if [[ "$fail" -gt 0 ]]; then
    echo "FAIL: $fail unmapped installer(s) — see remediation above"
    exit 1
fi

total=$(echo "$all_installers" | grep -c '^install-' || true)
echo "PASS: all $total installers are mapped (required/optional/deprecated)"
exit 0
