#!/usr/bin/env bash
# test-stuck-pr-filer-shared-blocker.sh — INFRA-454
#
# Verifies the 'shared-CI-blocker' detection pass in stuck-pr-filer.sh:
#   1. Five PRs failing on the same CI check → ONE cleanup gap (not 5)
#   2. Two PRs failing on the same check → individual gaps (below threshold)
#   3. Five PRs split across two checks (3+2) → 1 group gap + 2 individual gaps
#   4. Dedup: matching "CI blocker:" gap already open → not refiled

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FILER="$REPO_ROOT/scripts/ops/stuck-pr-filer.sh"

[[ -x "$FILER" ]] || { echo "FAIL: $FILER not executable"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/repo/.chump-locks"
export PATH="$TMP/bin:$PATH"

# Minimal git repo so reaper_setup finds a valid repo root.
( cd "$TMP/repo" && git init -q -b main \
  && git config user.email t@t && git config user.name t \
  && echo init > README && git add . && git commit -qm init \
  && git remote add origin https://github.com/example/chump )

# Dummy test script so script-path detection succeeds in tests 1/3/4.
mkdir -p "$TMP/repo/scripts/ci"
printf '#!/usr/bin/env bash\necho hi\n' > "$TMP/repo/scripts/ci/test-shared-fail.sh"
chmod +x "$TMP/repo/scripts/ci/test-shared-fail.sh"

run_in_repo() { ( cd "$TMP/repo" && "$@" ); }

# Stub git so fetch/rev-list/log/diff don't require a real remote.
cat > "$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    fetch)    exit 0 ;;
    rev-list) echo "0" ;;
    log)      echo "" ;;
    diff)     echo "" ;;
    *)        exec /usr/bin/git "$@" ;;
esac
EOF
chmod +x "$TMP/bin/git"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
THREE_HRS_AGO=$(python3 -c "
from datetime import datetime, timezone, timedelta
print((datetime.now(timezone.utc) - timedelta(hours=3)).strftime('%Y-%m-%dT%H:%M:%SZ'))
")

# ── Test 1: 5 PRs all failing on same check → 1 shared-blocker gap ───────────
echo "Test 1: 5 PRs all failing on 'test-shared-fail.sh' → 1 shared-blocker gap, 0 per-PR gaps"

cat > "$TMP/bin/chump" <<EOF
#!/usr/bin/env bash
case "\$*" in
    "gap list --status open --json") echo "[]" ;;
    gap\ reserve\ *) echo "INFRA-9901" ;;
    gap\ set\ *) ;;
    *) echo "[]" ;;
esac
EOF
chmod +x "$TMP/bin/chump"

cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
    pr\ list\ *)
        cat <<JSON
[
  {"number":201,"title":"INFRA-201 feat a","headRefName":"chump/infra-201","isDraft":false,"author":{"login":"bot"},"mergeStateStatus":"BLOCKED","autoMergeRequest":null,"updatedAt":"$NOW"},
  {"number":202,"title":"INFRA-202 feat b","headRefName":"chump/infra-202","isDraft":false,"author":{"login":"bot"},"mergeStateStatus":"BLOCKED","autoMergeRequest":null,"updatedAt":"$NOW"},
  {"number":203,"title":"INFRA-203 feat c","headRefName":"chump/infra-203","isDraft":false,"author":{"login":"bot"},"mergeStateStatus":"BLOCKED","autoMergeRequest":null,"updatedAt":"$NOW"},
  {"number":204,"title":"INFRA-204 feat d","headRefName":"chump/infra-204","isDraft":false,"author":{"login":"bot"},"mergeStateStatus":"BLOCKED","autoMergeRequest":null,"updatedAt":"$NOW"},
  {"number":205,"title":"INFRA-205 feat e","headRefName":"chump/infra-205","isDraft":false,"author":{"login":"bot"},"mergeStateStatus":"BLOCKED","autoMergeRequest":null,"updatedAt":"$NOW"}
]
JSON
        ;;
    pr\ checks\ *)
        printf '[{"name":"test-shared-fail.sh","state":"FAILURE","completedAt":"%s"}]\n' "$THREE_HRS_AGO"
        ;;
    pr\ view\ *) echo '{"state":"OPEN"}' ;;
    *) echo "[]" ;;
