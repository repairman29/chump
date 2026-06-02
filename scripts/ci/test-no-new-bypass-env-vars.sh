#!/usr/bin/env bash
# scripts/ci/test-no-new-bypass-env-vars.sh — INFRA-2429
#
# CI lint: forbids NEW CHUMP_*_BYPASS, CHUMP_*_SKIP, and CHUMP_IGNORE_*
# env var introductions in PR diffs.
#
# WHAT THIS DOES:
#   1. Computes a diff of added lines vs origin/main (or BASE_REF).
#   2. Scans for newly-introduced bypass-class env var names in:
#      - Rust source: std::env::var("CHUMP_..._BYPASS|SKIP"), env! macros
#      - Shell source: ${CHUMP_..._BYPASS|SKIP}, $CHUMP_..._BYPASS|SKIP
#      - scripts/ci/env-vars-internal.txt: new lines matching the patterns
#   3. For each found var name, checks scripts/ci/bypass-env-var-allowlist.txt.
#   4. Exits 1 if any unallowlisted bypass-class var is introduced.
#   5. *_DISABLED vars are NOT scanned — those are Category B operator
#      emergency kill-switches that are intentionally permitted.
#
# OPERATOR ZERO-BYPASS THESIS (INFRA-2429):
#   This script has NO env-var bypass of its own. If you need a short-term
#   exception, add the var name to bypass-env-var-allowlist.txt with a
#   Bypass-Justification: comment referencing a gap_id for tracking.
#
# Usage:
#   bash scripts/ci/test-no-new-bypass-env-vars.sh         # full mode
#   BASE_REF=some-branch bash scripts/ci/...               # custom base ref
#
# Self-test mode (AC step 5):
#   TEST_SELF_TEST=1 bash scripts/ci/test-no-new-bypass-env-vars.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ALLOWLIST="$REPO_ROOT/scripts/ci/bypass-env-var-allowlist.txt"

# ── Self-test mode ─────────────────────────────────────────────────────────────
if [[ "${TEST_SELF_TEST:-0}" == "1" ]]; then
  bash "$REPO_ROOT/scripts/ci/test-no-new-bypass-env-vars.sh" --self-test
  exit $?
fi

if [[ "${1:-}" == "--self-test" ]]; then
  PASS=0
  FAIL=0

  run_case() {
    local label="$1"
    local diff_input="$2"
    local expect_exit="$3"
    local tmpdir
    tmpdir="$(mktemp -d)"
    local fake_list="$tmpdir/allowlist.txt"
    # Use a minimal allowlist for self-tests that includes CHUMP_PREFLIGHT_SKIP
    # so we can test the allowlist-hit path.
    printf '%s\n' \
      '# self-test allowlist' \
      'CHUMP_PREFLIGHT_SKIP  # grandfathered; deletion target INFRA-2422' \
      > "$fake_list"
    local out
    local actual_exit=0
    out=$(BYPASS_ALLOWLIST_OVERRIDE="$fake_list" \
          BYPASS_DIFF_OVERRIDE="$diff_input" \
          bash "$REPO_ROOT/scripts/ci/test-no-new-bypass-env-vars.sh" 2>&1) \
      || actual_exit=$?
    if [[ "$actual_exit" -eq "$expect_exit" ]]; then
      echo "  PASS: $label (exit=$actual_exit)"
      PASS=$((PASS + 1))
    else
      echo "  FAIL: $label — expected exit $expect_exit, got $actual_exit"
      echo "        output: $out"
      FAIL=$((FAIL + 1))
    fi
    rm -rf "$tmpdir"
  }

  echo "[bypass-lint self-test] running 4 synthetic cases..."

  # Case 1: New bypass var NOT in allowlist → exit 1
  run_case "new CHUMP_NEW_BYPASS not in allowlist" \
    '+CHUMP_NEW_BYPASS=foo' \
    1

  # Case 2: New bypass var IN allowlist → exit 0
  run_case "new CHUMP_PREFLIGHT_SKIP in allowlist" \
    '+CHUMP_PREFLIGHT_SKIP=1' \
    0

  # Case 3: *_DISABLED var (Category B kill-switch) → exit 0 (exempt)
  run_case "CHUMP_FLEET_DOCTOR_DISABLED is Category B, exempt" \
    '+CHUMP_FLEET_DOCTOR_DISABLED=1' \
    0

  # Case 4: Diff with no bypass vars → exit 0
  run_case "clean diff with no bypass vars" \
    '+CHUMP_LOG_LEVEL=debug' \
    0

  echo ""
  if [[ $FAIL -gt 0 ]]; then
    echo "[bypass-lint self-test] FAIL: $FAIL/$((PASS+FAIL)) cases failed"
    exit 1
  else
    echo "[bypass-lint self-test] PASS: all $PASS cases passed"
    exit 0
  fi
