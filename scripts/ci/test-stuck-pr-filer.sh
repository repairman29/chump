#!/usr/bin/env bash
# test-stuck-pr-filer.sh — INFRA-307 smoke test.
#
# Exercises scripts/ops/stuck-pr-filer.sh against a synthetic PR feed
# delivered through a stubbed `gh` on PATH. Verifies:
#   1. CHUMP_STUCK_PR_FILER=0 bypasses cleanly (exit 0, banner emitted).
#   2. Empty PR list short-circuits without error.
#   3. A DIRTY-for-too-long PR is detected in --dry-run output.
#   4. A filing PR (`chore(gaps): file …`) is skipped even when DIRTY.
#   5. A draft PR is skipped even when DIRTY.
#   6. A PR with a recent kind=pr_stuck ambient emit is skipped (dedup,
#      ZERO-WASTE-014: ambient-based, no gap is filed by this script).
#
# Network-free: stubs `gh` and `chump` via PATH; the heartbeat / ambient
# emit is allowed to write under a fresh REAPER_LOCK_DIR temp.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/stuck-pr-filer.sh"

[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/.chump-locks"
export PATH="$TMP/bin:$PATH"

# Stub `chump` — returns empty open-list by default; reserve always succeeds
# but we run --dry-run so it won't actually be invoked.
cat > "$TMP/bin/chump" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "gap list --status open --json") echo "[]" ;;
    "gap reserve "*) echo "INFRA-9999" ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/chump"

# Reaper instrumentation looks at the parent of --git-common-dir; point it
# at TMP so we don't pollute the real .chump-locks/ambient.jsonl during
# tests. Initialize a tiny git repo there and cd into it.
cd "$TMP"
# Bare repo as "origin" so `git fetch origin main` succeeds without network.
git init -q --bare origin.git >/dev/null
git init -q -b main repo >/dev/null
cd "$TMP/repo"
git config user.email "test@chump.local"
git config user.name "Chump Test"
echo init > README.md
git add README.md && git commit -qm "init"
git remote add origin "$TMP/origin.git"
git push -q origin main

# ── Test 1: bypass env exits 0 ───────────────────────────────────────────────
echo "Test 1: CHUMP_STUCK_PR_FILER=0 bypasses"
out=$(CHUMP_STUCK_PR_FILER=0 "$SCRIPT" 2>&1)
if [[ "$out" == *"bypass"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected 'bypass' in output, got: $out"
    exit 1
fi

# ── Test 2: empty PR list short-circuits ─────────────────────────────────────
echo "Test 2: empty PR list short-circuits"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "pr list "*) echo "[]" ;;
    *) echo "[]" ;;
esac
EOF
chmod +x "$TMP/bin/gh"

out=$(REMOTE=origin "$SCRIPT" --dry-run 2>&1 || true)
if [[ "$out" == *"nothing to do"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected 'nothing to do', got: $out"
    exit 1
fi

# ── Test 3: DIRTY for too long → detected in dry-run output ──────────────────
echo "Test 3: DIRTY-for-too-long PR is detected"
OLD_TS=$(python3 -c "
from datetime import datetime, timezone, timedelta
print((datetime.now(timezone.utc) - timedelta(hours=8)).strftime('%Y-%m-%dT%H:%M:%SZ'))
")
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
    "pr list "*)
        cat <<JSON
[{"number":472,"title":"INFRA-100: do a thing","headRefName":"chump/infra-100","isDraft":false,"author":{"login":"alice"},"mergeStateStatus":"DIRTY","autoMergeRequest":null,"updatedAt":"$OLD_TS"}]
JSON
        ;;
    "pr checks "*) echo "[]" ;;
    *) echo "" ;;
esac
EOF
chmod +x "$TMP/bin/gh"

out=$(REMOTE=origin DIRTY_THRESHOLD_HOURS=4 "$SCRIPT" --dry-run 2>&1 || true)
# INFRA-376: title must include the [REBASE] stuck-class tag so the fleet
# picker / human triager can route DIRTY-class cleanups to pr-watch-shepherd.
if [[ "$out" == *"would file"*"PR #472 stuck [REBASE]"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected 'would file ... PR #472 stuck [REBASE]', got:"
    echo "$out" | sed 's/^/    /'
    exit 1
fi

# ── Test 4: chore(gaps) filing PR is skipped ─────────────────────────────────
echo "Test 4: filing PR is skipped"
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
    "pr list "*)
        cat <<JSON
[{"number":501,"title":"chore(gaps): file INFRA-200","headRefName":"chore/file-infra-200","isDraft":false,"author":{"login":"alice"},"mergeStateStatus":"DIRTY","autoMergeRequest":null,"updatedAt":"$OLD_TS"}]
JSON
        ;;
    "pr checks "*) echo "[]" ;;
