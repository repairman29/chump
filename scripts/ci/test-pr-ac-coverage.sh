#!/usr/bin/env bash
# test-pr-ac-coverage.sh — INFRA-1541 (CREDIBLE)
#
# Pre-merge gate: verify the PR diff actually covers the acceptance criteria
# of the gap referenced in the PR title.
#
# Usage:
#   scripts/ci/test-pr-ac-coverage.sh <PR_NUMBER>
#
# Coverage rule (any of the four marks an AC bullet "covered"):
#   (a) literal file path mentioned in the bullet appears in the diff filelist
#   (b) symbol or CLI-flag mentioned in the bullet appears in the diff text
#   (c) commit body carries trailer `Closes-AC: <prefix>` matching the
#       bullet's first 40 chars
#   (d) a new test file under scripts/ci/test-*.sh or tests/ in the diff
#       references a keyword from the bullet
#
# Trailers:
#   AC-Coverage-Waive: <bullet-index>: <reason>
#     waives the bullet, emits kind=ac_coverage_waived to ambient.
#
# Modes:
#   CHUMP_AC_GATE_BLOCKING=true   — exit non-zero on uncovered AC bullets
#   (default advisory)             — exit 0 always; misses emit ambient events
#   CHUMP_AC_GATE_ENABLED=false   — short-circuit to exit 0; emits
#                                    kind=ac_coverage_disabled
#
# Exit codes (when blocking mode is on):
#   0  every AC bullet covered (or waived, or no gap-ref, or gate disabled)
#   1  one or more bullets uncovered; numbered miss-list printed
#   2  bad invocation
#
# In advisory mode the script always exits 0 after emitting misses to the
# ambient stream so the pr-hygiene job is not blocked.
#
# See docs/gaps/INFRA-1541.yaml for the full contract.

set -uo pipefail

PR_NUMBER="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true

BLOCKING="${CHUMP_AC_GATE_BLOCKING:-false}"
ENABLED="${CHUMP_AC_GATE_ENABLED:-true}"

note() { echo "[ac-coverage] $*"; }

