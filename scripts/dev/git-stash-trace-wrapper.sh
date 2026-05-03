#!/usr/bin/env bash
# git-stash-trace-wrapper.sh — META-016 — log every `git stash push` with PPID + ancestry
#
# Background: META-016 was diagnosed as "untracked .chump/notes/* files
# disappearing during branch-mutation flows." The mechanism is `git stash
# push -u` named `claude-other-stash <unix-ts>` / `claude-watch-stash
# <unix-ts>` — a background process captures untracked content and never
# pops it. The acute pain is gone (gitignore in PR #884 makes stash -u
# skip .chump/notes/), but the *source* of those stash invocations is
# still unidentified. It's not in any in-repo script, not in `strings
# $(which claude)`, and not in obvious node-module locations
# (clawhub/openclaw/anthropic-ai). The Claude Code binary is a Bun-bundled
# Mach-O with the JS payload inside an opaque `__BUN` segment.
#
# This wrapper is the catch-it-on-next-fire approach. Drop it into PATH
# ahead of `/usr/bin/git` (typical: symlink `~/.local/bin/git` → this
# script). Every `git stash` invocation gets logged with:
#   - wall-clock timestamp
#   - full argv (so we see the message including `claude-*-stash`)
#   - PID + PPID
#   - parent process command line
#   - 5-deep process ancestry (PID/cmd at each level)
#
# Then the wrapper exec's the real git so behavior is unchanged.
#
# Recursion guard: this wrapper invokes the real git, which (because PATH
# search caches are subtle) might re-invoke the wrapper if a child process
# reads PATH after we've manipulated it. We export `_CHUMP_GIT_TRACE_REENTRY=1`
# and short-circuit if set.
#
# Install:
#   ln -sf "$(realpath scripts/dev/git-stash-trace-wrapper.sh)" ~/.local/bin/git
# Verify:
#   which -a git    # ~/.local/bin/git should come first
#   git --version   # passes through unchanged
# Uninstall:
#   rm ~/.local/bin/git
#
# Override real git path via CHUMP_REAL_GIT (default: /usr/bin/git).
# Override log file via CHUMP_STASH_TRACE_LOG (default: durable home-dir path).

set -u

REAL_GIT="${CHUMP_REAL_GIT:-/usr/bin/git}"
LOG_FILE="${CHUMP_STASH_TRACE_LOG:-$HOME/.claude/projects/-Users-jeffadkins-Projects-Chump/notes/git-stash-trace.log}"

# Recursion guard — see header. If we re-enter, just exec real git silently.
if [ "${_CHUMP_GIT_TRACE_REENTRY:-0}" = "1" ]; then
  exec "$REAL_GIT" "$@"
fi
export _CHUMP_GIT_TRACE_REENTRY=1

# Fast path: only do the trace work if argv mentions `stash`.
# Anything else passes through immediately. This keeps overhead near-zero
# for the 99% of git invocations we don't care about.
is_stash_invocation=0
for arg in "$@"; do
  case "$arg" in
    stash) is_stash_invocation=1; break ;;
    -*) ;;  # flag — keep scanning
    *) break ;;  # first non-flag positional that wasn't `stash` — we're done
  esac
done

if [ "$is_stash_invocation" != "1" ]; then
  exec "$REAL_GIT" "$@"
fi

# Trace-mode: build a structured log line and append.
# Format: JSONL so it's grep/jq-friendly. One record per invocation.

# Process ancestry (5 deep). Each entry: {pid, cmd}.
# Use ps to walk PPIDs. Defensively exit on first failure — never let
# tracing crash the actual git invocation.
ancestry_json() {
  local pid=$1
  local depth=0
  local sep=""
  printf '['
  while [ "$pid" != "0" ] && [ "$pid" != "1" ] && [ "$depth" -lt 5 ]; do
    local cmd ppid
    # macOS ps: -p <pid> -o ppid=,command=
    read -r ppid cmd < <(ps -o ppid=,command= -p "$pid" 2>/dev/null) || break
    [ -z "$ppid" ] && break
    # JSON-escape cmd: replace " with \", \ with \\, control chars dropped
    local cmd_esc
    cmd_esc=$(printf '%s' "$cmd" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null || printf '"unknown"')
    printf '%s{"pid":%s,"cmd":%s}' "$sep" "$pid" "$cmd_esc"
    sep=","
    pid=$ppid
    depth=$((depth + 1))
  done
  printf ']'
}

# Build the log record.
# Need argv as a JSON array.
argv_json=$(python3 -c '
import sys, json
print(json.dumps(sys.argv[1:]))
' "$@" 2>/dev/null || printf '["unparseable"]')

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
my_pid=$$
parent_pid=$PPID

# Best-effort log dir creation.
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# Compose the line (one JSON object per line).
{
  printf '{"ts":"%s","pid":%s,"ppid":%s,"argv":%s,"ancestry":' \
    "$ts" "$my_pid" "$parent_pid" "$argv_json"
  ancestry_json "$parent_pid"
  printf '}\n'
} >> "$LOG_FILE" 2>/dev/null || true

# Pass through to real git unchanged.
exec "$REAL_GIT" "$@"
