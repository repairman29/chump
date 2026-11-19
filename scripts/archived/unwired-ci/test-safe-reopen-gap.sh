#!/usr/bin/env bash
# RESILIENT-1579: safe_reopen_gap must not revert operator blocks.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/chump" <<'STUB'
#!/usr/bin/env bash
# stub: gap show ID --field status|notes ; gap set ID --status open
if [[ "$2" == show ]]; then
  [[ "$4" == "--field" && "$5" == status ]] && { echo "$STUB_STATUS"; exit 0; }
  [[ "$5" == notes ]] && { echo "$STUB_NOTES"; exit 0; }
fi
if [[ "$2" == set ]]; then echo "SET $*" >> "$STUB_LOG"; exit 0; fi
STUB
sed -i 's/\[\[ "\$2" == show \]\]/[[ "$2" == show ]]/' "$T/chump"; chmod +x "$T/chump"
export CHUMP_BIN="$T/chump" STUB_LOG="$T/log"; : > "$STUB_LOG"
source "$ROOT/scripts/lib/safe-reopen-gap.sh"
fail=0
check() { # name expected_rc expected_set status notes
  : > "$STUB_LOG"; STUB_STATUS="$4" STUB_NOTES="$5" safe_reopen_gap X-1 2>/dev/null; rc=$?
  n=$(wc -l < "$STUB_LOG")
  if [[ $rc -ne $2 || $n -ne $3 ]]; then echo "FAIL $1 rc=$rc sets=$n"; fail=1; else echo "ok $1"; fi
}
check operator-block 3 0 blocked "blocked by operator: waiting on legal"
check auto-block 0 1 blocked "INFRA-3832 auto-block last kind=timeout"
check closed-gap 0 1 done ""
check already-open 0 0 open ""
exit $fail
