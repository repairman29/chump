#!/usr/bin/env bash
# scripts/coord/pattern-fix-dispatcher.sh — INFRA-2355 (META-269 sub-6)
#
# Matches a CI-failure log against scripts/coord/known-failure-patterns.yaml
# (failure-regex -> fix-script). On the first match, runs the fix-script
# directly (no Sonnet hop), then commits any working-tree changes it made,
# pushes a branch, and opens a PR.
#
# Usage:
#   bash scripts/coord/pattern-fix-dispatcher.sh <ci-log-path|->
#
#   <ci-log-path>  path to a text file containing the CI failure output.
#                  Use "-" to read from stdin.
#
# Exit codes:
#   0 — pattern matched, fix-script ran, PR opened (or dry-run "would open")
#   1 — usage error
#   2 — fix-script ran but exited non-zero
#   3 — no known pattern matched the log
#   4 — fix-script succeeded but left no working-tree changes (nothing to ship)
#
# Env overrides:
#   CHUMP_PATTERN_FIX_PATTERNS_FILE   path to known-failure-patterns.yaml
#                                     (default scripts/coord/known-failure-patterns.yaml)
#   CHUMP_PATTERN_FIX_AMBIENT_FILE    override ambient.jsonl path (used in tests)
#   CHUMP_PATTERN_FIX_DRY_RUN         "1" -> run the fix-script but skip
#                                     git commit/push/PR (used in tests + when
#                                     gh/git remote isn't available)
#   CHUMP_PATTERN_FIX_BASE_BRANCH     PR base branch (default: main)
#
# Emits:
#   kind=pattern_fix_matched     a pattern's regex matched the log
#   kind=pattern_fix_applied     fix-script ran successfully and changed the tree
#   kind=pattern_fix_pr_opened   branch pushed + PR opened
#   kind=pattern_fix_dry_run     dry-run mode: matched + fixed, PR skipped
#   kind=pattern_fix_no_match    no pattern in the registry matched the log
#   kind=pattern_fix_failed      fix-script exited non-zero
#
# scanner-anchor: "kind":"pattern_fix_matched"
# scanner-anchor: "kind":"pattern_fix_applied"
# scanner-anchor: "kind":"pattern_fix_pr_opened"
# scanner-anchor: "kind":"pattern_fix_dry_run"
# scanner-anchor: "kind":"pattern_fix_no_match"
# scanner-anchor: "kind":"pattern_fix_failed"

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

PATTERNS_FILE="${CHUMP_PATTERN_FIX_PATTERNS_FILE:-$REPO_ROOT/scripts/coord/known-failure-patterns.yaml}"
AMBIENT="${CHUMP_PATTERN_FIX_AMBIENT_FILE:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
DRY_RUN="${CHUMP_PATTERN_FIX_DRY_RUN:-0}"
BASE_BRANCH="${CHUMP_PATTERN_FIX_BASE_BRANCH:-main}"

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log() { printf '[pattern-fix-dispatcher %s] %s\n' "$TS" "$*" >&2; }

emit_ambient() {
  local kind="$1" extra="${2:-}"
  local line
  mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
  if [[ -n "$extra" ]]; then
    line=$(printf '{"ts":"%s","kind":"%s",%s}' "$TS" "$kind" "$extra")
  else
    line=$(printf '{"ts":"%s","kind":"%s"}' "$TS" "$kind")
  fi
  echo "$line" >> "$AMBIENT"
}

LOG_PATH="${1:-}"
if [[ -z "$LOG_PATH" ]]; then
  echo "usage: pattern-fix-dispatcher.sh <ci-log-path|->" >&2
  exit 1
fi

if [[ "$LOG_PATH" == "-" ]]; then
  LOG_CONTENT="$(cat)"
else
  if [[ ! -f "$LOG_PATH" ]]; then
    echo "pattern-fix-dispatcher: log file not found: $LOG_PATH" >&2
    exit 1
  fi
  LOG_CONTENT="$(cat "$LOG_PATH")"
fi

if [[ ! -f "$PATTERNS_FILE" ]]; then
  echo "pattern-fix-dispatcher: patterns file not found: $PATTERNS_FILE" >&2
  exit 1
fi

# ── Minimal YAML parser for known-failure-patterns.yaml ─────────────────────
# Format is fixed (see file header): a top-level `patterns:` list of
# name / description / match_regex / fix_script records, 2-space indented.
# Emits one record per pattern: name<TAB>match_regex<TAB>fix_script
parse_patterns() {
  local cur_name="" cur_regex="" cur_fix=""
  local have_record=0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in
      "  - name: "*)
        if [[ "$have_record" -eq 1 ]]; then
          printf '%s\t%s\t%s\n' "$cur_name" "$cur_regex" "$cur_fix"
        fi
        cur_name="${line#"  - name: "}"
        cur_regex=""
        cur_fix=""
        have_record=1
        ;;
      "    match_regex: "*)
        cur_regex="${line#"    match_regex: "}"
        cur_regex="${cur_regex#\"}"
        cur_regex="${cur_regex%\"}"
        ;;
      "    fix_script: "*)
        cur_fix="${line#"    fix_script: "}"
        cur_fix="${cur_fix#\"}"
        cur_fix="${cur_fix%\"}"
        ;;
    esac
  done < "$PATTERNS_FILE"
  if [[ "$have_record" -eq 1 ]]; then
    printf '%s\t%s\t%s\n' "$cur_name" "$cur_regex" "$cur_fix"
  fi
}

