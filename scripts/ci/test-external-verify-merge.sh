#!/usr/bin/env bash
# scripts/ci/test-external-verify-merge.sh
# CREDIBLE-096: synthetic test harness for `chump external verify-merge`.
#
# Tests the 5-case matrix WITHOUT any live gh/LLM/network calls:
#   (a) CI-green + test-fails-on-base + passes-on-head    → MERGE
#   (b) CI-green + no test files changed                  → HELD(cosmetic)
#   (c) CI-green + test passes on BOTH base and head      → HELD(unproven)
#   (d) CI-red                                            → HELD(ci)
#   (e) repo has no CI checks                             → HELD(no-gates)
#
# Strategy: build a fake `gh` binary that returns canned JSON, create a
# minimal temp git repo with base + head branches, and a tiny test script
# whose behaviour we control via a sentinel file.
#
# shellcheck source=/dev/null
set -euo pipefail

# ── Setup ─────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

TOOLCHAIN_BIN="${HOME}/.rustup/toolchains/1.96.0-aarch64-apple-darwin/bin"
export PATH="${TOOLCHAIN_BIN}:${HOME}/.cargo/bin:${PATH}"

# Build the binary first (fail fast if it doesn't compile).
echo "[test] building chump binary ..."
cargo build --quiet --manifest-path "${REPO_ROOT}/Cargo.toml" 2>&1
# Resolve the REAL target dir. Both CI (CARGO_TARGET_DIR / sccache cache) and
# linked worktrees (.cargo/config target-dir, INFRA-481) redirect it, so the
# binary is NOT always under ${REPO_ROOT}/target. cargo metadata reports the
# actual target_directory; fall back to the conventional path if it's empty.
_target_dir="$(cargo metadata --no-deps --format-version 1 --manifest-path "${REPO_ROOT}/Cargo.toml" 2>/dev/null | jq -r '.target_directory // empty')"
CHUMP_BIN="${_target_dir:-${REPO_ROOT}/target}/debug/chump"
if [[ ! -x "${CHUMP_BIN}" ]]; then
  echo "FAIL: chump binary not found at ${CHUMP_BIN}" >&2
  exit 1
fi
echo "[test] build OK"

PASS=0
FAIL=0
ERRORS=()

# ── Helpers ───────────────────────────────────────────────────────────────

# Create a temp dir that is cleaned up on exit.
TMPDIR_ROOT=""
setup_tmpdir() {
  TMPDIR_ROOT="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${TMPDIR_ROOT}'" EXIT
}

# Write a fake `gh` binary to a temp dir and prepend that dir to PATH.
# $1 = subdir inside TMPDIR_ROOT
# $2 = content of the gh script (after #!/usr/bin/env bash)
install_fake_gh() {
  local dir="${TMPDIR_ROOT}/$1"
  mkdir -p "${dir}"
  local bin="${dir}/gh"
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "${bin}"
  chmod +x "${bin}"
  export CHUMP_GH_BIN="${bin}"
}

# Build a minimal git repo with a base commit + a PR-head branch.
# $1 = repo dir
# $2 = "has_test" | "no_test"   — whether the PR head adds a test file
# $3 = "fail_on_base" | "pass_on_base" — sentinel controlling test outcome on base
setup_git_repo() {
  local dir="$1"
  local has_test="$2"
  local fail_on_base="$3"

  mkdir -p "${dir}"
  git -C "${dir}" init -q
  git -C "${dir}" config user.email "test@example.com"
  git -C "${dir}" config user.name "Test"

  # ── base commit ──────────────────────────────────────────────────────────
  # A tiny Makefile with a 'test' target so detect_test_runner picks Make.
  cat > "${dir}/Makefile" <<'MAKEFILE'
.PHONY: test
test:
	@bash run_tests.sh
MAKEFILE

  # The sentinel: if FAIL_ON_BASE_SHA file exists, exit 1; else exit 0.
  cat > "${dir}/run_tests.sh" <<'TESTSH'
#!/usr/bin/env bash
# If the FAIL_ON_BASE sentinel file exists, fail.
if [[ -f "FAIL_ON_BASE" ]]; then
  echo "TEST FAIL: feature not implemented yet"
  exit 1
fi
echo "TEST PASS: all tests green"
exit 0
TESTSH

  # src file (not a test).
  printf "fn main() {}\n" > "${dir}/src.rs"

  git -C "${dir}" add Makefile run_tests.sh src.rs
  git -C "${dir}" commit -q -m "base commit"
  BASE_SHA="$(git -C "${dir}" rev-parse HEAD)"

  # ── PR head branch ───────────────────────────────────────────────────────
  git -C "${dir}" checkout -q -b pr-head

  if [[ "${fail_on_base}" == "fail_on_base" ]]; then
    # Create the sentinel on base first (we'll remove it for the head test).
    # Actually: the sentinel must exist on base → test fails on base.
    # On head it must NOT exist → test passes.
    # We create it in the base commit by amending (tricky), OR we just
    # control whether it's present via the repo state at each SHA.
    #
    # Simpler approach: on the pr-head branch we REMOVE the FAIL_ON_BASE file.
    # On the base commit it doesn't exist yet — we need it to exist on base.
    #
    # Re-think: the sentinel file makes the test FAIL when it EXISTS.
    # So: base = FAIL_ON_BASE present → test fails.  head = file removed → test passes.
    # We need to add FAIL_ON_BASE to the BASE commit, then remove it in head.
    #
    # Let's amend the base to include the sentinel.
    git -C "${dir}" checkout -q main 2>/dev/null || git -C "${dir}" checkout -q master 2>/dev/null || true
    # Add sentinel to base.
    touch "${dir}/FAIL_ON_BASE"
    git -C "${dir}" add FAIL_ON_BASE
    git -C "${dir}" commit -q --amend --no-edit
    BASE_SHA="$(git -C "${dir}" rev-parse HEAD)"
    # Back to pr-head — reset it onto the sentinel-bearing base so the
    # subsequent `git rm FAIL_ON_BASE` has the file to remove. (pr-head was
    # branched from the pre-amend base at line 105, so -B + BASE_SHA is required;
    # a plain `checkout -b` fails "already exists" and leaves no sentinel to rm.)
    git -C "${dir}" checkout -q -B pr-head "${BASE_SHA}"
    git -C "${dir}" rm -q FAIL_ON_BASE
    git -C "${dir}" commit -q -m "fix: implement the feature"
  fi

  if [[ "${has_test}" == "has_test" ]]; then
    # Add a test file (mkdir the dir first).
    mkdir -p "${dir}/tests"
    printf "#!/usr/bin/env bash\necho 'test file'\n" > "${dir}/tests/test_feature.sh"
    git -C "${dir}" add tests/test_feature.sh
    git -C "${dir}" commit -q -m "test: add test_feature"
  fi

  HEAD_SHA="$(git -C "${dir}" rev-parse HEAD)"

  # Export for the caller.
  export BASE_SHA HEAD_SHA
}

