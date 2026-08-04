#!/usr/bin/env bash
# test-review-verdict-report.sh — CREDIBLE-191 (learning-loop consumer)
#
# Guards review-verdict-report.sh: it must read only review_verdict events,
# ignore other kinds + malformed lines, and compute the verdict distribution and
# per-lens "catches" (which lens returned its blocking value on blocking verdicts).
#
# DEPTH: fixture-driven end-to-end unit — runs the real script against a synthetic
#   ambient log and asserts the aggregate JSON. GAP: does not assert the live
#   code-reviewer actually emits parseable rows in situ (covered by
#   test-code-reviewer-spirit.sh's emit-format + registry guards).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$HERE/../coord/review-verdict-report.sh"
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; else echo "  FAIL: $1 — expected [$2] got [$3]"; fail=1; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/ambient.jsonl"
cat > "$LOG" <<'EOF'
{"ts":"2026-08-04T10:00:00Z","kind":"review_verdict","verdict":"APPROVE","spirit":"GENUINE","correctness":"SOUND","harmony":"FITS","loc":12}
{"ts":"2026-08-04T10:01:00Z","kind":"review_verdict","verdict":"CONCERN","spirit":"STUB","correctness":"SOUND","harmony":"FITS","loc":40}
{"ts":"2026-08-04T10:02:00Z","kind":"review_verdict","verdict":"CONCERN","spirit":"GENUINE","correctness":"FALSE-GREEN","harmony":"FITS","loc":8}
{"ts":"2026-08-04T10:03:00Z","kind":"review_verdict","verdict":"ESCALATE","spirit":"GENUINE","correctness":"SOUND","harmony":"REGRESSION-RISK","loc":200}
{"ts":"2026-08-04T10:04:00Z","kind":"bot_merge_step_started","step":"push"}
this line is not json at all
EOF

OUT="$(bash "$REPORT" --json --ambient "$LOG")"

# Pull fields with python (the same tool the report uses). The accessor is a
# single-quoted python expression over `d` — eval keeps varied accessors simple
# and dodges shell/JSON quote-escaping entirely.
val() { echo "$OUT" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

echo "test-review-verdict-report (CREDIBLE-191):"
# 1. Only the 4 review_verdict rows counted (other kind + garbage ignored).
check "total = 4 (ignores other-kind + malformed)" "4" "$(val 'd["total"]')"
# 2. Verdict distribution.
check "APPROVE = 1"  "1" "$(val 'd["verdicts"].get("APPROVE",0)')"
check "CONCERN = 2"  "2" "$(val 'd["verdicts"].get("CONCERN",0)')"
check "ESCALATE = 1" "1" "$(val 'd["verdicts"].get("ESCALATE",0)')"
# 3. Blocking verdicts (CONCERN+ESCALATE) = 3.
check "blocking = 3" "3" "$(val 'd["blocking_verdicts"]')"
# 4. Lens catches — each lens's blocking value counted once among blocking verdicts.
check "spirit=STUB catch = 1"            "1" "$(val 'd["lens_catches"]["spirit=STUB"]')"
check "correctness=FALSE-GREEN catch = 1" "1" "$(val 'd["lens_catches"]["correctness=FALSE-GREEN"]')"
check "harmony=REGRESSION-RISK catch = 1"  "1" "$(val 'd["lens_catches"]["harmony=REGRESSION-RISK"]')"

# 5. --since filters lexically.
OUT="$(bash "$REPORT" --json --ambient "$LOG" --since '2026-08-04T10:02:30Z')"
check "since-filter keeps only later rows (1)" "1" "$(val 'd["total"]')"

# 6. Missing ambient log is a graceful no-op (exit 0, no crash).
if bash "$REPORT" --ambient "$TMP/nope.jsonl" >/dev/null 2>&1; then
  echo "  ok: missing ambient log is a graceful no-op"
else
  echo "  FAIL: missing ambient log should exit 0"; fail=1
fi

if [[ $fail -eq 0 ]]; then echo "PASS"; else echo "FAILED"; exit 1; fi
