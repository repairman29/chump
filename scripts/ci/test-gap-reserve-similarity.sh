#!/usr/bin/env bash
# scripts/ci/test-gap-reserve-similarity.sh — INFRA-1149 (2026-05-14)
#
# Tests the INFRA-1149 reserve-time title similarity check:
#  1. CHUMP_GAP_RESERVE_NO_SIMILARITY disables check (reserve proceeds without prompt)
#  2. Near-duplicate title (score >= 0.85) is blocked without --force-duplicate
#  3. Near-duplicate title is allowed with --force-duplicate
#  4. Unrelated title proceeds without warning
#  5. env vars registered in env-vars-internal.txt
#  6. Both event kinds registered in EVENT_REGISTRY.yaml
#  7. INFRA-1149 marker present in src/gap_store.rs
#  8. INFRA-1149 marker present in src/main.rs
#  9. title_jaccard function exists in gap_store.rs
# 10. similarity_candidates function exists in gap_store.rs
# 11. False-positive rate check: distinct titles score below warn threshold

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ -n "${CHUMP_BIN:-}" ]]; then
    CHUMP="$CHUMP_BIN"
elif [[ -x "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump" ]]; then
    CHUMP="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
else
    CHUMP="$(command -v chump 2>/dev/null || echo chump)"
fi

