#!/usr/bin/env bash
# test-install-scripts-executable.sh — INFRA-1808
#
# Asserts every scripts/setup/install-*.sh file is executable (mode 0755 in
# the git index). A non-executable install script silently no-ops when a
# daemon-check loop tries `bash install-foo.sh` via a subshell that assumes
# +x (e.g. chump-fleet-bootstrap.sh's chmod-then-run step), or fails outright
# when invoked directly (`./install-foo.sh: Permission denied`).
#
# Root cause precedent: scripts/setup/install-bot-merge-watchdog.sh shipped
# at mode 0644 — REQUIRED_DAEMONS never installed until an operator manually
# chmod'd it days later (curator-opus-shepherd, 2026-05-23).

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

echo "=== INFRA-1808 install-*.sh executable-bit test ==="

count=0
while IFS= read -r line; do
    mode="${line%% *}"
    path="${line#* }"
    count=$((count + 1))
    if [[ "$mode" == "100755" ]]; then
        ok "$path is executable"
    else
        fail "$path is mode $mode (expected 100755) — run: chmod +x $path && git add $path"
    fi
done < <(git ls-files -s scripts/setup/install-*.sh | awk '{print $1, $4}')

if (( count == 0 )); then
    fail "no scripts/setup/install-*.sh files found — glob broke?"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ($count checked) ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