esac
EOF
chmod +x "$TMP/bin/gh"

out=$(run_in_repo "$FILER" --dry-run 2>&1)

per_pr_gaps=$(echo "$out" | grep -c 'would file: PR #' || true)
shared_gaps=$(echo "$out" | grep -c 'would file shared-blocker gap:' || true)

if [[ "$shared_gaps" -eq 1 && "$per_pr_gaps" -eq 0 ]]; then
    echo "  PASS: 1 shared-blocker gap, 0 per-PR gaps"
else
    echo "  FAIL: expected 1 shared-blocker / 0 per-PR, got shared=$shared_gaps per-pr=$per_pr_gaps"
    echo "$out" | sed 's/^/    /' | head -20; exit 1
fi

if echo "$out" | grep -q 'test-shared-fail.sh'; then
    echo "  PASS: gap title references failing check name"
else
    echo "  FAIL: gap title missing check name"; echo "$out" | sed 's/^/    /' | head -10; exit 1
fi

if echo "$out" | grep -qE 'failing on 5\+'; then
    echo "  PASS: gap title includes affected-PR count"
else
    echo "  FAIL: gap title missing affected-PR count"; echo "$out" | sed 's/^/    /' | head -10; exit 1
fi

# ── Test 2: 2 PRs failing on same check → individual gaps (below threshold) ──
echo ""
echo "Test 2: 2 PRs failing on same check → individual CI-RED gaps (below threshold of 3)"

cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
    pr\ list\ *)
        cat <<JSON
[
  {"number":301,"title":"INFRA-301 feat","headRefName":"chump/infra-301","isDraft":false,"author":{"login":"bot"},"mergeStateStatus":"BLOCKED","autoMergeRequest":null,"updatedAt":"$NOW"},
  {"number":302,"title":"INFRA-302 feat","headRefName":"chump/infra-302","isDraft":false,"author":{"login":"bot"},"mergeStateStatus":"BLOCKED","autoMergeRequest":null,"updatedAt":"$NOW"}
]
JSON
        ;;
    pr\ checks\ *)
        printf '[{"name":"test-below-threshold.sh","state":"FAILURE","completedAt":"%s"}]\n' "$THREE_HRS_AGO"
        ;;
    pr\ view\ *) echo '{"state":"OPEN"}' ;;
    *) echo "[]" ;;
esac
EOF
chmod +x "$TMP/bin/gh"

out=$(run_in_repo "$FILER" --dry-run 2>&1)
per_pr_gaps=$(echo "$out" | grep -c 'would file: PR #' || true)
shared_gaps=$(echo "$out" | grep -c 'would file shared-blocker gap:' || true)

if [[ "$per_pr_gaps" -eq 2 && "$shared_gaps" -eq 0 ]]; then
    echo "  PASS: 2 individual CI-RED gaps, 0 shared-blocker gaps"
else
    echo "  FAIL: expected 2 individual / 0 shared, got per-pr=$per_pr_gaps shared=$shared_gaps"
    echo "$out" | sed 's/^/    /' | head -20; exit 1
fi

# ── Test 3: 5 PRs split 3+2 across two checks → 1 group + 2 individual ───────
echo ""
echo "Test 3: 5 PRs split 3+2 across two checks → 1 shared-blocker gap + 2 individual gaps"

cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
    pr\ list\ *)
        cat <<JSON
