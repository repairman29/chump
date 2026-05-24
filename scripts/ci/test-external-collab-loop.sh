#!/usr/bin/env bash
# scripts/ci/test-external-collab-loop.sh — META-104
#
# Smoke test for scripts/coord/external-collab-loop.sh.
# Stubs git log and grep; does NOT touch the real repo state.
#
# Cases:
#   1. Synthetic PITCH.md with banned word → assert external_collab_finding category=voice_drift
#   2. Synthetic >14d-stale doc → assert category=surface_stale
#   3. Synthetic ROADMAP_MARCUS with M-B at risk → assert category=marcus_at_risk
#   4. INFRA-1506 stalled >14d → assert category=partnership_stalled
#   5. All-fresh case → exit 0, no findings emitted
#
# Exit 0 = all pass. Exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOOP_SCRIPT="$REPO_ROOT/scripts/coord/external-collab-loop.sh"

if [ ! -f "$LOOP_SCRIPT" ]; then
    echo "FAIL: external-collab-loop.sh not found at $LOOP_SCRIPT" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

# Write a stub gap YAML file (printf '- id: ...' fails in bash when format starts with -)
write_gap() {
    local gap_id="$1" dest="$2"
    cat > "$dest" <<GAPEOF
- id: ${gap_id}
  status: open
  priority: P1
GAPEOF
}

# ── scaffold minimal fake repo ────────────────────────────────────────────────
setup_fake_repo() {
    local dir="$1"
    mkdir -p "$dir/docs/gaps" "$dir/docs/strategy" "$dir/.chump-locks" \
             "$dir/scripts/coord"
    cp "$LOOP_SCRIPT" "$dir/scripts/coord/external-collab-loop.sh"
    chmod +x "$dir/scripts/coord/external-collab-loop.sh"

    # Minimal git repo so git log calls work
    git -C "$dir" init --quiet
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
}

# Helper: run a subcommand in the fake repo, capturing ambient output
run_cmd() {
    local dir="$1"
    local subcmd="$2"
    CHUMP_EC_REPO_ROOT="$dir" \
    CHUMP_EC_AMBIENT_LOG="$dir/.chump-locks/ambient.jsonl" \
        bash "$dir/scripts/coord/external-collab-loop.sh" "$subcmd" 2>&1
}

ambient_has() {
    local dir="$1"
    local field="$2"
    local value="$3"
    grep -q "\"${field}\":\"${value}\"" "$dir/.chump-locks/ambient.jsonl" 2>/dev/null
}

# ── Case 1: banned word in PITCH.md → voice_drift finding ────────────────────
T1="$TMP/case1"
setup_fake_repo "$T1"

cat > "$T1/docs/PITCH.md" <<'EOF'
# Chump

A revolutionary approach to multi-agent orchestration.
This is truly synergy at its finest.
EOF
cat > "$T1/docs/HIDDEN_GEMS.md" <<'EOF'
# Hidden Gems
No banned words here.
EOF
cat > "$T1/docs/DEMO_5MIN.md" <<'EOF'
# 5-Minute Demo
Watch the demo now.
EOF

# Commit the docs so git log returns a recent timestamp (within 14d)
git -C "$T1" add -A
git -C "$T1" commit --quiet -m "initial"

run_cmd "$T1" "voice-audit" > /dev/null 2>&1

if ambient_has "$T1" "category" "voice_drift" && \
   ambient_has "$T1" "surface" "docs/PITCH.md"; then
    ok "Case 1: banned word 'revolutionary' in PITCH.md → voice_drift finding emitted"
else
    fail "Case 1: expected voice_drift finding for PITCH.md; ambient=$(cat "$T1/.chump-locks/ambient.jsonl" 2>/dev/null)"
fi

# ── Case 2: >14d-stale doc → surface_stale finding ───────────────────────────
T2="$TMP/case2"
setup_fake_repo "$T2"

cat > "$T2/docs/PITCH.md" <<'EOF'
# Chump
No banned words. Honest metrics. Quantified scalability at 10k req/s.
EOF
cat > "$T2/docs/HIDDEN_GEMS.md" <<'EOF'
# Hidden Gems
Clean doc.
EOF
cat > "$T2/docs/DEMO_5MIN.md" <<'EOF'
# 5-Minute Demo
Watch it live.
EOF

# Commit the docs but backdate so they appear >14d old
git -C "$T2" add -A
GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" \
GIT_COMMITTER_DATE="2026-01-01T00:00:00Z" \
    git -C "$T2" commit --quiet -m "old commit" --date="2026-01-01T00:00:00Z"

CHUMP_EC_STALE_DAYS=14 run_cmd "$T2" "surface-freshness" > /dev/null 2>&1