assert_verdict() {
  local case_name="$1"
  local expected="$2"
  local output="$3"
  if echo "${output}" | grep -qE "Verdict: ${expected}"; then
    echo "  PASS [${case_name}]: verdict=${expected}"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [${case_name}]: expected Verdict: ${expected}"
    echo "  --- actual output ---"
    echo "${output}" | head -20
    echo "  ---"
    FAIL=$((FAIL + 1))
    ERRORS+=("${case_name}: expected ${expected}")
  fi
}

run_verify() {
  local pr="$1"; local repo="$2"; local gap="$3"; local clone_dir="$4"
  local extra_args="${5:-}"
  # Disable ambient writes to a real file during tests.
  export CHUMP_AMBIENT_IN_PROMPT="${TMPDIR_ROOT}/ambient_test.jsonl"
  # shellcheck disable=SC2086
  "${CHUMP_BIN}" external verify-merge \
    --pr "${pr}" --repo "${repo}" --gap "${gap}" \
    --clone-dir "${clone_dir}" \
    ${extra_args} 2>&1 || true
}

# ── Shared setup ──────────────────────────────────────────────────────────

setup_tmpdir
echo ""
echo "=== CREDIBLE-096: external verify-merge test matrix ==="
echo ""

# ── Case (a): CI-green + test-fails-on-base + passes-on-head → MERGE ─────
echo "--- Case (a): CI-green + test-fails-on-base + passes-on-head ---"
{
  CASE_DIR="${TMPDIR_ROOT}/case_a"
  REPO_DIR="${CASE_DIR}/repo"
  CLONE_DIR="${CASE_DIR}/clone"

  # Set up git repo: has test, fails on base.
  setup_git_repo "${REPO_DIR}" "has_test" "fail_on_base"
  B="${BASE_SHA}"; H="${HEAD_SHA}"

  # Clone it ourselves so the subcommand doesn't need network.
  git clone -q "${REPO_DIR}" "${CLONE_DIR}"
  git -C "${CLONE_DIR}" fetch -q origin "${B}" "${H}" 2>/dev/null || true

  # Fake gh: CI green with one SUCCESS check.
  install_fake_gh "fake_gh_a" "
args=(\"\$@\")
joined=\$(echo \"\${args[*]}\")
if echo \"\${joined}\" | grep -q 'statusCheckRollup'; then
  printf '{\"statusCheckRollup\":[{\"name\":\"CI\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"}]}\n'
elif echo \"\${joined}\" | grep -q 'baseRefOid'; then
  printf '{\"baseRefOid\":\"${B}\",\"headRefOid\":\"${H}\"}\n'
else
  echo '{}'
fi
"

  OUT="$(run_verify 42 "owner/repo" "CREDIBLE-096" "${CLONE_DIR}")"
  assert_verdict "case_a" "MERGE" "${OUT}"
}

# ── Case (b): CI-green + no test files changed → HELD(cosmetic) ──────────
echo "--- Case (b): CI-green + no test files changed ---"
{
  CASE_DIR="${TMPDIR_ROOT}/case_b"
  REPO_DIR="${CASE_DIR}/repo"
  CLONE_DIR="${CASE_DIR}/clone"

  setup_git_repo "${REPO_DIR}" "no_test" "pass_on_base"
  B="${BASE_SHA}"; H="${HEAD_SHA}"

  git clone -q "${REPO_DIR}" "${CLONE_DIR}"

  install_fake_gh "fake_gh_b" "
args=(\"\$@\")
joined=\$(echo \"\${args[*]}\")
if echo \"\${joined}\" | grep -q 'statusCheckRollup'; then
  printf '{\"statusCheckRollup\":[{\"name\":\"CI\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"}]}\n'
elif echo \"\${joined}\" | grep -q 'baseRefOid'; then
  printf '{\"baseRefOid\":\"${B}\",\"headRefOid\":\"${H}\"}\n'
else
  echo '{}'
fi
"

  OUT="$(run_verify 43 "owner/repo" "CREDIBLE-096" "${CLONE_DIR}")"
  assert_verdict "case_b" "HELD.cosmetic." "${OUT}"
}

# ── Case (c): CI-green + test passes on BOTH base and head → HELD(unproven)
echo "--- Case (c): CI-green + test passes on both base and head ---"
{
  CASE_DIR="${TMPDIR_ROOT}/case_c"
  REPO_DIR="${CASE_DIR}/repo"
  CLONE_DIR="${CASE_DIR}/clone"

  # no "fail_on_base" → test passes on base too → unproven
  setup_git_repo "${REPO_DIR}" "has_test" "pass_on_base"
  B="${BASE_SHA}"; H="${HEAD_SHA}"

  git clone -q "${REPO_DIR}" "${CLONE_DIR}"

  install_fake_gh "fake_gh_c" "
args=(\"\$@\")
joined=\$(echo \"\${args[*]}\")
if echo \"\${joined}\" | grep -q 'statusCheckRollup'; then
  printf '{\"statusCheckRollup\":[{\"name\":\"CI\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"}]}\n'
elif echo \"\${joined}\" | grep -q 'baseRefOid'; then
  printf '{\"baseRefOid\":\"${B}\",\"headRefOid\":\"${H}\"}\n'
else
  echo '{}'
fi
"

  OUT="$(run_verify 44 "owner/repo" "CREDIBLE-096" "${CLONE_DIR}")"
  assert_verdict "case_c" "HELD.unproven." "${OUT}"
}

# ── Case (d): CI-red → HELD(ci) ──────────────────────────────────────────
echo "--- Case (d): CI-red ---"
{
  CASE_DIR="${TMPDIR_ROOT}/case_d"
  REPO_DIR="${CASE_DIR}/repo"
  CLONE_DIR="${CASE_DIR}/clone"

  setup_git_repo "${REPO_DIR}" "has_test" "fail_on_base"
  B="${BASE_SHA}"; H="${HEAD_SHA}"

  git clone -q "${REPO_DIR}" "${CLONE_DIR}"

  install_fake_gh "fake_gh_d" "
args=(\"\$@\")
joined=\$(echo \"\${args[*]}\")
if echo \"\${joined}\" | grep -q 'statusCheckRollup'; then
  printf '{\"statusCheckRollup\":[{\"name\":\"CI\",\"status\":\"COMPLETED\",\"conclusion\":\"FAILURE\"}]}\n'
elif echo \"\${joined}\" | grep -q 'baseRefOid'; then
  printf '{\"baseRefOid\":\"${B}\",\"headRefOid\":\"${H}\"}\n'
else
  echo '{}'
fi
"

  OUT="$(run_verify 45 "owner/repo" "CREDIBLE-096" "${CLONE_DIR}")"
  assert_verdict "case_d" "HELD.ci." "${OUT}"
}

# ── Case (e): repo has no CI checks → HELD(no-gates) ─────────────────────
echo "--- Case (e): repo has no CI checks ---"
{
  CASE_DIR="${TMPDIR_ROOT}/case_e"
  REPO_DIR="${CASE_DIR}/repo"
  CLONE_DIR="${CASE_DIR}/clone"

  setup_git_repo "${REPO_DIR}" "has_test" "fail_on_base"
  B="${BASE_SHA}"; H="${HEAD_SHA}"

  git clone -q "${REPO_DIR}" "${CLONE_DIR}"

  install_fake_gh "fake_gh_e" "
args=(\"\$@\")
joined=\$(echo \"\${args[*]}\")
if echo \"\${joined}\" | grep -q 'statusCheckRollup'; then
  printf '{\"statusCheckRollup\":[]}\n'
elif echo \"\${joined}\" | grep -q 'baseRefOid'; then
  printf '{\"baseRefOid\":\"${B}\",\"headRefOid\":\"${H}\"}\n'
else
  echo '{}'
fi
"

  OUT="$(run_verify 46 "owner/repo" "CREDIBLE-096" "${CLONE_DIR}")"
  assert_verdict "case_e" "HELD.no-gates." "${OUT}"
}

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if [[ ${FAIL} -gt 0 ]]; then
  for err in "${ERRORS[@]}"; do
    echo "  FAIL: ${err}"
  done
  exit 1
fi
echo "All ${PASS} cases passed."
exit 0
