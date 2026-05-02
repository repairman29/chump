#!/usr/bin/env bash
# ambient-emit.sh — append one event to .chump-locks/ambient.jsonl
#
# Usage:
#   scripts/dev/ambient-emit.sh <event_kind> [key=value ...]
#
# Examples:
#   scripts/dev/ambient-emit.sh session_start gap=FLEET-004a
#   scripts/dev/ambient-emit.sh file_edit path=src/foo.rs
#   scripts/dev/ambient-emit.sh commit sha=abc1234 msg="feat: add thing" gap=FLEET-004a
#   scripts/dev/ambient-emit.sh ALERT kind=lease_overlap sessions=a,b path=src/main.rs
#
# The file is written with a file-lock (flock) so concurrent writers never
# produce interleaved JSON. Falls back to no-lock on systems without flock.
#
# Environment:
#   CHUMP_SESSION_ID   / CLAUDE_SESSION_ID  — used for the session field
#   CHUMP_AMBIENT_LOG  — override the output path (default: .chump-locks/ambient.jsonl)

set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <event_kind> [key=value ...]" >&2
    exit 1
fi

EVENT_KIND="$1"
shift

# ── Paths ─────────────────────────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# Linked worktrees have a separate --show-toplevel but share --git-common-dir.
# Resolve the main repo root so all agents write to the same ambient.jsonl.
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
# Worktree-local lock dir: session ID files are scoped per worktree, not shared.
LOCAL_LOCK_DIR="$REPO_ROOT/.chump-locks"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"

mkdir -p "$LOCK_DIR"

# ── Session ID (same precedence as gap-claim.sh) ──────────────────────────────
SESSION_ID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
if [[ -z "$SESSION_ID" ]]; then
    WT_SESSION_CACHE="$LOCAL_LOCK_DIR/.wt-session-id"
    if [[ -f "$WT_SESSION_CACHE" ]]; then
        SESSION_ID="$(cat "$WT_SESSION_CACHE")"
    else
        SESSION_ID="chump-$(basename "$REPO_ROOT")-$(date +%s)"
    fi
fi

# ── Worktree label ────────────────────────────────────────────────────────────
WORKTREE="$(basename "$REPO_ROOT")"

# ── Timestamp ─────────────────────────────────────────────────────────────────
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Build extra fields from key=value args ────────────────────────────────────
EXTRA_JSON=""
for arg in "$@"; do
    KEY="${arg%%=*}"
    VAL="${arg#*=}"
    # Escape value for JSON: backslash, double-quote, control chars
    VAL_ESC="$(printf '%s' "$VAL" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])'  2>/dev/null || printf '%s' "$VAL" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    EXTRA_JSON="${EXTRA_JSON},\"${KEY}\":\"${VAL_ESC}\""
done

# ── Build the JSON line ───────────────────────────────────────────────────────
JSON_LINE="{\"ts\":\"${TS}\",\"session\":\"${SESSION_ID}\",\"worktree\":\"${WORKTREE}\",\"event\":\"${EVENT_KIND}\"${EXTRA_JSON}}"

# ── INFRA-101: validate against docs/ambient-schema.json before append ───────
# Catches the schema drift the 2026-04-26 audit flagged (INTENT rows with
# reordered keys + nonstandard shape) at write time, not at parse time.
# Disable with CHUMP_AMBIENT_SCHEMA_CHECK=0 (e.g. when emitting a brand-new
# event kind whose schema entry hasn't landed yet).
if [[ "${CHUMP_AMBIENT_SCHEMA_CHECK:-1}" != "0" ]] && command -v python3 >/dev/null 2>&1; then
    # Worktree first (lets a fresh schema land before merge), main second.
    if [[ -f "$REPO_ROOT/docs/ambient-schema.json" ]]; then
        SCHEMA_PATH="$REPO_ROOT/docs/ambient-schema.json"
    elif [[ -f "$MAIN_REPO/docs/ambient-schema.json" ]]; then
        SCHEMA_PATH="$MAIN_REPO/docs/ambient-schema.json"
    else
        SCHEMA_PATH=""
    fi
    if [[ -n "$SCHEMA_PATH" ]]; then
        validation_err="$(JSON_LINE="$JSON_LINE" SCHEMA_PATH="$SCHEMA_PATH" python3 - <<'PYEOF' 2>&1
