#!/usr/bin/env bash
# scripts/ci/test-daemon-contract.sh — INFRA-2356 (META-269 sub-7)
#
# Cross-daemon contract test: verifies that the ambient event kinds each
# launchd daemon is *expected* to emit (per scripts/coord/daemon-expectations.yaml,
# the source dispatchers/monitors read to detect silent daemons) are actually
# emitted by that daemon's script — i.e. the kind literal appears in the
# source, either as an `emit`/`emit_ambient` call argument or a
# `# scanner-anchor: "kind":"X"` comment.
#
# A daemon whose plist can't be resolved to a script is reported but does
# not fail the test (plists are macOS-only artifacts with placeholder paths
# in some cases; resolution is best-effort by basename search).
#
# A daemon whose script resolves but emits ZERO of its expected_kinds fails
# the test — that's a daemon-silence-monitor.sh "min_per_hour" check that
# can never pass because the daemon literally never emits any of the kinds
# the monitor is watching for. Partial coverage (some but not all expected
# kinds found) is reported as a warning, not a failure — daemons legitimately
# have conditional/rare event kinds that are hard to grep-prove statically.
#
# Exit codes:
#   0 — no daemon has zero-kind contract drift
#   1 — at least one daemon emits none of its expected kinds

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

EXPECTATIONS="${CHUMP_DAEMON_CONTRACT_EXPECTATIONS:-$REPO_ROOT/scripts/coord/daemon-expectations.yaml}"

if [[ ! -f "$EXPECTATIONS" ]]; then
    echo "FATAL: expectations file missing: $EXPECTATIONS" >&2
    exit 2
fi

echo "=== INFRA-2356 daemon contract test ==="
echo "expectations: $EXPECTATIONS"
echo

PASS=0
FAIL=0
WARN=0
FAILS=()

# Strip the com.chump./dev.chump. reverse-DNS prefix so plist Labels and
# yaml daemon names compare on their distinguishing suffix only.
_strip_prefix() {
    local s="$1"
    s="${s#com.chump.}"
    s="${s#dev.chump.}"
    printf '%s\n' "$s"
}

# Find every plist under the repo (multiple historical dirs: launchd/,
# scripts/plists/, scripts/launchd/, scripts/setup/launchd/).
mapfile -t ALL_PLISTS < <(find "$REPO_ROOT" -iname "*.plist" -not -path "*/node_modules/*" 2>/dev/null)

# resolve_script_for_daemon <daemon-name> → prints repo-relative script path, or empty.
resolve_script_for_daemon() {
    local daemon="$1"
    local want
    want="$(_strip_prefix "$daemon")"
    local plist label
    for plist in "${ALL_PLISTS[@]}"; do
        label="$(grep -A1 '<key>Label</key>' "$plist" 2>/dev/null | tail -1 | sed -E 's#.*<string>(.*)</string>.*#\1#')"
        [[ -z "$label" ]] && continue
        if [[ "$(_strip_prefix "$label")" == "$want" ]]; then
            # Extract every <string>...</string> inside ProgramArguments and
            # pick the one that looks like a shell script path/basename.
            local script_ref
            script_ref="$(awk '/<key>ProgramArguments<\/key>/{f=1;next} f && /<\/array>/{exit} f' "$plist" \
                | grep -oE '<string>[^<]*</string>' \
                | sed -E 's#<string>(.*)</string>#\1#' \
                | grep -oE '[A-Za-z0-9_./-]+\.sh' \
                | head -1)"
            [[ -z "$script_ref" ]] && continue
            local basename_ref
            basename_ref="$(basename "$script_ref")"
            # Resolve to an actual file in the repo by basename.
            local found
            found="$(find "$REPO_ROOT" -type f -name "$basename_ref" -not -path "*/node_modules/*" 2>/dev/null | head -1)"
            [[ -n "$found" ]] && { printf '%s\n' "$found"; return 0; }
        fi
    done
    return 1
}

# kind_in_script <script-path> <kind> → 0 if literal kind found quoted in source.
kind_in_script() {
    local script="$1" kind="$2"
    grep -qE "\"${kind}\"" "$script" 2>/dev/null
}

# Parse the yaml with python3 (available in CI) into TSV: daemon<TAB>kind1,kind2,...
DAEMON_ROWS="$(python3 - "$EXPECTATIONS" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
for d in doc.get("daemons", []):
    name = d.get("daemon", "")
    kinds = d.get("expected_kinds", []) or []
    print(f"{name}\t{','.join(kinds)}")
PY
)"

if [[ -z "$DAEMON_ROWS" ]]; then
    echo "FATAL: no daemons parsed from $EXPECTATIONS" >&2
    exit 2
fi

while IFS=$'\t' read -r daemon kinds_csv; do
    [[ -z "$daemon" ]] && continue
    echo "--- daemon: $daemon ---"

    SCRIPT="$(resolve_script_for_daemon "$daemon" || true)"
    if [[ -z "$SCRIPT" ]]; then
        echo "  WARN: could not resolve a script for $daemon (skipping — no plist/script match)"
        WARN=$((WARN+1))
        continue
    fi
    echo "  script: ${SCRIPT#"$REPO_ROOT"/}"

    IFS=',' read -r -a KINDS <<< "$kinds_csv"
    FOUND=0
    MISSING=()
    for kind in "${KINDS[@]}"; do
        [[ -z "$kind" ]] && continue
        if kind_in_script "$SCRIPT" "$kind"; then
            FOUND=$((FOUND+1))
        else
            MISSING+=("$kind")
        fi
    done

    TOTAL=${#KINDS[@]}
    if [[ $FOUND -eq 0 ]]; then
        echo "  FAIL: 0/$TOTAL expected kinds found in source — contract drift (missing: ${MISSING[*]})"
        FAIL=$((FAIL+1))
        FAILS+=("$daemon: 0/$TOTAL expected kinds present (missing: ${MISSING[*]})")
    elif [[ ${#MISSING[@]} -gt 0 ]]; then
        echo "  WARN: $FOUND/$TOTAL expected kinds found (missing: ${MISSING[*]})"
        WARN=$((WARN+1))
        PASS=$((PASS+1))
    else
        echo "  PASS: $FOUND/$TOTAL expected kinds found"
        PASS=$((PASS+1))
    fi
done <<< "$DAEMON_ROWS"

echo
echo "=== Results: $PASS passed, $FAIL failed, $WARN warned ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