esac
EOF
chmod +x "$TMP/bin/gh"

out=$(REMOTE=origin "$SCRIPT" --dry-run 2>&1 || true)
if [[ "$out" == *"gap-filing PR, skipping"* && "$out" != *"would file"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: filing PR should be skipped, got:"
    echo "$out" | sed 's/^/    /'
    exit 1
fi

# ── Test 5: draft PR is skipped ──────────────────────────────────────────────
echo "Test 5: draft PR is skipped"
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
    "pr list "*)
        cat <<JSON
[{"number":603,"title":"INFRA-300: WIP","headRefName":"chump/infra-300","isDraft":true,"author":{"login":"alice"},"mergeStateStatus":"DIRTY","autoMergeRequest":null,"updatedAt":"$OLD_TS"}]
JSON
        ;;
    "pr checks "*) echo "[]" ;;
esac
EOF
chmod +x "$TMP/bin/gh"

out=$(REMOTE=origin "$SCRIPT" --dry-run 2>&1 || true)
if [[ "$out" == *"draft, skipping"* && "$out" != *"would file"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: draft PR should be skipped, got:"
    echo "$out" | sed 's/^/    /'
    exit 1
fi

# ── Test 6 (ZERO-WASTE-014): dedup against a recent pr_stuck ambient emit ────
echo "Test 6: recent pr_stuck ambient emit for the same PR dedups"
cat > "$TMP/bin/chump" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/chump"

DEDUP_AMBIENT="$TMP/dedup_ambient.jsonl"
NOW_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"ts":"%s","kind":"pr_stuck","pr":472,"reason":"DIRTY for 8h"}\n' "$NOW_TS" > "$DEDUP_AMBIENT"

cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
    "pr list "*)
        cat <<JSON
[{"number":472,"title":"INFRA-100: do a thing","headRefName":"chump/infra-100","isDraft":false,"author":{"login":"alice"},"mergeStateStatus":"DIRTY","autoMergeRequest":null,"updatedAt":"$OLD_TS"}]
JSON
        ;;
    "pr checks "*) echo "[]" ;;
esac
EOF
chmod +x "$TMP/bin/gh"

out=$(REMOTE=origin CHUMP_AMBIENT_LOG="$DEDUP_AMBIENT" "$SCRIPT" --dry-run 2>&1 || true)
if [[ "$out" == *"already has a stuck-pr filing"* && "$out" != *"would file"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: existing pr_stuck emit should dedup, got:"
    echo "$out" | sed 's/^/    /'
    exit 1
fi

# ── Test 9 (INFRA-376): CI-RED stuck class gets [CI-RED] title tag ──────────
echo "Test 9: CI-RED stuck PR gets [CI-RED] title tag"
# Build a fresh BLOCKED PR (not DIRTY) but with a long-failing required check.
# Reset chump stub so dedup doesn't fire.
cat > "$TMP/bin/chump" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "gap list --status open --json") echo "[]" ;;
    "gap reserve "*) echo "INFRA-9999" ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/chump"

# CI failure 5h ago — over the 2h CI_FAIL_THRESHOLD_HOURS default.
CI_OLD_TS=$(python3 -c "
from datetime import datetime, timezone, timedelta
print((datetime.now(timezone.utc) - timedelta(hours=5)).strftime('%Y-%m-%dT%H:%M:%SZ'))
")
RECENT_TS=$(python3 -c "
from datetime import datetime, timezone, timedelta
print((datetime.now(timezone.utc) - timedelta(minutes=10)).strftime('%Y-%m-%dT%H:%M:%SZ'))
")
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
    "pr list "*)
        cat <<JSON
[{"number":888,"title":"INFRA-200: green branch with red CI","headRefName":"chump/infra-200","isDraft":false,"author":{"login":"alice"},"mergeStateStatus":"BLOCKED","autoMergeRequest":{"enabledAt":"$RECENT_TS"},"updatedAt":"$RECENT_TS"}]
JSON
        ;;
    "pr checks 888 --json name,state,completedAt")
        cat <<JSON
