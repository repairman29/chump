#!/usr/bin/env bash
# main-health-watchdog.sh — INFRA-1656
#
# CREDIBLE pillar daily watchdog. Detects red main and files a P0 gap so the
# next operator session inherits the diagnostic instead of discovering it the
# slow way (every subsequent PR's CI burning before someone notices).
#
# Background:
#   2026-05-20 → main-branch CI was red for ~24h with six distinct failure
#   classes (INFRA-1287 orphans, INFRA-682 skills-bundle path-filter,
#   DOC-026 env-var allowlist, INFRA-1274 raw-gh allowlist, INFRA-306 canonical
#   comment, etc). Each failure blocked every PR's CI until someone manually
#   fixed it. No watchdog flagged main itself.
#
# Algorithm:
#   1. Query the latest CI run on main:
#        gh run list --branch main --workflow CI --limit 1 \
#          --json conclusion,jobs,headSha,url,databaseId,createdAt
#   2. If conclusion = "success" → emit ambient (heartbeat) and exit.
#   3. If conclusion = "failure" → walk jobs[*].steps[*] for failed steps and
#      pick the first failing job's name as the "gate" label.
#   4. Dedup: scan open P0 INFRA-NEW-MAIN-RED-* gaps. If any one's notes
#      reference the same headSha, skip filing.
#   5. File a P0 gap titled  INFRA-NEW-MAIN-RED-<YYYY-MM-DD>: <gate>
#      with description linking run URL + failed step + headSha, and AC
#      instructing the next session how to triage.
#   6. Emit kind=main_red_detected to ambient.jsonl with fields:
#         gate, sha, run_url, head_sha, gap_id, dry_run, status
#
# Bypass:  CHUMP_MAIN_HEALTH_DISABLED=1
#
# Test hooks (used by scripts/ci/test-main-health-watchdog.sh):
#   CHUMP_MAIN_HEALTH_GH_BIN     — path to a stubbed `gh` binary
#   CHUMP_MAIN_HEALTH_CHUMP_BIN  — path to a stubbed `chump` binary
#   CHUMP_AMBIENT_LOG            — override ambient.jsonl path
#   CHUMP_MAIN_HEALTH_DRY_RUN=1  — walk all logic but skip the actual
#                                  `chump gap reserve`/`set` call
#
# Exit codes:
#   0  normal (whether or not a gap was filed; success or dedup or no_runs)
#   0  bypass via CHUMP_MAIN_HEALTH_DISABLED
#   2  internal failure (gh unavailable / malformed response / reserve failed)

set -euo pipefail

# ── Bypass ───────────────────────────────────────────────────────────────────
if [[ "${CHUMP_MAIN_HEALTH_DISABLED:-0}" == "1" ]]; then
    echo "[main-health-watchdog] CHUMP_MAIN_HEALTH_DISABLED=1 — exiting"
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
DRY_RUN="${CHUMP_MAIN_HEALTH_DRY_RUN:-0}"

GH_BIN="${CHUMP_MAIN_HEALTH_GH_BIN:-gh}"
CHUMP_BIN="${CHUMP_MAIN_HEALTH_CHUMP_BIN:-chump}"

mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true

emit_ambient() {
    # emit_ambient <kind> <key=value> [key=value ...]
    local kind="$1"; shift
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local extra=""
    local kv k v
    for kv in "$@"; do
        k="${kv%%=*}"
        v="${kv#*=}"
        v="${v//\\/\\\\}"
        v="${v//\"/\\\"}"
        extra+=",\"${k}\":\"${v}\""
    done
    printf '{"ts":"%s","kind":"%s","emitter":"main-health-watchdog"%s}\n' \
        "$ts" "$kind" "$extra" >> "$AMBIENT_LOG"
}

# ── 1. Query latest CI run on main ───────────────────────────────────────────
RUN_JSON_FILE="$(mktemp)"
trap 'rm -f "$RUN_JSON_FILE" "${PARSE_OUT:-}" "${DEDUP_IN:-}" "${DEDUP_OUT:-}"' EXIT