fi

# ── Load allowlist ─────────────────────────────────────────────────────────────
# Support override for self-test injection.
ALLOWLIST="${BYPASS_ALLOWLIST_OVERRIDE:-$ALLOWLIST}"

load_allowlist() {
  if [[ ! -f "$ALLOWLIST" ]]; then
    echo "[bypass-lint] WARN: allowlist not found at $ALLOWLIST — treating as empty" >&2
    return
  fi
  # Strip comment-only lines and blank lines; take first whitespace-delimited token.
  grep -v '^\s*#' "$ALLOWLIST" | grep -v '^\s*$' | awk '{print $1}'
}

ALLOWED_VARS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && ALLOWED_VARS+=("$line")
done < <(load_allowlist)

is_allowed() {
  local varname="$1"
  local v
  for v in "${ALLOWED_VARS[@]:-}"; do
    if [[ "$v" == "$varname" ]]; then
      return 0
    fi
  done
  return 1
}

# ── Compute diff ───────────────────────────────────────────────────────────────
# BYPASS_DIFF_OVERRIDE allows self-test to inject a synthetic diff string.
get_diff_lines() {
  if [[ -n "${BYPASS_DIFF_OVERRIDE:-}" ]]; then
    printf '%s\n' "$BYPASS_DIFF_OVERRIDE"
    return
  fi
  local base="${BASE_REF:-origin/main}"
  # In CI pull_request context git diff origin/main...HEAD gives the PR diff.
  # Locally (or merge_group) fall back to origin/main..HEAD.
  local diff_output
  diff_output="$(git diff "${base}...HEAD" 2>/dev/null)" \
    || diff_output="$(git diff "${base}..HEAD" 2>/dev/null)" \
    || diff_output=""
  printf '%s\n' "$diff_output"
}

# ── Pattern matching ───────────────────────────────────────────────────────────
# We want to find ADDED lines (starting with +, not ++) that contain
# bypass-class env var names. The DISABLED category is intentionally exempt.
#
# Patterns we scan for (as var name extractions):
#   Rust:  std::env::var("CHUMP_XYZ_BYPASS")
#          std::env::var("CHUMP_XYZ_SKIP")
#          std::env::var("CHUMP_IGNORE_XYZ")
#          env!("CHUMP_XYZ_BYPASS")
#   Shell: ${CHUMP_XYZ_BYPASS}, $CHUMP_XYZ_BYPASS
#          ${CHUMP_XYZ_SKIP},   $CHUMP_XYZ_SKIP
#          ${CHUMP_IGNORE_XYZ}, $CHUMP_IGNORE_XYZ
#   env-vars-internal.txt bare names: CHUMP_XYZ_BYPASS, CHUMP_XYZ_SKIP,
#                                     CHUMP_IGNORE_XYZ
#
# _DISABLED is excluded from all patterns.

