#!/usr/bin/env bash
# scripts/ci/test-bootstrap-manifest-coverage.sh — INFRA-1926
#
# Prevents the silent-daemon recurrence caught on 2026-05-24:
#   3 daemons (branch-reaper, pr-watch-shepherd, distill-pr-skills) had
#   install scripts on disk but no manifest entry, so chump-fleet-bootstrap
#   never installed them. Result: operator hit daemon_silent ALERTs that
#   could only be cleared by manual install.
#
# This gate works like the raw-gh allowlist (INFRA-1274): every
# install-*-launchd.sh in scripts/setup/ must either appear in
# bootstrap-manifest.yaml OR be listed in scripts/setup/bootstrap-manifest-
# unmapped.txt with a reason. The unmapped file is the explicit "we know
# these aren't bootstrap-installed and here's why" register.
#
# Failure modes:
#   - new installer added without manifest entry AND without unmapped entry → FAIL
#   - unmapped entry exists for a script that's now in the manifest    → FAIL (dup)
#   - unmapped entry exists for a script that no longer exists on disk → FAIL (stale)

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="$REPO/scripts/setup/bootstrap-manifest.yaml"
UNMAPPED="$REPO/scripts/setup/bootstrap-manifest-unmapped.txt"
SETUP_DIR="$REPO/scripts/setup"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$MANIFEST" ]] || fail "bootstrap-manifest.yaml not found"
ok "manifest present at $MANIFEST"

# unmapped.txt is optional but recommended — entries are basename lines, comments allowed.
# Read into array via while-read so bash 3.2 (default macOS) is supported.
unmapped=()
if [[ -f "$UNMAPPED" ]]; then
    while IFS= read -r line; do
        unmapped+=("$line")
    done < <(grep -vE '^\s*(#|$)' "$UNMAPPED" | awk '{print $1}')
fi
ok "unmapped register has ${#unmapped[@]} entries"

is_unmapped() {
    local name="$1"
    (( ${#unmapped[@]} == 0 )) && return 1
    for u in "${unmapped[@]}"; do
        [[ "$name" == "$u" ]] && return 0
    done
    return 1
}

# ── Discover all install-*-launchd.sh and classify ─────────────────────────
unmapped_but_missing=()
covered=0
unmapped_count=0
missing=()
total=0

for installer in "$SETUP_DIR"/install-*-launchd.sh; do
    [[ -f "$installer" ]] || continue
    total=$((total + 1))
    base="$(basename "$installer")"
    if grep -qE "install:\s*bash scripts/setup/${base}\b" "$MANIFEST"; then
        covered=$((covered + 1))
        # Sanity: must not also be in unmapped (duplicate classification)
        if is_unmapped "$base"; then
            fail "dup classification: $base is in BOTH manifest and unmapped register"
        fi
    elif is_unmapped "$base"; then
        unmapped_count=$((unmapped_count + 1))
    else
        missing+=("$base")
    fi
done

# ── Sanity: stale unmapped entries (file no longer on disk) ────────────────
for u in "${unmapped[@]+"${unmapped[@]}"}"; do
    if [[ ! -f "$SETUP_DIR/$u" ]]; then
        unmapped_but_missing+=("$u")
    fi
done

if (( ${#unmapped_but_missing[@]} > 0 )); then
    echo "" >&2
    echo "FAIL: unmapped register contains entries for scripts no longer in scripts/setup/:" >&2
    for u in "${unmapped_but_missing[@]}"; do
        echo "  - $u" >&2
    done
    echo "" >&2
    echo "Remove the stale entry from scripts/setup/bootstrap-manifest-unmapped.txt" >&2
    exit 1
fi

echo "[bootstrap-manifest-coverage] total=$total covered=$covered unmapped=$unmapped_count missing=${#missing[@]}"

if (( ${#missing[@]} > 0 )); then
    echo "" >&2
    echo "FAIL: install-*-launchd.sh scripts not classified:" >&2
    for m in "${missing[@]}"; do
        echo "  - $m" >&2
    done
    echo "" >&2
    echo "Fix one of:" >&2
    echo "  1. Add an installer entry to scripts/setup/bootstrap-manifest.yaml referencing this script" >&2
    echo "  2. Add the basename to scripts/setup/bootstrap-manifest-unmapped.txt with a # reason comment" >&2
    echo "" >&2
    echo "Why: missing manifest entries mean chump-fleet-bootstrap never installs the daemon," >&2
    echo "which silently breaks the fleet (reaper-heartbeat-watchdog emits daemon_silent ALERTs)." >&2
    exit 1
fi

ok "all $total install-*-launchd.sh scripts are classified (manifest=$covered + unmapped=$unmapped_count)"

echo ""
echo "ALL INFRA-1926 bootstrap-manifest-coverage assertions passed."
