#!/usr/bin/env bash
# test-voice-banlist.sh — INFRA-1728
#
# CI gate: changed docs/ files must not introduce banned marketing words.
# Audience: tired senior engineers — hype erodes trust.
#
# What is checked:
#   • git diff against base branch, docs/ files only, ADDED lines only
#   • Pre-existing banned words in unchanged lines are NOT flagged (INFRA-2050)
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
    | grep -v '^docs/process/VOICE_GUARDRAIL\.md$' \
    || true
  # VOICE_GUARDRAIL.md is excluded: it is the definitional document that lists
  # banned words as examples. Scanning it would be self-defeating.
}

# Build BASE_REF: if BASE_BRANCH already contains a slash (e.g. "origin/main")
# use it directly; otherwise prefix with "origin/" so "main" → "origin/main".
# This prevents the double-prefix bug when CI passes --base=origin/main.
[[ "$BASE_BRANCH" == */* ]] && BASE_REF="$BASE_BRANCH" || BASE_REF="origin/$BASE_BRANCH"
if ! git -C "$REPO_ROOT" rev-parse "$BASE_REF" &>/dev/null; then
  BASE_REF="HEAD~1"
fi

changed_files=$(_changed_docs_files "$BASE_REF")

if [[ -z "$changed_files" ]]; then
  echo "PASS: no docs/ files changed — voice lint not applicable"
  exit 0
fi

# ── Capture violations (diff-hunk-only, INFRA-2050) ──────────────────────────
# Only lines ADDED in this PR are scanned. Pre-existing content in changed files
# is not flagged — only lines the author actually introduced (lines beginning
# with '+' in the unified diff, excluding the '+++' file header).
violations=$(git -C "$REPO_ROOT" diff --unified=0 --no-color "${BASE_REF}...HEAD" \
    -- $(echo "$changed_files" | tr '\n' ' ') 2>/dev/null \
  | python3 -c "
import sys, re

banned_raw = sys.argv[1].split(',')

patterns = []
for w in banned_raw:
    w = w.strip()
    if not w:
        continue
    escaped = re.escape(w)
    patterns.append((w, re.compile(r'(?i)\b' + escaped + r'\b')))

def strip_code_spans(line):
    return re.sub(r'\`[^\`]*\`', '', line)

# Parse unified diff: track current file, hunk line numbers, fence state.
# Hunk header: @@ -old_start,old_count +new_start,new_count @@ [context]
HUNK_RE = re.compile(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@')
FILE_RE = re.compile(r'^\+\+\+ b/(.+)')

violations = []
current_file = None
current_lineno = 0
in_fence = False

for raw_line in sys.stdin:
    line = raw_line.rstrip('\n')

    # File header
    m = FILE_RE.match(line)
    if m:
        current_file = m.group(1)
        in_fence = False
        current_lineno = 0
        continue

    # Hunk header — reset line counter
    m = HUNK_RE.match(line)
    if m:
        current_lineno = int(m.group(1)) - 1  # will be incremented on first '+'
        continue

    # Added line
    if line.startswith('+') and not line.startswith('+++'):
        current_lineno += 1
        content = line[1:]  # strip leading '+'

        # Track code fences in added hunks
        stripped = content.strip()
        if stripped.startswith('\`\`\`') or stripped.startswith('~~~'):
            in_fence = not in_fence
            continue
        if in_fence:
            continue

        check_line = strip_code_spans(content)
        for word, pat in patterns:
            if pat.search(check_line):
                violations.append(f'{current_file}|{current_lineno}|{word}|{content.strip()[:100]}')
        continue

    # Context / removed lines do not advance new-file line counter
    # (removed lines '-' don't exist in new file; context lines tracked separately
    #  but we don't need their numbers since we only scan added lines)

for v in violations:
    print(v)
" "$(IFS=','; echo "${BANNED_WORDS[*]}")" 2>/dev/null || true)

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
