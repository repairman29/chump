#!/usr/bin/env bash
# scripts/dev/reality-check.sh — CREDIBLE-090
#
# The signal-is-not-outcome gate. Run BEFORE you broadcast or act on any
# ALARM-CLASS belief — "X is down / dead / blocked / broken / halted / starved".
#
# A detector firing is a SIGNAL. The thing actually being broken is an OUTCOME.
# They are not the same. This gate forces you to check the outcome the belief
# would *cause* against ground truth, and to check whether the signal itself is
# a known false-positive, before you act.
#
# Born from the 2026-06-04 auth-dead misdiagnosis: a session saw AUTH_DEAD
# operator_recall events + a stale oauth token, concluded "the fleet is down for
# 9 hours", and acted on it for ~2h — while the fleet shipped 99 PRs (merges at
# 03:58, hours after the declared "death"). One ground-truth check — "is the
# fleet actually shipping?" — would have refuted it instantly. The AUTH_DEAD
# signal was a known false-positive (INFRA-2031).
#
# Usage:
#   reality-check.sh "<belief>" [--detector <kind>] [--halt-class]
#
# Exit codes:
#   0  CONFIRMED   — ground truth is consistent with the belief; you may act
#                    (halt-class still needs a fresh-eyes confirm — see below).
#   1  REFUTED     — ground truth contradicts the belief (or the signal is a
#                    known false-positive). STAND DOWN. Do not broadcast/act.
#   2  UNVERIFIED  — couldn't establish ground truth. Investigate manually;
#                    do NOT act on the signal alone.
#
# Test/CI injection (so this is deterministic offline):
#   CHUMP_RC_LAST_MERGE_AGE_MIN=<n>   minutes since the fleet last shipped
#   CHUMP_RC_TRUNK=<green|red>        trunk required-check state
#   CHUMP_RC_FRESH_MIN=<n>            "recently shipping" threshold (default 60)
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" 2>/dev/null || true

BELIEF=""; DETECTOR=""; HALT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --detector)   DETECTOR="${2:-}"; shift 2 ;;
    --halt-class) HALT=1; shift ;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           echo "reality-check: unknown flag $1" >&2; exit 2 ;;
    *)            BELIEF="$1"; shift ;;
  esac
done
[ -z "$BELIEF" ] && { echo "usage: reality-check.sh \"<belief>\" [--detector <kind>] [--halt-class]" >&2; exit 2; }

REPO="${CHUMP_REPO_SLUG:-repairman29/chump}"
FRESH_MIN="${CHUMP_RC_FRESH_MIN:-60}"

# ---- auth-class guard (the #1 recurring false-positive): name the wrong probes ----
if printf '%s' "$BELIEF" | grep -qiE 'auth|login|logged.?in|credential|token|401'; then
  _ak="$(launchctl getenv ANTHROPIC_API_KEY 2>/dev/null)"
  echo "  ⚠ AUTH-CLASS belief — these do NOT measure fleet auth (they mislead):"
  echo "      • 'claude -p' in your shell   → tests YOUR interactive login, NOT the fleet's"
  echo "        env auth. Fleet uses ANTHROPIC_API_KEY = $([ -n "$_ak" ] && echo SET || echo unset) (launchctl getenv)."
  echo "      • 'chump fleet doctor' exit-0 → auth PRESENCE, not VALIDITY (RESILIENT-086)."
  echo "      • fleet-brief '✓ healthy'     → does not check ship-rate."
  echo "      The only proof of life is the recent-merge ground truth below."
fi

echo "=== reality-check (CREDIBLE-090) — a SIGNAL is not an OUTCOME ==="
echo "  (1) BELIEF : $BELIEF"
[ -n "$DETECTOR" ] && echo "      SIGNAL : detector=$DETECTOR"
echo "  (2) If this belief were true, the predicted OUTCOME is: the fleet STOPS"
echo "      shipping (no recent merges) and/or trunk goes red."

