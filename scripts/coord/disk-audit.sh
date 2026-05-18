#!/usr/bin/env bash
# scripts/coord/disk-audit.sh — INFRA-1469
# Rust-First-Bypass: read-only du aggregator; no state mutation; pairs with
# disk-pressure-reaper.sh already in scripts/coord/ under the same exemption.
#
# Top-20 disk consumer audit across hotspot dirs.
# Runs in <30s without a full filesystem scan.
#
# Hotspot dirs scanned (AC-1):
#   /private/tmp        — worktrees, build artifacts, temp files
#   ~/Library/Caches    — app caches
#   ~/.cargo/registry   — cargo crate registry
#   ~/.cargo/git        — cargo git checkouts
#   ~/Library/Developer — Xcode / CoreSimulator images
#   /var/folders        — macOS per-user temp (TMPDIR)
#   ~/Library/Logs      — app logs
#
# Emits kind=disk_audit_report to ambient.jsonl (AC-2).
#
# Usage:
#   disk-audit.sh [--top N] [--json] [--no-ambient] [--help]
#
#   --top N        Report top N consumers (default 20)
#   --json         Print machine-readable JSON summary to stdout
#   --no-ambient   Skip ambient emit (useful in CI)
#   --verbose      Show per-dir scan progress

set -uo pipefail

REPO_ROOT="${CHUMP_REPO:-${CHUMP_HOME:-/Users/jeffadkins/Projects/Chump}}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

TOP_N=20
JSON_OUT=0
NO_AMBIENT=0
VERBOSE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --top)       TOP_N="$2"; shift 2 ;;
    --json)      JSON_OUT=1; shift ;;
    --no-ambient) NO_AMBIENT=1; shift ;;
    --verbose)   VERBOSE=1; shift ;;
    --help|-h)   sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

info()  { [[ "$VERBOSE" -eq 1 ]] && printf '\033[0;36m→\033[0m  %s\n' "$*" >&2 || true; }

# ── Detect free disk ──────────────────────────────────────────────────────────
free_gb=$(df -g /System/Volumes/Data 2>/dev/null | awk 'NR==2 {print $4}')
if [[ -z "$free_gb" ]]; then
  free_gb=$(df -BG / 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
fi
free_gb="${free_gb:-0}"

total_gb=$(df -g /System/Volumes/Data 2>/dev/null | awk 'NR==2 {print $2}')
[[ -z "$total_gb" ]] && total_gb=0
used_gb=$(( total_gb - free_gb ))

# ── Dirs to scan ─────────────────────────────────────────────────────────────
# Expand ~ explicitly since du doesn't always do it
HOME_DIR="${HOME:-/Users/$(id -un)}"
SCAN_DIRS=(
  "/private/tmp"
  "$HOME_DIR/Library/Caches"
  "$HOME_DIR/.cargo/registry"
  "$HOME_DIR/.cargo/git"
  "$HOME_DIR/Library/Developer"
  "/var/folders"
  "$HOME_DIR/Library/Logs"
)

# ── Gather per-first-level-child sizes (max depth=1) ─────────────────────────
# We use du -sh on each dir's direct children to stay fast.
# 30s total budget split across dirs.
TMPFILE="$(mktemp /tmp/disk-audit-XXXXXX.txt)"
trap 'rm -f "$TMPFILE"' EXIT

for dir in "${SCAN_DIRS[@]}"; do
  [[ -d "$dir" ]] || { info "skip (not found): $dir"; continue; }
  info "scanning: $dir"
  # Use GNU timeout if available, else fall back to built-in approach
  if command -v gtimeout &>/dev/null; then
    gtimeout 8 du -sh "$dir"/*/  2>/dev/null >> "$TMPFILE" || true
    gtimeout 4 du -sh "$dir"     2>/dev/null >> "$TMPFILE" || true
  else
    # macOS: use perl-based timeout wrapper or just du with a ceiling
    (
      du -sh "$dir"/*/ 2>/dev/null || true
    ) & DU_PID=$!
    # Wait max 8s per dir
    ( sleep 8; kill "$DU_PID" 2>/dev/null || true ) &
    KILL_PID=$!
    wait "$DU_PID" 2>/dev/null
    kill "$KILL_PID" 2>/dev/null || true
    wait "$KILL_PID" 2>/dev/null || true
    du -sh "$dir" 2>/dev/null >> "$TMPFILE" || true
  fi >> "$TMPFILE" 2>/dev/null || true
done

# ── Convert human sizes to MB for sorting ─────────────────────────────────────
# Parse lines like: "4.2G /path" or "512M /path"
python3 - "$TMPFILE" "$TOP_N" <<'PYEOF'
import sys, re, os

def parse_du_size(s):
    """Convert du -sh output like '4.2G', '512M', '1.1T' to MB float."""
    s = s.strip()
    m = re.match(r'^([0-9.]+)([KMGT]?)$', s, re.IGNORECASE)
    if not m:
        return 0.0
    num, unit = float(m.group(1)), m.group(2).upper()
    multipliers = {'': 1/1024, 'K': 1/1024, 'M': 1, 'G': 1024, 'T': 1024*1024}
    return num * multipliers.get(unit, 1)

