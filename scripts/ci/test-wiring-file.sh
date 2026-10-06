#!/usr/bin/env bash
# ZERO-WASTE-129: wiring-file.py files one gap-with-receipt per real finding, with a
# stable dedupe hash so the same finding run twice yields ONE gap, not two.
# A fake filer stands in for `chump gap file` (same `<filer> <finding.json>` contract).
# Pure local; no network.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FILE="$ROOT/scripts/ops/wiring-file.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { echo "  ok: $1"; pass=$((pass+1)); }; bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# Fake filer: records the finding file it was given, hands out sequential gap ids.
cat > "$T/filer.sh" <<'F'
#!/usr/bin/env bash
n=$(( $(cat "$FILER_DIR/count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FILER_DIR/count"
cp "$1" "$FILER_DIR/finding-$n.json"
[[ -f "$FILER_DIR/fail" ]] && { echo "endpoint down" >&2; exit 1; }
echo "ZERO-WASTE-$((9000 + n))"
F
chmod +x "$T/filer.sh"; mkdir -p "$T/filer"; export FILER_DIR="$T/filer"
filer_calls() { cat "$T/filer/count" 2>/dev/null || echo 0; }

row() { # <detector> <artifact> <decision> [evidence-json]
  printf '{"detector":"%s","name":"no-scheduler","severity":"med","artifact":"%s","detail":"declares periodic intent but nothing runs it","evidence":%s,"rank":1,"triage":{"decision":"%s","why":"alive but not connected"}}\n' \
    "$1" "$2" "${4:-{\"intent_phrase\":\"every 10 min\"\}}" "$3"
}
{ row D1 scripts/coord/a.sh WIRE; row D1 scripts/coord/b.sh ARCHIVE-DEAD; row D1 scripts/coord/c.sh ALLOWLIST-DORMANT; } > "$T/run1.jsonl"
run() { python3 "$FILE" --findings "$1" --ledger "$T/ledger.jsonl" --filer-cmd "$T/filer.sh" "${@:2}" 2>"$T/err.txt"; }

# 1. First run: the two real findings are filed, the allowlisted one is not.
run "$T/run1.jsonl" --today 2026-10-01 >/dev/null
[[ "$(filer_calls)" == "2" ]] && ok "two real findings filed; the ALLOWLIST-DORMANT one never is" || bad "filer calls: $(filer_calls)"
grep -q 'filed=2 updated=0 skipped(allowlisted/untriaged)=1' "$T/err.txt" && ok "summary counts filed / updated / skipped" || bad "summary: $(cat "$T/err.txt")"

# 2. Each gap carries an evidence receipt, a stable dedupe hash and acceptance criteria (the filer's schema).
python3 - "$T/filer/finding-1.json" <<'PY' && ok "gap has title tag + dedupe_hash + body receipt + acceptance + project/repo/priority" || bad "finding schema"
import json, re, sys
f = json.load(open(sys.argv[1]))
assert f["project"] == "chump" and f["repo"] == "repairman29/chump" and f["priority"] in ("P2", "P3"), f
h = f["dedupe_hash"]
assert re.fullmatch(r"wiring:[0-9a-f]{12}", h), h
assert f"[{h}]" in f["title"] and f"dedupe_hash: {h}" in f["body"], f
assert "Evidence receipt" in f["body"] and "scripts/coord/a.sh" in f["body"] and "every 10 min" in f["body"], f["body"]
assert len(f["acceptance"]) == 2 and all(f["acceptance"]), f
PY

# 3. SAME findings run again: one gap, not two — the filer is not called again.
before="$(filer_calls)"
run "$T/run1.jsonl" --today 2026-10-02 >/dev/null
[[ "$(filer_calls)" == "$before" ]] && ok "the same findings run twice produce ONE gap each, not two (no refile)" || bad "refiled: calls $before -> $(filer_calls)"
grep -q 'filed=0 updated=2' "$T/err.txt" && ok "re-detected standing conditions are updated, not filed" || bad "summary: $(cat "$T/err.txt")"
python3 - "$T/ledger.jsonl" <<'PY' && ok "ledger entry updated in place: last_seen advanced, seen_count=2, gap id kept" || bad "ledger"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
assert len(rows) == 2, rows
for r in rows:
    assert r["seen_count"] == 2 and r["first_seen"] == "2026-10-01" and r["last_seen"] == "2026-10-02", r
    assert r["gap_id"].startswith("ZERO-WASTE-90"), r
PY

# 4. The hash is stable under volatile evidence (counts/ages change between cycles).
python3 - "$FILE" <<'PY' && ok "dedupe hash ignores volatile evidence but changes with the decision" || bad "hash stability"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("wf", sys.argv[1]); wf = importlib.util.module_from_spec(spec); spec.loader.exec_module(wf)
base = {"detector": "D1", "artifact": "scripts/x.sh", "triage": {"decision": "WIRE"}, "evidence": {"refs": 1}}
same = {**base, "evidence": {"refs": 99, "age": 400}}
other = {**base, "triage": {"decision": "ARCHIVE-DEAD"}}
assert wf.dedupe_hash(base) == wf.dedupe_hash(same) != wf.dedupe_hash(other)
PY

# 5. A genuinely new finding still files; only the new one hits the filer.
{ cat "$T/run1.jsonl"; row D4 scripts/ci/new-runner.sh WIRE; } > "$T/run2.jsonl"
before="$(filer_calls)"
run "$T/run2.jsonl" --today 2026-10-03 >/dev/null
[[ "$(filer_calls)" == "$((before + 1))" ]] && ok "a new finding files exactly one new gap" || bad "calls $before -> $(filer_calls)"

# 6. A filer failure records nothing, so the next cycle retries.
touch "$T/filer/fail"
{ row D1 scripts/coord/flaky.sh WIRE; } > "$T/run3.jsonl"
run "$T/run3.jsonl" --today 2026-10-04 >/dev/null
grep -q 'failed=1' "$T/err.txt" && ! grep -q 'flaky.sh' "$T/ledger.jsonl" && ok "failed filing is not recorded in the ledger" || bad "failure recorded"
rm "$T/filer/fail"; before="$(filer_calls)"
run "$T/run3.jsonl" --today 2026-10-05 >/dev/null
[[ "$(filer_calls)" == "$((before + 1))" ]] && grep -q 'flaky.sh' "$T/ledger.jsonl" && ok "next cycle retries and files it" || bad "no retry"

# 7. --dry-run files nothing and writes no ledger; --max-new caps a flood.
rm -f "$T/ledger.jsonl"; before="$(filer_calls)"
out="$(run "$T/run1.jsonl" --dry-run)"
[[ "$(filer_calls)" == "$before" && ! -f "$T/ledger.jsonl" && "$out" == *"would file wiring:"* ]] && ok "--dry-run files nothing and writes no ledger" || bad "dry-run side effects"
run "$T/run1.jsonl" --max-new 1 >/dev/null
grep -q 'filed=1' "$T/err.txt" && grep -q 'deferred(max-new)=1' "$T/err.txt" && ok "--max-new caps new gaps per run (flood guard)" || bad "max-new: $(cat "$T/err.txt")"

echo "=== wiring file: $pass passed, $fail failed ==="
[[ $fail -eq 0 ]]
