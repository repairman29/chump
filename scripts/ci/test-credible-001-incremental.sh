#!/usr/bin/env bash
# scripts/ci/test-credible-001-incremental.sh — INFRA-1293
#
# Asserts the CREDIBLE-001 smoke gate (scripts/ci/test-infra-changes-smoke.sh)
# only runs shellcheck on STAGED .sh files, not the whole repo. Pre-fix
# behavior: any broken file in scripts/coord/ or scripts/dispatch/ blocked
# every commit through pre-commit. Post-fix: only staged files matter;
# unrelated broken files don't block; full repo scan still available via
# CHUMP_CREDIBLE_001_FULL_SCAN=1.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SMOKE="$REPO_ROOT/scripts/ci/test-infra-changes-smoke.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -x "$SMOKE" ]] || fail "smoke script not executable"
ok "smoke script present and executable"

# 1. Static checks on the patch
grep -q "INFRA-1293" "$SMOKE" || fail "smoke script missing INFRA-1293 comment marker"
grep -q "CHUMP_CREDIBLE_001_FULL_SCAN" "$SMOKE" || fail "smoke script missing CHUMP_CREDIBLE_001_FULL_SCAN bypass"
grep -q "no staged .sh files" "$SMOKE" || fail "smoke script missing skip message for no staged shell files"
ok "smoke script wires staged-only path + full-scan bypass"

# 2. End-to-end: create a temp repo with one clean + one broken shell file,
#    stage only the clean file, run smoke, assert PASS.
TMP=$(mktemp -d -t cr001-incremental-test-XXXX)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts/coord" "$TMP/scripts/dispatch" "$TMP/scripts/ci" "$TMP/.github/workflows"
cp "$SMOKE" "$TMP/scripts/ci/"

# Clean shell file
cat > "$TMP/scripts/coord/clean.sh" <<'CLEAN'
#!/usr/bin/env bash
set -euo pipefail
echo "ok"
CLEAN
chmod +x "$TMP/scripts/coord/clean.sh"

# Broken shell file (SC2034 unused var)
cat > "$TMP/scripts/coord/broken.sh" <<'BROKEN'
#!/usr/bin/env bash
set -euo pipefail
UNUSED_VAR="value"
echo "broken still runs but has shellcheck warning"
BROKEN
chmod +x "$TMP/scripts/coord/broken.sh"

# Init a real git repo so 'git diff --cached' works inside smoke script
cd "$TMP" && git init -q && git config user.email t@t && git config user.name t
git add scripts/coord/broken.sh
git commit -q -m "init: broken file already on main"
# Now stage ONLY the clean file (broken.sh remains on main but not staged again)
git add scripts/coord/clean.sh

# Run smoke gate with only the clean file as staged-file arg
out=$(REPO_ROOT="$TMP" bash "$TMP/scripts/ci/test-infra-changes-smoke.sh" scripts/coord/clean.sh 2>&1)
rc=$?
if [[ "$rc" -ne 0 ]]; then
    echo "--- smoke output ---"
    echo "$out"
    fail "smoke gate failed on clean-staged-file case (rc=$rc) — incremental mode should pass"
fi
ok "incremental mode: smoke PASSES when only clean files staged (broken file in repo ignored)"

# 3. Negative case: staging the BROKEN file → must fail
git add scripts/coord/broken.sh
out=$(REPO_ROOT="$TMP" bash "$TMP/scripts/ci/test-infra-changes-smoke.sh" scripts/coord/broken.sh 2>&1)
rc=$?
[[ "$rc" -ne 0 ]] || fail "smoke gate did NOT fail on staged broken file (incremental should catch its own)"
ok "incremental mode: smoke FAILS when broken file is staged"

# 4. Full-scan bypass: CHUMP_CREDIBLE_001_FULL_SCAN=1 with only clean staged → fails because broken.sh is in repo
out=$(CHUMP_CREDIBLE_001_FULL_SCAN=1 REPO_ROOT="$TMP" bash "$TMP/scripts/ci/test-infra-changes-smoke.sh" scripts/coord/clean.sh 2>&1)
rc=$?
[[ "$rc" -ne 0 ]] || fail "FULL_SCAN=1 should fail (broken.sh in repo) when only clean.sh staged"
ok "CHUMP_CREDIBLE_001_FULL_SCAN=1 forces repo-wide scan (catches unrelated broken file)"

echo
echo "All INFRA-1293 credible-001-incremental tests passed."