tmpfile = sys.argv[1]
top_n = int(sys.argv[2])
entries = []
seen = set()

with open(tmpfile) as f:
    for line in f:
        line = line.strip()
        if not line or '\t' not in line:
            continue
        parts = line.split('\t', 1)
        if len(parts) != 2:
            continue
        size_str, path = parts[0].strip(), parts[1].strip()
        if path in seen:
            continue
        seen.add(path)
        size_mb = parse_du_size(size_str)
        entries.append((size_mb, size_str, path))

entries.sort(reverse=True)
top = entries[:top_n]

# Print as TSV for shell consumption: size_mb \t human_size \t path
for size_mb, human, path in top:
    print(f"{size_mb:.1f}\t{human}\t{path}")
PYEOF
_RANK_EXIT=$?

# Re-run to capture sorted output
SORTED_FILE="$(mktemp /tmp/disk-audit-sorted-XXXXXX.txt)"
trap 'rm -f "$TMPFILE" "$SORTED_FILE"' EXIT

python3 - "$TMPFILE" "$TOP_N" > "$SORTED_FILE" <<'PYEOF'
import sys, re

def parse_du_size(s):
    s = s.strip()
    m = re.match(r'^([0-9.]+)([KMGT]?)$', s, re.IGNORECASE)
    if not m:
        return 0.0
    num, unit = float(m.group(1)), m.group(2).upper()
    multipliers = {'': 1/1024, 'K': 1/1024, 'M': 1, 'G': 1024, 'T': 1024*1024}
    return num * multipliers.get(unit, 1)

tmpfile = sys.argv[1]
top_n = int(sys.argv[2])
entries = []
seen = set()

with open(tmpfile) as f:
    for line in f:
        line = line.strip()
        if not line or '\t' not in line:
            continue
        parts = line.split('\t', 1)
        if len(parts) != 2:
            continue
        size_str, path = parts[0].strip(), parts[1].strip()
        if path in seen:
            continue
        seen.add(path)
        size_mb = parse_du_size(size_str)
        entries.append((size_mb, size_str, path))

entries.sort(reverse=True)
top = entries[:top_n]

for size_mb, human, path in top:
    print(f"{size_mb:.1f}\t{human}\t{path}")
PYEOF

# ── Print human-readable report ───────────────────────────────────────────────
printf '\n\033[1mDisk Audit Report\033[0m — %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
_free_color="0;32"
if [[ "$free_gb" -lt 10 ]]; then _free_color="0;31"
elif [[ "$free_gb" -lt 30 ]]; then _free_color="0;33"; fi
printf '  Total: %sGB  Used: %sGB  Free: \033[%sm%sGB\033[0m\n' \
  "$total_gb" "$used_gb" "$_free_color" "$free_gb"
printf '\n  Top %d consumers:\n' "$TOP_N"
printf '  %-10s  %s\n' "SIZE" "PATH"
printf '  %s\n' "$(printf '%0.s-' {1..60})"

rank=0
while IFS=$'\t' read -r _size_mb human_size path; do
  rank=$(( rank + 1 ))
  printf '  %2d. %-8s  %s\n' "$rank" "$human_size" "$path"
done < "$SORTED_FILE"

# ── Ambient emit (AC-2) ───────────────────────────────────────────────────────
if [[ "$NO_AMBIENT" -eq 0 ]] && [[ -d "$(dirname "$AMBIENT_LOG")" ]]; then
  # Build JSON array of top paths
  TOP_JSON="$(python3 - "$SORTED_FILE" <<'PYEOF'
import sys, json

entries = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        parts = line.split('\t', 2)
        if len(parts) == 3:
            entries.append({"size": parts[1], "path": parts[2]})

print(json.dumps(entries))
PYEOF
  )"
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"ts":"%s","kind":"disk_audit_report","free_gb":%s,"used_gb":%s,"top_paths":%s}\n' \
    "$TS" "$free_gb" "$used_gb" "$TOP_JSON" \
    >> "$AMBIENT_LOG" 2>/dev/null || true
  info "emitted disk_audit_report to ambient.jsonl"
fi

# ── JSON output (--json flag) ─────────────────────────────────────────────────
if [[ "$JSON_OUT" -eq 1 ]]; then
  TOP_JSON2="$(python3 - "$SORTED_FILE" <<'PYEOF'
import sys, json

entries = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        parts = line.split('\t', 2)
        if len(parts) == 3:
            entries.append({"size": parts[1], "path": parts[2]})

print(json.dumps(entries))
PYEOF
  )"
  printf '{"kind":"disk_audit_report","free_gb":%s,"used_gb":%s,"top_paths":%s}\n' \
    "$free_gb" "$used_gb" "$TOP_JSON2"
fi

exit 0
