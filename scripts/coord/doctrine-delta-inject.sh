#!/usr/bin/env bash
# scripts/coord/doctrine-delta-inject.sh — META-292
#
# SessionStart hook: surfaces doctrine changes (CLAUDE.md, AGENTS.md,
# docs/process/*.md, docs/MISSION.md) that landed on the target ref since
# this machine's last session, so an agent doesn't have to re-read the
# whole file to notice e.g. a no-band-aids rule shipped mid-session
# yesterday (CREDIBLE-105 was the precedent that motivated this gap).
#
# Also runs a lightweight "directive freshness" sub-check (AC3): scans
# pending inbox / urgent-inbox message bodies for "<file>:<line>" or
# "line N in/of <file>" style operator directives and flags any whose
# target file (a) no longer exists at the target ref, or (b) has changed
# since the stored doctrine-commit cursor — line numbers may have shifted.
#
# Output: Claude Code hook JSON —
#   {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}
#
# State: ~/.chump/session-last-doctrine-commit stores the last-seen
# target-ref commit sha for doctrine paths. Updated on every SessionStart
# invocation (not session end — session end may not fire on crash, per AC4).
#
# Env:
#   CHUMP_DOCTRINE_INJECT=0       disable (emits empty additionalContext, cursor still advances)
#   CHUMP_DOCTRINE_COMMIT_FILE    override cursor file (default: ~/.chump/session-last-doctrine-commit)
#   CHUMP_DOCTRINE_TARGET_REF     override target ref (default: origin/main; tests use HEAD)
#   CHUMP_DOCTRINE_DEBUG=1        echo the rendered context to stderr

set -uo pipefail

HOOK_EVENT="${1:-SessionStart}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT" || exit 0

emit_empty() {
    printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":""}}\n' "$HOOK_EVENT"
    exit 0
}

[[ "$HOOK_EVENT" != "SessionStart" ]] && emit_empty

STATE_FILE="${CHUMP_DOCTRINE_COMMIT_FILE:-$HOME/.chump/session-last-doctrine-commit}"
TARGET_REF="${CHUMP_DOCTRINE_TARGET_REF:-origin/main}"

CURRENT_HEAD="$(git rev-parse "$TARGET_REF" 2>/dev/null || echo "")"

if [[ "${CHUMP_DOCTRINE_INJECT:-1}" == "0" ]]; then
    # Kill switch still advances the cursor so a later re-enable doesn't
    # dump weeks of backlog at once.
    if [[ -n "$CURRENT_HEAD" ]]; then
        mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
        printf '%s\n' "$CURRENT_HEAD" > "$STATE_FILE" 2>/dev/null || true
    fi
    emit_empty
fi

[[ -z "$CURRENT_HEAD" ]] && emit_empty

STORED_COMMIT=""
[[ -f "$STATE_FILE" ]] && STORED_COMMIT="$(head -1 "$STATE_FILE" 2>/dev/null | tr -d '[:space:]')"

SID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
INBOX_FILE=""
[[ -n "$SID" && -f "$REPO_ROOT/.chump-locks/inbox/${SID}.jsonl" ]] && INBOX_FILE="$REPO_ROOT/.chump-locks/inbox/${SID}.jsonl"
URGENT_INBOX_FILE=""
[[ -f "$REPO_ROOT/.chump-locks/URGENT-INBOX.jsonl" ]] && URGENT_INBOX_FILE="$REPO_ROOT/.chump-locks/URGENT-INBOX.jsonl"

CONTEXT="$(
    REPO_ROOT="$REPO_ROOT" \
    TARGET_REF="$CURRENT_HEAD" \
    STORED_COMMIT="$STORED_COMMIT" \
    INBOX_FILE="$INBOX_FILE" \
    URGENT_INBOX_FILE="$URGENT_INBOX_FILE" \
    HOOK_EVENT="$HOOK_EVENT" \
    python3 - <<'PY'
import json
import os
import re
import subprocess
import sys

repo = os.environ.get("REPO_ROOT", ".")
ref = os.environ.get("TARGET_REF", "")
stored = os.environ.get("STORED_COMMIT", "")
hook = os.environ.get("HOOK_EVENT", "SessionStart")