import json, os, sys, re

line = os.environ["JSON_LINE"]
schema = json.load(open(os.environ["SCHEMA_PATH"]))

# Parse the assembled line.
try:
    obj = json.loads(line)
except json.JSONDecodeError as e:
    print(f"ambient JSON malformed: {e}")
    sys.exit(1)

# Required base fields.
for f in schema.get("required", []):
    if f not in obj:
        print(f"missing required base field: {f}")
        sys.exit(1)

# Base-field type/format checks.
props = schema.get("properties", {})
for name, spec in props.items():
    if name not in obj:
        continue
    val = obj[name]
    if spec.get("type") == "string" and not isinstance(val, str):
        print(f"field {name} must be string, got {type(val).__name__}")
        sys.exit(1)
    pat = spec.get("pattern")
    if pat and not re.match(pat, str(val)):
        print(f"field {name}={val!r} does not match pattern {pat}")
        sys.exit(1)
    enum = spec.get("enum")
    if enum and val not in enum:
        print(f"field {name}={val!r} not in enum {enum}")
        sys.exit(1)

# Per-event-kind branch: pick the matching oneOf entry by event value
# and check its required fields.
event = obj.get("event")
for branch in schema.get("oneOf", []):
    bp = branch.get("properties", {}).get("event", {})
    matches = (bp.get("const") == event) or (event in (bp.get("enum") or []))
    if not matches:
        continue
    for f in branch.get("required", []):
        if f not in obj:
            print(f"event={event} requires field {f!r}")
            sys.exit(1)
    # Per-field type / pattern checks within the branch.
    for name, spec in branch.get("properties", {}).items():
        if name == "event" or name not in obj:
            continue
        val = obj[name]
        if spec.get("type") == "string" and not isinstance(val, str):
            print(f"event={event} field {name} must be string")
            sys.exit(1)
        pat = spec.get("pattern")
        if pat and not re.match(pat, str(val)):
            print(f"event={event} field {name}={val!r} does not match pattern {pat}")
            sys.exit(1)
    break
else:
    # No branch matched the event kind. event enum check above should
    # have caught this; fall through silently if user disabled enum.
    pass

sys.exit(0)
PYEOF
        )"
        if [[ -n "$validation_err" ]]; then
            echo "[ambient-emit] schema validation failed (INFRA-101):" >&2
            printf '  %s\n' "$validation_err" >&2
            echo "[ambient-emit] line: $JSON_LINE" >&2
            echo "[ambient-emit] schema: $SCHEMA_PATH" >&2
            echo "[ambient-emit] bypass: CHUMP_AMBIENT_SCHEMA_CHECK=0 $0 ..." >&2
            exit 1
        fi
    fi
fi

# ── Atomic append (flock if available, plain >> otherwise) ───────────────────
if command -v flock &>/dev/null; then
    (
        flock -x 200
        printf '%s\n' "$JSON_LINE" >> "$AMBIENT_LOG"
    ) 200>"${AMBIENT_LOG}.lock"
else
    # macOS: no flock, use noclobber trick — races are rare enough at human timescales
    printf '%s\n' "$JSON_LINE" >> "$AMBIENT_LOG"
fi

# ── FLEET-006: best-effort NATS dual-emit ─────────────────────────────────────
# When chump-coord is on PATH, fan the same event out to JetStream so
# remote machines (and Cold Water) can see it. No-op when chump-coord or
# NATS are unavailable — file append above is the durable record.
if [[ "${CHUMP_AMBIENT_NATS:-1}" != "0" ]] && command -v chump-coord &>/dev/null; then
    # Translate event kind to upper-case for chump.events.<lower> subject
    # consistency with broadcast.sh; pass-through key=value args.
    CHUMP_SESSION_ID="$SESSION_ID" \
        chump-coord emit "$EVENT_KIND" "$@" >/dev/null 2>&1 || true
fi
