#!/usr/bin/env bash
# scripts/coord/trunk-sentinel-daemon.sh — Trunk Health Sentinel daemon
#
# Detects when main's ci.yml conclusion has been non-success for >N minutes
# and autonomously triggers fix-class actions: file a fix-trunk gap, dispatch
# a Sonnet sub-agent via the typed CodeFixContract pattern (shell-out to
# `claude -p`), and at the halt-class threshold page the operator via
# scripts/dispatch/operator-recall.sh (T4 doctrine).
#
# Pillars: RESILIENT + ZERO-WASTE. A red trunk that nobody notices for an
# hour burns runners on PRs that can't merge, and stalls every fleet ship.
# This daemon closes that observation gap autonomously.
#
# State machine:
#   TRUNK_GREEN              last main ci.yml run conclusion=success → no action
#   TRUNK_AMBER              last run is queued/in_progress AND prev was green → wait
#   TRUNK_RED <  5 min       emit trunk_state_change once, wait (cooldown)
#   TRUNK_RED  5-15 min      file fix-trunk gap (idempotent via failing-job fingerprint)
#   TRUNK_RED 15+ min        also write brief + shell out to `claude -p` (CodeFixContract)
#   TRUNK_RED 60+ min        also emit trunk_red_operator_recall via operator-recall.sh
#
# Idempotency: a sha256 fingerprint of the sorted failing-job list is used as
# the dedup key for both the gap-filing step and the sub-agent dispatch step.
# Same fingerprint → no re-spam. Different fingerprint (e.g. new failing job
# appears) → new gap + new dispatch.
#
# Recovery: when main goes green again, emits kind=trunk_recovered and walks
# the open gaps with skills_required containing "fix_trunk" — closes the ones
# this daemon filed (state file tracks our filings).
#
# scanner-anchor: "kind":"trunk_state_change"
# scanner-anchor: "kind":"trunk_red_persistent"
# scanner-anchor: "kind":"trunk_red_dispatch"
# scanner-anchor: "kind":"trunk_red_operator_recall"
# scanner-anchor: "kind":"trunk_recovered"
# scanner-anchor: "kind":"trunk_sentinel_tick"
#
# Usage:
#   bash scripts/coord/trunk-sentinel-daemon.sh tick        # one tick
#   bash scripts/coord/trunk-sentinel-daemon.sh --help
#
# Env knobs (all optional):
#   CHUMP_TRUNK_SENTINEL_DRY_RUN          non-empty → no gh/chump writes (default unset)
#   CHUMP_TRUNK_SENTINEL_RED_FILE_S       seconds RED before filing gap (default 300 = 5m)
#   CHUMP_TRUNK_SENTINEL_RED_DISPATCH_S   seconds RED before dispatching Sonnet (default 900 = 15m)
#   CHUMP_TRUNK_SENTINEL_RED_RECALL_S     seconds RED before operator-recall (default 3600 = 60m)
#   CHUMP_TRUNK_SENTINEL_STATE_FILE       state-tracking path (default $CHUMP/.chump/trunk-sentinel-state.json)
#   CHUMP_TRUNK_SENTINEL_MOCK_RUN_JSON    path to a JSON fixture (test-mode only)
#   CHUMP_AMBIENT_PATH                    override ambient.jsonl path (META-248)
#   CHUMP_AMBIENT_LOG                     legacy alias for CHUMP_AMBIENT_PATH

set -uo pipefail

# ── Resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# META-248: honor CHUMP_AMBIENT_PATH first, CHUMP_AMBIENT_LOG legacy alias second.
AMBIENT="${CHUMP_AMBIENT_PATH:-${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}}"
mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true

CACHE_DB="${CHUMP_CACHE_DB:-$REPO_ROOT/.chump/github_cache.db}"

# ── Configuration ─────────────────────────────────────────────────────────────
DRY_RUN="${CHUMP_TRUNK_SENTINEL_DRY_RUN:-}"
RED_FILE_S="${CHUMP_TRUNK_SENTINEL_RED_FILE_S:-300}"
RED_DISPATCH_S="${CHUMP_TRUNK_SENTINEL_RED_DISPATCH_S:-900}"
RED_RECALL_S="${CHUMP_TRUNK_SENTINEL_RED_RECALL_S:-3600}"
STATE_FILE="${CHUMP_TRUNK_SENTINEL_STATE_FILE:-$REPO_ROOT/.chump/trunk-sentinel-state.json}"
MOCK_RUN_JSON="${CHUMP_TRUNK_SENTINEL_MOCK_RUN_JSON:-}"

mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true

CHUMP_BIN="${CHUMP_TRUNK_SENTINEL_CHUMP_CMD:-chump}"
OPERATOR_RECALL_SCRIPT="$REPO_ROOT/scripts/dispatch/operator-recall.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_now_epoch() { date +%s; }
log() { printf '[trunk-sentinel] %s\n' "$*" >&2; }

emit() {
    # Args: $1=kind  $2=extra-json-fields (no leading comma)
    local kind="$1" extra="${2:-}"
    local ts; ts="$(_ts)"
    local dry; if [[ -n "$DRY_RUN" ]]; then dry="true"; else dry="false"; fi
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"dry_run\":$dry,$extra}"
    else
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"dry_run\":$dry}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT"
}

# Read the persisted state JSON (or emit a green default if file missing).
_load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE" 2>/dev/null || echo '{}'
    else
        echo '{}'
    fi
}

_save_state() {
    local body="$1"
    printf '%s\n' "$body" > "$STATE_FILE"
}

# Fingerprint = sha256(sorted failing-job names, comma-joined), first 12 chars.
# Same failure pattern → same fingerprint → idempotent gap/dispatch.
_failing_fingerprint() {
    local jobs_csv="$1"
    if [[ -z "$jobs_csv" ]]; then
        printf 'nofail'
        return
    fi
    printf '%s' "$jobs_csv" \
        | tr ',' '\n' \
        | sort \
        | tr '\n' ',' \
        | shasum -a 256 \
        | cut -c1-12
}

# ── (1) Fetch the latest main ci.yml run ─────────────────────────────────────
# Strategy (per CLAUDE.md INFRA-1081): cache-first, REST fallback.
#  - If CHUMP_TRUNK_SENTINEL_MOCK_RUN_JSON is set, parse that file (test mode).
#  - Else: call `gh run list --branch main --workflow=ci.yml --limit 1 --json …`.
#    The cache only stores per-SHA check-runs (not workflow_runs by branch),
#    so the cheapest path for "latest main run" is one REST list call per tick.
#  - We background-tag the call so it yields the GH bucket to ship-blocking
#    writes when quota is tight (INFRA-1080).
#
# Output: JSON object on stdout with keys: run_id, head_sha, conclusion,
# status, created_at, html_url, failing_jobs (sorted CSV of failing job names).
# Empty object {} on hard failure.
_fetch_main_run() {
    if [[ -n "$MOCK_RUN_JSON" && -f "$MOCK_RUN_JSON" ]]; then
        cat "$MOCK_RUN_JSON"
        return
    fi

    # 1. Get the latest ci.yml run on main (one row).
    local runs_raw
    runs_raw=$(CHUMP_GH_CALL_CRITICALITY=background \
        gh run list --branch main --workflow=ci.yml --limit 1 \
        --json databaseId,headSha,conclusion,status,createdAt,url 2>/dev/null \
        || echo "[]")

    # 2. Parse + (if conclusion=failure) fetch failing-job names via the cache
    #    when possible, REST fallback when not.
    # NOTE: shellcheck SC2259 — we pass runs_raw via env var because a heredoc
    # (the program) and a pipe (the data) can't both feed stdin.
    local cache_db="$CACHE_DB"
    RUNS_RAW="$runs_raw" CACHE_DB="$cache_db" python3 <<'PYEOF' 2>/dev/null || echo '{}'
import json, os, sqlite3, subprocess
runs = json.loads(os.environ.get("RUNS_RAW", "") or "[]")
cache_db = os.environ.get("CACHE_DB", "")
if not runs:
    print("{}")
    raise SystemExit(0)

r = runs[0]
run_id = r.get("databaseId", 0)
head_sha = r.get("headSha", "")
conclusion = r.get("conclusion", "") or ""
status = r.get("status", "") or ""
created_at = r.get("createdAt", "")
html_url = r.get("url", "")

failing_jobs = []
if conclusion == "failure" and head_sha:
    # Cache-first: check_runs table is keyed by head_sha.
    try:
        conn = sqlite3.connect(cache_db)
        cur = conn.cursor()
        rows = cur.execute(
            "SELECT name, conclusion FROM check_runs WHERE head_sha=? "
            "AND conclusion IN ('failure','timed_out','cancelled','action_required')",
            (head_sha,),
        ).fetchall()
        failing_jobs = sorted(name for (name, _) in rows if name)
        conn.close()
    except Exception:
        failing_jobs = []
    # REST fallback if cache empty.
    if not failing_jobs:
        try:
            out = subprocess.run(
                ["gh", "run", "view", str(run_id), "--json", "jobs"],
                capture_output=True, text=True, timeout=20,
                env={**__import__("os").environ, "CHUMP_GH_CALL_CRITICALITY": "background"},
            )
            if out.returncode == 0:
                data = json.loads(out.stdout or "{}")
                failing_jobs = sorted(
                    j.get("name", "") for j in (data.get("jobs") or [])
                    if j.get("conclusion") in ("failure", "timed_out", "cancelled", "action_required")
                    and j.get("name")
                )
        except Exception:
            pass

print(json.dumps({
    "run_id": run_id,
    "head_sha": head_sha,
    "conclusion": conclusion,
    "status": status,
    "created_at": created_at,
    "html_url": html_url,
    "failing_jobs": ",".join(failing_jobs),
}))
PYEOF
}

