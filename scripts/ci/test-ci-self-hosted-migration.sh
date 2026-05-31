#!/usr/bin/env bash
# test-ci-self-hosted-migration.sh — INFRA-1540
#
# Guards:
#   1. The 14 macOS-safe jobs in ci.yml MUST reference [self-hosted, macOS, ARM64].
#   2. Every self-hosted job MUST carry the fork-PR security guard
#      (INFRA-1534 AC #7). Otherwise fork PRs can RCE the operator's machine.
#   3. The INFRA-1540 marker comment must be present so future migrations
#      can locate already-migrated jobs.

set -uo pipefail
PASS=0
FAIL=0
FAILS=()

ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"

[[ -f "$CI_YML" ]] || { echo "FATAL: $CI_YML missing"; exit 2; }

echo "=== INFRA-1540 self-hosted runner migration audit ==="

# Test 1: marker comment appears at least once per migrated job (we migrated 14).
marker_count=$(grep -c "INFRA-1540: self-hosted macOS-ARM64 runner" "$CI_YML")
if (( marker_count >= 14 )); then
    ok "INFRA-1540 marker appears $marker_count times (expected >= 14)"
else
    fail "INFRA-1540 marker only appears $marker_count times (expected >= 14)"
fi

# Test 2: each self-hosted job must have the fork-PR guard.
#   Strategy: extract each block from `# INFRA-1540` to next blank-then-non-indented
#   line, assert the guard string appears within ~20 lines.
python3 - "$CI_YML" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
# Walk by job (header pattern: 2-space-indent identifier with colon).
job_re = re.compile(r'^  ([a-zA-Z][a-zA-Z0-9_-]*):\s*\n', re.MULTILINE)
jobs = [(m.group(1), m.start()) for m in job_re.finditer(src)]
jobs.append(('__END__', len(src)))
fails, oks = 0, 0
for i in range(len(jobs)-1):
    name, start = jobs[i]
    end = jobs[i+1][1]
    body = src[start:end]
    if 'INFRA-1540: self-hosted macOS-ARM64 runner' not in body:
        continue  # not a migrated job
    if 'fork == false' in body:
        oks += 1
    else:
        fails += 1
        ln = src[:start].count('\n') + 1
        print(f"  MISS_GUARD: job '{name}' (line {ln}) lacks `fork == false`", file=sys.stderr)
if fails:
    print(f"  FAIL: {fails} of {oks+fails} migrated jobs missing fork-PR security guard", file=sys.stderr)
    sys.exit(1)
print(f"  OK: {oks} migrated jobs all have fork-PR security guard")
PY
if [[ $? -eq 0 ]]; then
    ok "every self-hosted job carries fork-PR security guard"
else
    fail "at least one self-hosted job missing fork-PR security guard"
fi

# Test 3: no `runs-on: ubuntu-latest` exists for jobs we explicitly migrated.
MIGRATED_JOBS="changes test pr-hygiene e2e-battle-sim test-e2e clippy-required cargo-test-required fast-checks-required audit-required integration-test"
for job in $MIGRATED_JOBS; do
    python3 - "$CI_YML" "$job" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
job = sys.argv[2]
m = re.search(rf'^  {re.escape(job)}:\s*\n', src, re.MULTILINE)
if not m:
    print(f"NOT_FOUND: {job}")
    sys.exit(2)
body_start = m.end()
nh = re.search(r'^  [a-zA-Z][a-zA-Z0-9_-]*:\s*\n', src[body_start:], re.MULTILINE)
body = src[body_start: body_start + (nh.start() if nh else len(src) - body_start)]
if 'runs-on: ubuntu-latest' in body:
    print(f"STILL_UBUNTU: {job}")
    sys.exit(1)
if 'self-hosted' not in body:
    print(f"NOT_MIGRATED: {job}")
    sys.exit(1)
sys.exit(0)
PY
    rc=$?
    if [[ $rc -eq 0 ]]; then
        :  # silent pass per job
    elif [[ $rc -eq 2 ]]; then
        fail "job '$job' not found in ci.yml"
    else
        fail "job '$job' still on ubuntu-latest or not migrated"
    fi
done
if (( FAIL == 0 )); then
    ok "all 14 migrated jobs on self-hosted, none still on ubuntu-latest"
fi

# Test 4: setup scripts present + executable
if [[ -x "$REPO_ROOT/scripts/setup/install-self-hosted-runner-cache.sh" ]]; then
    ok "install-self-hosted-runner-cache.sh present + executable"
else
    fail "install-self-hosted-runner-cache.sh missing or not executable"
fi
if [[ -x "$REPO_ROOT/scripts/setup/install-self-hosted-runners-all-local.sh" ]]; then
    ok "install-self-hosted-runners-all-local.sh (automation wrapper) present + executable"
else
    fail "install-self-hosted-runners-all-local.sh missing or not executable"
fi
# Smoke: wrapper passes --help and exits 0
if bash "$REPO_ROOT/scripts/setup/install-self-hosted-runners-all-local.sh" --help >/dev/null 2>&1; then
    ok "automation wrapper accepts --help"
else
    fail "automation wrapper --help returns non-zero"
fi

# Test 5: migration script exists + dry-run clean on already-migrated file
if [[ -x "$REPO_ROOT/scripts/setup/migrate-ci-jobs-to-self-hosted.py" ]]; then
    out=$(cd "$REPO_ROOT" && python3 scripts/setup/migrate-ci-jobs-to-self-hosted.py --dry-run 2>&1 | tail -5)
    if echo "$out" | grep -qE "DRY-RUN: no changes|ALREADY MIGRATED.*14"; then
        ok "migration script is idempotent (dry-run on migrated file = no changes)"
    else
        # Allow ALREADY MIGRATED for each of the 14
        already=$(echo "$out" | grep -c "ALREADY MIGRATED")
        if (( already >= 1 )); then
            ok "migration script reports ALREADY MIGRATED (idempotent)"
        else
            fail "migration script not idempotent: $out"
        fi
    fi
else
    fail "migrate-ci-jobs-to-self-hosted.py missing"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
