#!/usr/bin/env bash
# test-phantom-gap-refs.sh — RESEARCH-001
#
# CI gate: every gap ID cited in docs/process/RESEARCH_INTEGRITY.md must
# resolve to a real file in docs/gaps/ OR appear in the historical allowlist.
#
# Motivation: RESEARCH_INTEGRITY.md §4 cited EVAL-094 and RESEARCH-026 for
# months while neither YAML existed, making the eval-awareness mandate
# un-enforceable. This gate prevents future phantom-ID drift.
#
# Allowlist: scripts/ci/research-integrity-phantom-allowlist.txt
#   Lists IDs that predate the public registry (in chump-proprietary).
#   Do NOT add new IDs there to paper over a missing gap — create the YAML.
#
# Bypass (per-commit, documented):
#   Commit body trailer: Phantom-Ref-Bypass: <reason>
#   Valid reason: gap exists in chump-proprietary (private companion repo)
#
# Usage:
#   scripts/ci/test-phantom-gap-refs.sh            # normal run
#   REPO_ROOT=/path scripts/ci/test-phantom-gap-refs.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
GAPS_DIR="$REPO_ROOT/docs/gaps"
ALLOWLIST="$SCRIPT_DIR/research-integrity-phantom-allowlist.txt"

# Primary scan target: RESEARCH_INTEGRITY.md only.
# Preregistration docs have broader historical references (many in
# chump-proprietary) — extending coverage there is a separate gap.
SCAN_FILE="docs/process/RESEARCH_INTEGRITY.md"
FULL_PATH="$REPO_ROOT/$SCAN_FILE"

if [[ ! -f "$FULL_PATH" ]]; then
  echo "SKIP: $SCAN_FILE not found"
  exit 0
fi

# ── Load allowlist (bash 3.2-compatible, no associative arrays) ──────────────
# Stripped copy of the allowlist (comments + blank lines removed) for grep -Fx
_allowlist_stripped=""
if [[ -f "$ALLOWLIST" ]]; then
  _allowlist_stripped=$(grep -v '^#' "$ALLOWLIST" | grep -v '^[[:space:]]*$' || true)
fi
_in_allowlist() { echo "$_allowlist_stripped" | grep -qFx "$1" 2>/dev/null; }

# ── Check for bypass trailer ──────────────────────────────────────────────────
_has_bypass() {
  git -C "$REPO_ROOT" log -1 --format='%B' 2>/dev/null \
    | grep -qi "^Phantom-Ref-Bypass:"
}

# ── Extract gap IDs, stripping code fences and backticks ─────────────────────
gap_ids=$(python3 -c "
import re, sys

with open('$FULL_PATH', encoding='utf-8', errors='replace') as f:
    content = f.read()

content = re.sub(r'\`\`\`.*?\`\`\`', '', content, flags=re.DOTALL)
content = re.sub(r'\`[^\`]+\`', '', content)

domains = r'(?:EVAL|RESEARCH|INFRA|META|FLEET|COG|CREDIBLE|EFFECTIVE|RESILIENT|ZERO-WASTE|MISSION|DOC)'
ids = re.findall(rf'\b({domains}-\d+)\b', content)
for gid in sorted(set(ids)):
    print(gid)
" 2>/dev/null || true)

# ── Check each ID ─────────────────────────────────────────────────────────────
fail=0
while IFS= read -r gap_id; do
  [[ -z "$gap_id" ]] && continue

  # Allowlisted IDs are exempt (historical, in chump-proprietary)
  _in_allowlist "$gap_id" && continue

  # Check for a real YAML
  if [[ ! -f "$GAPS_DIR/${gap_id}.yaml" ]]; then
    echo "PHANTOM [$SCAN_FILE] $gap_id — no docs/gaps/${gap_id}.yaml and not in allowlist"
    fail=$((fail + 1))
  fi
done <<< "$gap_ids"

if [[ "$fail" -gt 0 ]]; then
  if _has_bypass; then
    reason=$(git -C "$REPO_ROOT" log -1 --format='%B' 2>/dev/null \
      | grep -i "^Phantom-Ref-Bypass:" | head -1 | sed 's/Phantom-Ref-Bypass: *//i')
    echo "BYPASS: Phantom-Ref-Bypass trailer found — $reason"
    exit 0
  fi
  echo ""
  echo "FAIL: $fail new phantom gap ID(s) in $SCAN_FILE"
  echo ""
  echo "  Remediation — pick ONE per phantom ID:"
  echo "    (A) Create docs/gaps/<ID>.yaml with concrete acceptance_criteria"
  echo "    (B) Update the citation to reference the correct existing gap ID"
  echo "    (C) If the gap is in chump-proprietary, add it to:"
  echo "        scripts/ci/research-integrity-phantom-allowlist.txt"
  echo "        with a comment explaining why it belongs there"
  exit 1
fi

allowlist_count=$(echo "$_allowlist_stripped" | grep -c '.' || true)
echo "PASS: all new gap ID references in $SCAN_FILE resolve ($allowlist_count allowlisted historical IDs skipped)"
exit 0