"$GH_BIN" run list \
    --branch main \
    --workflow CI \
    --limit 1 \
    --json conclusion,headSha,url,databaseId,jobs,createdAt \
    > "$RUN_JSON_FILE" 2>/dev/null \
    || true

if [[ ! -s "$RUN_JSON_FILE" ]] || [[ "$(cat "$RUN_JSON_FILE")" == "[]" ]]; then
    echo "[main-health-watchdog] no recent CI run on main; nothing to do"
    emit_ambient main_red_detected gate=none sha=none run_url=none head_sha=none gap_id=none dry_run=0 status=no_runs
    exit 0
fi

# ── 2. Parse the run JSON ────────────────────────────────────────────────────
PARSE_OUT="$(mktemp)"
PARSE_SCRIPT="$(mktemp)"
cat > "$PARSE_SCRIPT" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    raw = f.read()
try:
    arr = json.loads(raw)
except json.JSONDecodeError as e:
    sys.stderr.write("PARSE_ERROR:" + str(e) + "\n")
    sys.exit(2)
if not arr:
    print("NO_RUNS")
    sys.exit(0)
r = arr[0]
conclusion = r.get("conclusion") or "unknown"
head_sha = r.get("headSha") or ""
url = r.get("url") or ""
created = r.get("createdAt") or ""
gate = "unknown"
failed_step = ""
for job in (r.get("jobs") or []):
    if (job.get("conclusion") or "") != "failure":
        continue
    for step in (job.get("steps") or []):
        if (step.get("conclusion") or "") == "failure":
            gate = job.get("name") or "unknown"
            failed_step = step.get("name") or ""
            break
    if gate != "unknown":
        break
print(conclusion + "\t" + head_sha + "\t" + url + "\t" + created + "\t" + gate + "\t" + failed_step)
PYEOF

if ! python3 "$PARSE_SCRIPT" "$RUN_JSON_FILE" > "$PARSE_OUT" 2>/dev/null; then
    echo "[main-health-watchdog] failed to parse gh JSON" >&2
    rm -f "$PARSE_SCRIPT"
    exit 2
fi
rm -f "$PARSE_SCRIPT"

PARSED="$(cat "$PARSE_OUT")"

if [[ "$PARSED" == "NO_RUNS" ]]; then
    echo "[main-health-watchdog] gh returned empty run list"
    emit_ambient main_red_detected gate=none sha=none run_url=none head_sha=none gap_id=none dry_run=0 status=no_runs
    exit 0
fi

IFS=$'\t' read -r CONCLUSION HEAD_SHA RUN_URL CREATED GATE FAILED_STEP <<<"$PARSED"

echo "[main-health-watchdog] latest CI run on main: conclusion=$CONCLUSION sha=${HEAD_SHA:0:12} gate=$GATE"

# ── 3. Success path ─────────────────────────────────────────────────────────
if [[ "$CONCLUSION" != "failure" ]]; then
    # Heartbeat — emit on success too so consumers can prove the watchdog is
    # alive (same pattern as orphan-reaper count=0 events).
    emit_ambient main_red_detected \
        gate=none \
        sha="${HEAD_SHA:0:12}" \
        run_url="$RUN_URL" \
        head_sha="$HEAD_SHA" \
        gap_id=none \
        dry_run=0 \
        status="$CONCLUSION"
    exit 0
fi

# ── 4. Dedup against existing open MAIN-RED gaps ─────────────────────────────
# Stash the open-gap JSON in a file and grep with python for the sha-in-notes
# match. Match a gap iff: P0 AND title contains MAIN-RED- AND notes contains
# the head_sha.
DEDUP_IN="$(mktemp)"
DEDUP_OUT="$(mktemp)"
DEDUP_SCRIPT="$(mktemp)"

"$CHUMP_BIN" gap list --status open --json > "$DEDUP_IN" 2>/dev/null || true

cat > "$DEDUP_SCRIPT" <<'PYEOF'
import json, sys
path = sys.argv[1]
target_sha = sys.argv[2]
try:
    with open(path) as f:
        gaps = json.load(f)
except Exception:
    sys.exit(0)