if ambient_has "$T2" "category" "surface_stale"; then
    ok "Case 2: >14d-stale doc → surface_stale finding emitted"
else
    fail "Case 2: expected surface_stale finding; ambient=$(cat "$T2/.chump-locks/ambient.jsonl" 2>/dev/null)"
fi

# ── Case 3: M-B gaps stalled >7d → marcus_at_risk finding ────────────────────
T3="$TMP/case3"
setup_fake_repo "$T3"

# Write clean operator-facing docs (no banned words, fresh)
for doc in PITCH.md HIDDEN_GEMS.md DEMO_5MIN.md; do
    printf '# %s\nClean content.\n' "${doc%.md}" > "$T3/docs/$doc"
done

# Write stale gap files for M-B (INFRA-1483, INFRA-1484, INFRA-1487)
for gap in INFRA-1483 INFRA-1484 INFRA-1487; do
    write_gap "$gap" "$T3/docs/gaps/${gap}.yaml"
done

# Write stub gap files for other milestones (so marcus-status doesn't warn-skip)
for gap in INFRA-1486 INFRA-1488 INFRA-1473 INFRA-1475 INFRA-1489 INFRA-1479 INFRA-1480 INFRA-1491; do
    write_gap "$gap" "$T3/docs/gaps/${gap}.yaml"
done

# Commit all files with a stale date so M-B gaps appear >7d untouched
git -C "$T3" add -A
GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" \
GIT_COMMITTER_DATE="2026-01-01T00:00:00Z" \
    git -C "$T3" commit --quiet -m "old state" --date="2026-01-01T00:00:00Z"

CHUMP_EC_MARCUS_STALL_DAYS=7 run_cmd "$T3" "marcus-status" > /dev/null 2>&1

if ambient_has "$T3" "category" "marcus_at_risk"; then
    ok "Case 3: M-B stalled >7d → marcus_at_risk finding emitted"
else
    fail "Case 3: expected marcus_at_risk finding; ambient=$(cat "$T3/.chump-locks/ambient.jsonl" 2>/dev/null)"
fi

# ── Case 4: INFRA-1506 stalled >14d → partnership_stalled finding ────────────
T4="$TMP/case4"
setup_fake_repo "$T4"

for doc in PITCH.md HIDDEN_GEMS.md DEMO_5MIN.md; do
    printf '# %s\nClean content.\n' "${doc%.md}" > "$T4/docs/$doc"
done
for gap in INFRA-1501 INFRA-1506 INFRA-1511; do
    write_gap "$gap" "$T4/docs/gaps/${gap}.yaml"
done

git -C "$T4" add -A
GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" \
GIT_COMMITTER_DATE="2026-01-01T00:00:00Z" \
    git -C "$T4" commit --quiet -m "old pipeline state" --date="2026-01-01T00:00:00Z"

run_cmd "$T4" "partnership-pipeline" > /dev/null 2>&1

if ambient_has "$T4" "category" "partnership_stalled"; then
    ok "Case 4: INFRA-1506 stalled >14d → partnership_stalled finding emitted"
else
    fail "Case 4: expected partnership_stalled finding; ambient=$(cat "$T4/.chump-locks/ambient.jsonl" 2>/dev/null)"
fi

# ── Case 5: all-fresh, clean docs → no findings ──────────────────────────────
T5="$TMP/case5"
setup_fake_repo "$T5"

for doc in PITCH.md HIDDEN_GEMS.md DEMO_5MIN.md; do
    printf '# %s\nHonest metrics. Quantified value. Specific claims only.\n' "${doc%.md}" \
        > "$T5/docs/$doc"
done
for gap in INFRA-1501 INFRA-1506 INFRA-1511 \
           INFRA-1486 INFRA-1483 INFRA-1484 INFRA-1487 \
           INFRA-1488 INFRA-1473 INFRA-1475 \
           INFRA-1489 INFRA-1479 INFRA-1480 INFRA-1491; do
    write_gap "$gap" "$T5/docs/gaps/${gap}.yaml"
done

# Commit with today's date (fresh)
git -C "$T5" add -A
git -C "$T5" commit --quiet -m "fresh state"

CHUMP_EC_STALE_DAYS=14 \
CHUMP_EC_MARCUS_STALL_DAYS=7 \
    run_cmd "$T5" "tick" > /dev/null 2>&1

finding_count=$(grep -c '"kind":"external_collab_finding"' "$T5/.chump-locks/ambient.jsonl" 2>/dev/null || echo "0")
if [ "$finding_count" = "0" ]; then
    ok "Case 5: all-fresh + clean docs → no findings emitted"
else
    fail "Case 5: expected 0 findings, got ${finding_count}; ambient=$(cat "$T5/.chump-locks/ambient.jsonl" 2>/dev/null)"
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
