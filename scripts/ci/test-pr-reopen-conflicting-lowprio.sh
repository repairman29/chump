#!/usr/bin/env bash
# INFRA-3604: conflicting + P2/P3 PRs are not reopened; mergeable or P0/P1 are.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/gh" <<'G'
#!/usr/bin/env bash
echo "$GH_OUT"
G
cat > "$T/chump" <<'C'
#!/usr/bin/env bash
echo "$GAP_PRIO"
C
chmod +x "$T/gh" "$T/chump"
export PATH="$T:$PATH" CHUMP_BIN="$T/chump"
source "$ROOT/scripts/lib/safe-reopen-gap.sh"
fail=0
check() { # want out prio
    GH_OUT="$2" GAP_PRIO="$3" pr_conflicting_lowprio_refused 1 r INFRA-1 2>/dev/null; rc=$?
    [[ $rc -eq $1 ]] || { echo "FAIL: $2/$3 want rc=$1 got $rc"; fail=1; }
}
check 3 "CONFLICTING DIRTY" P2
check 3 "CONFLICTING DIRTY" P3
check 0 "CONFLICTING DIRTY" P1
check 0 "MERGEABLE CLEAN" P2
check 0 "UNKNOWN UNKNOWN" P2
[[ $fail -eq 0 ]] && echo "PASS"
exit $fail