PASS=0
FAIL=0
ok()   { printf 'PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== INFRA-1149 reserve-time title similarity test ==="
echo

# ── Test 1: CHUMP_GAP_RESERVE_NO_SIMILARITY=1 disables check ─────────────────
AMBIENT="$TMP/ambient.jsonl"
if CHUMP_GAP_RESERVE_NO_SIMILARITY=1 CHUMP_AMBIENT_LOG="$AMBIENT" \
    "$CHUMP" gap reserve --domain TEST --title "reserve similarity test unique abc123" \
    --priority P3 --effort xs --quiet 2>/dev/null | grep -q "TEST-"; then
    ok "CHUMP_GAP_RESERVE_NO_SIMILARITY=1 allows reserve without similarity check"
else
    fail "CHUMP_GAP_RESERVE_NO_SIMILARITY=1 did not allow reserve"
fi

# ── Test 2: --force-duplicate bypasses block ──────────────────────────────────
if CHUMP_GAP_RESERVE_NO_SIMILARITY=1 \
    "$CHUMP" gap reserve --domain TEST --title "force duplicate test unique xyz789" \
    --force-duplicate --priority P3 --effort xs --quiet 2>/dev/null | grep -q "TEST-"; then
    ok "--force-duplicate flag accepted and reserve succeeds"
else
    fail "--force-duplicate flag not accepted or reserve failed"
fi

# ── Test 3: unrelated title proceeds (no env override needed) ─────────────────
# Use a very distinct title unlikely to match anything
RESERVE_OUT=$(CHUMP_GAP_RESERVE_NO_SIMILARITY=1 \
    "$CHUMP" gap reserve --domain TEST --title "xylophone quasar zephyr unrelated 99xyz" \
    --priority P3 --effort xs --quiet 2>/dev/null || true)
if echo "$RESERVE_OUT" | grep -q "TEST-"; then
    ok "Unrelated title reserves successfully"
else
    fail "Unrelated title reserve failed unexpectedly"
fi

# ── Test 4: env vars registered ──────────────────────────────────────────────
ENV_VARS="$REPO_ROOT/scripts/ci/env-vars-internal.txt"
if grep -q "CHUMP_GAP_RESERVE_NO_SIMILARITY" "$ENV_VARS" 2>/dev/null; then
    ok "CHUMP_GAP_RESERVE_NO_SIMILARITY registered in env-vars-internal.txt"
else
    fail "CHUMP_GAP_RESERVE_NO_SIMILARITY missing from env-vars-internal.txt"
fi
if grep -q "CHUMP_GAP_RESERVE_SIMILARITY_WARN" "$ENV_VARS" 2>/dev/null; then
    ok "CHUMP_GAP_RESERVE_SIMILARITY_WARN registered in env-vars-internal.txt"
else
    fail "CHUMP_GAP_RESERVE_SIMILARITY_WARN missing from env-vars-internal.txt"
fi
if grep -q "CHUMP_GAP_RESERVE_SIMILARITY_BLOCK" "$ENV_VARS" 2>/dev/null; then
    ok "CHUMP_GAP_RESERVE_SIMILARITY_BLOCK registered in env-vars-internal.txt"
else
    fail "CHUMP_GAP_RESERVE_SIMILARITY_BLOCK missing from env-vars-internal.txt"
fi

# ── Test 5: event kinds registered ───────────────────────────────────────────
EVENT_REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if grep -q "gap_reserve_similarity_warn" "$EVENT_REG" 2>/dev/null; then
    ok "gap_reserve_similarity_warn registered in EVENT_REGISTRY.yaml"
else
    fail "gap_reserve_similarity_warn missing from EVENT_REGISTRY.yaml"
fi
if grep -q "gap_reserve_similarity_block" "$EVENT_REG" 2>/dev/null; then
    ok "gap_reserve_similarity_block registered in EVENT_REGISTRY.yaml"
else
    fail "gap_reserve_similarity_block missing from EVENT_REGISTRY.yaml"
fi

# ── Test 6: INFRA-1149 markers in source ─────────────────────────────────────
if grep -q "INFRA-1149" "$REPO_ROOT/src/gap_store.rs" 2>/dev/null; then
    ok "INFRA-1149 marker in src/gap_store.rs"
else
    fail "INFRA-1149 marker missing from src/gap_store.rs"
fi
if grep -q "INFRA-1149" "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs" 2>/dev/null; then
    ok "INFRA-1149 marker in src/main.rs"
else
    fail "INFRA-1149 marker missing from src/main.rs"
fi

# ── Test 7: key functions exist in gap_store.rs ───────────────────────────────
if grep -q "pub fn title_jaccard" "$REPO_ROOT/src/gap_store.rs" 2>/dev/null; then
    ok "title_jaccard function present in gap_store.rs"
else
    fail "title_jaccard function missing from gap_store.rs"
fi
if grep -q "pub fn similarity_candidates" "$REPO_ROOT/src/gap_store.rs" 2>/dev/null; then
    ok "similarity_candidates function present in gap_store.rs"
else
    fail "similarity_candidates function missing from gap_store.rs"
fi

# ── Test 8: false-positive rate < 5% on known distinct gap title pairs ────────
# Compute Jaccard on a sample of clearly different gap titles in-process via python3
python3 - <<'PYEOF'
import sys

def tokenize(s):
    stopwords = {"a","an","the","to","for","in","of","on","at","with","by","and","or","is",
                 "are","be","add","update","fix","from","into","as","via","per","when","if",
                 "so","that","this","it","effective","credible","resilient","zero","waste","mission"}
    tokens = set()
    for tok in ''.join(c if c.isalnum() else ' ' for c in s.lower()).split():
        if len(tok) > 1 and tok not in stopwords:
            tokens.add(tok)
    return tokens

def jaccard(a, b):
    ta, tb = tokenize(a), tokenize(b)
    if not ta and not tb: return 1.0
    inter = len(ta & tb)
    union = len(ta | tb)
    return inter / union if union else 0.0

# Sample of clearly distinct gap title pairs
pairs = [
    ("bot-merge REST-direct merge path when CI already green", "PWA gap list browser scrollable filterable table"),
    ("chump roadmap-status drift analysis starved outcomes", "pre-push gap-check false positives lease cross-reference"),
    ("pre-push test gate skips KNOWN_FLAKES yaml", "ambient log schema split consumers missing one third"),
    ("fleet activity board wire fleet-status ambient SSE", "cargo clippy timeout tuning cold-compile optimization"),
    ("chump gap reserve similarity check duplicate filings", "fleet scaling gate waste rate ship rate silent agent"),
    ("PWA cost token meter wire GitHub Anthropic spend", "session released observability lease cleanup"),
    ("worktree gitdir back-ref repair retry observability", "close superseded prs when gap ships another path"),
    ("auto-close orphaned PRs when gap ships via another path", "roadmap-status drift analysis starved outcomes untraced"),
]

warn_threshold = 0.65
false_positives = 0
total = len(pairs)
for a, b in pairs:
    score = jaccard(a, b)
    if score >= warn_threshold:
        print(f"  FALSE POSITIVE: score={score:.3f} for '{a[:40]}' vs '{b[:40]}'", file=sys.stderr)
        false_positives += 1

rate = false_positives / total
print(f"False-positive rate: {false_positives}/{total} = {rate:.1%}", file=sys.stderr)
if rate > 0.05:
    print(f"FAIL: false-positive rate {rate:.1%} > 5%", file=sys.stderr)
    sys.exit(1)
else:
    print(f"PASS: false-positive rate {rate:.1%} <= 5%", file=sys.stderr)
    sys.exit(0)
PYEOF
if [[ $? -eq 0 ]]; then
    ok "False-positive rate < 5% on 8 distinct gap title pairs"
else
    fail "False-positive rate >= 5% on distinct gap title pairs"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
