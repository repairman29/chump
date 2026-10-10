#!/usr/bin/env bash
# RESILIENT-495 (RESILIENT-345 slice): post-restart binary-freshness self-test.
# Runs `git rev-parse HEAD` in the running organ binary's directory and
# compares it to origin/main. Pass only when they match; on mismatch warn,
# emit kind=organ_binary_stale (organ marked unhealthy) and exit 1.
#
# Usage: organ-binary-freshness-selftest.sh --organ NAME [--bin-dir DIR | --pid PID]
#   --bin-dir  directory containing the binary (inside a git checkout)
#   --pid      resolve the directory from /proc/PID/exe
# Env: CHUMP_AMBIENT_LOG overrides the ambient.jsonl path.
set -uo pipefail

organ="" bin_dir="" pid=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --organ) organ="$2"; shift 2 ;;
        --bin-dir) bin_dir="$2"; shift 2 ;;
        --pid) pid="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done
[[ -n "$organ" ]] || { echo "--organ required" >&2; exit 2; }
if [[ -z "$bin_dir" && -n "$pid" ]]; then
    exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
    [[ -n "$exe" ]] && bin_dir="$(dirname "$exe")"
fi
[[ -n "$bin_dir" && -d "$bin_dir" ]] || { echo "binary dir not resolvable" >&2; exit 2; }

AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$(git -C "$bin_dir" rev-parse --show-toplevel 2>/dev/null)/.chump-locks/ambient.jsonl}"

fail() {  # reason, running, expected
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "WARN: organ $organ unhealthy: $1 (running=$2 origin/main=$3)" >&2
    mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"organ_binary_stale","organ":"%s","reason":"%s","running_sha":"%s","origin_main_sha":"%s"}\n' \
        "$ts" "$organ" "$1" "$2" "$3" >> "$AMBIENT_LOG" 2>/dev/null || true
    exit 1
}

running="$(git -C "$bin_dir" rev-parse HEAD 2>/dev/null)" || fail not_a_git_checkout "" ""
git -C "$bin_dir" fetch origin main --quiet 2>/dev/null || true
expected="$(git -C "$bin_dir" rev-parse origin/main 2>/dev/null)" || fail origin_main_unresolvable "$running" ""

[[ "$running" == "$expected" ]] || fail sha_mismatch "$running" "$expected"
echo "OK: organ $organ binary fresh at $running"
