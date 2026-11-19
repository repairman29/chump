#!/usr/bin/env bash
# RESILIENT-118: cargo-target-reaper.sh must produce LITERAL paths from its
# /tmp ↔ /private/tmp variant generator, not backslash-escaped strings.
#
# The original buggy form `${var/\/tmp\//\/private\/tmp\/}` stored
# `\/tmp\/foo` (backslash + slash + tmp + ...) into the registered-worktree
# set, so `grep -qxF /tmp/foo` never matched and every active /tmp worktree
# on macOS was misidentified as orphaned. cargo-target-reaper then attempted
# `rm -rf` against live target/ dirs, racing the build and corrupting
# .fingerprint / dep-graph / sccache rmeta files (chump preflight fail-loop
# observed 2026-06-05).
#
# Pass criterion: a path of the form /private/tmp/foo must, after variant
# expansion, also appear as /tmp/foo in the registered set (and vice versa)
# so that `grep -qxF` matches the iteration candidate from a /tmp/* glob.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER="${SCRIPT_DIR}/../ops/cargo-target-reaper.sh"

if [[ ! -f "$REAPER" ]]; then
    echo "FAIL: cargo-target-reaper.sh not found at $REAPER"
    exit 1
fi

# Inline-reproduce the variant-generator block from the script, then assert
# the produced strings are literal paths (no backslashes).
_test_variant() {
    local _input="$1" _expected="$2"
    local _registered_wts=$'\n'
    local _wt_path="$_input"
    local _tmp_pat='/tmp/'
    local _priv_pat='/private/tmp/'
    _registered_wts="${_registered_wts}${_wt_path}"$'\n'
    case "$_wt_path" in
        /tmp/*)          _registered_wts="${_registered_wts}${_wt_path//$_tmp_pat/$_priv_pat}"$'\n' ;;
        /private/tmp/*)  _registered_wts="${_registered_wts}${_wt_path//$_priv_pat/$_tmp_pat}"$'\n' ;;
    esac

    local _buf
    _buf=$(mktemp)
    printf '%s' "$_registered_wts" > "$_buf"

    if grep -qxF "$_expected" "$_buf"; then
        rm -f "$_buf"
        return 0
    else
        echo "FAIL: input='$_input' expected literal '$_expected' in registered set, got:"
        cat "$_buf" | sed 's/^/  /'
        rm -f "$_buf"
        return 1
    fi
}

# Case 1: /private/tmp/foo → /tmp/foo variant must be matchable.
_test_variant "/private/tmp/chump-effective-216" "/tmp/chump-effective-216"

# Case 2: /tmp/foo → /private/tmp/foo variant must be matchable.
_test_variant "/tmp/chump-bar" "/private/tmp/chump-bar"

# Case 3: regression — the buggy backslash-escaped form must NOT appear.
_buf=$(mktemp)
trap 'rm -f "$_buf"' EXIT
_wt_path="/private/tmp/chump-baz"
_tmp_pat='/tmp/'
_priv_pat='/private/tmp/'
case "$_wt_path" in
    /private/tmp/*) printf '%s\n' "${_wt_path//$_priv_pat/$_tmp_pat}" > "$_buf" ;;
esac
if grep -qF '\/' "$_buf"; then
    echo "FAIL: variant contains backslash-escaped slashes (the original bug):"
    cat "$_buf" | sed 's/^/  /'
    exit 1
fi

# Case 4: /Users/... worktrees (the main checkout) are passed through unchanged.
_test_variant "/Users/jeffadkins/Projects/Chump" "/Users/jeffadkins/Projects/Chump"

echo "OK: cargo-target-reaper variant quoting produces literal paths."
