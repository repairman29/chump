#!/usr/bin/env bash
# scripts/ops/audit-allowlist-staleness.sh — INFRA-1868 (parent INFRA-1861 slice c)
#
# Daily audit: every entry in scripts/ci/event-registry-reserved.txt and
# scripts/ci/env-vars-internal.txt is grepped against the codebase. If an
# entry has no code reference for 30+ days, the operator is warned.
#
# Per-entry last-seen-in-code timestamps are tracked in
# .chump-locks/allowlist-staleness.json so the "no reference for 30+ days"
# threshold survives across daily runs even if the entry disappears from code.
#
# Emits:
#   - kind=allowlist_stale_entry {entry, file, days_since_seen}  per stale entry
#   - WARN broadcast to operator-*  if any stale entries found
#
# NOTE: This script WARNS only — it does NOT prune entries. Pruning is a
# separate gap.
#
# Exit:
#   0 — no stale entries (or bypass active)
#   1 — stale entries found (cron alerts via launchctl monitoring)
#
# Bypass: CHUMP_AUDIT_ALLOWLIST_STALENESS=0 silently exits 0.
#
# Usage:
#   audit-allowlist-staleness.sh            # daily mode: emit + broadcast
#   audit-allowlist-staleness.sh --json     # machine-readable, no broadcast
#   audit-allowlist-staleness.sh --dry-run  # compute + log, skip ambient + broadcast
#   audit-allowlist-staleness.sh --stale-days N  # override 30d threshold (default: 30)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
STATE_FILE="${CHUMP_ALLOWLIST_STATE:-$LOCK_DIR/allowlist-staleness.json}"
RESERVED_TXT="${CHUMP_ALLOWLIST_RESERVED:-$REPO_ROOT/scripts/ci/event-registry-reserved.txt}"
ENVVARS_TXT="${CHUMP_ALLOWLIST_ENVVARS:-$REPO_ROOT/scripts/ci/env-vars-internal.txt}"
# CHUMP_ALLOWLIST_CODE_ROOT: override the root used for code-reference grep
# (used by CI tests to point at a fake code tree; defaults to REPO_ROOT).
CODE_ROOT="${CHUMP_ALLOWLIST_CODE_ROOT:-$REPO_ROOT}"

JSON=0
DRY_RUN=0
STALE_DAYS="${CHUMP_ALLOWLIST_STALE_DAYS:-30}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)        JSON=1; shift ;;
        --dry-run)     DRY_RUN=1; shift ;;
        --stale-days)  STALE_DAYS="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "audit-allowlist-staleness: unknown flag '$1'" >&2; exit 2 ;;
    esac
done

now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

if [[ "${CHUMP_AUDIT_ALLOWLIST_STALENESS:-1}" == "0" ]]; then
    printf '{"ts":"%s","kind":"audit_allowlist_staleness_bypassed","reason":"CHUMP_AUDIT_ALLOWLIST_STALENESS=0"}\n' \
        "$(now_ts)" >> "$AMBIENT_LOG" 2>/dev/null || true
    echo "[audit-allowlist-staleness] bypassed via CHUMP_AUDIT_ALLOWLIST_STALENESS=0"
    exit 0
fi

if [[ ! -r "$RESERVED_TXT" ]]; then
    echo "[audit-allowlist-staleness] cannot read $RESERVED_TXT — skipping" >&2
    exit 0
fi
if [[ ! -r "$ENVVARS_TXT" ]]; then
    echo "[audit-allowlist-staleness] cannot read $ENVVARS_TXT — skipping" >&2
    exit 0
fi

mkdir -p "$LOCK_DIR"