# ── (2) Derive trunk state from the run JSON ─────────────────────────────────
# Returns one of: TRUNK_GREEN, TRUNK_AMBER, TRUNK_RED, TRUNK_UNKNOWN
_derive_state() {
    local run_json="$1"
    printf '%s' "$run_json" | python3 -c "
import json, sys
try:
    r = json.loads(sys.stdin.read() or '{}')
except Exception:
    r = {}
conclusion = (r.get('conclusion') or '').lower()
status = (r.get('status') or '').lower()
if not r:
    print('TRUNK_UNKNOWN')
elif conclusion == 'success':
    print('TRUNK_GREEN')
elif conclusion == 'failure' or conclusion in ('timed_out', 'cancelled', 'action_required'):
    print('TRUNK_RED')
elif status in ('queued', 'in_progress', 'requested', 'waiting', 'pending'):
    print('TRUNK_AMBER')
else:
    print('TRUNK_UNKNOWN')
" 2>/dev/null
}

# ── (3) File a fix-trunk gap (idempotent via fingerprint) ────────────────────
_file_fix_trunk_gap() {
    local fingerprint="$1" run_id="$2" head_sha="$3" failing_csv="$4" red_minutes="$5"

    if [[ -n "$DRY_RUN" ]]; then
        log "DRY_RUN: would file fix-trunk gap (fp=$fingerprint, jobs=$failing_csv)"
        printf 'INFRA-DRYRUN-%s' "$fingerprint"
        return 0
    fi

    local title
    title="RESILIENT: trunk red — main ci.yml failing on [${failing_csv:-unknown}] (fp=${fingerprint})"

    local description
    description="$(cat <<DESC
Trunk-sentinel detected main ci.yml has been RED for ${red_minutes}m.

  - Run ID: ${run_id}
  - Head SHA: ${head_sha}
  - Failing jobs: ${failing_csv:-unknown}
  - Fingerprint: ${fingerprint}

This gap was auto-filed by scripts/coord/trunk-sentinel-daemon.sh. The
fingerprint above is sha256(sorted failing-job names) so a second tick with
the same failure set will NOT re-file. A different failure pattern (a new
failing job appears) WILL file a new gap.

Recommended workflow:
  1. Inspect the run: gh run view ${run_id}
  2. Identify the root commit (gh log origin/main --oneline -5).
  3. Either revert the offending commit OR file a forward fix.
  4. When main is green again the sentinel will emit trunk_recovered and
     close this gap.

This is a fleet-halt-class wedge: every other PR currently in flight will
land BEHIND a red trunk; bot-merge will refuse to arm new ones until green.
DESC
)"

    # INFRA-2337: `chump gap reserve` only persists domain+title+priority+effort
    # (see src/main.rs:7683 reserve_verified signature). --description and
    # --skills-required are PARSED but SILENTLY DROPPED — the flags never reach
    # the gap row. Backfill via `chump gap set` after reserve.
    local out exit_code gap_id
    out="$(CHUMP_IGNORE_WASTE_PAUSE=1 CHUMP_GAP_RESERVE_NO_SIMILARITY=1 FLEET_029_AMBIENT_GLANCE_SKIP=1 \
        "$CHUMP_BIN" gap reserve \
        --domain INFRA \
        --priority P0 \
        --effort s \
        --title "$title" \
        --force-duplicate 2>&1)" || exit_code=$?
    exit_code="${exit_code:-0}"

    gap_id="$(printf '%s' "$out" | grep -oE 'INFRA-[0-9]+' | head -1)"
    if [[ -n "$gap_id" ]]; then
        log "filed fix-trunk gap: $gap_id (fp=$fingerprint)"

        # Backfill skills_required + description via `chump gap set` (the
        # canonical store.set_fields path; src/main.rs:8538). Both fields are
        # load-bearing: the dispatcher's SQL filter is
        # `WHERE skills_required LIKE '%fix_trunk%'`, so missing the tag means
        # the dispatcher won't find this gap. Description carries the run-id +
        # fingerprint context the Sonnet sub-agent needs.
        if ! "$CHUMP_BIN" gap set "$gap_id" \
            --skills-required "fix_trunk,ci_repair" \
            --description "$description" >/dev/null 2>&1; then
            log "WARN: failed to backfill skills_required/description on $gap_id"
        fi

        printf '%s' "$gap_id"
    else
        log "WARN: gap reserve failed (exit=$exit_code): $out"
        printf 'UNFILED'
    fi
}

