#!/usr/bin/env bash
# Single-pane read-only snapshot for fleet / unattended loops:
# musher dispatch, gap lease JSON files, recent ambient, open PRs touching gaps.yaml.
#
# Usage (from repo root):
#   bash scripts/dev/fleet-status.sh

set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"

echo "========== FLEET STATUS ($(date -u +%Y-%m-%dT%H:%M:%SZ)) =========="
echo ""

echo "---------- musher ----------"
MUSHER_TEXT=""
if [[ -x scripts/coord/musher.sh ]] || [[ -f scripts/coord/musher.sh ]]; then
  MUSHER_TEXT=$(bash scripts/coord/musher.sh --status 2>&1) || echo "[fleet-status] WARN: musher --status exited non-zero"
  echo "$MUSHER_TEXT"
else
  echo "[fleet-status] WARN: scripts/coord/musher.sh not found"
fi
echo ""

echo "---------- gap leases ($LOCK_DIR/*.json) ----------"
mkdir -p "$LOCK_DIR" 2>/dev/null || true
shopt -s nullglob
leases=("$LOCK_DIR"/*.json)
if [[ ${#leases[@]} -eq 0 ]]; then
  echo "(no *.json lease files — idle or agents using another CHUMP_LOCK_DIR)"
else
  for f in "${leases[@]}"; do
    echo "  $f"
    # One-line summary: gap_id + paths head
    if command -v python3.12 >/dev/null 2>&1; then
      python3.12 -c "import json,sys; d=json.load(open(sys.argv[1])); print('    gap_id:', d.get('gap_id')); print('    session:', d.get('session_id', d.get('session'))); p=d.get('paths') or []; print('    paths:', (p[:5] if isinstance(p,list) else p))" "$f" 2>/dev/null || echo "    (unparseable json)"
    else
      head -c 200 "$f" | tr '\n' ' '
      echo ""
    fi
  done
fi
shopt -u nullglob

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }
if [[ ${#leases[@]} -eq 0 && -n "$MUSHER_TEXT" ]] && echo "$MUSHER_TEXT" | strip_ansi | grep -qE '[[:space:]]claimed[[:space:]]'; then
  echo "[fleet-status] WARN: musher reports claimed gap(s) but no *.json under $LOCK_DIR — check CHUMP_LOCK_DIR / cwd"
  echo ""
fi

echo "---------- ambient (last 20 lines) ----------"
if [[ -f "$AMBIENT" ]]; then
  tail -n 20 "$AMBIENT"
  total=$(wc -l <"$AMBIENT" | tr -d ' ')
  edits=$(grep -c 'file_edit' "$AMBIENT" 2>/dev/null || true)
  commits=$(grep -c '"event":"commit"' "$AMBIENT" 2>/dev/null || true)
  edits=${edits:-0}
  commits=${commits:-0}
  if [[ "$total" -gt 5 && "$edits" -eq 0 && "$commits" -eq 0 ]]; then
    echo ""
    echo "[fleet-status] WARN: ambient has ${total} lines but no file_edit/commit events — possible idle/stale stream or logging misconfig"
  fi
  tail_sample=$(tail -n 20 "$AMBIENT")
  if echo "$tail_sample" | grep -q . && ! echo "$tail_sample" | grep -qE 'file_edit|"event":"commit"'; then
    echo ""
    echo "[fleet-status] WARN: last 20 ambient lines show no file_edit/commit — fleet may be idle or ambient is session_start-only"
  fi
else
  echo "(no $AMBIENT — no ambient yet)"
fi
echo ""

echo "---------- open PRs touching docs/gaps.yaml ----------"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  nums=$(gh pr list --state open --json number --jq '.[].number' 2>/dev/null || true)
  found=0
  for n in $nums; do
    if gh pr diff "$n" -- docs/gaps.yaml 2>/dev/null | grep -q .; then
      echo "  PR #$n touches docs/gaps.yaml"
      found=1
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    echo "(none detected among open PRs)"
  fi
else
  echo "(skipped: gh not installed or not authenticated)"
fi

echo ""
echo "========== END =========="
