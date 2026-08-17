#!/usr/bin/env bash
# CREDIBLE-279 AC1 + AC6: prove the BOOKKEEPING tier in
# scripts/ops/false-done-sweep.py is set membership (not a heuristic) via a
# fixture, and prove the regression that motivated the whole sweep: a
# bookkeeping-only PR must be flagged even when the gap's own text names the
# exact files that PR touched (the CREDIBLE-175 false-negative that
# path-overlap alone could not catch — see the docstring's MEASURED NEGATIVE
# CONTROL note).
set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

python3 - "$REPO_ROOT" <<'PYEOF'
import sys
sys.path.insert(0, f"{sys.argv[1]}/scripts/ops")
import importlib.util
spec = importlib.util.spec_from_file_location(
    "false_done_sweep", f"{sys.argv[1]}/scripts/ops/false-done-sweep.py"
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

failures = []

def check(name, cond):
    if cond:
        print(f"[PASS] {name}")
    else:
        print(f"[FAIL] {name}")
        failures.append(name)


class FakePrFiles:
    """Duck-types PrFiles.get() against a fixed pr -> file-list map."""
    def __init__(self, table):
        self.table = table

    def get(self, pr):
        return self.table.get(str(pr))


# ── AC1: BOOKKEEPING tier is set membership ─────────────────────────────────
# A PR touching only docs/gaps/*.yaml must flag as bookkeeping-closed.
bookkeeping_only_gap = {
    "id": "FAKE-1", "status": "done", "closed_pr": 9001,
    "title": "purely bookkeeping close", "priority": "P1",
    "description": "", "acceptance_criteria": "", "evidence": "", "notes": "",
}
# A PR with one real implementation file must NOT flag as bookkeeping-closed,
# even though it also touches a docs/gaps yaml (real PRs usually do both).
real_pr_gap = {
    "id": "FAKE-2", "status": "done", "closed_pr": 9002,
    "title": "add a real fix in src/foo.rs", "priority": "P1",
    "description": "touches src/foo.rs", "acceptance_criteria": "", "evidence": "", "notes": "",
}

prf = FakePrFiles({
    "9001": ["docs/gaps/FAKE-1.yaml"],
    "9002": ["docs/gaps/FAKE-2.yaml", "src/foo.rs"],
})

result = m.run_sweep([bookkeeping_only_gap, real_pr_gap], prf)
bk_ids = {b["gap"] for b in result["bookkeeping_closed"]}
check("docs-only PR (docs/gaps/*.yaml) flags as BOOKKEEPING-CLOSED", "FAKE-1" in bk_ids)
check("PR with one .rs file does NOT flag as BOOKKEEPING-CLOSED", "FAKE-2" not in bk_ids)

# Also prove membership at the unit level, not just via the sweep: an
# audits/archive-only PR is bookkeeping; a scripts/*.sh PR is not.
check("is_implementation('docs/audits/RED_LETTER.md') is False",
      m.is_implementation("docs/audits/RED_LETTER.md") is False)
check("is_implementation('docs/archive/old.md') is False",
      m.is_implementation("docs/archive/old.md") is False)
check("is_implementation('docs/ROADMAP.md') is False",
      m.is_implementation("docs/ROADMAP.md") is False)
check("is_implementation('scripts/coord/foo.sh') is True",
      m.is_implementation("scripts/coord/foo.sh") is True)

# ── AC6: regression — CREDIBLE-175-shaped false negative must be caught ────
# The gap's text names the EXACT files the (bookkeeping-only) closing PR
# touched. Path-overlap alone would call this clean (the measured negative
# control the docstring warns about) — the bookkeeping tier must catch it
# anyway because it runs FIRST and depends only on the PR diff.
credible175_shaped_gap = {
    "id": "FAKE-175", "status": "done", "closed_pr": 9003,
    "title": "harden git_safety pre-push hook",
    "description": "fixes src/git_safety.rs and tests/git_safety_e2e.rs",
    "acceptance_criteria": "", "evidence": "", "notes": "",
    "priority": "P0",
}
prf2 = FakePrFiles({
    # Bookkeeping-only PR that happens to NAME the same files in its... gap
    # text, but the diff itself ships zero implementation.
    "9003": ["docs/gaps/FAKE-175.yaml"],
})
result2 = m.run_sweep([credible175_shaped_gap], prf2)
bk_ids2 = {b["gap"] for b in result2["bookkeeping_closed"]}
check(
    "gap naming its own fix-site files still flags when the closing PR shipped no code "
    "(the CREDIBLE-175 false-negative path-overlap alone misses)",
    "FAKE-175" in bk_ids2,
)
# And prove path-overlap alone WOULD have missed it, to document why the
# bookkeeping tier exists and runs first.
gp = m.paths_in(m.gap_text(credible175_shaped_gap))
overlap_files = ["src/git_safety.rs", "tests/git_safety_e2e.rs"]
overlap_hit = m.basename_overlap(gp, overlap_files)
check(
    "sanity: path-overlap alone (against a hypothetical non-bookkeeping PR "
    "touching those files) WOULD call this clean — proving bookkeeping-first ordering matters",
    len(overlap_hit) > 0,
)

if failures:
    print(f"\n{len(failures)} check(s) failed: {failures}")
    sys.exit(1)
print(f"\nall checks passed")
PYEOF
rc=$?
if [[ $rc -eq 0 ]]; then
    pass "false-done-sweep BOOKKEEPING tier + CREDIBLE-175 regression fixture"
else
    fail "false-done-sweep BOOKKEEPING tier + CREDIBLE-175 regression fixture"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