matched_name=""
matched_regex=""
matched_fix=""
matched_line=""
matched_capture=""

while IFS=$'\t' read -r p_name p_regex p_fix; do
  [[ -z "$p_name" ]] && continue
  while IFS= read -r log_line; do
    if [[ "$log_line" =~ $p_regex ]]; then
      matched_name="$p_name"
      matched_regex="$p_regex"
      matched_fix="$p_fix"
      matched_line="$log_line"
      matched_capture="${BASH_REMATCH[1]:-}"
      break 2
    fi
  done <<< "$LOG_CONTENT"
done < <(parse_patterns)

if [[ -z "$matched_name" ]]; then
  log "no known pattern matched the supplied log"
  emit_ambient "pattern_fix_no_match" "\"patterns_file\":\"${PATTERNS_FILE#"$REPO_ROOT"/}\""
  exit 3
fi

log "matched pattern=$matched_name fix_script=$matched_fix"
emit_ambient "pattern_fix_matched" "\"pattern\":\"$matched_name\",\"fix_script\":\"$matched_fix\""

FIX_SCRIPT_PATH="$matched_fix"
if [[ "$FIX_SCRIPT_PATH" != /* ]]; then
  FIX_SCRIPT_PATH="$REPO_ROOT/$FIX_SCRIPT_PATH"
fi
if [[ ! -x "$FIX_SCRIPT_PATH" ]]; then
  log "ERROR: fix-script not found or not executable: $FIX_SCRIPT_PATH"
  emit_ambient "pattern_fix_failed" "\"pattern\":\"$matched_name\",\"reason\":\"fix_script_missing\""
  exit 2
fi

# ── Run the fix-script ───────────────────────────────────────────────────────
fix_rc=0
if [[ -n "$matched_capture" ]]; then
  "$FIX_SCRIPT_PATH" "$matched_capture" || fix_rc=$?
else
  "$FIX_SCRIPT_PATH" || fix_rc=$?
fi

if [[ "$fix_rc" -ne 0 ]]; then
  log "fix-script $matched_fix exited $fix_rc"
  emit_ambient "pattern_fix_failed" "\"pattern\":\"$matched_name\",\"fix_script\":\"$matched_fix\",\"exit_code\":$fix_rc"
  exit 2
fi

if git diff --quiet && git diff --cached --quiet; then
  log "fix-script ran clean but left no working-tree changes"
  emit_ambient "pattern_fix_failed" "\"pattern\":\"$matched_name\",\"reason\":\"no_changes\""
  exit 4
fi

emit_ambient "pattern_fix_applied" "\"pattern\":\"$matched_name\",\"fix_script\":\"$matched_fix\""
log "fix-script applied changes for pattern=$matched_name"

if [[ "$DRY_RUN" == "1" ]]; then
  log "DRY_RUN=1; skipping commit/push/PR"
  emit_ambient "pattern_fix_dry_run" "\"pattern\":\"$matched_name\""
  exit 0
fi

# ── Commit, push, open PR ────────────────────────────────────────────────────
BRANCH="chump/pattern-fix-${matched_name}-$(date -u +%Y%m%d%H%M%S)"
git checkout -b "$BRANCH"
git add -A
git commit -m "pattern-fix: auto-repair ${matched_name} (INFRA-2355 pattern-fix-dispatcher)"

if ! git push -u origin "$BRANCH"; then
  log "ERROR: git push failed for $BRANCH"
  emit_ambient "pattern_fix_failed" "\"pattern\":\"$matched_name\",\"reason\":\"push_failed\""
  exit 2
fi

pr_url="$(gh pr create --base "$BASE_BRANCH" \
  --title "pattern-fix: auto-repair ${matched_name}" \
  --body "Auto-repaired by scripts/coord/pattern-fix-dispatcher.sh — matched known-failure-pattern \`${matched_name}\` and ran \`${matched_fix}\`. Matched line: \`${matched_line}\`" \
  2>&1)"
pr_rc=$?
if [[ "$pr_rc" -ne 0 ]]; then
  log "ERROR: gh pr create failed: $pr_url"
  emit_ambient "pattern_fix_failed" "\"pattern\":\"$matched_name\",\"reason\":\"pr_create_failed\""
  exit 2
fi

log "PR opened: $pr_url"
emit_ambient "pattern_fix_pr_opened" "\"pattern\":\"$matched_name\",\"branch\":\"$BRANCH\",\"pr_url\":\"$pr_url\""
exit 0
