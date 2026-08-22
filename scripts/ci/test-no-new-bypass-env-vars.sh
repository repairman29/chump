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

# ── EFFECTIVE-094: bypass-var DEBT-CEILING (the addition tax) ────────────────────
# The allowlist logic below permits growth-with-paperwork — which is exactly how
# the count climbed 113 → 233. This is the hard ceiling: the TOTAL distinct
# bypass/skip/check CHUMP_* var count must not EXCEED scripts/ci/bypass-var-ceiling.txt.
# To add a var you must delete one (net-negative). The only way UP is the operator
# editing the ceiling file with a reason. A cull (count < ceiling) prints a nudge to
# ratchet the ceiling down, so the floor only ever falls. Skipped in --self-test.
# DELIBERATELY no env bypass: an anti-bypass gate must not ship its own bypass var
# (that would both defeat the purpose AND add to the count). The ONLY way up is the
# operator editing the ceiling file — a visible, reviewed, single source of truth.
# ── RESILIENT-298: functional read-site detector (shared by the debt-ceiling
# counter above and its self-test below). Returns 0 (true) iff the given bypass
# var name is READ somewhere under the given roots — shell $VAR/${VAR}, an inline
# `VAR=... cmd` assignment, or an env accessor (Rust env::var / this repo's
# env_trim_eq|env_flags|env_bool helpers, C getenv, Python os.environ|os.getenv,
# JS process.env, Deno.env). A name that appears ONLY as a bare string mention
# (doc/registry/comment/absence-assertion/concat-fragment) has no read-site and is
# NOT a functional bypass. Generous by design: err toward COUNTING so a real var is
# never dropped; only provable phantoms fall out.
_bypass_var_has_readsite() {
  local _v="$1"; shift
  local _tmpl='(\$\{?VAR\b|env::var(_os)?\([[:space:]]*"?VAR|env_trim_eq\([[:space:]]*"?VAR|env_flags::[a-z_]+\([[:space:]]*"?VAR|env_bool\([[:space:]]*"?VAR|getenv\([[:space:]]*"?VAR|os\.getenv\([[:space:]]*"?VAR|os\.environ[^)]*VAR|process\.env[.\[][[:space:]]*"?VAR|Deno\.env[^)]*VAR|(^|[^A-Za-z0-9_])VAR=)'
  local _rx="${_tmpl//VAR/$_v}"
  grep -rqE "$_rx" "$@" 2>/dev/null
}