for g in gaps:
    title = g.get("title") or ""
    notes = g.get("notes") or ""
    priority = g.get("priority") or ""
    if "MAIN-RED-" not in title:
        continue
    if priority != "P0":
        continue
    if target_sha and target_sha in notes:
        print(g.get("id"))
        sys.exit(0)
PYEOF

if [[ -s "$DEDUP_IN" ]]; then
    python3 "$DEDUP_SCRIPT" "$DEDUP_IN" "$HEAD_SHA" > "$DEDUP_OUT" 2>/dev/null || true
fi
rm -f "$DEDUP_SCRIPT"

DEDUP_HIT="$(cat "$DEDUP_OUT" 2>/dev/null | tr -d '[:space:]')"

if [[ -n "$DEDUP_HIT" ]]; then
    echo "[main-health-watchdog] dedup hit: $DEDUP_HIT already filed for sha ${HEAD_SHA:0:12}; not re-filing"
    emit_ambient main_red_detected \
        gate="$GATE" \
        sha="${HEAD_SHA:0:12}" \
        run_url="$RUN_URL" \
        head_sha="$HEAD_SHA" \
        gap_id="$DEDUP_HIT" \
        dry_run="$DRY_RUN" \
        status=deduped
    exit 0
fi

# ── 5. File the P0 gap ───────────────────────────────────────────────────────
TODAY="$(date -u +%Y-%m-%d)"
GATE_FLAT="$(printf '%s' "$GATE" | tr '|"\n\r' '/   ' | tr -s ' ')"
TITLE="INFRA-NEW-MAIN-RED-${TODAY}: ${GATE_FLAT}"

DESCRIPTION="Daily main-health watchdog (INFRA-1656) detected red CI on main.
Run URL: ${RUN_URL}
Head SHA: ${HEAD_SHA}
Failed gate: ${GATE}
Failed step: ${FAILED_STEP:-<unknown>}
Detected at: $(date -u +%Y-%m-%dT%H:%M:%SZ)

Every PR opened against main inherits this failure on rebase or branch-update. Triage immediately: open the run URL, identify the failing test or gate, and either revert the offending commit or file a follow-up fix-gap.

Dedup token (do NOT remove from notes): sha=${HEAD_SHA}"

AC="Root-cause identified for failing gate ${GATE_FLAT}|Fix PR opened and merged (or offending commit reverted)|main CI back to green on a fresh empty-change PR|This gap closed with --closed-pr <N>"

if [[ "$DRY_RUN" == "1" ]]; then
    echo "[main-health-watchdog] DRY_RUN — would file: $TITLE"
    GAP_ID="DRY-RUN"
else
    RESERVE_OUT="$("$CHUMP_BIN" gap reserve --domain INFRA --title "$TITLE" --priority P0 --effort xs 2>&1 || true)"
    GAP_ID="$(printf '%s\n' "$RESERVE_OUT" | tail -1 | tr -d '[:space:]')"
    if [[ -z "$GAP_ID" || ! "$GAP_ID" =~ ^[A-Z]+-[0-9]+$ ]]; then
        echo "[main-health-watchdog] reserve failed; output: $RESERVE_OUT" >&2
        emit_ambient main_red_detected \
            gate="$GATE" \
            sha="${HEAD_SHA:0:12}" \
            run_url="$RUN_URL" \
            head_sha="$HEAD_SHA" \
            gap_id=none \
            dry_run="$DRY_RUN" \
            status=reserve_failed
        exit 2
    fi
    "$CHUMP_BIN" gap set "$GAP_ID" \
        --description "$DESCRIPTION" \
        --notes "sha=${HEAD_SHA} watchdog=main-health (INFRA-1656)" \
        --acceptance-criteria "$AC" \
        >/dev/null 2>&1 || {
            echo "[main-health-watchdog] WARN: gap set partial-failure for $GAP_ID" >&2
        }
    echo "[main-health-watchdog] filed $GAP_ID for $TITLE"
fi

emit_ambient main_red_detected \
    gate="$GATE" \
    sha="${HEAD_SHA:0:12}" \
    run_url="$RUN_URL" \
    head_sha="$HEAD_SHA" \
    gap_id="$GAP_ID" \
    dry_run="$DRY_RUN" \
    status=filed

exit 0
