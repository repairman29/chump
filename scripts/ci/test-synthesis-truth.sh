#!/usr/bin/env bash
# scripts/ci/test-synthesis-truth.sh — INFRA-1684 (narrow follow-up to INFRA-1554)
#
# Synthesis docs (docs/syntheses/*.md) often reference gaps they claim to have
# filed: lines like "filed: INFRA-1305" or "INFRA-1305 (filed)". Today's audit
# (2026-05-22) found multiple such references whose target gaps do not exist
# in state.db — META-054's 95 retag sub-actions were marked done but the
# referenced filings were hallucinated text, not actual chump gap reserve
# calls.
#
# This validator catches the regression class. For each "filed:" reference in
# docs/syntheses/, it asserts the gap exists in state.db (status open or done
# both acceptable — the validator cares about existence, not lifecycle).
#
# Bypass: a synthesis file may declare itself exempt by including the literal
# marker '<!-- synthesis-truth-exempt: <reason> -->' (e.g. for files
# referencing archived / private-repo gap IDs).
#
# Self-test: when invoked with CHUMP_SYNTHESIS_TRUTH_SELFTEST=1, the script
# creates a synthetic fixture with a known-bad reference and asserts the
# validator's logic catches it.
#
# Exit: 0 = all referenced gaps exist, 1 = at least one orphan reference

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYN_DIR="${SYN_DIR:-$REPO_ROOT/docs/syntheses}"
EXEMPT_MARKER='<!-- synthesis-truth-exempt:'

# Resolve chump binary
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    if command -v chump >/dev/null 2>&1; then
        CHUMP_BIN="$(command -v chump)"
    else
        echo "FAIL INFRA-1684: chump binary not on PATH (set CHUMP_BIN= to override)"
        exit 1
    fi
fi

# Permit the chump-staleness warning during this check
export CHUMP_BINARY_STALENESS_CHECK="${CHUMP_BINARY_STALENESS_CHECK:-0}"

gap_exists() {
    local id="$1"
    "$CHUMP_BIN" gap show "$id" >/dev/null 2>&1
}

# ── Self-test mode (regression guard on the validator itself) ────────────────
if [[ "${CHUMP_SYNTHESIS_TRUTH_SELFTEST:-0}" == "1" ]]; then
    tmp="$(mktemp -d -t synth-truth-selftest-XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT
    cat > "$tmp/bad-fixture.md" <<'MD'
# Synthesis with a known-bad gap reference

This file references a gap that should never exist in state.db.

filed: INFRA-99999999
MD
    if SYN_DIR="$tmp" CHUMP_SYNTHESIS_TRUTH_SELFTEST=0 "$0" >/dev/null 2>&1; then
        echo "FAIL INFRA-1684 self-test: validator accepted a known-bad fixture"
        exit 1
    fi
    echo "OK INFRA-1684 self-test: validator catches orphan reference"
    exit 0
fi

# ── Main scan ────────────────────────────────────────────────────────────────
if [[ ! -d "$SYN_DIR" ]]; then
    echo "FAIL INFRA-1684: synthesis directory not found: $SYN_DIR"
    exit 1
fi

files_scanned=0
refs_checked=0
orphans=0

# Patterns that surface gap-ID references in syntheses:
#   "filed: INFRA-1305"   "files INFRA-1305"   "INFRA-1305 (filed)"
#   "filing INFRA-1305"   "filed INFRA-1305"
# Conservative: only consider the "filed:" style to avoid false positives on
# casual mentions ("see INFRA-1305 for context" is not a claim of filing).
PATTERN='filed:?\s*(INFRA|CREDIBLE|DOC|EFFECTIVE|RESILIENT|EVAL|COG|PRODUCT|MISSION|META|FLEET|ZERO-WASTE|REMOVAL|RESEARCH)-[0-9]+'

while IFS= read -r -d '' f; do
    files_scanned=$((files_scanned + 1))
    if grep -q "$EXEMPT_MARKER" "$f" 2>/dev/null; then
        continue
    fi
    while IFS= read -r line; do
        # Extract the gap ID from the matching line
        id="$(echo "$line" | grep -oE '(INFRA|CREDIBLE|DOC|EFFECTIVE|RESILIENT|EVAL|COG|PRODUCT|MISSION|META|FLEET|ZERO-WASTE|REMOVAL|RESEARCH)-[0-9]+' | head -1)"
        [[ -z "$id" ]] && continue
        refs_checked=$((refs_checked + 1))
        if ! gap_exists "$id"; then
            rel="${f#"$REPO_ROOT/"}"
            line_no="$(grep -n "$id" "$f" 2>/dev/null | head -1 | cut -d: -f1)"
            echo "ORPHAN $id  $rel:${line_no:-?}"
            orphans=$((orphans + 1))
        fi
    done < <(grep -iE "$PATTERN" "$f" 2>/dev/null || true)
done < <(find "$SYN_DIR" -type f -name '*.md' -print0)

if [[ $orphans -gt 0 ]]; then
    echo ""
    echo "FAIL INFRA-1684: $orphans orphan gap reference(s) found across $files_scanned synthesis file(s)"
    echo "  Either (a) the synthesis hallucinated the ID — reconcile or correct, or"
    echo "         (b) the gap was reaped — add the exempt marker if intentional"
    exit 1
fi

echo "OK INFRA-1684: $refs_checked 'filed:' reference(s) across $files_scanned synthesis(es), 0 orphans"