DOCTRINE_PATHSPECS = ["CLAUDE.md", "AGENTS.md", "docs/process/*.md", "docs/MISSION.md"]

lines_out = []

# ── AC2: doctrine delta since last session ─────────────────────────────────
if stored and stored != ref:
    valid = subprocess.run(
        ["git", "-C", repo, "cat-file", "-e", stored + "^{commit}"],
        capture_output=True,
    ).returncode == 0
    if valid:
        r = subprocess.run(
            ["git", "-C", repo, "log", "--no-merges", "--date=short",
             "--format=%h %ad %s", f"{stored}..{ref}", "--"] + DOCTRINE_PATHSPECS,
            capture_output=True, text=True,
        )
        log_out = r.stdout.strip()
        if log_out:
            lines_out.append("=== Doctrine changes since your last session (META-292) ===")
            lines_out.extend(log_out.splitlines())
            lines_out.append(
                "Re-read the touched file(s) before relying on prior-session doctrine assumptions."
            )

# ── AC3: directive freshness sub-check ──────────────────────────────────────
pat_line_of = re.compile(r"line\s+(\d+)\s+(?:of|in)\s+([\w./-]+\.\w+)", re.IGNORECASE)
pat_colon = re.compile(r"([\w./-]+\.\w+):(\d+)")

refs_found = set()
for src in (os.environ.get("INBOX_FILE", ""), os.environ.get("URGENT_INBOX_FILE", "")):
    if not src or not os.path.isfile(src):
        continue
    try:
        with open(src, "r", errors="replace") as f:
            for raw in f:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    d = json.loads(raw)
                except Exception:
                    continue
                body = d.get("reason") or d.get("body") or d.get("note") or ""
                if not isinstance(body, str) or not body:
                    continue
                for m in pat_line_of.finditer(body):
                    refs_found.add((m.group(2), m.group(1)))
                for m in pat_colon.finditer(body):
                    refs_found.add((m.group(1), m.group(2)))
    except OSError:
        continue

fresh_lines = []
for path, ln in sorted(refs_found):
    exists = subprocess.run(
        ["git", "-C", repo, "cat-file", "-e", f"{ref}:{path}"],
        capture_output=True,
    ).returncode == 0
    if not exists:
        fresh_lines.append(f"⚠ {path} not found at HEAD — line {ln} reference may be stale")
        continue
    shifted_n = 0
    if stored:
        valid = subprocess.run(
            ["git", "-C", repo, "cat-file", "-e", stored + "^{commit}"],
            capture_output=True,
        ).returncode == 0
        if valid:
            r = subprocess.run(
                ["git", "-C", repo, "diff", "--shortstat", f"{stored}..{ref}", "--", path],
                capture_output=True, text=True,
            )
            out = r.stdout.strip()
            if out:
                ins = re.search(r"(\d+) insertion", out)
                dele = re.search(r"(\d+) deletion", out)
                shifted_n = abs((int(ins.group(1)) if ins else 0) - (int(dele.group(1)) if dele else 0))
    if shifted_n:
        fresh_lines.append(
            f"⚠ {path} has been modified since this directive — line numbers may have shifted ~{shifted_n} lines"
        )
    else:
        fresh_lines.append(f"✓ {path}:{ln} verified at HEAD")

if fresh_lines:
    lines_out.append("=== Directive freshness (META-292) ===")
    lines_out.extend(fresh_lines)

context = "\n".join(lines_out)
out = {"hookSpecificOutput": {"hookEventName": hook, "additionalContext": context}}
sys.stdout.write(json.dumps(out))
PY
)"

if [[ "${CHUMP_DOCTRINE_DEBUG:-0}" == "1" ]]; then
    printf '%s\n' "$CONTEXT" >&2
fi

printf '%s\n' "$CONTEXT"

# ── AC4: advance the cursor on every SessionStart, not session end ─────────
mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
printf '%s\n' "$CURRENT_HEAD" > "$STATE_FILE" 2>/dev/null || true

exit 0
