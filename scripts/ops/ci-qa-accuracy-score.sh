#!/usr/bin/env bash
# scripts/ops/ci-qa-accuracy-score.sh — INFRA-5753 (parent INFRA-1861 slice)
#
# Hourly rolling-24h "CI/QA accuracy" score, per the exact formula in the
# INFRA-1861 AC:
#   score = (accurate / (accurate + false_positive + missed_locally + flake)) * 100
#
# Classification sources (existing ambient signals, no new instrumentation
# needed — this script is a pure aggregator):
#   accurate_failures  — kind=ci_triage_verdict, verdict in {real, known-bug}
#                         (scripts/ci/triage-cargo-test-failure.sh, INFRA-1834-era)
#   flake_count        — kind=ci_triage_verdict verdict=flake, PLUS standalone
#                         kind=ci_flake_rerun events (operator/bot flake reruns
#                         not routed through the triage classifier)
#   false_positives    — kind=duty_officer_action verdict=refuted (a halt-class
#                         signal that was determined to be a false alarm —
#                         same classification chump-kpi-report's
#                         GateFalsePositiveSection uses)
#   missed_locally     — kind=ci_parity_drift (a CI gate not mirrored in
#                         `chump preflight`, i.e. a defect class CI catches
#                         that local checks structurally cannot)
#
# NOTE: this intentionally emits kind=ci_qa_accuracy_score, NOT kind=ci_qa_score.
# `ci_qa_score` is already owned by scripts/ops/ci-qa-score.sh (INFRA-1872) with
# a different schema (pct/sample_size/bypassed/window — a PR-clean-landing
# metric) that dashboard.rs and fleet-brief already parse. Reusing that kind
# name for this differently-shaped payload would silently break those
# consumers (INFRA-3847). Field names below otherwise match the INFRA-1861 AC
# verbatim (window_h, accurate_failures, false_positives, missed_locally,
# flake_count, score).
#
# Emits exactly one ambient event per invocation:
#   {"ts":"<iso>","kind":"ci_qa_accuracy_score","window_h":24,
#    "accurate_failures":N,"false_positives":N,"missed_locally":N,
#    "flake_count":N,"score":<float|null>}
#
# Usage:
#   ci-qa-accuracy-score.sh                  # default: window_h=24, emit
#   ci-qa-accuracy-score.sh --window-h 48
#   ci-qa-accuracy-score.sh --json           # machine-readable
#   ci-qa-accuracy-score.sh --dry-run        # compute but don't emit ambient
#
# Bypass: CHUMP_CI_QA_ACCURACY_SCORE=0 silently exits 0 (still emits audit line).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

WINDOW_H=24
JSON=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --window-h) WINDOW_H="$2"; shift 2 ;;
        --json) JSON=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "ci-qa-accuracy-score: unknown flag '$1'" >&2; exit 2 ;;
    esac
done

now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
emit_ambient() { printf '%s\n' "$1" >> "$AMBIENT_LOG" 2>/dev/null || true; }

if [[ "${CHUMP_CI_QA_ACCURACY_SCORE:-1}" == "0" ]]; then
    emit_ambient "$(printf '{"ts":"%s","kind":"ci_qa_accuracy_score_bypassed","reason":"CHUMP_CI_QA_ACCURACY_SCORE=0"}' "$(now_ts)")"
    echo "[ci-qa-accuracy-score] bypassed via CHUMP_CI_QA_ACCURACY_SCORE=0"
    exit 0
fi

if [[ ! -r "$AMBIENT_LOG" ]]; then
    payload="$(printf '{"ts":"%s","kind":"ci_qa_accuracy_score","window_h":%d,"accurate_failures":0,"false_positives":0,"missed_locally":0,"flake_count":0,"score":null}' "$(now_ts)" "$WINDOW_H")"
    [[ "$DRY_RUN" -eq 0 ]] && emit_ambient "$payload"
    if [[ "$JSON" -eq 1 ]]; then echo "$payload"; else echo "[ci-qa-accuracy-score] no ambient log found; nothing to score"; fi
    exit 0
fi

read -r ACCURATE FALSE_POSITIVES MISSED_LOCALLY FLAKE_COUNT SCORE_JSON <<PYEOF_OUT
$(python3 - "$AMBIENT_LOG" "$WINDOW_H" <<'PYEOF'
import json, sys
from datetime import datetime, timedelta, timezone

ambient_path = sys.argv[1]
window_h = float(sys.argv[2])
cutoff = datetime.now(timezone.utc) - timedelta(hours=window_h)

accurate = 0
false_positives = 0
missed_locally = 0
flake = 0

def parse_ts(raw):
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None

with open(ambient_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        ts = parse_ts(e.get("ts", ""))
        if ts is None or ts < cutoff:
            continue
        kind = e.get("kind", "")
        if kind == "ci_triage_verdict":
            verdict = e.get("verdict", "")
            if verdict in ("real", "known-bug"):
                accurate += 1
            elif verdict == "flake":
                flake += 1
        elif kind == "ci_flake_rerun":
            flake += 1
        elif kind == "duty_officer_action" and e.get("verdict") == "refuted":
            false_positives += 1
        elif kind == "ci_parity_drift":
            missed_locally += 1

denom = accurate + false_positives + missed_locally + flake
score = (accurate / denom) * 100 if denom > 0 else None
print(accurate, false_positives, missed_locally, flake, json.dumps(score))
PYEOF
)
PYEOF_OUT

if [[ "$SCORE_JSON" == "null" ]]; then
    SCORE_FIELD="null"
else
    SCORE_FIELD="$SCORE_JSON"
fi

payload="$(printf '{"ts":"%s","kind":"ci_qa_accuracy_score","window_h":%d,"accurate_failures":%d,"false_positives":%d,"missed_locally":%d,"flake_count":%d,"score":%s}' \
    "$(now_ts)" "$WINDOW_H" "$ACCURATE" "$FALSE_POSITIVES" "$MISSED_LOCALLY" "$FLAKE_COUNT" "$SCORE_FIELD")"

[[ "$DRY_RUN" -eq 0 ]] && emit_ambient "$payload"

if [[ "$JSON" -eq 1 ]]; then
    echo "$payload"
else
    if [[ "$SCORE_FIELD" == "null" ]]; then
        echo "[ci-qa-accuracy-score] no classified CI signals in last ${WINDOW_H}h window; score=null"
    else
        echo "[ci-qa-accuracy-score] score=${SCORE_FIELD}% (accurate=${ACCURATE} fp=${FALSE_POSITIVES} missed_locally=${MISSED_LOCALLY} flake=${FLAKE_COUNT}) window_h=${WINDOW_H}"
    fi
fi

exit 0
