#!/usr/bin/env bash
# scripts/ci/test-fresh-eyes-loop.sh — META-132 smoke test for fresh-eyes-loop.sh
#
# Self-contained: every comparator is exercised against synthetic fixtures via
# the loop's env overrides (CHUMP_AMBIENT_LOG / *_BRIEF_CMD / *_SLO_CMD /
# *_ROADMAP / *_REGISTRY / *_LOOPS_DIR / *_SHIPS_CMD). No real fleet state is
# read; runs offline in well under a second.

set -uo pipefail   # NOT -e: we check exit codes explicitly

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOOP="$REPO_ROOT/scripts/coord/fresh-eyes-loop.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HEALTHY='printf "No urgent actions — fleet looks healthy\n"'
NOISY='printf "fire fire fire\n"'   # brief that does NOT claim health
PASS=0; FAIL=0

_check() { # _check <label> <expected_exit> <actual_exit>
    if [[ "$2" == "$3" ]]; then printf '  ok   %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
    else printf '  FAIL %s (expected exit %s, got %s)\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
_emitted() { # _emitted <label> <ambient_file> <grep-ERE>
    if grep -qE "$3" "$2" 2>/dev/null; then printf '  ok   %s\n' "$1"; PASS=$((PASS+1))
    else printf '  FAIL %s (no match /%s/ in %s)\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

[[ -x "$LOOP" ]] || { printf 'FATAL: %s not found or not executable\n' "$LOOP" >&2; exit 1; }

echo "[test-fresh-eyes] subcommand contract"
rc=0; bash "$LOOP" help    >/dev/null 2>&1 || rc=$?; _check "help exits 0" 0 "$rc"
rc=0; bash "$LOOP" bogus   >/dev/null 2>&1 || rc=$?; _check "bad subcommand exits 2" 2 "$rc"
HB="$TMP/hb.jsonl"; : > "$HB"
rc=0; CHUMP_AMBIENT_LOG="$HB" bash "$LOOP" heartbeat >/dev/null 2>&1 || rc=$?
_check "heartbeat exits 0" 0 "$rc"
_emitted "heartbeat emits fresh_eyes_heartbeat" "$HB" '"kind":"fresh_eyes_heartbeat"'

echo "[test-fresh-eyes] comparator 1 — brief healthy + fire in stream"
A="$TMP/c1.jsonl"; printf '{"ts":"%s","kind":"regression_attributed","session":"blame_bot"}\n' "$NOW" > "$A"
rc=0; CHUMP_AMBIENT_LOG="$A" CHUMP_FRESH_EYES_BRIEF_CMD="$HEALTHY" CHUMP_FRESH_EYES_SLO_CMD='true' \
    CHUMP_FRESH_EYES_ROADMAP=/nonexistent CHUMP_FRESH_EYES_REGISTRY=/nonexistent \
    CHUMP_FRESH_EYES_BACKLOG="$TMP/bk.jsonl" bash "$LOOP" audit >/dev/null 2>&1 || rc=$?
_check "C1 disagreement exits 0" 0 "$rc"
_emitted "C1 emits disagreement comparator_id=1" "$A" '"kind":"fresh_eyes_disagreement".*"comparator_id":1'

echo "[test-fresh-eyes] comparator 4 — brief healthy + SLO breach"
A="$TMP/c4.jsonl"; printf '{"ts":"%s","kind":"bash_call","session":"x"}\n' "$NOW" > "$A"
rc=0; CHUMP_AMBIENT_LOG="$A" CHUMP_FRESH_EYES_BRIEF_CMD="$HEALTHY" CHUMP_FRESH_EYES_SLO_CMD='exit 1' \
    CHUMP_FRESH_EYES_ROADMAP=/nonexistent CHUMP_FRESH_EYES_REGISTRY=/nonexistent \
    CHUMP_FRESH_EYES_BACKLOG="$TMP/bk.jsonl" bash "$LOOP" audit >/dev/null 2>&1 || rc=$?
_check "C4 disagreement exits 0" 0 "$rc"
_emitted "C4 emits disagreement comparator_id=4" "$A" '"comparator_id":4'

echo "[test-fresh-eyes] comparator 3 — curator heartbeat with no action"
A="$TMP/c3.jsonl"; printf '{"ts":"%s","kind":"decompose_heartbeat","session":"curator-x"}\n' "$NOW" > "$A"
rc=0; CHUMP_AMBIENT_LOG="$A" CHUMP_FRESH_EYES_BRIEF_CMD="$NOISY" CHUMP_FRESH_EYES_SLO_CMD='true' \
    CHUMP_FRESH_EYES_ROADMAP=/nonexistent CHUMP_FRESH_EYES_REGISTRY=/nonexistent \
    CHUMP_FRESH_EYES_BACKLOG="$TMP/bk.jsonl" bash "$LOOP" audit >/dev/null 2>&1 || rc=$?
_check "C3 silent-curator exits 0" 0 "$rc"
_emitted "C3 emits fresh_eyes_silent_curator" "$A" '"kind":"fresh_eyes_silent_curator"'

echo "[test-fresh-eyes] comparator 5 — ROADMAP bottleneck pillar starved"
A="$TMP/c5.jsonl"; printf '{"ts":"%s","kind":"bash_call","session":"x"}\n' "$NOW" > "$A"
RM="$TMP/roadmap.md"; printf '# Roadmap\nCurrent bottleneck: EFFECTIVE\n' > "$RM"
SHIPS='for i in 1 2 3 4 5 6 7 8 9 10; do echo "feat(INFRA-$i): thing (#$i)"; done'
rc=0; CHUMP_AMBIENT_LOG="$A" CHUMP_FRESH_EYES_BRIEF_CMD="$NOISY" CHUMP_FRESH_EYES_SLO_CMD='true' \
    CHUMP_FRESH_EYES_ROADMAP="$RM" CHUMP_FRESH_EYES_REGISTRY=/nonexistent CHUMP_FRESH_EYES_SHIPS_CMD="$SHIPS" \
    CHUMP_FRESH_EYES_BACKLOG="$TMP/bk.jsonl" bash "$LOOP" audit >/dev/null 2>&1 || rc=$?
_check "C5 roadmap-starvation exits 0" 0 "$rc"
_emitted "C5 emits disagreement comparator_id=5" "$A" '"comparator_id":5'

echo "[test-fresh-eyes] comparator 2 — registered kind with zero loop coverage"
A="$TMP/c2.jsonl"; printf '{"ts":"%s","kind":"bash_call","session":"x"}\n' "$NOW" > "$A"
REG="$TMP/registry.yaml"; printf 'events:\n  - kind: ghost_kind_never_watched\n    effect_metric: credible\n' > "$REG"
LP="$TMP/loops"; mkdir -p "$LP"; printf '#!/usr/bin/env bash\necho noop\n' > "$LP/dummy-loop.sh"
rc=0; CHUMP_AMBIENT_LOG="$A" CHUMP_FRESH_EYES_BRIEF_CMD="$NOISY" CHUMP_FRESH_EYES_SLO_CMD='true' \
    CHUMP_FRESH_EYES_ROADMAP=/nonexistent CHUMP_FRESH_EYES_REGISTRY="$REG" CHUMP_FRESH_EYES_LOOPS_DIR="$LP" \
    CHUMP_FRESH_EYES_BACKLOG="$TMP/bk.jsonl" bash "$LOOP" audit >/dev/null 2>&1 || rc=$?
_check "C2 coverage-gap exits 0" 0 "$rc"
_emitted "C2 emits fresh_eyes_coverage_gap" "$A" '"kind":"fresh_eyes_coverage_gap"'

echo "[test-fresh-eyes] all-clear — brief healthy + quiet stream → exit 1"
A="$TMP/ok.jsonl"; printf '{"ts":"%s","kind":"bash_call","session":"x"}\n' "$NOW" > "$A"
rc=0; CHUMP_AMBIENT_LOG="$A" CHUMP_FRESH_EYES_BRIEF_CMD="$HEALTHY" CHUMP_FRESH_EYES_SLO_CMD='true' \
    CHUMP_FRESH_EYES_ROADMAP=/nonexistent CHUMP_FRESH_EYES_REGISTRY=/nonexistent \
    CHUMP_FRESH_EYES_BACKLOG="$TMP/bk.jsonl" bash "$LOOP" audit >/dev/null 2>&1 || rc=$?
_check "all-clear exits 1" 1 "$rc"

echo
printf '[test-fresh-eyes] %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "[test-fresh-eyes] PASS"
