#!/usr/bin/env bash
# Ghost-gap thrash fix — two regressions in one PR.
#
# (1) scripts/dispatch/_dep_resolution.py::unresolved_deps must count EVERY
#     terminal/done-like status as resolved (not only "done"), and must treat a
#     dangling/nonexistent dep ID as resolved — otherwise superseded/closed
#     dep-edges (observed ~1,142 of them) falsely pin ~456 open gaps shut and
#     workers starve on ghosts.
#
# (2) scripts/coord/gap-doctor-reconcile.py --check-merged-pr-titles must scan
#     the FULL merged-PR history by default (--merged-pr-limit 0), not the old
#     cap of 300 — the repo has ~5,200 merged PRs, so any gap shipped before
#     ~PR#4900 never auto-closed and got re-picked forever.
#
# Depth: edge/adversarial for unresolved_deps (terminal, dangling, active,
# unknown-status, mixed); happy-path + window-bound-passthrough for the
# gap-doctor window. Gaps: does NOT exercise the live gh/GitHub path (fake gh);
# does NOT assert the full-picker AC/priority pipeline (covered elsewhere).

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# ── Part 1: unresolved_deps terminal + dangling resolution ───────────────────
python3 - "$REPO_ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/scripts/dispatch")
from _dep_resolution import unresolved_deps, _DONE_LIKE_STATUSES

gaps = [
    {"id": "A", "status": "done"},
    {"id": "B", "status": "superseded"},
    {"id": "C", "status": "open"},
    {"id": "D", "status": "closed"},
    {"id": "E", "status": "already_satisfied"},
    {"id": "F", "status": "duplicate"},
    {"id": "G", "status": "OPEN"},        # case-insensitive gate
    {"id": "H", "status": "weird-status"},  # unknown -> stays gating
]

def check(desc, got, want):
    if got == want:
        print(f"[PASS] {desc}")
        return 0
    print(f"[FAIL] {desc}: got {got!r} want {want!r}")
    return 1

rc = 0
rc |= check("done dep resolves", unresolved_deps(["A"], gaps, set()), [])
rc |= check("superseded dep resolves (NEW)", unresolved_deps(["B"], gaps, set()), [])
rc |= check("closed dep resolves (NEW)", unresolved_deps(["D"], gaps, set()), [])
rc |= check("already_satisfied dep resolves (NEW)", unresolved_deps(["E"], gaps, set()), [])
rc |= check("duplicate dep resolves (NEW)", unresolved_deps(["F"], gaps, set()), [])
rc |= check("open dep still gates", unresolved_deps(["C"], gaps, set()), ["C"])
rc |= check("OPEN (any case) still gates", unresolved_deps(["G"], gaps, set()), ["G"])
rc |= check("unknown status stays gating (conservative)", unresolved_deps(["H"], gaps, set()), ["H"])
rc |= check("dangling/nonexistent dep resolves (NEW)", unresolved_deps(["ZZZ-999"], gaps, set()), [])
rc |= check("active dep resolves", unresolved_deps(["C"], gaps, {"C"}), [])
rc |= check("mixed: only open C/G gate", unresolved_deps(["A","B","C","D","E","F","G","H","NOPE-1"], gaps, set()), ["C","G","H"])
# Sanity: the resolver reuses the picker's done-like set, not a private copy.
assert "superseded" in _DONE_LIKE_STATUSES and "done" in _DONE_LIKE_STATUSES
print("[PASS] _DONE_LIKE_STATUSES reused (single source of truth)")
sys.exit(rc)
PY
if [ $? -eq 0 ]; then pass "unresolved_deps terminal+dangling resolution"; else fail "unresolved_deps regressions"; fi

# ── Part 2: gap-doctor-reconcile widened merged-PR window ─────────────────────
SCRIPT="$REPO_ROOT/scripts/coord/gap-doctor-reconcile.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake gh that RECORDS the --limit it was asked for, then returns a single ghost
# PR (#5001 — far beyond the old cap of 300) titled with the gap-ID.
mkdir -p "$TMP/fakebin"
cat >"$TMP/fakebin/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "repo" && "\$2" == "view" ]]; then echo "test/repo"; exit 0; fi
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then
  while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "--limit" ]]; then echo "\$2" > "$TMP/limit-seen"; fi
    shift
  done
  cat <<'JSON'
[
  {"number":5001,"title":"INFRA-7777: shipped long ago","mergedAt":"2026-01-02T00:00:00Z"}
]
JSON
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/fakebin/gh"

mkdb() {  # mkdb <path> <gap-id>  → a fresh state.db with one open gap
  sqlite3 "$1" <<SQL
CREATE TABLE gaps (
  id TEXT PRIMARY KEY, status TEXT NOT NULL DEFAULT 'open',
  closed_pr INTEGER, closed_date TEXT NOT NULL DEFAULT '',
  evidence TEXT, title TEXT NOT NULL DEFAULT ''
);
INSERT INTO gaps(id,status,title) VALUES ('$2','open','fixture');
SQL
}
run() { local db="$1"; shift; PATH="$TMP/fakebin:$PATH" CHUMP_STATE_DB="$db" \
        python3 "$SCRIPT" --check-merged-pr-titles "$@" 2>&1; }

# Default (no --merged-pr-limit): must request the FULL history from gh, not 300.
DB1="$TMP/db1.db"; mkdb "$DB1" "INFRA-7777"
rm -f "$TMP/limit-seen"
out="$(run "$DB1" --dry-run)"
seen="$(cat "$TMP/limit-seen" 2>/dev/null || echo 0)"
if [ "$seen" -gt 300 ]; then
  pass "default requests >300 merged PRs from gh (got --limit $seen)"
else
  fail "default still caps the merged-PR window at $seen (<=300) — ghost fix missing"
fi
echo "$out" | grep -q "GHOST INFRA-7777" \
  && pass "default window reaches PR #5001 (far beyond old 300 cap)" \
  || fail "default window did not reach the far-back ghost: $out"

# A gap shipped in a PR well beyond #300 now actually closes (apply).
run "$DB1" >/dev/null
st="$(sqlite3 "$DB1" "SELECT status FROM gaps WHERE id='INFRA-7777'")"
[ "$st" = "done" ] && pass "far-back ghost INFRA-7777 (PR #5001) auto-closes" \
  || fail "INFRA-7777 still $st (want done)"

# Clean path reports the full-history scope string.
DB2="$TMP/db2.db"; mkdb "$DB2" "INFRA-NOMATCH"
out="$(run "$DB2" --dry-run)"
echo "$out" | grep -q "all merged PRs" \
  && pass "clean run reports full-history scope (all merged PRs)" \
  || fail "clean run did not report full-history scope: $out"

# A positive --merged-pr-limit is still honored (bounded/debug runs).
DB3="$TMP/db3.db"; mkdb "$DB3" "INFRA-NOMATCH"
rm -f "$TMP/limit-seen"
run "$DB3" --merged-pr-limit 50 --dry-run >/dev/null
seen="$(cat "$TMP/limit-seen" 2>/dev/null || echo 0)"
[ "$seen" = "50" ] && pass "explicit --merged-pr-limit 50 honored (bounded scan)" \
  || fail "explicit limit not passed through (got --limit $seen)"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