# ── Collect entries to audit ───────────────────────────────────────────────────
# Returns one line per entry: "<file>:<entry>"
# Entry is just the bare name (no comment, no leading whitespace).
collect_entries() {
    # event-registry-reserved.txt: one kind per line (skip blank + comment lines)
    while IFS= read -r raw; do
        entry="${raw%%#*}"           # strip inline comment
        entry="${entry#"${entry%%[![:space:]]*}"}"  # ltrim
        entry="${entry%"${entry##*[![:space:]]}"}"  # rtrim
        [[ -z "$entry" ]] && continue
        printf '%s:%s\n' "event-registry-reserved.txt" "$entry"
    done < "$RESERVED_TXT"

    # env-vars-internal.txt: one var name per line (skip blank + comment lines)
    while IFS= read -r raw; do
        entry="${raw%%#*}"
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [[ -z "$entry" ]] && continue
        printf '%s:%s\n' "env-vars-internal.txt" "$entry"
    done < "$ENVVARS_TXT"
}

# ── Check whether an entry has a code reference ───────────────────────────────
# Returns "found" if grep hits anywhere in the repo (excluding the allowlist
# files themselves and .chump-locks/).
has_code_reference() {
    local entry="$1"
    # Grep across src/, scripts/, web/, crates/ (canonical production paths).
    # Also include the allowlist files' sibling directories, but NOT the
    # allowlist files themselves (event-registry-reserved.txt, env-vars-internal.txt)
    # since an entry that ONLY appears in the allowlist is exactly what we want
    # to detect.
    if grep -r --include='*.rs' --include='*.sh' --include='*.py' \
               --include='*.ts' --include='*.js' --include='*.toml' \
               --include='*.yaml' --include='*.yml' \
               -l -q -F "$entry" \
               "$REPO_ROOT/src" \
               "$REPO_ROOT/crates" \
               "$REPO_ROOT/scripts" \
               "$REPO_ROOT/web" \
               2>/dev/null \
       | grep -v -F "scripts/ci/event-registry-reserved.txt" \
       | grep -v -F "scripts/ci/env-vars-internal.txt" \
       | grep -qv '^$'; then
        echo "found"
    else
        echo "absent"
    fi
}

# ── Load / merge state JSON ───────────────────────────────────────────────────
# State schema: {"<file>:<entry>": {"last_seen": "<ISO8601>", "absent_since": "<ISO8601>|null"}}
load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo '{}'
    fi
}

TODAY_TS="$(now_ts)"
TODAY_DATE="${TODAY_TS%%T*}"  # YYYY-MM-DD portion

# Run the full audit via python3 for correct date arithmetic.
REPORT=$(
    REPO_ROOT="$REPO_ROOT" \
    CODE_ROOT="$CODE_ROOT" \
    RESERVED_TXT="$RESERVED_TXT" \
    ENVVARS_TXT="$ENVVARS_TXT" \
    STATE_FILE="$STATE_FILE" \
    STALE_DAYS="$STALE_DAYS" \
    TODAY_TS="$TODAY_TS" \
    python3 - <<'PYEOF'
import os
import json
import re
import subprocess
import sys
from datetime import datetime, timezone

repo_root   = os.environ["REPO_ROOT"]
code_root   = os.environ.get("CODE_ROOT", repo_root)
reserved    = os.environ["RESERVED_TXT"]
envvars     = os.environ["ENVVARS_TXT"]
state_file  = os.environ["STATE_FILE"]
stale_days  = int(os.environ["STALE_DAYS"])
today_ts    = os.environ["TODAY_TS"]

today = datetime.fromisoformat(today_ts.replace("Z", "+00:00"))

# Load persisted state.
state = {}
if os.path.isfile(state_file):
    try:
        state = json.load(open(state_file))
    except Exception:
        state = {}

def parse_allowlist(path):
    """Return list of bare entry strings (stripped, non-blank, non-comment)."""
    entries = []
    with open(path) as f:
        for raw in f:
            line = raw.split("#")[0].strip()
            if line:
                entries.append(line)
    return entries

def has_code_reference(entry):
    """Return True if entry appears in any .rs/.sh/.py/.ts/.js/.toml/.yaml file
    outside the two allowlist files."""
    extensions = [
        "*.rs", "*.sh", "*.py", "*.ts", "*.js", "*.toml", "*.yaml", "*.yml"
    ]
    search_dirs = []
    for d in ["src", "crates", "scripts", "web"]:
        full = os.path.join(code_root, d)
        if os.path.isdir(full):
            search_dirs.append(full)

    if not search_dirs:
        return False

    # Build grep include flags.
    include_args = []
    for ext in extensions:
        include_args += ["--include", ext]

    cmd = ["grep", "-r", "-q", "-F", entry] + include_args + search_dirs
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            return False
        # At least one file matched; confirm it's not only the allowlist files.
        cmd_l = ["grep", "-r", "-l", "-F", entry] + include_args + search_dirs
        result_l = subprocess.run(cmd_l, capture_output=True, text=True)
        hits = [
            p for p in result_l.stdout.splitlines()
            if "event-registry-reserved.txt" not in p
            and "env-vars-internal.txt" not in p
        ]
        return len(hits) > 0
    except Exception:
        return False

# Collect all entries from both files.
all_entries = []
for path, source in [(reserved, "event-registry-reserved.txt"),
                     (envvars, "env-vars-internal.txt")]:
    for entry in parse_allowlist(path):
        all_entries.append({"entry": entry, "file": source})

new_state = {}
stale = []

for item in all_entries:
    key = f"{item['file']}:{item['entry']}"
    present = has_code_reference(item["entry"])
    old = state.get(key, {})

    if present:
        # Seen in code today — update last_seen, clear absent_since.
        new_state[key] = {"last_seen": today_ts, "absent_since": None}
    else:
        # Not seen in code today.
        absent_since = old.get("absent_since")
        last_seen    = old.get("last_seen")
        if absent_since is None:
            # First day we notice absence.
            absent_since = today_ts
        new_state[key] = {"last_seen": last_seen, "absent_since": absent_since}

        # Compute days absent.
        try:
            abs_dt = datetime.fromisoformat(absent_since.replace("Z", "+00:00"))
            days_absent = (today - abs_dt).days
        except Exception:
            days_absent = 0

        if days_absent >= stale_days:
            stale.append({
                "entry": item["entry"],
                "file":  item["file"],
                "days_since_seen": days_absent,
                "absent_since": absent_since,
                "last_seen": last_seen,
            })

print(json.dumps({
    "today": today_ts,
    "total_entries": len(all_entries),
    "stale_count": len(stale),
    "stale": stale,
    "new_state": new_state,
}, separators=(',', ':')))
PYEOF
)