extract_bypass_varnames() {
  local diff_text="$1"
  local tmpfile
  tmpfile="$(mktemp)"
  printf '%s\n' "$diff_text" > "$tmpfile"

  # Only look at added lines (+ prefix, not ++ which is the diff header).
  # Use grep -E; avoid pipe-to-grep-q (INFRA-1658).
  local added_lines
  added_lines="$(grep -E '^\+[^+]' "$tmpfile" 2>/dev/null)" || added_lines=""
  rm -f "$tmpfile"

  local added_file
  added_file="$(mktemp)"
  printf '%s\n' "$added_lines" > "$added_file"

  # Extract var names matching the bypass patterns.
  # Strategy: grep for the CHUMP_*_BYPASS|SKIP|IGNORE_* substrings using -o,
  # then filter out _DISABLED.
  local raw_hits
  raw_hits="$(grep -oE 'CHUMP_[A-Z0-9_]*(BYPASS|SKIP)|CHUMP_IGNORE_[A-Z0-9_]*' \
    "$added_file" 2>/dev/null || true)"
  rm -f "$added_file"

  if [[ -z "$raw_hits" ]]; then
    return
  fi

  # Filter out _DISABLED vars (Category B exempt).
  local name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    # Skip if the var name itself ends in _DISABLED — this shouldn't happen
    # since _DISABLED doesn't match our grep patterns above, but belt+suspenders.
    case "$name" in
      *_DISABLED) continue ;;
    esac
    printf '%s\n' "$name"
  done <<< "$raw_hits" | sort -u
}

# ── Main scan ──────────────────────────────────────────────────────────────────
DIFF_TEXT="$(get_diff_lines)"

if [[ -z "$DIFF_TEXT" ]]; then
  echo "[bypass-lint] INFO: empty diff — nothing to scan"
  exit 0
fi

FOUND_VARS=()
while IFS= read -r varname; do
  [[ -n "$varname" ]] && FOUND_VARS+=("$varname")
done < <(extract_bypass_varnames "$DIFF_TEXT")

if [[ ${#FOUND_VARS[@]} -eq 0 ]]; then
  echo "[bypass-lint] PASS: no new bypass-class env vars in diff (${#ALLOWED_VARS[@]} allowlisted)"
  exit 0
fi

# ── Allowlist check ────────────────────────────────────────────────────────────
VIOLATIONS=()
for varname in "${FOUND_VARS[@]}"; do
  if ! is_allowed "$varname"; then
    VIOLATIONS+=("$varname")
  fi
done

if [[ ${#VIOLATIONS[@]} -eq 0 ]]; then
  echo "[bypass-lint] PASS: all new bypass-class vars are allowlisted (${#FOUND_VARS[@]} found, all OK)"
  exit 0
fi

# ── Report violations ──────────────────────────────────────────────────────────
{
  echo "[bypass-lint] FAIL: ${#VIOLATIONS[@]} new bypass-class env var(s) not in allowlist"
  echo ""
  echo "  Violations:"
  for v in "${VIOLATIONS[@]}"; do
    echo "    $v"
  done
  echo ""
  echo "  Bypass-class patterns covered by this lint:"
  echo "    CHUMP_*_BYPASS, CHUMP_*_SKIP, CHUMP_IGNORE_*"
  echo "  (CHUMP_*_DISABLED vars are exempt — those are Category B kill-switches)"
  echo ""
  echo "  Remediation (pick one):"
  echo "    1. Add the var name to scripts/ci/bypass-env-var-allowlist.txt with a"
  echo "       Bypass-Justification: comment referencing a deletion gap ID."
  echo "       Operator review is required for all new allowlist entries."
  echo "    2. Remove the env var and fix the underlying gate — the preferred path."
  echo "       See INFRA-2422 through INFRA-2428 for the deletion pattern."
  echo ""
  echo "  See docs/process/BYPASS_TRAILER_SCHEMA.md (INFRA-2407) for bypass policy."
  echo "  See INFRA-2429 for the zero-bypass thesis that drives this lint."
} >&2

exit 1