if [[ "${1:-}" != "--self-test" ]]; then
  _ceiling_file="$REPO_ROOT/scripts/ci/bypass-var-ceiling.txt"
  _ceiling="$(grep -oE '^[0-9]+' "$_ceiling_file" 2>/dev/null | head -1 || true)"
  _ceiling="${_ceiling:-99999}"
  # Counter correctness (RESILIENT-297). The scan matched var-name STRINGS in any
  # file under scripts/src/crates — including prose that merely NAMES a var rather
  # than using it. Three classes were inflating the count as a result:
  #   1. --exclude this linter's own file. Its --self-test cases below embed
  #      synthetic props (CHUMP_BRAND_NEW_BYPASS, CHUMP_XYZ_SKIP, ...) to exercise
  #      the diff-scanner — test doubles, never real toggles.
  #   2. --exclude the ceiling file itself. bypass-var-ceiling.txt is this gate's
  #      DOCUMENTATION: its changelog names every var it signs off on. Scanning it
  #      double-counts each documented var (once at its real use-site, once in the
  #      prose) and, worse, counts vars that live ONLY in the changelog — so the
  #      act of DOCUMENTING a sign-off raised the very count it documents. The
  #      linter's own bookkeeping files must not be part of its input.
  #   3. Drop command-VALUED vars (…_CMD). CHUMP_DUTY_OFFICER_REALITY_CHECK_CMD
  #      names a command to RUN — not a check-disabling toggle; the greedy _CHECK
  #      branch matched it as a false positive.
  # This is a ratchet-DOWN of the honest baseline, not a bypass: the true count of
  # real bypass USE-SITES falls, and the ceiling file falls with it.
  # RESILIENT-298: count only bypass vars that have a FUNCTIONAL READ-SITE. The bare
  # string-mention scan over-counted PHANTOMS — names that appear ONLY in documentation,
  # registry lines (env-vars-internal.txt), absence-assertion guards (a test grepping
  # that a DELETED var is *not* present), string-concat fragments of removed names,
  # include-guard sentinels (_CHUMP_*_LOADED), or out-of-scope toggles read in web/
  # (localStorage) or .github/ (Actions repo-vars). So the act of DOCUMENTING or
  # GUARDING a var inflated the very count it documents. A real bypass var must be READ
  # to function, so requiring a read-site cannot hide a genuine bypass (the per-PR
  # diff-scanner below still blocks any NEW unallowlisted var at add-time) — it only
  # stops counting phantoms. Honest instrument: the ceiling measures real read-backed
  # bypass debt, not string mentions. Before/after on main: 221 (mentions) -> 211 (read-backed, excl. linter meta-files).
  _cands="$(grep -rhoE 'CHUMP_[A-Z0-9_]*(BYPASS|SKIP|IGNORE|_CHECK|NO_)[A-Z0-9_]*' \
            "$REPO_ROOT/scripts" "$REPO_ROOT/src" "$REPO_ROOT/crates" 2>/dev/null \
            --exclude='test-no-new-bypass-env-vars.sh' \
            --exclude='bypass-var-ceiling.txt' \
            | grep -vE '_CMD$' | sort -u)"
  # Speed: build a one-pass haystack of every line that mentions a candidate token,
  # then read-site-test each candidate against that small in-memory file (grep -rq on a
  # single file). Identical detection to scanning the tree per-var, ~1s instead of ~12s.
  _hayfile="$(mktemp)"
  grep -rhE 'CHUMP_[A-Z0-9_]*(BYPASS|SKIP|IGNORE|_CHECK|NO_)' \
    "$REPO_ROOT/scripts" "$REPO_ROOT/src" "$REPO_ROOT/crates" 2>/dev/null \
    --exclude='test-no-new-bypass-env-vars.sh' \
    --exclude='bypass-var-ceiling.txt' > "$_hayfile" || true
  _now=0
  while IFS= read -r _v; do
    [ -z "$_v" ] && continue
    if _bypass_var_has_readsite "$_v" "$_hayfile"; then
      _now=$((_now + 1))
    fi
  done <<< "$_cands"
  rm -f "$_hayfile"
  if [ "${_now:-0}" -gt "$_ceiling" ]; then
    {
      echo "[bypass-lint] FAIL (EFFECTIVE-094 debt-ceiling): bypass/skip/check var count ${_now} > ceiling ${_ceiling}."
      echo "  To ADD a bypass var you must DELETE one — the count must ratchet DOWN, not up."
      echo "  The only way to RAISE the ceiling is an operator editing scripts/ci/bypass-var-ceiling.txt with a reason."
      echo "  This is the thing that reverses the 113 → 233 climb. See EFFECTIVE-089."
    } >&2
    exit 1
  fi
  if [ "${_now:-0}" -lt "$_ceiling" ]; then
    echo "[bypass-lint] debt-ceiling OK: ${_now} < ceiling ${_ceiling} — culled $((_ceiling - _now)). Ratchet it down: echo ${_now} > scripts/ci/bypass-var-ceiling.txt" >&2
  fi
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
    # Use a minimal allowlist for self-tests. CHUMP_PREFLIGHT_SKIP is deleted
    # (INFRA-2422) so we use CHUMP_AUDIT_BYPASS as the allowlist-hit test case.
    printf '%s\n' \
      '# self-test allowlist' \
      'CHUMP_AUDIT_BYPASS  # grandfathered; deletion gap TBD' \
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
  # (CHUMP_PREFLIGHT_SKIP deleted per INFRA-2422; using CHUMP_AUDIT_BYPASS as allowlist-hit test)
  run_case "new CHUMP_AUDIT_BYPASS in allowlist" \
    '+CHUMP_AUDIT_BYPASS=1' \
    0

  # Case 3: *_DISABLED var (Category B kill-switch) → exit 0 (exempt)
  run_case "CHUMP_FLEET_DOCTOR_DISABLED is Category B, exempt" \
    '+CHUMP_FLEET_DOCTOR_DISABLED=1' \
    0

  # Case 4: Diff with no bypass vars → exit 0
  run_case "clean diff with no bypass vars" \
    '+CHUMP_LOG_LEVEL=debug' \
    0

  # ── INFRA-2438: comment-context cases ────────────────────────────────────
  # These cases exercise the comment-only-line filter added by INFRA-2438
  # (this script was over-matching: any + line mentioning the var name was
  # flagged, including PRs whose entire purpose was DOCUMENTING the deletion).
  # The lint must distinguish actual env::var() / shell-dereference / bare-
  # env-vars-internal-line introductions from comments mentioning the var.

  # Case 5: + line in a shell comment → NOT flagged (exit 0)
  run_case "shell comment mentioning bypass var name → exit 0" \
    '+# CHUMP_OBS_BUDGET_BYPASS is deleted (INFRA-2425) — guard is warn-only.' \
    0

  # Case 6: + line in a Rust comment → NOT flagged (exit 0)
  run_case "Rust // comment mentioning bypass var name → exit 0" \
    '+// CHUMP_CLAIM_IGNORE_MAIN_HEALTH is removed (INFRA-2428).' \
    0

  # Case 7: + line as block-comment body → NOT flagged (exit 0)
  run_case "block-comment body line mentioning bypass var → exit 0" \
    '+ * CHUMP_PREFLIGHT_SKIP_PIPEFAIL removed per INFRA-2427.' \
    0

  # Case 8: + line as actual shell dereference → IS flagged (exit 1, unless allowlisted)
  run_case "actual shell dereference of bypass var → exit 1" \
    '+    if [[ -n "${CHUMP_BRAND_NEW_BYPASS:-}" ]]; then' \
    1

  # ── RESILIENT-298: read-site counter cases. Prove the debt-ceiling counter counts
  # a var ONLY when it has a functional read-site, so phantom mentions never inflate it.
  _rs_root="$(mktemp -d)"
  # A real read: shell dereference.
  printf '%s\n' 'if [ "${CHUMP_RS_REAL_SKIP:-0}" = "1" ]; then :; fi' > "$_rs_root/real.sh"
  # A phantom: bare name in a registry-style doc + an absence-assertion grep — no read.
  printf '%s\n' 'CHUMP_RS_PHANTOM_SKIP' > "$_rs_root/registry.txt"
  printf '%s\n' 'grep -q "CHUMP_RS_PHANTOM_SKIP" "$f" && fail "must be absent"' > "$_rs_root/guard.sh"
  if _bypass_var_has_readsite "CHUMP_RS_REAL_SKIP" "$_rs_root"; then
    echo "  PASS: read-backed var is counted (has read-site)"; PASS=$((PASS + 1))
  else
    echo "  FAIL: read-backed var CHUMP_RS_REAL_SKIP was not detected"; FAIL=$((FAIL + 1))
  fi
  if _bypass_var_has_readsite "CHUMP_RS_PHANTOM_SKIP" "$_rs_root"; then
    echo "  FAIL: phantom var CHUMP_RS_PHANTOM_SKIP counted despite no read-site"; FAIL=$((FAIL + 1))
  else
    echo "  PASS: phantom (mention-only) var is NOT counted"; PASS=$((PASS + 1))
  fi
  # The env_trim_eq helper form (this repo's Rust accessor) must count as a read.
  printf '%s\n' 'crate::env_flags::env_trim_eq("CHUMP_RS_HELPER_SKIP", "1")' > "$_rs_root/helper.rs"
  if _bypass_var_has_readsite "CHUMP_RS_HELPER_SKIP" "$_rs_root"; then
    echo "  PASS: env_trim_eq read-site is counted"; PASS=$((PASS + 1))
  else
    echo "  FAIL: env_trim_eq read-site not detected (would undercount live vars)"; FAIL=$((FAIL + 1))
  fi
  rm -rf "$_rs_root"

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

  # Strip diff hunks that belong to this lint script or the allowlist file —
  # these legitimately contain bypass var names for documentation/self-test
  # purposes and should not be flagged. The diff format uses
  # "diff --git a/path b/path" headers; we blank out lines between matching
  # headers and the next "diff --git" header.
  # Strategy: pipe through awk to suppress lines from exempt files.
  local filtered_file
  filtered_file="$(mktemp)"
  awk '
    /^diff --git / {
      # Exempt files that legitimately contain bypass var names:
      #   - this lint script itself (self-test case strings)
      #   - the allowlist file (grandfathered var documentation)
      #   - env-vars-internal.txt (var documentation registry, not code)
      suppress = ($0 ~ /scripts\/ci\/test-no-new-bypass-env-vars\.sh/ ||
                  $0 ~ /scripts\/ci\/bypass-env-var-allowlist\.txt/ ||
                  $0 ~ /scripts\/ci\/env-vars-internal\.txt/)
    }
    !suppress { print }
  ' "$tmpfile" > "$filtered_file"
  rm -f "$tmpfile"

  # Only look at added lines (+ prefix, not ++ which is the diff header).
  # Use grep -E; avoid pipe-to-grep-q (INFRA-1658).
  local added_lines
  added_lines="$(grep -E '^\+[^+]' "$filtered_file" 2>/dev/null)" || added_lines=""
  rm -f "$filtered_file"

  local added_file
  added_file="$(mktemp)"
  printf '%s\n' "$added_lines" > "$added_file"

  # INFRA-2438: filter out comment-only lines before pattern-matching. A `+`
  # diff line whose body (after stripping leading whitespace) begins with `#`
  # (shell/yaml/toml), `//` (Rust/JS), `*` (block-comment body), or `>` (md
  # quote) is documentation/explanation of a deletion — NOT an introduction.
  # Without this filter, deletion-PRs that document what they removed (e.g.
  # "# CHUMP_X_BYPASS is deleted") self-flag and the lint blocks the very
  # change it's meant to encourage.
  local code_only_file
  code_only_file="$(mktemp)"
  awk '
    {
      # Strip the leading "+" prefix.
      line = substr($0, 2)
      # Trim leading whitespace.
      stripped = line
      sub(/^[ \t]+/, "", stripped)
      # Skip comment-only lines.
      if (stripped ~ /^#/)  next
      if (stripped ~ /^\/\//) next
      if (stripped ~ /^\*/) next
      if (stripped ~ /^>/) next
      # Keep the original "+"-prefixed line.
      print $0
    }
  ' "$added_file" > "$code_only_file"
  rm -f "$added_file"

  # Extract var names matching the bypass patterns.
  # Strategy: grep for the CHUMP_*_BYPASS|SKIP|IGNORE_* substrings using -o.
  # CHUMP_IGNORE_ requires at least one trailing [A-Z0-9] to avoid matching
  # bare pattern-description text like "CHUMP_IGNORE_*" in comments.
  # Then filter out _DISABLED (Category B exempt).
  local raw_hits
  raw_hits="$(grep -oE 'CHUMP_[A-Z0-9_]*(BYPASS|SKIP)|CHUMP_IGNORE_[A-Z0-9][A-Z0-9_]*' \
    "$code_only_file" 2>/dev/null || true)"
  rm -f "$code_only_file"

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