[
  {"number":401,"title":"INFRA-401","headRefName":"chump/infra-401","isDraft":false,"author":{"login":"bot"},"mergeStateStatus":"BLOCKED","autoMergeRequest":null,"updatedAt":"$NOW"},
  {"number":402,"title":"INFRA-402","headRefName":"chump/infra-402","isDraft":false,"author":{"login":"bot"},"mergeStateStatus":"BLOCKED","autoMergeRequest":null,"updatedAt":"$NOW"},
  {"number":403,"title":"INFRA-403","headRefName":"chump/infra-403","isDraft":false,"author":{"login":"bot"},"mergeStateStatus":"BLOCKED","autoMergeRequest":null,"updatedAt":"$NOW"},
  {"number":404,"title":"INFRA-404","headRefName":"chump/infra-404","isDraft":false,"author":{"login":"bot"},"mergeStateStatus":"BLOCKED","autoMergeRequest":null,"updatedAt":"$NOW"},
  {"number":405,"title":"INFRA-405","headRefName":"chump/infra-405","isDraft":false,"author":{"login":"bot"},"mergeStateStatus":"BLOCKED","autoMergeRequest":null,"updatedAt":"$NOW"}
]
JSON
        ;;
    pr\ checks\ 40[123]\ *)
        printf '[{"name":"test-shared-fail.sh","state":"FAILURE","completedAt":"%s"}]\n' "$THREE_HRS_AGO"
        ;;
    pr\ checks\ 40[45]\ *)
        printf '[{"name":"test-minority-check.sh","state":"FAILURE","completedAt":"%s"}]\n' "$THREE_HRS_AGO"
        ;;
    pr\ view\ *) echo '{"state":"OPEN"}' ;;
    *) echo "[]" ;;
esac
EOF
chmod +x "$TMP/bin/gh"

out=$(run_in_repo "$FILER" --dry-run 2>&1)
per_pr_gaps=$(echo "$out" | grep -c 'would file: PR #' || true)
shared_gaps=$(echo "$out" | grep -c 'would file shared-blocker gap:' || true)

if [[ "$shared_gaps" -eq 1 && "$per_pr_gaps" -eq 2 ]]; then
    echo "  PASS: 1 shared-blocker gap + 2 individual gaps"
else
    echo "  FAIL: expected shared=1 per-pr=2, got shared=$shared_gaps per-pr=$per_pr_gaps"
    echo "$out" | sed 's/^/    /' | head -20; exit 1
fi

# ── Test 4: dedup — matching "CI blocker:" gap already open → not refiled ─────
echo ""
echo "Test 4: 'CI blocker: test-shared-fail.sh ...' gap already open → not refiled"

cat > "$TMP/bin/chump" <<EOF
#!/usr/bin/env bash
case "\$*" in
    "gap list --status open --json")
        printf '[{"id":"INFRA-8888","title":"CI blocker: test-shared-fail.sh failing on 5+ open PRs","status":"open"}]\n'
        ;;
    gap\ reserve\ *) echo "SHOULD_NOT_REACH_9999" ;;
    gap\ set\ *) ;;
    *) echo "[]" ;;
esac
EOF
chmod +x "$TMP/bin/chump"

cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
    pr\ list\ *)
        cat <<JSON
[
  {"number":501,"title":"INFRA-501","headRefName":"chump/infra-501","isDraft":false,"author":{"login":"bot"},"mergeStateStatus":"BLOCKED","autoMergeRequest":null,"updatedAt":"$NOW"},
  {"number":502,"title":"INFRA-502","headRefName":"chump/infra-502","isDraft":false,"author":{"login":"bot"},"mergeStateStatus":"BLOCKED","autoMergeRequest":null,"updatedAt":"$NOW"},
  {"number":503,"title":"INFRA-503","headRefName":"chump/infra-503","isDraft":false,"author":{"login":"bot"},"mergeStateStatus":"BLOCKED","autoMergeRequest":null,"updatedAt":"$NOW"}
]
JSON
        ;;
    pr\ checks\ *)
        printf '[{"name":"test-shared-fail.sh","state":"FAILURE","completedAt":"%s"}]\n' "$THREE_HRS_AGO"
        ;;
    pr\ view\ *) echo '{"state":"OPEN"}' ;;
    *) echo "[]" ;;
esac
EOF
chmod +x "$TMP/bin/gh"

out=$(run_in_repo "$FILER" --dry-run 2>&1)
shared_gaps=$(echo "$out" | grep -c 'would file shared-blocker gap:' || true)

if [[ "$shared_gaps" -eq 0 ]]; then
    echo "  PASS: no duplicate shared-blocker gap filed (already exists)"
else
    echo "  FAIL: shared-blocker gap refiled despite existing one"
    echo "$out" | sed 's/^/    /' | head -10; exit 1
fi

echo ""
echo "All shared-CI-blocker tests passed."