# ---- (3) GROUND TRUTH: does that outcome actually hold right now? ----
age="${CHUMP_RC_LAST_MERGE_AGE_MIN:-}"
trunk="${CHUMP_RC_TRUNK:-}"
if [ -z "$age" ]; then
  lm="$(gh pr list --repo "$REPO" --state merged --limit 1 --json mergedAt --jq '.[0].mergedAt' 2>/dev/null || echo '')"
  if [ -n "$lm" ] && command -v python3 >/dev/null 2>&1; then
    age="$(python3 -c "import datetime as d;t=d.datetime.fromisoformat('$lm'.replace('Z','+00:00'));print(int((d.datetime.now(d.timezone.utc)-t).total_seconds()//60))" 2>/dev/null || echo 999999)"
  else
    age=999999
  fi
fi
if [ -z "$trunk" ]; then
  sha="$(git rev-parse origin/main 2>/dev/null || echo '')"
  if [ -n "$sha" ]; then
    trunk="$(gh api "repos/$REPO/commits/$sha/check-runs" --jq 'if ([.check_runs[]?|select(.name=="test" or .name=="audit")|select(.conclusion=="failure")]|length)>0 then "red" else "green" end' 2>/dev/null || echo unknown)"
  else
    trunk=unknown
  fi
fi
case "$age" in (*[!0-9]*) age=999999 ;; esac
echo "  (3) GROUND TRUTH: fleet last shipped ${age}min ago | trunk=$trunk"

# ---- (4) SIGNAL RELIABILITY: is the detector a known false-positive? ----
fp_gap=""
if [ -n "$DETECTOR" ] && [ -f .chump/state.db ] && command -v sqlite3 >/dev/null 2>&1; then
  fam="$(printf '%s' "$DETECTOR" | tr 'A-Z' 'a-z' | cut -d_ -f1)"
  fp_gap="$(sqlite3 .chump/state.db "SELECT id FROM gaps WHERE status='open' AND lower(title) LIKE '%false-positive%' AND (lower(title) LIKE '%$(printf '%s' "$DETECTOR"|tr 'A-Z' 'a-z')%' OR lower(title) LIKE '%${fam}%') LIMIT 1;" 2>/dev/null || true)"
  if [ -n "$fp_gap" ]; then
    echo "  (4) SIGNAL RELIABILITY: ⚠ open false-positive gap $fp_gap matches '$DETECTOR' — signal is KNOWN-UNRELIABLE"
  else
    echo "  (4) SIGNAL RELIABILITY: no open false-positive gap for '$DETECTOR'"
  fi
fi

# ---- (5) VERDICT ----
echo "  (5) VERDICT:"
verdict=0
if [ -n "$fp_gap" ]; then
  echo "      🔴 REFUTED — the signal has an OPEN false-positive gap ($fp_gap). Do NOT act on it."
  echo "         Fix/silence the detector (that gap) instead of acting on its output."
  verdict=1
elif [ "$age" -lt "$FRESH_MIN" ]; then
  echo "      🔴 REFUTED — the fleet shipped ${age}min ago (< ${FRESH_MIN}min). A '$BELIEF'"
  echo "         belief predicts the fleet stops shipping; it hasn't. STAND DOWN."
  verdict=1
elif [ "$trunk" = "green" ] && [ "$age" -lt 240 ]; then
  echo "      🔴 REFUTED — trunk is green and the fleet shipped ${age}min ago; the outage the"
  echo "         belief predicts isn't happening. STAND DOWN."
  verdict=1
elif [ "$age" = "999999" ] || [ "$trunk" = "unknown" ]; then
  echo "      🟡 UNVERIFIED — couldn't read recent-ship / trunk ground truth. Investigate"
  echo "         manually; do NOT broadcast or act on the signal alone."
  verdict=2
else
  echo "      🟢 CONFIRMED — no recent ships (${age}min) and trunk=$trunk are consistent with"
  echo "         the belief. You may act."
  verdict=0
fi

# ---- halt-class second opinion (fleet consensus for high-blast beliefs) ----
if [ "$HALT" = 1 ]; then
  echo ""
  echo "  ⛔ HALT-CLASS belief (outage / stop-fleet / page-operator): a single session may NOT"
  echo "     unilaterally act on this even if CONFIRMED. Get a fresh-eyes (or peer) confirm first:"
  echo "       /fresh-eyes     # the designated reality-check curator (META-132)"
  echo "       — or — scripts/coord/broadcast.sh FEEDBACK proposal \"reality-check: $BELIEF\" \"<ground-truth>\" 0"
  [ "$verdict" = 0 ] && verdict=2   # confirmed-but-unconfirmed-by-peer → treat as not-yet-actionable
fi
exit "$verdict"