STALE_COUNT=$(python3 -c "import json,sys; print(json.loads(sys.stdin.read())['stale_count'])" <<< "$REPORT")
NEW_STATE=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps(d['new_state']))" <<< "$REPORT")

# ── Persist updated state ─────────────────────────────────────────────────────
if [[ "$DRY_RUN" -eq 0 ]]; then
    printf '%s\n' "$NEW_STATE" > "$STATE_FILE"
fi

# ── JSON mode: print report and exit ─────────────────────────────────────────
if [[ "$JSON" -eq 1 ]]; then
    echo "$REPORT"
    if (( STALE_COUNT > 0 )); then exit 1; fi
    exit 0
fi

# ── Emit per-stale-entry ambient lines ───────────────────────────────────────
if [[ "$DRY_RUN" -eq 0 && "$STALE_COUNT" -gt 0 ]]; then
    python3 - <<PYEOF
import json, sys
d = json.loads('''$REPORT''')
ts = d['today']
with open("$AMBIENT_LOG", "a") as af:
    for s in d['stale']:
        ev = {
            'ts': ts,
            'kind': 'allowlist_stale_entry',
            'entry': s['entry'],
            'file': s['file'],
            'days_since_seen': s['days_since_seen'],
            'absent_since': s['absent_since'],
        }
        af.write(json.dumps(ev, separators=(',',':')) + '\n')
PYEOF
fi

# ── Human-readable summary ─────────────────────────────────────────────────────
SUMMARY=$(python3 - <<PYEOF
import json
d = json.loads('''$REPORT''')
if d['stale_count'] == 0:
    print(f"all {d['total_entries']} entries have recent code references — no stale entries")
else:
    out = [f"{d['stale_count']} of {d['total_entries']} entries stale (no code reference for 30+ days):"]
    for s in d['stale'][:10]:
        out.append(f"  - [{s['file']}] {s['entry']}  (absent {s['days_since_seen']}d since {s['absent_since']})")
    if d['stale_count'] > 10:
        out.append(f"  ... and {d['stale_count'] - 10} more")
    print('\n'.join(out))
PYEOF
)

printf '[audit-allowlist-staleness] %s\n' "$REPO_ROOT/scripts/ci/event-registry-reserved.txt + env-vars-internal.txt"
printf '%s\n' "$SUMMARY"

# ── Broadcast WARN if stale entries found ────────────────────────────────────
if [[ "$DRY_RUN" -eq 0 && "$STALE_COUNT" -gt 0 ]]; then
    bash "$REPO_ROOT/scripts/coord/broadcast.sh" WARN \
        --reason "[audit-allowlist-staleness] ${STALE_COUNT} stale allowlist entry(ies) — entries with no code reference for 30+ days. Run 'scripts/ops/audit-allowlist-staleness.sh --json' for details." \
        2>/dev/null || true
fi

if (( STALE_COUNT > 0 )); then exit 1; fi
exit 0
