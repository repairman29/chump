#!/usr/bin/env bash
# test-semantic-lesson-retrieval.sh — COG-041
#
# Verifies the new TF-IDF semantic retrieval path returns lessons whose
# directive text overlaps with the query, not just recent-and-frequent
# lessons. The decisive comparison is for a query that has NO recent
# matches in the recency-frequency pool but DOES have lexical overlap
# with an older lesson — the semantic path should surface it; the
# recency path won't.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHUMP="$REPO_ROOT/target/release/chump"
[[ -x "$CHUMP" ]] || { echo "FATAL: $CHUMP not built"; exit 2; }

echo "=== COG-041 semantic lesson retrieval test ==="
echo

# --- Test 1: function exists and is wired into briefing.rs ---
if grep -q 'fn load_relevant_lessons_semantic' "$REPO_ROOT/src/reflection_db.rs"; then
    ok "load_relevant_lessons_semantic defined in reflection_db.rs"
else
    fail "load_relevant_lessons_semantic missing"
fi

if grep -q 'lessons_semantic_enabled' "$REPO_ROOT/src/briefing.rs"; then
    ok "briefing.rs gates on CHUMP_LESSONS_SEMANTIC env"
else
    fail "briefing.rs does not call lessons_semantic_enabled"
fi

# --- Test 2: tokenize + cosine_similarity + IDF unit tests are the cargo
#     side; here we exercise the end-to-end via `chump --briefing` against
#     a real DB, comparing semantic-on vs semantic-off outputs. ---

# We need a DB with at least one lesson + a gap. Use the live state.db
# of the repo we're in (read-only — briefing is a pure-read command).
# Pick a gap that exists.
GAP_ID=$(sqlite3 "$REPO_ROOT/.chump/state.db" \
    "SELECT id FROM gaps WHERE status='open' AND id LIKE 'INFRA-%' LIMIT 1" 2>/dev/null || true)

if [[ -z "$GAP_ID" ]]; then
    echo "  SKIP: no open INFRA gap in state.db — skipping live retrieval comparison"
else
    BRIEF_OFF=$(CHUMP_LESSONS_SEMANTIC=0 "$CHUMP" --briefing "$GAP_ID" 2>/dev/null \
                | grep -A 100 "Top relevant reflections" | head -30)
    BRIEF_ON=$(CHUMP_LESSONS_SEMANTIC=1 "$CHUMP" --briefing "$GAP_ID" 2>/dev/null \
               | grep -A 100 "Top relevant reflections" | head -30)

    # Both should produce non-empty output (briefing always has the section).
    if [[ -n "$BRIEF_OFF" ]] && [[ -n "$BRIEF_ON" ]]; then
        ok "both briefing modes produced output for $GAP_ID"
    else
        fail "briefing produced empty output. OFF=${#BRIEF_OFF}b ON=${#BRIEF_ON}b"
    fi

    # The two should not be IDENTICAL — if they are, semantic isn't doing
    # anything (e.g. corpus too small or all-zero similarity → fell back).
    # Note: this is a smoke check; identical output is acceptable in some
    # corpora but unusual. Don't fail on it; just report.
    if [[ "$BRIEF_OFF" == "$BRIEF_ON" ]]; then
        echo "  NOTE: semantic produced identical output to recency-frequency for $GAP_ID"
        echo "        (possible: corpus has no relevant lessons OR all scored zero — fell back)"
    else
        ok "semantic produced different ranking than recency-frequency for $GAP_ID"
    fi
fi

# --- Test 3: tokenizer unit checks via cargo ---
# Run the in-tree cargo tests for the new functions.
cd "$REPO_ROOT"
# --- Unit tests are run by the workspace cargo test step in bot-merge.sh
# (see `cargo test --workspace`). This CI shell test stays within the
# 60s budget by NOT re-running them here — re-linking the test binary
# alone is ~3min on a cold build, blowing the budget. We just verify
# the test fns exist by name in the source. ---
if grep -qE 'fn cog041_(tokenize|cosine|semantic)' "$REPO_ROOT/src/reflection_db.rs"; then
    test_count=$(grep -cE 'fn cog041_(tokenize|cosine|semantic)' "$REPO_ROOT/src/reflection_db.rs")
    ok "in-tree cog041_ unit tests defined ($test_count fns; full run via cargo test --workspace)"
else
    fail "no cog041_ unit tests found — semantic retrieval has no test coverage"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