[{"state":"FAILURE","completedAt":"$CI_OLD_TS"}]
JSON
        ;;
    "pr checks "*) echo "[]" ;;
esac
EOF
chmod +x "$TMP/bin/gh"

out=$(REMOTE=origin "$SCRIPT" --dry-run 2>&1 || true)
if [[ "$out" == *"would file"*"PR #888 stuck [CI-RED]"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected 'would file ... PR #888 stuck [CI-RED]', got:"
    echo "$out" | sed 's/^/    /'
    exit 1
fi

# ── Test 10 (INFRA-376): ORPHAN stuck class gets [ORPHAN] title tag ─────────
echo "Test 10: ORPHAN (auto-merge disarmed, no live lease) gets [ORPHAN] title tag"
# auto-merge null + cited gap with no live lease + recent updatedAt.
# We need REBASE/CI-RED/BEHIND to NOT trigger so the script falls through to
# the ORPHAN branch. updatedAt fresh (no DIRTY-age), CI checks empty (no
# CI-RED). gh pr list returns mss=BLOCKED. PR title cites a gap so GAP_IDS is
# non-empty, then has_live_lease checks .chump-locks/ — which is fresh (no
# leases) — so ORPHAN=1.
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
    "pr list "*)
        cat <<JSON
[{"number":901,"title":"INFRA-300: orphan no auto-merge","headRefName":"chump/infra-300","isDraft":false,"author":{"login":"alice"},"mergeStateStatus":"BLOCKED","autoMergeRequest":null,"updatedAt":"$RECENT_TS"}]
JSON
        ;;
    "pr checks "*) echo "[]" ;;
esac
EOF
chmod +x "$TMP/bin/gh"

out=$(REMOTE=origin "$SCRIPT" --dry-run 2>&1 || true)
if [[ "$out" == *"would file"*"PR #901 stuck [ORPHAN]"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected 'would file ... PR #901 stuck [ORPHAN]', got:"
    echo "$out" | sed 's/^/    /'
    exit 1
fi

# ── Test 11 (INFRA-376): BEHIND stuck class gets [BEHIND] title tag ─────────
echo "Test 11: BEHIND PR gets [BEHIND] title tag"
cat > "$TMP/bin/chump" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "gap list --status open --json") echo "[]" ;;
    "gap reserve "*) echo "INFRA-9999" ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/chump"

cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
    "pr list "*)
        cat <<JSON
[{"number":999,"title":"INFRA-400: far behind branch","headRefName":"chump/infra-400","isDraft":false,"author":{"login":"alice"},"mergeStateStatus":"BEHIND","autoMergeRequest":{"enabledAt":"$RECENT_TS"},"updatedAt":"$RECENT_TS"}]
JSON
        ;;
    "pr checks "*) echo "[]" ;;
esac
EOF
chmod +x "$TMP/bin/gh"

# Fake the branch as 25 commits behind main in our temp git repo so the
# `git rev-list` count reaches BEHIND_COMMITS_THRESHOLD (default 20).
cd "$TMP/repo"
# Push the branch at its current (old) position before advancing main.
git checkout -q main
git checkout -qb "chump/infra-400"
git push -q origin "chump/infra-400"
git checkout -q main
# Now add 25 commits to main so chump/infra-400 is 25 behind.
for i in $(seq 1 25); do
    echo "commit $i" > "commit_$i.txt"
    git add "commit_$i.txt"
    git commit -qm "dummy $i"
done
git push -q origin main
cd "$TMP/repo"

out=$(REMOTE=origin BEHIND_COMMITS_THRESHOLD=20 "$SCRIPT" --dry-run 2>&1 || true)
if [[ "$out" == *"would file"*"PR #999 stuck [BEHIND]"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected 'would file ... PR #999 stuck [BEHIND]', got:"
    echo "$out" | sed 's/^/    /'
    exit 1
fi

# ── Test N+1: INFRA-855 — INDIVIDUAL path emits one pr_stuck per PR, not per check ──
echo "Test: INFRA-855 — INDIVIDUAL dedup: two checks on same PR → one pr_stuck emit"

cat > "$TMP/bin/chump" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/chump"

# Two INDIVIDUAL entries for the same PR #111, different check names.
# The filer should emit exactly one pr_stuck event (for the first check) and
# skip the second.
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
OLD_TS_855="${OLD_TS}"
case "\$*" in
    "pr list "*)
        cat <<JSON
[{"number":111,"title":"INFRA-999: test gap","headRefName":"chump/infra-999","isDraft":false,"author":{"login":"alice"},"mergeStateStatus":"BLOCKED","autoMergeRequest":{"enabledAt":"\${OLD_TS_855}"},"updatedAt":"\${OLD_TS_855}"}]
JSON
        ;;
    "pr checks 111"*)
        cat <<JSON
