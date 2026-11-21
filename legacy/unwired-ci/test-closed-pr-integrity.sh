#!/usr/bin/env bash
# CREDIBLE-1489: closed-pr-integrity-check.py flags done/superseded gaps whose
# closed_pr does not reference the gap id or predates the gap, and leaves clean
# and unverifiable ones alone. Pure local (fixtures); no network.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHK="$REPO_ROOT/scripts/ops/closed-pr-integrity-check.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

cat > "$T/gaps.json" <<'J'
[
 {"id":"AAA-1","status":"done","closed_pr":10,"opened_date":"2026-09-01"},
 {"id":"BBB-2","status":"done","closed_pr":4326,"opened_date":"2026-09-01"},
 {"id":"CCC-3","status":"superseded","closed_pr":11,"opened_date":"2026-09-20"},
 {"id":"DDD-4","status":"done","closed_pr":777,"opened_date":"2026-09-01"},
 {"id":"EEE-5","status":"open","closed_pr":4326,"opened_date":"2026-09-01"},
 {"id":"FFF-6","status":"done","closed_pr":12,"opened_date":"2026-09-01"}
]
J
cat > "$T/pr.json" <<'J'
{
 "10":   {"title":"AAA-1: real fix","head_ref":"claude/aaa-1","created_at":"2026-09-02T00:00:00Z"},
 "4326": {"title":"Discord digest","head_ref":"chump/digest","created_at":"2026-09-03T00:00:00Z"},
 "11":   {"title":"CCC-3: replaced","head_ref":"claude/ccc-3","created_at":"2026-08-01T00:00:00Z"},
 "12":   {"title":"misc","head_ref":"x","body":"Closes FFF-6","created_at":"2026-09-02T00:00:00Z"}
}
J
OUT="$(python3 "$CHK" --gaps-json "$T/gaps.json" --pr-meta "$T/pr.json" --json)"
flag() { python3 -c "import json,sys; d=json.load(sys.stdin); print(','.join(sorted(f['id']+':'+'/'.join(f['reasons']) for f in d['flagged'])))" <<<"$OUT"; }
[[ "$(flag)" == "BBB-2:MISMATCH,CCC-3:TOO_OLD" ]] && ok "flags unrelated PR (MISMATCH) and implausibly old PR (TOO_OLD) only" || bad "flagged: $(flag)"
python3 -c "import json,sys; d=json.load(sys.stdin); assert [u['id'] for u in d['unverified']]==['DDD-4']" <<<"$OUT" \
  && ok "PR missing from the cache is reported unverified, not flagged" || bad "unverified wrong"

set +e; python3 "$CHK" --gaps-json "$T/gaps.json" --pr-meta "$T/pr.json" --strict >/dev/null; RC=$?; set -e
[[ $RC -eq 1 ]] && ok "--strict exits 1 when anything is flagged" || bad "--strict rc=$RC"

echo '[{"id":"AAA-1","status":"done","closed_pr":10,"opened_date":"2026-09-01"}]' > "$T/clean.json"
python3 "$CHK" --gaps-json "$T/clean.json" --pr-meta "$T/pr.json" --strict >/dev/null \
  && ok "--strict exits 0 on a clean set" || bad "clean set failed strict"

CMDS="$(python3 "$CHK" --gaps-json "$T/gaps.json" --pr-meta "$T/pr.json" --reopen-cmds | grep '^REOPEN:')"
[[ "$(wc -l <<<"$CMDS")" -eq 2 ]] && grep -q "gap set BBB-2 --status open" <<<"$CMDS" \
  && ok "--reopen-cmds prints a re-open command per flagged gap (no changes without --apply)" || bad "reopen cmds: $CMDS"

echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
