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
#   6. A PR whose number already appears in the EXISTING_FILINGS list is
#      skipped (dedup).
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
if [[ "$out" == *"would file"*"PR #472 stuck"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected 'would file ... PR #472 stuck', got:"
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

# ── Test 6: dedup against existing INFRA stuck-pr filings ────────────────────
echo "Test 6: existing 'PR #N stuck' gap dedups"
cat > "$TMP/bin/chump" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "gap list --status open --json")
        echo '[{"id":"INFRA-308","title":"PR #472 stuck — DIRTY for 8h","status":"open"}]'
        ;;
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
[{"number":472,"title":"INFRA-100: do a thing","headRefName":"chump/infra-100","isDraft":false,"author":{"login":"alice"},"mergeStateStatus":"DIRTY","autoMergeRequest":null,"updatedAt":"$OLD_TS"}]
JSON
        ;;
    "pr checks "*) echo "[]" ;;
esac
EOF
chmod +x "$TMP/bin/gh"

out=$(REMOTE=origin "$SCRIPT" --dry-run 2>&1 || true)
if [[ "$out" == *"already has a stuck-pr filing gap, skipping"* && "$out" != *"would file"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: existing filing should dedup, got:"
    echo "$out" | sed 's/^/    /'
    exit 1
fi

# ── Test 7: INFRA-386 — auto-close filed gap when underlying PR resolves ─────
echo "Test 7: filed gap auto-closes when its PR is MERGED"
SHIP_LOG="$TMP/ship.log"
rm -f "$SHIP_LOG"
cat > "$TMP/bin/chump" <<EOF
#!/usr/bin/env bash
case "\$*" in
    "gap list --status open --json")
        echo '[{"id":"INFRA-9777","title":"PR #777 stuck — DIRTY for 6h","status":"open"}]'
        ;;
    "gap ship INFRA-9777 --closed-pr 777 --update-yaml")
        echo "INFRA-9777 ship --closed-pr 777" >> "$SHIP_LOG"
        ;;
    "gap reserve "*) echo "INFRA-9999" ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/chump"

cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "pr view 777 --json state -q .state") echo "MERGED" ;;
    "pr list "*) echo "[]" ;;
    "pr checks "*) echo "[]" ;;
esac
EOF
chmod +x "$TMP/bin/gh"

out=$(REMOTE=origin "$SCRIPT" 2>&1 || true)
if [[ -f "$SHIP_LOG" ]] && grep -q "INFRA-9777 ship --closed-pr 777" "$SHIP_LOG" \
   && [[ "$out" == *"auto-closed INFRA-9777"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected gap ship + auto-closed message"
    echo "  ship log: $(cat "$SHIP_LOG" 2>/dev/null || echo "(empty)")"
    echo "  output:"
    echo "$out" | sed 's/^/    /'
    exit 1
fi

# ── Test 8: INFRA_386_AUTOCLOSE=0 bypass leaves the gap alone ────────────────
echo "Test 8: INFRA_386_AUTOCLOSE=0 bypass"
rm -f "$SHIP_LOG"
out=$(INFRA_386_AUTOCLOSE=0 REMOTE=origin "$SCRIPT" 2>&1 || true)
if { [[ ! -f "$SHIP_LOG" ]] || [[ ! -s "$SHIP_LOG" ]]; } && [[ "$out" != *"auto-closed"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: bypass should suppress gap ship + auto-closed message"
    echo "  ship log: $(cat "$SHIP_LOG" 2>/dev/null || echo "(empty)")"
    exit 1
fi

echo ""
echo "All stuck-pr-filer tests passed."