[
  {"name":"test","state":"FAILURE","completedAt":"\${OLD_TS_855}"},
  {"name":"clippy","state":"FAILURE","completedAt":"\${OLD_TS_855}"}
]
JSON
        ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/gh"

rm -f "$TMP/ambient_855.jsonl"
out=$(REMOTE=origin CI_FAIL_THRESHOLD_MINS=0 SHARED_BLOCKER_THRESHOLD=999 \
    CHUMP_AMBIENT_LOG="$TMP/ambient_855.jsonl" \
    "$SCRIPT" 2>&1 || true)

emit_count=$(python3 -c "
import json
n = 0
with open('$TMP/ambient_855.jsonl') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if ev.get('kind') == 'pr_stuck' and ev.get('pr') == 111:
            n += 1
print(n)
" 2>/dev/null || echo 0)
if [[ "$emit_count" -eq 1 ]]; then
    echo "  PASS: INDIVIDUAL dedup: 2 failing checks → exactly 1 pr_stuck emit (got $emit_count)"
else
    echo "  FAIL: INDIVIDUAL dedup: expected 1 pr_stuck emit, got $emit_count"
    echo "$out" | sed 's/^/    /'
    exit 1
fi

# ── Test N+2: INFRA-855 — stuck_pr_filing_dedup_hit event emitted ──────────────
echo "Test: INFRA-855 — stuck_pr_filing_dedup_hit event emitted on dedup"
if [[ -f "$TMP/ambient_855.jsonl" ]] && grep -q '"stuck_pr_filing_dedup_hit"' "$TMP/ambient_855.jsonl"; then
    echo "  PASS: stuck_pr_filing_dedup_hit event emitted"
else
    echo "  FAIL: stuck_pr_filing_dedup_hit event missing from ambient.jsonl"
    echo "  (ambient contents: $(cat "$TMP/ambient_855.jsonl" 2>/dev/null || echo '(empty)'))"
    exit 1
fi

# ── Test N+3: INFRA-855 — ambient dedup is live within a single run ─────────
echo "Test: INFRA-855 — ambient-based dedup so second check on the same PR is skipped mid-run"
cat > "$TMP/bin/chump" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/chump"

cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
OLD_TS_855b="${OLD_TS}"
case "\$*" in
    "pr list "*)
        cat <<JSON
[{"number":222,"title":"INFRA-888: second test","headRefName":"chump/infra-888","isDraft":false,"author":{"login":"bob"},"mergeStateStatus":"BLOCKED","autoMergeRequest":{"enabledAt":"\${OLD_TS_855b}"},"updatedAt":"\${OLD_TS_855b}"}]
JSON
        ;;
    "pr checks 222"*)
        cat <<JSON
[{"name":"test","state":"FAILURE","completedAt":"\${OLD_TS_855b}"},
 {"name":"audit","state":"FAILURE","completedAt":"\${OLD_TS_855b}"}]
JSON
        ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/gh"

AMBIENT_855B="$TMP/ambient_855b.jsonl"
rm -f "$AMBIENT_855B"
out2=$(REMOTE=origin CI_FAIL_THRESHOLD_MINS=0 SHARED_BLOCKER_THRESHOLD=999 \
    CHUMP_AMBIENT_LOG="$AMBIENT_855B" \
    "$SCRIPT" 2>&1 || true)
cnt2=$(python3 -c "
import json
n = 0
with open('$AMBIENT_855B') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if ev.get('kind') == 'pr_stuck' and ev.get('pr') == 222:
            n += 1
print(n)
" 2>/dev/null || echo 0)
if [[ "$cnt2" -eq 1 ]]; then
    echo "  PASS: two failing checks for same PR → 1 pr_stuck emit (ambient dedup live mid-run)"
else
    echo "  FAIL: expected 1 pr_stuck emit, got $cnt2"
    echo "$out2" | sed 's/^/    /'
    exit 1
fi

echo ""
echo "All stuck-pr-filer tests passed."
