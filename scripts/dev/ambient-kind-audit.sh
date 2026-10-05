#!/usr/bin/env bash
# ambient-kind-audit.sh — INFRA-1889 backfill report.
#
# Scans the last N days (default 30) of .chump-locks/ambient.jsonl and
# prints the distinct "kind" values NOT present in
# docs/observability/EVENT_REGISTRY.yaml or scripts/ci/event-registry-reserved.txt.
# Used to size the migration before turning on kind-schema enforcement
# (scripts/dev/ambient-emit.sh, CHUMP_AMBIENT_KIND_LAX).
#
# Usage:
#   scripts/dev/ambient-kind-audit.sh [--days N] [--json]

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi

AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$MAIN_REPO/.chump-locks/ambient.jsonl}"
REGISTRY_PATH="$MAIN_REPO/docs/observability/EVENT_REGISTRY.yaml"
RESERVED_PATH="$MAIN_REPO/scripts/ci/event-registry-reserved.txt"

DAYS=30
JSON_OUT=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --days) DAYS="$2"; shift 2 ;;
        --json) JSON_OUT=true; shift ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done

if [[ ! -f "$AMBIENT_LOG" ]]; then
    echo "[ambient-kind-audit] no ambient log at $AMBIENT_LOG" >&2
    exit 0
fi

CUTOFF_EPOCH=$(( $(date -u +%s) - DAYS * 86400 ))

python3 - "$AMBIENT_LOG" "$REGISTRY_PATH" "$RESERVED_PATH" "$CUTOFF_EPOCH" "$JSON_OUT" <<'PYEOF'
import json, re, sys, time, calendar

ambient_path, registry_path, reserved_path, cutoff_epoch, json_out = sys.argv[1:6]
cutoff_epoch = int(cutoff_epoch)
json_out = json_out == "True" or json_out == "true"

registered = set()
try:
    with open(registry_path) as f:
        for line in f:
            m = re.match(r"^  - kind: (.+)$", line.rstrip("\n"))
            if m:
                registered.add(m.group(1).strip())
except FileNotFoundError:
    pass

try:
    with open(reserved_path) as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            registered.add(s.split()[0])
except FileNotFoundError:
    pass

slug_re = re.compile(r"^[a-z][a-z0-9_]+$")
counts = {}
total_lines = 0
with open(ambient_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        total_lines += 1
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        ts = obj.get("ts", "")
        try:
            epoch = calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ"))
        except ValueError:
            epoch = None
        if epoch is not None and epoch < cutoff_epoch:
            continue
        kind = obj.get("kind") or obj.get("event")
        if kind is None:
            continue
        if kind in registered:
            continue
        counts[kind] = counts.get(kind, 0) + 1

not_slug_shaped = {k: v for k, v in counts.items() if not slug_re.match(k)}

if json_out:
    print(json.dumps({
        "distinct_unregistered_kinds": len(counts),
        "distinct_free_text_kinds": len(not_slug_shaped),
        "unregistered": counts,
        "free_text": not_slug_shaped,
    }, indent=2, sort_keys=True))
else:
    print(f"[ambient-kind-audit] scanned {total_lines} lines")
    print(f"[ambient-kind-audit] distinct kinds NOT in registry: {len(counts)}")
    for k, v in sorted(counts.items(), key=lambda kv: -kv[1]):
        flag = " (FREE-TEXT, would be quarantined)" if k in not_slug_shaped else ""
        print(f"  {v:6d}  {k}{flag}")
    print(f"[ambient-kind-audit] of those, {len(not_slug_shaped)} are free-text (not slug-shaped) and would be quarantined under kind-schema enforcement")
PYEOF
