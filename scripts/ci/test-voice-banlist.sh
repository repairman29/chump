#!/usr/bin/env bash
# test-voice-banlist.sh — INFRA-1728
#
# CI gate: changed docs/ files must not introduce banned marketing words.
# Audience: tired senior engineers — hype erodes trust.
#
# What is checked:
#   • git diff against base branch, docs/ files only
#   • Case-insensitive, word-boundary grep (Python re for portability)
#   • Code fences (```) and inline backticks are exempt
#
# Bypass (per-PR, documented):
#   Commit body trailer: Voice-Lint-Bypass: <reason>
#   Emits kind=voice_lint_bypassed to ambient.jsonl
#
# Operator opt-out: CHUMP_VOICE_LINT_DISABLE=1 (emits bypass event + warns)
#
# Usage:
#   scripts/ci/test-voice-banlist.sh [--base <branch>] [--pr <number>]
#   CHUMP_VOICE_LINT_DISABLE=1 scripts/ci/test-voice-banlist.sh   # no-op

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

BASE_BRANCH="main"
PR_NUMBER=""
DRY_RUN="${CHUMP_VOICE_LINT_DRY_RUN:-0}"

for arg in "$@"; do
  case "$arg" in
    --base=*)   BASE_BRANCH="${arg#--base=}" ;;
    --base)     shift; BASE_BRANCH="$1" ;;
    --pr=*)     PR_NUMBER="${arg#--pr=}" ;;
    --pr)       shift; PR_NUMBER="$1" ;;
    --dry-run)  DRY_RUN=1 ;;
  esac
done

# ── Operator opt-out ──────────────────────────────────────────────────────────
if [[ "${CHUMP_VOICE_LINT_DISABLE:-0}" == "1" ]]; then
  echo "WARN: CHUMP_VOICE_LINT_DISABLE=1 — voice lint skipped (operator override)"
  mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
  printf '{"ts":"%s","kind":"voice_lint_bypassed","reason":"operator_override","pr":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${PR_NUMBER:-}" >> "$AMBIENT" 2>/dev/null || true
  exit 0
fi

# ── Ban-list ──────────────────────────────────────────────────────────────────
BANNED_WORDS=(
  "synergy"
  "revolutionary"
  "disruptive"
  "game-changing"
  "paradigm-shift"
  "seamless"
  "robust"
  "world-class"
  "best-in-class"
  "unleash"
  "supercharge"
  "next-generation"
)
# "leverage" only banned as a verb — heuristic: followed by whitespace/punct
# (e.g. "leverage our" but not "leverages the" or "leveraging — allowed in noun context)
# We keep it simple: ban "leverage" as a standalone word in docs prose.
BANNED_WORDS+=("leverage")

# ── Check for bypass trailer ──────────────────────────────────────────────────
_has_bypass() {
  # Check all commit messages in this PR range, or just HEAD.
  local base="${1:-origin/$BASE_BRANCH}"
  git -C "$REPO_ROOT" log "$base..HEAD" --format='%B' 2>/dev/null \
    | grep -qi "^Voice-Lint-Bypass:" || \
  git -C "$REPO_ROOT" log -1 --format='%B' 2>/dev/null \
    | grep -qi "^Voice-Lint-Bypass:"
}

_bypass_reason() {
  git -C "$REPO_ROOT" log -1 --format='%B' 2>/dev/null \
    | grep -i "^Voice-Lint-Bypass:" | head -1 | sed 's/Voice-Lint-Bypass: *//i'
}

# ── Get changed docs files ────────────────────────────────────────────────────
_changed_docs_files() {
  local base="${1:-origin/$BASE_BRANCH}"
  git -C "$REPO_ROOT" diff --name-only "$base..HEAD" 2>/dev/null \
    | grep '^docs/' \
    | grep -E '\.(md|txt|rst|adoc)$' \
    || true
}

