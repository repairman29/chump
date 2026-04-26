#!/usr/bin/env bash
# scripts/audit/run-auditor.sh — runs every executable check in
# scripts/audit/auditor-checks/ in lex order. Each check emits JSONL findings on
# stdout; this wrapper concatenates them and writes to a single output file.
#
# Usage:
#   scripts/audit/run-auditor.sh [--out PATH] [--check NAME[,NAME…]]
#
# By default writes to .chump/auditor-findings-<UTC-timestamp>.jsonl. Stderr
# prints per-check progress.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

OUT=""
ONLY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --check) ONLY="$2"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

mkdir -p .chump
: "${OUT:=.chump/auditor-findings-$(date -u +%Y%m%dT%H%M%SZ).jsonl}"
> "$OUT"

CHECK_DIR="$ROOT/scripts/audit/auditor-checks"
total=0
for check in "$CHECK_DIR"/check-*.sh; do
    [ -x "$check" ] || continue
    name="$(basename "$check" .sh)"
    if [ -n "$ONLY" ]; then
        case ",$ONLY," in
            *",${name#check-},"*) ;;  # match
            *) continue ;;
        esac
    fi
    printf '[%s] running %s...\n' "$(date -u +%FT%TZ)" "$name" >&2
    set +e
    bash "$check" >>"$OUT"
    rc=$?
    set -e
    new=$(wc -l <"$OUT" | awk '{print $1}')
    delta=$((new - total))
    total=$new
    printf '[%s]   %s emitted %d findings (rc=%d)\n' "$(date -u +%FT%TZ)" "$name" "$delta" "$rc" >&2
done

printf '[%s] auditor wrote %d findings to %s\n' "$(date -u +%FT%TZ)" "$total" "$OUT" >&2
echo "$OUT"
