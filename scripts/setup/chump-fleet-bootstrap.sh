#!/usr/bin/env bash
# chump-fleet-bootstrap.sh — META-066
#
# Idempotent orchestrator that installs every required launchd plist + git
# hook so the productization layer (META-063/064/065 + INFRA-1257/1258)
# is actually ACTIVE on this machine, not just on disk.
#
# Each entry in scripts/setup/bootstrap-manifest.yaml has a `check`
# command that returns 0 iff already installed. The bootstrap runs the
# `install` command only when `check` fails.
#
# Usage:
#   bash scripts/setup/chump-fleet-bootstrap.sh                # install missing
#   bash scripts/setup/chump-fleet-bootstrap.sh --check        # audit only (exits non-zero if anything missing)
#   bash scripts/setup/chump-fleet-bootstrap.sh --only ID,…    # install just these IDs
#   bash scripts/setup/chump-fleet-bootstrap.sh --skip ID,…    # install all except these IDs
#   bash scripts/setup/chump-fleet-bootstrap.sh --priority P0  # only P0 entries
#
# Bypass: CHUMP_FLEET_BOOTSTRAP_CHECK=0 disables the check side-effect (still installs).
#
# Source: META-066 (2026-05-15 keystone — productizes the productization layer).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="$REPO_ROOT/scripts/setup/bootstrap-manifest.yaml"

[[ -f "$MANIFEST" ]] || { echo "ERROR: manifest missing at $MANIFEST" >&2; exit 1; }

MODE="install"   # install | check
ONLY=""
SKIP=""
PRI_FILTER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)    MODE="check"; shift ;;
        --only)     ONLY="$2"; shift 2 ;;
        --skip)     SKIP="$2"; shift 2 ;;
        --priority) PRI_FILTER="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown flag: $1" >&2; exit 2 ;;
    esac
done

# Parse the manifest (YAML → tab-separated rows: id\tpriority\tinstall\tcheck).
# We use python3 because awk + YAML is misery.
parse_manifest() {
    python3 -c "
import sys
try:
    import yaml
except ImportError:
    print('ERROR: pyyaml required (pip3 install pyyaml)', file=sys.stderr)
    sys.exit(3)
data = yaml.safe_load(open('$MANIFEST'))
for e in data.get('installers', []):
    eid = e.get('id', '')
    pri = e.get('priority', 'P2')
    install = e.get('install', '').replace('\t', ' ')
    check = e.get('check', '').replace('\t', ' ')
    print(f'{eid}\t{pri}\t{install}\t{check}')
"
}

# Filter by --only / --skip / --priority.
should_run() {
    local id="$1" pri="$2"
    if [[ -n "$ONLY" ]] && ! echo ",$ONLY," | grep -q ",$id,"; then return 1; fi
    if [[ -n "$SKIP" ]] && echo ",$SKIP," | grep -q ",$id,"; then return 1; fi
    if [[ -n "$PRI_FILTER" ]] && [[ "$pri" != "$PRI_FILTER" ]]; then return 1; fi
    return 0
}

INSTALLED=0
SKIPPED_HEALTHY=0
SKIPPED_FILTERED=0
INSTALLED_LIST=()
FAILED=0
FAILED_LIST=()
MISSING_AT_CHECK=()

cd "$REPO_ROOT"

# Process P0 first, then P1, then P2 (rough dep ordering — manifest authors
# put depends_on in the right column anyway).
for pri in P0 P1 P2 P3; do
    while IFS=$'\t' read -r id pri_actual install check; do
        [[ -z "$id" ]] && continue
        [[ "$pri_actual" != "$pri" ]] && continue
        if ! should_run "$id" "$pri_actual"; then
            SKIPPED_FILTERED=$((SKIPPED_FILTERED + 1))
            continue
        fi

        # Check if already installed.
        if eval "$check" >/dev/null 2>&1; then
            SKIPPED_HEALTHY=$((SKIPPED_HEALTHY + 1))
            [[ "$MODE" == "check" ]] && echo "  ok      $id"
            continue
        fi

        if [[ "$MODE" == "check" ]]; then
            MISSING_AT_CHECK+=("$id")
            echo "  MISSING $id  (would run: $install)"
            continue
        fi

        # Install.
        echo "[bootstrap] installing $id ($pri_actual): $install"
        if eval "$install" >/dev/null 2>&1; then
            INSTALLED=$((INSTALLED + 1))
            INSTALLED_LIST+=("$id")
        else
            rc=$?
            FAILED=$((FAILED + 1))
            FAILED_LIST+=("$id:rc=$rc")
            echo "[bootstrap] FAILED $id (rc=$rc); continuing" >&2
        fi
    done < <(parse_manifest)
done

# Ambient emit for audit trail.
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
if [[ -d "$(dirname "$AMBIENT")" ]]; then
    printf '{"ts":"%s","kind":"fleet_bootstrap_ran","mode":"%s","installed":%d,"skipped_healthy":%d,"failed":%d,"missing_count":%d}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$MODE" \
        "$INSTALLED" \
        "$SKIPPED_HEALTHY" \
        "$FAILED" \
        "${#MISSING_AT_CHECK[@]}" \
        >> "$AMBIENT" 2>/dev/null || true
fi

echo
if [[ "$MODE" == "check" ]]; then
    echo "=== bootstrap audit: $SKIPPED_HEALTHY installed, ${#MISSING_AT_CHECK[@]} missing"
    if (( ${#MISSING_AT_CHECK[@]} > 0 )); then
        echo "Run: bash scripts/setup/chump-fleet-bootstrap.sh"
        exit 1
    fi
    exit 0
fi

echo "=== bootstrap done: $INSTALLED installed, $SKIPPED_HEALTHY already healthy, $FAILED failed"
if (( FAILED > 0 )); then
    for f in "${FAILED_LIST[@]}"; do echo "  FAILED: $f" >&2; done
    exit 1
fi
exit 0