# Fallback: compare against origin/main if the base ref doesn't resolve
BASE_REF="origin/$BASE_BRANCH"
if ! git -C "$REPO_ROOT" rev-parse "$BASE_REF" &>/dev/null; then
  BASE_REF="HEAD~1"
fi

changed_files=$(_changed_docs_files "$BASE_REF")

if [[ -z "$changed_files" ]]; then
  echo "PASS: no docs/ files changed — voice lint not applicable"
  exit 0
fi

# ── Capture violations ────────────────────────────────────────────────────────
violations=$(python3 -c "
import sys, re, os

repo_root = sys.argv[1]
banned_raw = sys.argv[2].split(',')
files = sys.argv[3].split('\n')

patterns = []
for w in banned_raw:
    w = w.strip()
    if not w:
        continue
    escaped = re.escape(w)
    patterns.append((w, re.compile(r'(?i)\b' + escaped + r'\b')))

def strip_code_spans(line):
    return re.sub(r'\`[^\`]*\`', '', line)

def is_in_code_fence(line, in_fence):
    stripped = line.strip()
    if stripped.startswith('\`\`\`') or stripped.startswith('~~~'):
        return not in_fence, True
    return in_fence, False

violations = []
for fpath in files:
    fpath = fpath.strip()
    if not fpath:
        continue
    full = os.path.join(repo_root, fpath)
    if not os.path.isfile(full):
        continue
    in_fence = False
    with open(full, encoding='utf-8', errors='replace') as fh:
        for lineno, raw_line in enumerate(fh, 1):
            line = raw_line.rstrip('\n')
            in_fence, is_marker = is_in_code_fence(line, in_fence)
            if in_fence or is_marker:
                continue
            check_line = strip_code_spans(line)
            for word, pat in patterns:
                if pat.search(check_line):
                    violations.append(f'{fpath}|{lineno}|{word}|{line.strip()[:100]}')

for v in violations:
    print(v)
" "$REPO_ROOT" "$(IFS=','; echo "${BANNED_WORDS[*]}")" "$changed_files" 2>/dev/null || true)

if [[ -z "$violations" ]]; then
  echo "PASS: no banned words found in changed docs/"
  exit 0
fi

# ── Violations found — check for bypass ──────────────────────────────────────
if _has_bypass "$BASE_REF"; then
  reason=$(_bypass_reason)
  echo "BYPASS: Voice-Lint-Bypass trailer found — skipping voice lint"
  echo "  Reason: $reason"
  if [[ "$DRY_RUN" != "1" ]]; then
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"voice_lint_bypassed","reason":"%s","pr":"%s"}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$(echo "$reason" | sed 's/"/\\"/g')" \
      "${PR_NUMBER:-}" >> "$AMBIENT" 2>/dev/null || true
  fi
  exit 0
fi

# ── Emit violation events and fail ───────────────────────────────────────────
fail_count=0
echo ""
echo "FAIL: banned marketing words found in docs/ changes"
echo ""
while IFS='|' read -r doc_path line_no word line_content; do
  [[ -z "$doc_path" ]] && continue
  echo "  [$word] $doc_path:$line_no"
  echo "    $line_content"
  echo ""
  fail_count=$((fail_count + 1))
  if [[ "$DRY_RUN" != "1" ]]; then
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"voice_lint_violation","pr":"%s","doc_path":"%s","word":"%s","line_no":%s}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "${PR_NUMBER:-}" \
      "$doc_path" \
      "$word" \
      "$line_no" >> "$AMBIENT" 2>/dev/null || true
  fi
done <<< "$violations"

echo "  Remediation:"
echo "    (A) Remove or rephrase the flagged text."
echo "    (B) If necessary, add to a commit body:"
echo "        Voice-Lint-Bypass: <one-sentence reason>"
echo "    (C) See docs/process/VOICE_GUARDRAIL.md for the full ban-list and rationale."
echo ""
echo "FAIL: $fail_count violation(s) — see remediation above"
exit 1