# ── (4) Dispatch a Sonnet sub-agent via CodeFixContract pattern ─────────────
# Writes a brief markdown to .chump/trunk-sentinel-briefs/<fp>.md then shells
# out to `claude -p` with the brief on stdin. Emits trunk_red_dispatch with
# the brief path so a human can inspect after the fact.
_dispatch_sonnet() {
    local fingerprint="$1" run_id="$2" head_sha="$3" failing_csv="$4" gap_id="$5"

    local briefs_dir="$REPO_ROOT/.chump/trunk-sentinel-briefs"
    mkdir -p "$briefs_dir" 2>/dev/null || true
    local brief_path="$briefs_dir/${fingerprint}.md"

    # Pick a representative failing job for the CodeFixContract file_path hint.
    # We use the first failing job name; the sub-agent will read CI logs from
    # there to triangulate the actual offending file.
    local first_job
    first_job="$(printf '%s' "$failing_csv" | tr ',' '\n' | head -1)"

    cat > "$brief_path" <<BRIEF
# Trunk Sentinel — fix-trunk dispatch (fp=${fingerprint})

You are Sonnet. Trunk main is RED. Diagnose + draft a fix.

## Symptom

main's ci.yml workflow has been failing for >15 minutes. Failing job(s):

\`\`\`
${failing_csv}
\`\`\`

The first failing job — use as your starting investigation point — is:

\`\`\`
${first_job}
\`\`\`

Run / commit references:

  - Run ID: ${run_id}
  - Head SHA: ${head_sha}
  - Filed gap: ${gap_id}

## What we need from you

This is a CodeFixContract-shaped dispatch (per
\`crates/chump-handoff/src/contracts.rs\`). Output a single fenced JSON block
of the shape:

\`\`\`json
{
  "unified_diff": "diff --git a/<path> b/<path>\n--- a/<path>\n+++ b/<path>\n@@ ... @@\n...",
  "files_touched": ["path/relative/to/repo/root", ...],
  "tests_added": ["path/to/test/file", ...]
}
\`\`\`

Rules (from CodeFixContract):

  - \`unified_diff\` MUST start with \`diff --git\` (or \`---\` for a pure
    file-add) and be appliable via \`git apply\`.
  - \`files_touched\` MUST list every file the diff modifies — the parent
    uses this to check for lease collisions before applying.
  - \`tests_added\` MAY be empty if the fix is too small to need a new test,
    but prefer adding one.

## Investigation steps

  1. \`gh run view ${run_id} --log\` to read the failure output.
  2. Identify the offending file + commit.
  3. Read the file, infer the minimal diff.
  4. If the fix is a revert: prefer that.
  5. If the fix requires new logic: keep the diff < 30 lines.

## STOP conditions

  - If you cannot identify the offending file in 10 minutes → exit with a
    plain-text "STOP: ${first_job} root cause not isolable from logs;
    needs operator" and do NOT emit a JSON block.
  - If the fix needs > 30 lines of new code → STOP and recommend an operator
    decompose instead.

## Pre-push checklist (paste into the PR body)

  - [ ] cargo fmt --all -- --check
  - [ ] cargo clippy --workspace --all-targets -- -D warnings
  - [ ] cargo check --workspace
  - [ ] relevant scripts/ci/test-*.sh passes locally
  - [ ] No \`--no-verify\` used
BRIEF

    log "wrote sub-agent brief: $brief_path"

    if [[ -n "$DRY_RUN" ]]; then
        log "DRY_RUN: skipping claude -p dispatch"
        emit "trunk_red_dispatch" \
            "\"fingerprint\":\"$fingerprint\",\"run_id\":$run_id,\"head_sha\":\"$head_sha\",\"gap_id\":\"$gap_id\",\"brief_path\":\"$brief_path\",\"dispatched\":false"
        return 0
    fi

    # Background dispatch via claude -p — we don't block the tick on it.
    # The sub-agent runs to completion in its own process; we just record
    # that we triggered it. The brief file is the audit trail.
    if command -v claude >/dev/null 2>&1; then
        # INFRA-2340: OAUTH defensive read — see fix-trunk-dispatcher.sh
        # for full rationale. launchd may not pass CLAUDE_CODE_OAUTH_TOKEN
        # through; we read from ~/.chump/oauth-token.json (refreshed every
        # 5 min, mode 0600) if neither auth env var is set. Token length
        # is the only thing ever logged.
        if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" && -z "${ANTHROPIC_API_KEY:-}" ]]; then
            if [[ -r "$HOME/.chump/oauth-token.json" ]]; then
                local _tok
                _tok=$(python3 -c "import json; print(json.load(open('$HOME/.chump/oauth-token.json')).get('token',''))" 2>/dev/null)
                if [[ -n "$_tok" ]]; then
                    export CLAUDE_CODE_OAUTH_TOKEN="$_tok"
                    log "loaded CLAUDE_CODE_OAUTH_TOKEN from ~/.chump/oauth-token.json (len=${#_tok})"
                fi
                unset _tok
            else
                log "WARN: no CLAUDE_CODE_OAUTH_TOKEN, no ANTHROPIC_API_KEY, no readable ~/.chump/oauth-token.json — Sonnet may 401"
            fi
        fi
        (
            # 15-minute hard timeout via gtimeout if available; otherwise
            # rely on claude -p's own internal timeout.
            local _timeout="gtimeout 900"
            command -v gtimeout >/dev/null 2>&1 || _timeout=""
            cat "$brief_path" | $_timeout claude -p --bare \
                > "$briefs_dir/${fingerprint}.response.txt" 2>&1 || true
        ) &
        disown 2>/dev/null || true
        log "dispatched Sonnet (background pid)"
        emit "trunk_red_dispatch" \
            "\"fingerprint\":\"$fingerprint\",\"run_id\":$run_id,\"head_sha\":\"$head_sha\",\"gap_id\":\"$gap_id\",\"brief_path\":\"$brief_path\",\"dispatched\":true"
    else
        log "WARN: claude CLI not in PATH — skipping sub-agent dispatch"
        emit "trunk_red_dispatch" \
            "\"fingerprint\":\"$fingerprint\",\"run_id\":$run_id,\"head_sha\":\"$head_sha\",\"gap_id\":\"$gap_id\",\"brief_path\":\"$brief_path\",\"dispatched\":false,\"reason\":\"claude_cli_missing\""
    fi
}

# ── (5) Operator-recall (T4 halt-class) ──────────────────────────────────────
_operator_recall_trunk() {
    local fingerprint="$1" run_id="$2" head_sha="$3" failing_csv="$4" red_minutes="$5"

    emit "trunk_red_operator_recall" \
        "\"fingerprint\":\"$fingerprint\",\"run_id\":$run_id,\"head_sha\":\"$head_sha\",\"red_minutes\":$red_minutes,\"failing_jobs\":\"$failing_csv\""

    if [[ -n "$DRY_RUN" ]]; then
        log "DRY_RUN: would call operator-recall for trunk_red ($red_minutes min)"
        return 0
    fi

    if [[ -x "$OPERATOR_RECALL_SCRIPT" ]]; then
        "$OPERATOR_RECALL_SCRIPT" --condition CI_BROKEN \
            --reason "trunk red ${red_minutes}m: jobs=[${failing_csv}] run=${run_id}" \
            >/dev/null 2>&1 || log "WARN: operator-recall.sh exit non-zero"
    else
        log "WARN: $OPERATOR_RECALL_SCRIPT missing or not executable"
    fi
}

# ── (6) Recovery: close fix-trunk gaps this daemon filed ─────────────────────
# Reads state.last_filed_gaps[] and closes each via `chump gap set --status done`.
_recover_close_gaps() {
    local prev_state="$1"
    local filed_csv
    filed_csv="$(printf '%s' "$prev_state" | python3 -c "
import json, sys
try:
    s = json.loads(sys.stdin.read() or '{}')
    print(','.join(s.get('filed_gaps', [])))
except Exception:
    pass
" 2>/dev/null || true)"

    if [[ -z "$filed_csv" ]]; then
        return 0
    fi

    local closed=0 g
    local IFS=','
    for g in $filed_csv; do
        [[ -z "$g" || "$g" == "UNFILED" || "$g" == INFRA-DRYRUN-* ]] && continue
        if [[ -n "$DRY_RUN" ]]; then
            log "DRY_RUN: would close $g (trunk recovered)"
            closed=$((closed + 1))
            continue
        fi
        # shellcheck disable=SC1010  # `done` here is chump-gap-set status literal, not a do/done close.
        if "$CHUMP_BIN" gap set "$g" --status "done" >/dev/null 2>&1; then
            log "closed $g (trunk recovered)"
            closed=$((closed + 1))
        else
            log "WARN: failed to close $g"
        fi
    done

    if [[ "$closed" -gt 0 ]]; then
        emit "trunk_recovered" "\"closed_gaps_count\":$closed,\"closed_gaps\":\"$filed_csv\""
    else
        emit "trunk_recovered" "\"closed_gaps_count\":0"
    fi
}

# ── (7) Tick — the main reconcile loop, one iteration ────────────────────────
cmd_tick() {
    local run_json
    run_json="$(_fetch_main_run)"

    local cur_state run_id head_sha conclusion failing_csv
    cur_state="$(_derive_state "$run_json")"
    run_id="$(printf '%s' "$run_json" | python3 -c "import json,sys; print(json.loads(sys.stdin.read() or '{}').get('run_id', 0))" 2>/dev/null || echo 0)"
    head_sha="$(printf '%s' "$run_json" | python3 -c "import json,sys; print(json.loads(sys.stdin.read() or '{}').get('head_sha', ''))" 2>/dev/null || echo "")"
    conclusion="$(printf '%s' "$run_json" | python3 -c "import json,sys; print(json.loads(sys.stdin.read() or '{}').get('conclusion', ''))" 2>/dev/null || echo "")"
    failing_csv="$(printf '%s' "$run_json" | python3 -c "import json,sys; print(json.loads(sys.stdin.read() or '{}').get('failing_jobs', ''))" 2>/dev/null || echo "")"

    local fingerprint
    fingerprint="$(_failing_fingerprint "$failing_csv")"

    local prev_state prev_state_str prev_red_since prev_filed_fps prev_filed_gaps prev_dispatched_fps prev_recalled_fps
    prev_state_str="$(_load_state)"
    prev_state="$(printf '%s' "$prev_state_str" | python3 -c "
import json, sys
try:
    s = json.loads(sys.stdin.read() or '{}')
except Exception:
    s = {}
print(s.get('state', 'TRUNK_UNKNOWN'))
" 2>/dev/null)"
    prev_red_since="$(printf '%s' "$prev_state_str" | python3 -c "
import json, sys
try:
    s = json.loads(sys.stdin.read() or '{}')
except Exception:
    s = {}
print(s.get('red_since_epoch', 0))
" 2>/dev/null)"
    prev_red_since="${prev_red_since:-0}"

    local now_epoch; now_epoch="$(_now_epoch)"

    emit "trunk_sentinel_tick" \
        "\"state\":\"$cur_state\",\"prev_state\":\"$prev_state\",\"run_id\":$run_id,\"head_sha\":\"$head_sha\",\"conclusion\":\"$conclusion\",\"fingerprint\":\"$fingerprint\""

    # ── State transition: log every change ────────────────────────────────────
    if [[ "$cur_state" != "$prev_state" ]]; then
        emit "trunk_state_change" \
            "\"from\":\"$prev_state\",\"to\":\"$cur_state\",\"conclusion\":\"$conclusion\",\"run_id\":$run_id,\"head_sha\":\"$head_sha\""
        log "state: $prev_state → $cur_state (run=$run_id conclusion=$conclusion)"
    fi

    # ── TRUNK_GREEN: recover, reset state ─────────────────────────────────────
    if [[ "$cur_state" == "TRUNK_GREEN" ]]; then
        # If we were RED, close any gaps we filed.
        if [[ "$prev_state" == "TRUNK_RED" ]]; then
            _recover_close_gaps "$prev_state_str"
        fi
        _save_state "$(printf '{"state":"TRUNK_GREEN","red_since_epoch":0,"filed_fingerprints":[],"filed_gaps":[],"dispatched_fingerprints":[],"recalled_fingerprints":[],"last_run_id":%d,"last_head_sha":"%s","updated_at":"%s"}' \
            "$run_id" "$head_sha" "$(_ts)")"
        return 0
    fi

    # ── TRUNK_AMBER / TRUNK_UNKNOWN: just persist + wait ──────────────────────
    if [[ "$cur_state" == "TRUNK_AMBER" || "$cur_state" == "TRUNK_UNKNOWN" ]]; then
        _save_state "$(printf '%s' "$prev_state_str" | python3 -c "
import json, sys
try:
    s = json.loads(sys.stdin.read() or '{}')
except Exception:
    s = {}
s['state'] = '$cur_state'
s['last_run_id'] = $run_id
s['last_head_sha'] = '$head_sha'
s['updated_at'] = '$(_ts)'
print(json.dumps(s))
" 2>/dev/null)"
        return 0
    fi

    # ── TRUNK_RED: time-bucketed actions ──────────────────────────────────────
    # Compute red_since_epoch (sticky on first RED tick).
    if [[ "$prev_state" != "TRUNK_RED" || "$prev_red_since" -eq 0 ]]; then
        prev_red_since="$now_epoch"
    fi
    local red_age_s=$(( now_epoch - prev_red_since ))
    local red_minutes=$(( red_age_s / 60 ))

    log "TRUNK_RED for ${red_minutes}m (fp=$fingerprint failing=[$failing_csv])"

    # Load fingerprint dedup sets.
    prev_filed_fps="$(printf '%s' "$prev_state_str" | python3 -c "
import json, sys
try:
    s = json.loads(sys.stdin.read() or '{}')
except Exception:
    s = {}
print(','.join(s.get('filed_fingerprints', [])))
" 2>/dev/null)"
    prev_filed_gaps="$(printf '%s' "$prev_state_str" | python3 -c "
import json, sys
try:
    s = json.loads(sys.stdin.read() or '{}')
except Exception:
    s = {}
print(','.join(s.get('filed_gaps', [])))
" 2>/dev/null)"
    prev_dispatched_fps="$(printf '%s' "$prev_state_str" | python3 -c "
import json, sys
try:
    s = json.loads(sys.stdin.read() or '{}')
except Exception:
    s = {}
print(','.join(s.get('dispatched_fingerprints', [])))
" 2>/dev/null)"
    prev_recalled_fps="$(printf '%s' "$prev_state_str" | python3 -c "
import json, sys
try:
    s = json.loads(sys.stdin.read() or '{}')
except Exception:
    s = {}
print(','.join(s.get('recalled_fingerprints', [])))
" 2>/dev/null)"

    # ── Bucket 1: RED <5min — only the trunk_state_change above; just persist ─
    # ── Bucket 2: RED >=5min, <15min — file gap (idempotent) ──────────────────
    local new_filed_fps="$prev_filed_fps"
    local new_filed_gaps="$prev_filed_gaps"
    local new_dispatched_fps="$prev_dispatched_fps"
    local new_recalled_fps="$prev_recalled_fps"

    if [[ "$red_age_s" -ge "$RED_FILE_S" ]]; then
        # INFRA-2343: bash-native substring match avoids printf|grep pipefail race
        if [[ ",$prev_filed_fps," != *",$fingerprint,"* ]]; then
            emit "trunk_red_persistent" \
                "\"red_minutes\":$red_minutes,\"fingerprint\":\"$fingerprint\",\"failing_jobs\":\"$failing_csv\",\"run_id\":$run_id,\"head_sha\":\"$head_sha\""
            local gap_id
            gap_id="$(_file_fix_trunk_gap "$fingerprint" "$run_id" "$head_sha" "$failing_csv" "$red_minutes")"
            if [[ -n "$new_filed_fps" ]]; then new_filed_fps="$new_filed_fps,$fingerprint"; else new_filed_fps="$fingerprint"; fi
            if [[ -n "$new_filed_gaps" ]]; then new_filed_gaps="$new_filed_gaps,$gap_id"; else new_filed_gaps="$gap_id"; fi
        fi
    fi

    # ── Bucket 3: RED >=15min — dispatch Sonnet (idempotent per fingerprint) ──
    if [[ "$red_age_s" -ge "$RED_DISPATCH_S" ]]; then
        # INFRA-2343: bash-native substring match avoids printf|grep pipefail race
        if [[ ",$prev_dispatched_fps," != *",$fingerprint,"* ]]; then
            # Find the gap id for this fingerprint (it should be the last one
            # filed if it's a fresh fingerprint, but we lookup by position).
            local gap_for_fp
            gap_for_fp="$(printf '%s\n%s\n' "$new_filed_fps" "$new_filed_gaps" | python3 -c "
import sys
fps = sys.stdin.readline().strip().split(',')
gids = sys.stdin.readline().strip().split(',')
fp = '$fingerprint'
for i, f in enumerate(fps):
    if f == fp and i < len(gids):
        print(gids[i])
        break
else:
    print('UNFILED')
" 2>/dev/null)"
            _dispatch_sonnet "$fingerprint" "$run_id" "$head_sha" "$failing_csv" "${gap_for_fp:-UNFILED}"
            if [[ -n "$new_dispatched_fps" ]]; then new_dispatched_fps="$new_dispatched_fps,$fingerprint"; else new_dispatched_fps="$fingerprint"; fi
        fi
    fi

    # ── Bucket 4: RED >=60min — operator-recall (idempotent per fingerprint) ──
    if [[ "$red_age_s" -ge "$RED_RECALL_S" ]]; then
        # INFRA-2343: bash-native substring match avoids printf|grep pipefail race
        if [[ ",$prev_recalled_fps," != *",$fingerprint,"* ]]; then
            _operator_recall_trunk "$fingerprint" "$run_id" "$head_sha" "$failing_csv" "$red_minutes"
            if [[ -n "$new_recalled_fps" ]]; then new_recalled_fps="$new_recalled_fps,$fingerprint"; else new_recalled_fps="$fingerprint"; fi
        fi
    fi

    # ── Persist new state ─────────────────────────────────────────────────────
    # NOTE: We pass vars via env to a single-quoted heredoc because bash
    # performs brace expansion on `{...,...}` patterns inside
    # `$(python3 -c "...")` command-substitution, breaking the dict literal.
    local _now_ts; _now_ts="$(_ts)"
    _save_state "$(NEW_STATE=TRUNK_RED \
        RED_SINCE="$prev_red_since" \
        FILED_FPS="$new_filed_fps" \
        FILED_GAPS="$new_filed_gaps" \
        DISPATCHED_FPS="$new_dispatched_fps" \
        RECALLED_FPS="$new_recalled_fps" \
        RUN_ID="$run_id" \
        HEAD_SHA="$head_sha" \
        CONCLUSION="$conclusion" \
        FAILING_CSV="$failing_csv" \
        UPDATED_AT="$_now_ts" \
        python3 <<'PYEOF'
import json, os
out = {
    'state': os.environ.get('NEW_STATE', 'TRUNK_RED'),
    'red_since_epoch': int(os.environ.get('RED_SINCE', '0') or '0'),
    'filed_fingerprints': [s for s in os.environ.get('FILED_FPS', '').split(',') if s],
    'filed_gaps': [s for s in os.environ.get('FILED_GAPS', '').split(',') if s],
    'dispatched_fingerprints': [s for s in os.environ.get('DISPATCHED_FPS', '').split(',') if s],
    'recalled_fingerprints': [s for s in os.environ.get('RECALLED_FPS', '').split(',') if s],
    'last_run_id': int(os.environ.get('RUN_ID', '0') or '0'),
    'last_head_sha': os.environ.get('HEAD_SHA', ''),
    'last_conclusion': os.environ.get('CONCLUSION', ''),
    'last_failing_csv': os.environ.get('FAILING_CSV', ''),
    'updated_at': os.environ.get('UPDATED_AT', ''),
}
print(json.dumps(out))
PYEOF
)"
}

# ── (8) CLI ──────────────────────────────────────────────────────────────────
case "${1:-}" in
    tick) cmd_tick ;;
    --help|-h)
        sed -n '1,52p' "$0"
        exit 0
        ;;
    "")
        # No-arg invocation (launchd default) = one tick.
        cmd_tick
        ;;
    *)
        echo "Usage: $0 tick | --help" >&2
        exit 2
        ;;
esac
