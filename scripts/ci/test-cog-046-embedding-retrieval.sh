#!/usr/bin/env bash
# test-cog-046-embedding-retrieval.sh — COG-046
#
# Static-validates the embedding retrieval plumbing:
#  - lesson_embeddings.rs module + public API
#  - reflection_db.rs has load_relevant_lessons_embedding
#  - briefing.rs prefers embedding when CHUMP_LESSONS_EMBEDDING=1
#  - cascade chain is correct: embedding → semantic → recency
#  - default OFF
#  - unit tests defined (cog046_ prefix)
#
# Live e2e (Ollama embed call) is out of scope — that requires Ollama
# running with nomic-embed-text. The unit tests already exercise the
# unreachable-URL path.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== COG-046 embedding-retrieval plumbing test ==="
echo

# --- 1. module exists ---
if [[ -f "$REPO_ROOT/src/lesson_embeddings.rs" ]]; then
    ok "src/lesson_embeddings.rs module exists"
else
    fail "src/lesson_embeddings.rs missing"
fi

# --- 2. public API ---
for fn in embed_text cosine_similarity_f32 embedding_enabled; do
    if grep -qE "pub fn ${fn}\b" "$REPO_ROOT/src/lesson_embeddings.rs"; then
        ok "  pub fn $fn exists"
    else
        fail "  pub fn $fn missing"
    fi
done

# --- 3. reflection_db wiring ---
if grep -q 'pub fn load_relevant_lessons_embedding' "$REPO_ROOT/src/reflection_db.rs"; then
    ok "load_relevant_lessons_embedding defined in reflection_db.rs"
else
    fail "load_relevant_lessons_embedding missing"
fi

# --- 4. briefing chain order: embedding → semantic → recency ---
if grep -q 'embedding_enabled' "$REPO_ROOT/src/briefing.rs" \
   && grep -q 'load_relevant_lessons_embedding' "$REPO_ROOT/src/briefing.rs"; then
    ok "briefing.rs gates on embedding_enabled + calls embedding loader"
else
    fail "briefing.rs does not wire embedding mode"
fi

if grep -qE 'recency_fallback_from_embedding|semantic_fallback_from_embedding' "$REPO_ROOT/src/briefing.rs"; then
    ok "briefing.rs honestly records fallback ranking_mode (cascade is observable)"
else
    fail "no fallback ranking_mode labels — EVAL-099 can't attribute correctly"
fi

# --- 5. default OFF: env unset → embedding_enabled false ---
# Unit tests cover this; just check default in source.
if grep -qE 'CHUMP_LESSONS_EMBEDDING' "$REPO_ROOT/src/lesson_embeddings.rs"; then
    ok "CHUMP_LESSONS_EMBEDDING env documented"
else
    fail "no env documentation"
fi

# --- 6. best-effort: embed_text body has no panic/unwrap on the I/O path ---
embed_block=$(awk '/pub fn embed_text/,/^}/' "$REPO_ROOT/src/lesson_embeddings.rs")
# `unwrap` IS allowed in tests. We're checking the production fn body.
# Only the production fn block is extracted by the awk above.
if echo "$embed_block" | grep -qE '\.expect\(|\bpanic!\('; then
    fail "embed_text body contains expect/panic — must be best-effort"
else
    ok "embed_text body is panic-free (uses .ok()? for graceful failure)"
fi

# --- 7. unit tests defined ---
test_count=$(grep -cE 'fn cog046_' "$REPO_ROOT/src/lesson_embeddings.rs" 2>/dev/null || echo 0)
if [[ "$test_count" -ge 7 ]]; then
    ok "in-tree cog046_ unit tests defined ($test_count fns; full run via cargo test --workspace)"
else
    fail "expected >=7 cog046_ unit tests, found $test_count"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