# ─── ambient emit (no flock; sufficient for CI line-buffered writes) ─────────
emit() {
  local kind="$1"; shift
  local ts json
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  json="{\"ts\":\"$ts\",\"kind\":\"$kind\""
  while [[ $# -gt 0 ]]; do
    local kv="$1"; shift
    local k="${kv%%=*}" v="${kv#*=}"
    # escape backslashes and quotes for JSON
    v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
    json+=",\"$k\":\"$v\""
  done
  json+="}"
  echo "$json" >> "$AMBIENT_LOG"
}

if [[ -z "$PR_NUMBER" ]]; then
  note "usage: $0 <PR_NUMBER>"
  exit 2
fi

# ─── Operator override: gate disabled ────────────────────────────────────────
if [[ "$ENABLED" != "true" ]]; then
  emit ac_coverage_disabled pr_number="$PR_NUMBER" mode="${BLOCKING:-advisory}"
  note "gate disabled via CHUMP_AC_GATE_ENABLED=$ENABLED (pr=$PR_NUMBER)"
  exit 0
fi

# ─── Pull PR metadata (title, body, files, commits) ──────────────────────────
GH_BIN="${GH_BIN:-gh}"
if ! command -v "$GH_BIN" >/dev/null 2>&1; then
  note "gh not available; skipping (advisory)"
  exit 0
fi

PR_JSON="$("$GH_BIN" pr view "$PR_NUMBER" --json title,body,files,commits 2>/dev/null || true)"
if [[ -z "$PR_JSON" ]]; then
  note "could not fetch PR #$PR_NUMBER metadata; skipping"
  exit 0
fi

PR_TITLE="$(printf '%s' "$PR_JSON" | jq -r '.title // ""')"
PR_BODY="$(printf '%s' "$PR_JSON" | jq -r '.body // ""')"

# ─── Parse title for <DOMAIN>-<N> gap ref ────────────────────────────────────
GAP_ID=""
if [[ "$PR_TITLE" =~ ([A-Z][A-Z0-9]+)-([0-9]+) ]]; then
  GAP_ID="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
fi

if [[ -z "$GAP_ID" ]]; then
  emit ac_coverage_no_gap_ref pr_number="$PR_NUMBER" note="no_gap_ref"
  note "no_gap_ref: PR title has no <DOMAIN>-N reference; pass-through"
  exit 0
fi

# ─── Load AC bullets for the gap ─────────────────────────────────────────────
AC_LINES=()
GAP_AC_JSON=""
if command -v chump >/dev/null 2>&1; then
  GAP_AC_JSON="$(chump gap show "$GAP_ID" --json 2>/dev/null || true)"
fi

if [[ -n "$GAP_AC_JSON" ]] && echo "$GAP_AC_JSON" | jq -e '.acceptance_criteria' >/dev/null 2>&1; then
  # acceptance_criteria is a JSON-encoded string of an array; parse twice.
  AC_RAW="$(printf '%s' "$GAP_AC_JSON" | jq -r '.acceptance_criteria // ""')"
  if [[ -n "$AC_RAW" && "$AC_RAW" != "null" ]]; then
    # Try parsing as a JSON array; fall back to | split.
    if echo "$AC_RAW" | jq -e 'type == "array"' >/dev/null 2>&1; then
      while IFS= read -r line; do
        [[ -n "$line" ]] && AC_LINES+=("$line")
      done < <(printf '%s' "$AC_RAW" | jq -r '.[]')
    else
      IFS='|' read -ra AC_LINES <<< "$AC_RAW"
    fi
  fi
fi

# Fallback: read docs/gaps/<GAP_ID>.yaml directly
if [[ ${#AC_LINES[@]} -eq 0 && -f "$REPO_ROOT/docs/gaps/${GAP_ID}.yaml" ]]; then
  # crude YAML-array extractor: lines under "acceptance_criteria:" starting with "  - "
  in_ac=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^acceptance_criteria: ]]; then
      in_ac=1
      continue
    fi
    if [[ $in_ac -eq 1 ]]; then
      if [[ "$line" =~ ^[[:space:]]+-[[:space:]](.*) ]]; then
        bullet="${BASH_REMATCH[1]}"
        # strip surrounding quotes
        bullet="${bullet#\"}"; bullet="${bullet%\"}"
        bullet="${bullet#\'}"; bullet="${bullet%\'}"
        AC_LINES+=("$bullet")
      elif [[ "$line" =~ ^[^[:space:]] ]]; then
        in_ac=0
      fi
    fi
  done < "$REPO_ROOT/docs/gaps/${GAP_ID}.yaml"
fi

if [[ ${#AC_LINES[@]} -eq 0 ]]; then
  emit ac_coverage_no_ac pr_number="$PR_NUMBER" gap_id="$GAP_ID"
  note "gap $GAP_ID has no acceptance_criteria; pass-through"
  exit 0
fi

# ─── Build the diff context: file list + diff text ───────────────────────────
FILES_LIST="$(printf '%s' "$PR_JSON" | jq -r '.files[]?.path // empty' | tr '\n' ' ')"

# Get the unified diff text (best-effort; falls back to empty)
DIFF_TEXT=""
if "$GH_BIN" pr diff "$PR_NUMBER" >/tmp/.ac-coverage-diff.$$ 2>/dev/null; then
  DIFF_TEXT="$(cat /tmp/.ac-coverage-diff.$$)"
  rm -f /tmp/.ac-coverage-diff.$$
fi

# Commit messages
COMMIT_MSGS="$(printf '%s' "$PR_JSON" | jq -r '.commits[]?.messageHeadline + "\n" + (.commits[]?.messageBody // "")' 2>/dev/null || echo "")"
# Include the PR body so trailers added there also count
ALL_TRAILERS="$PR_BODY"$'\n'"$COMMIT_MSGS"

# ─── Parse waivers (bash-3 compatible: parallel arrays) ──────────────────────
WAIVED_IDX=()
WAIVED_REASON=()
while IFS= read -r line; do
  if [[ "$line" =~ ^AC-Coverage-Waive:[[:space:]]*([0-9]+):[[:space:]]*(.*)$ ]]; then
    WAIVED_IDX+=("${BASH_REMATCH[1]}")
    WAIVED_REASON+=("${BASH_REMATCH[2]}")
  fi
done <<< "$ALL_TRAILERS"

# Lookup helper for waived idx → reason ("" = not waived).
waiver_for() {
  local want="$1" j
  for j in "${!WAIVED_IDX[@]}"; do
    if [[ "${WAIVED_IDX[$j]}" == "$want" ]]; then
      echo "${WAIVED_REASON[$j]}"
      return 0
    fi
  done
  return 1
}

# ─── Parse Closes-AC trailers (prefix matchers) ──────────────────────────────
CLOSES_PREFIXES=()
while IFS= read -r line; do
  if [[ "$line" =~ ^Closes-AC:[[:space:]]*(.*)$ ]]; then
    CLOSES_PREFIXES+=("${BASH_REMATCH[1]}")
  fi
done <<< "$ALL_TRAILERS"

# ─── Helpers ─────────────────────────────────────────────────────────────────
# Extract file-path-like tokens from a bullet (anything matching <segment>/<segment>
# or with a known extension).
extract_paths() {
  local bullet="$1"
  echo "$bullet" | grep -oE '[A-Za-z0-9_./-]+/[A-Za-z0-9_./*-]+|[A-Za-z0-9_.-]+\.(sh|rs|py|js|ts|yaml|yml|md|txt|toml)' || true
}

# Extract CLI-flag/symbol-like tokens (--flag, kind=foo, kind=, identifiers with _)
extract_symbols() {
  local bullet="$1"
  {
    echo "$bullet" | grep -oE '\-\-[A-Za-z][A-Za-z0-9_-]+' || true
    echo "$bullet" | grep -oE 'kind=[A-Za-z][A-Za-z0-9_-]+' || true
    echo "$bullet" | grep -oE '[A-Z][A-Z0-9_]{3,}=[A-Za-z0-9_-]+' || true
    echo "$bullet" | grep -oE 'CHUMP_[A-Z0-9_]+' || true
  } | sort -u
}

# Extract candidate keywords (longest non-trivial words/identifiers)
extract_keywords() {
  local bullet="$1"
  echo "$bullet" | tr -c 'A-Za-z0-9_' '\n' | awk 'length($0) >= 6' | sort -u | head -8
}

# Check if a bullet is covered (a/b/c/d).
covered_by() {
  local bullet="$1"

  # (a) file paths in bullet appear in diff filelist
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if [[ "$FILES_LIST" == *"$path"* ]]; then
      echo "a:$path"; return 0
    fi
  done < <(extract_paths "$bullet")

  # (b) symbol or CLI-flag in bullet appears in diff
  while IFS= read -r sym; do
    [[ -z "$sym" ]] && continue
    if [[ "$DIFF_TEXT" == *"$sym"* ]] || [[ "$FILES_LIST" == *"$sym"* ]]; then
      echo "b:$sym"; return 0
    fi
  done < <(extract_symbols "$bullet")

  # (c) Closes-AC trailer matching first 40 chars
  local prefix40="${bullet:0:40}"
  for ct in "${CLOSES_PREFIXES[@]:-}"; do
    [[ -z "$ct" ]] && continue
    if [[ "$ct" == "$prefix40"* ]] || [[ "${prefix40}" == "${ct:0:40}"* ]] || [[ "$bullet" == *"$ct"* ]]; then
      echo "c:Closes-AC"; return 0
    fi
  done

  # (d) new test file under scripts/ci/test-*.sh or tests/ in diff that
  #     references a keyword from the bullet
  local test_files
  test_files="$(echo "$FILES_LIST" | tr ' ' '\n' | grep -E '^(scripts/ci/test-.*\.sh|tests/)' || true)"
  if [[ -n "$test_files" ]]; then
    while IFS= read -r kw; do
      [[ -z "$kw" ]] && continue
      while IFS= read -r tf; do
        [[ -z "$tf" || ! -f "$REPO_ROOT/$tf" ]] && continue
        if grep -qi -- "$kw" "$REPO_ROOT/$tf" 2>/dev/null; then
          echo "d:$tf"; return 0
        fi
      done <<< "$test_files"
    done < <(extract_keywords "$bullet")
  fi

  return 1
}

# ─── Evaluate each AC bullet ─────────────────────────────────────────────────
MISSES=()
COVERED=0
for i in "${!AC_LINES[@]}"; do
  bullet="${AC_LINES[$i]}"
  [[ -z "$bullet" ]] && continue
  idx=$((i + 1))

  # waiver?
  if reason="$(waiver_for "$idx")"; then
    emit ac_coverage_waived pr_number="$PR_NUMBER" gap_id="$GAP_ID" \
      bullet_index="$idx" reason="$reason"
    note "  [$idx] WAIVED: $reason"
    continue
  fi

  if rationale="$(covered_by "$bullet")"; then
    COVERED=$((COVERED + 1))
    note "  [$idx] covered ($rationale)"
  else
    prefix80="${bullet:0:80}"
    MISSES+=("$idx: $prefix80")
    emit ac_coverage_miss pr_number="$PR_NUMBER" gap_id="$GAP_ID" \
      bullet_index="$idx" bullet_text_prefix="$prefix80"
    note "  [$idx] MISS: $prefix80"
  fi
done

# ─── Report ──────────────────────────────────────────────────────────────────
TOTAL="${#AC_LINES[@]}"
echo "[ac-coverage] gap=$GAP_ID pr=$PR_NUMBER covered=$COVERED/$TOTAL misses=${#MISSES[@]}"

if [[ ${#MISSES[@]} -gt 0 ]]; then
  echo "[ac-coverage] uncovered AC bullets:"
  for m in "${MISSES[@]}"; do
    echo "  - $m"
  done
fi

if [[ "$BLOCKING" == "true" && ${#MISSES[@]} -gt 0 ]]; then
  echo "[ac-coverage] BLOCKING mode: failing pr-hygiene"
  exit 1
fi

# advisory mode: always exit 0
exit 0
