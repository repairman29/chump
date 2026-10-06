#!/usr/bin/env bash
# test-doctrine-weave-detectors.sh — META-1041
#
# Fixture test for scripts/coord/doctrine-weave-detectors.py: asserts the
# missing-thread and frayed-edge detectors flag seeded defects, stay quiet on
# healthy references, and emit doctrine_weave_asymmetry / doctrine_weave_frayed_edge.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DET="$REPO_ROOT/scripts/coord/doctrine-weave-detectors.py"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d -t test-meta-1041.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
R="$TMP/repo"
mkdir -p "$R/docs/process" "$R/docs/gaps"

cat > "$R/docs/process/ALPHA.md" <<'DOC'
# Alpha
Rescue stuck merge queue pull requests: rebase, rearm, cascade unblock.
Uses [Beta](BETA.md#2-real-section) and BETA.md §2 (both exist).
Stale: see [Beta](BETA.md#gone-section) and BETA.md §9.
Shipped under TEST-1 (closed) while TEST-2 is still open.
DOC
cat > "$R/docs/process/BETA.md" <<'DOC'
# Beta
## 1. Intro
## 2. Real Section
Merge queue rescue: rebase stuck pull requests then rearm cascade unblock.
DOC
cat > "$R/docs/process/GAMMA.md" <<'DOC'
# Gamma
Merge queue rescue rebase rearm cascade unblock stuck pull requests.
DOC
printf -- '- id: TEST-1\n  status: done\n' > "$R/docs/gaps/TEST-1.yaml"
printf -- '- id: TEST-2\n  status: open\n'  > "$R/docs/gaps/TEST-2.yaml"

AMB="$TMP/ambient.jsonl"
OUT="$TMP/out.json"
python3 "$DET" --root "$R" --emit --ambient "$AMB" > "$OUT" || fail "detector exited non-zero"
pass "runs and emits JSON"

q() { python3 - "$OUT" "$1" <<'PY'
import json, sys
f = json.load(open(sys.argv[1]))["findings"]
print(eval(sys.argv[2], {"f": f}))
PY
}

[[ "$(q 'any(x["reason"]=="one-way" and x["from"].endswith("ALPHA.md") and x["to"].endswith("BETA.md") for x in f)')" == "True" ]] \
  || fail "one-way reference ALPHA->BETA not flagged"
pass "missing-thread: X references Y but not the reverse"

[[ "$(q 'any(x["reason"]=="overlap-no-link" and {x["from"],x["to"]}=={"docs/process/BETA.md","docs/process/GAMMA.md"} for x in f)')" == "True" ]] \
  || fail "high-overlap unlinked pair BETA/GAMMA not flagged"
pass "missing-thread: high topic overlap with no link"

[[ "$(q 'sorted(x["section"] for x in f if x["reason"]=="missing-section")')" == "['#gone-section', '§9']" ]] \
  || fail "missing-section wrong: $(q '[x for x in f if x["reason"]=="missing-section"]')"
pass "frayed-edge: dead #anchor and §N flagged, live ones not"

[[ "$(q '[x["gap_id"] for x in f if x["reason"]=="closed-gap"]')" == "['TEST-1']" ]] \
  || fail "closed-gap wrong: $(q '[x for x in f if x["reason"]=="closed-gap"]')"
pass "frayed-edge: closed gap ID flagged, open gap ID not"

python3 - "$AMB" <<'PY' || fail "ambient emission wrong"
import json, sys
ev = [json.loads(l) for l in open(sys.argv[1])]
kinds = {e["kind"] for e in ev}
assert kinds == {"doctrine_weave_asymmetry", "doctrine_weave_frayed_edge"}, kinds
assert all("ts" in e for e in ev)
PY
pass "emits doctrine_weave_asymmetry + doctrine_weave_frayed_edge to ambient"

# Healthy tree -> zero findings, no events.
H="$TMP/healthy"; mkdir -p "$H/docs/process"
printf '# One\nSee TWO.md.\n' > "$H/docs/process/ONE.md"
printf '# Two\nSee ONE.md.\nTotally different cooking recipes.\n' > "$H/docs/process/TWO.md"
HA="$TMP/h-ambient.jsonl"
python3 "$DET" --root "$H" --emit --ambient "$HA" > "$TMP/h.json"
[[ "$(python3 -c "import json;print(len(json.load(open('$TMP/h.json'))['findings']))")" == "0" ]] \
  || fail "healthy tree produced findings"
[[ ! -s "$HA" ]] || fail "healthy tree emitted events"
pass "healthy tree: no findings, no events"

python3 "$DET" --root "$REPO_ROOT" > "$TMP/real.json" || fail "real-tree run failed"
python3 -c "import json;json.load(open('$TMP/real.json'))" || fail "real-tree output invalid"
pass "real tree scans cleanly"

echo "=== META-1041: all checks passed ==="
