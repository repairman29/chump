#!/usr/bin/env bash
# check-mechanism-kappa.sh — EVAL-093 advisory: mechanism claims need a κ citation.
#
# Pre-commit advisory: when the staged diff contains "mechanism" + a delta
# value > 0.05 (e.g. "Δ=-0.30", "delta=+0.18"), require a κ / kappa citation
# in the same diff or the commit message. Catches the EVAL-074 class
# (single-judge mechanism claim that didn't survive cross-rescore).
#
# Usage (called from pre-commit hook):
#   scripts/ci/check-mechanism-kappa.sh [--commit-msg-file <path>]
#
# Behavior: prints WARN to stderr and exits 0 (advisory). When CHUMP_KAPPA_GATE=enforce,
# exits 1 and blocks the commit.
#
# Bypass: CHUMP_KAPPA_GATE=0 (silence) or CHUMP_KAPPA_GATE=enforce (block).
# Default: warn-only.

set -euo pipefail

GATE_MODE="${CHUMP_KAPPA_GATE:-warn}"
[[ "$GATE_MODE" == "0" ]] && exit 0  # silenced

COMMIT_MSG_FILE=""
if [[ "${1:-}" == "--commit-msg-file" ]]; then
    COMMIT_MSG_FILE="$2"
fi

# Pull staged diff (added lines only — that's where new claims appear).
# Use [+] character class instead of \+ for BSD grep compatibility (BSD -E
# treats \+ as a repetition operator; matching the literal + needs the class).
STAGED_DIFF="$(git diff --cached --diff-filter=AM 2>/dev/null | grep '^[+]' | grep -v '^[+][+][+] ' || true)"
[[ -z "$STAGED_DIFF" ]] && exit 0

# Quick keyword filter: does the diff mention "mechanism" / "hypothesis"?
# Use POSIX-safe alternation only — BSD grep on macOS chokes on complex regex.
HAS_MECHANISM="$(echo "$STAGED_DIFF" | grep -ciE 'mechanism|hypothesis' || true)"
[[ "$HAS_MECHANISM" -eq 0 ]] && exit 0

# Find any delta-like value with magnitude > 0.05.
# Patterns: "Δ=-0.30", "delta=+0.18", "−30pp", "delta_max=0.150"
LARGE_DELTAS="$(echo "$STAGED_DIFF" | python3 -c "
import sys, re
text = sys.stdin.read()
hits = []
# Float deltas
for m in re.finditer(r'(?:delta|Δ|κ-)\s*=?\s*([+-]?\d+\.\d+)', text, re.IGNORECASE):
    val = abs(float(m.group(1)))
    if val > 0.05:
        hits.append(m.group(0))
# Percentage-point deltas (e.g. '-30pp', '−15 pp')
for m in re.finditer(r'[+-−]?(\d+(?:\.\d+)?)\s*pp\b', text):
    val = abs(float(m.group(1)))
    if val > 5.0:  # 5pp = 0.05
        hits.append(m.group(0))
print('\n'.join(sorted(set(hits))[:5]))
")"
[[ -z "$LARGE_DELTAS" ]] && exit 0

# Now check: is there a κ / kappa citation in the diff OR in the commit message?
HAS_KAPPA_DIFF="$(echo "$STAGED_DIFF" | grep -ciE 'κ|kappa|cohen|inter-rater|inter rater|cross-judge|cross judge' || true)"
HAS_KAPPA_MSG=0
if [[ -n "$COMMIT_MSG_FILE" && -f "$COMMIT_MSG_FILE" ]]; then
    HAS_KAPPA_MSG="$(grep -ciE 'κ|kappa|cohen|cross-judge|cross judge' "$COMMIT_MSG_FILE" || true)"
fi

if [[ "$HAS_KAPPA_DIFF" -gt 0 || "$HAS_KAPPA_MSG" -gt 0 ]]; then
    exit 0  # citation present
fi

# No citation found — warn (or block if enforce).
{
    echo ""
    echo "[mechanism-kappa] ADVISORY (EVAL-093): mechanism claim with |Δ|>0.05 lacks κ citation."
    echo "[mechanism-kappa]   Detected delta(s):"
    while IFS= read -r d; do echo "[mechanism-kappa]     - $d"; done <<<"$LARGE_DELTAS"
    echo "[mechanism-kappa]   Required: cross-judge κ ≥ 0.60 (or ≥80% binary agreement) on the fixture class where the mechanism was detected."
    echo "[mechanism-kappa]   Add the κ value, judge panel, and fixture scope to the commit body or linked result doc."
    echo "[mechanism-kappa]   Background: EVAL-074 retraction (PR #549 → #551) — Llama-only −30pp claim → Sonnet cross-rescore −0.4pp p=1.0, κ=0.40."
    echo "[mechanism-kappa]   Bypass: CHUMP_KAPPA_GATE=0 git commit ... (silence)"
    echo "[mechanism-kappa]   Enforce: CHUMP_KAPPA_GATE=enforce git commit ... (block instead of warn)"
    echo ""
} >&2

if [[ "$GATE_MODE" == "enforce" ]]; then
    exit 1
fi
exit 0  # advisory default
