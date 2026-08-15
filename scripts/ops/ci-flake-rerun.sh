#!/usr/bin/env bash
# ci-flake-rerun.sh — INFRA-375: pattern-match known CI flakes on open
# PRs and auto-rerun their failed jobs once.
#
# Each PR gets at most ONE auto-rerun per failing run-id (cooldown record).
# Real failures retry once, fail again, and are then left alone for human/
# stuck-pr-filer. Only matches against a tight allowlist of flake patterns
# observed in this repo's CI logs:
#
#   - "##[error]The operation was canceled" (runner cancel)
#   - "Error: getaddrinfo EAI_AGAIN" (DNS hiccup)
#   - "Error: connect ETIMEDOUT" (transient network)
#   - "fatal: unable to access" (git network)
#   - "rustup: command not found" (toolchain race in setup)
#   - "Process completed with exit code 137" (OOM kill)
#
# Real test failures don't match → no rerun → no waste.
#
# Usage:
#   scripts/ops/ci-flake-rerun.sh                # live run
#   scripts/ops/ci-flake-rerun.sh --dry-run      # print what would rerun
#
# Environment:
#   CHUMP_CI_FLAKE_RERUN=0       bypass — exit 0 immediately
#   CI_FLAKE_PATTERNS_FILE       path to extra patterns (one per line)
#
# Wired into reaper-heartbeat-watchdog (1h threshold, hourly cadence).

set -euo pipefail

if [[ "${CHUMP_CI_FLAKE_RERUN:-1}" == "0" ]]; then
    echo "[ci-flake-rerun] CHUMP_CI_FLAKE_RERUN=0 — bypass"
    exit 0
fi

# shellcheck source=../lib/reaper-instrumentation.sh
source "$(dirname "$0")/../lib/reaper-instrumentation.sh"
reaper_setup ci-flake
reaper_check_disk_headroom  # INFRA-453: exit 0 + ALERT if <5% free
reaper_rotate_log /tmp/chump-ci-flake-rerun.out.log
reaper_rotate_log /tmp/chump-ci-flake-rerun.err.log
trap 'rc=$?; [[ $rc -ne 0 ]] && reaper_finish fail "{\"exit\":$rc}"' EXIT

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

COOLDOWN_DIR="$REAPER_REPO_ROOT/.chump-locks/ci-flake-cooldown"
mkdir -p "$COOLDOWN_DIR" 2>/dev/null || true

# Tight allowlist of flake fingerprints (extended via CI_FLAKE_PATTERNS_FILE).
FLAKE_PATTERNS=(
    'The operation was canceled'
    'getaddrinfo EAI_AGAIN'
    'connect ETIMEDOUT'
    'fatal: unable to access'
    'rustup: command not found'
    'Process completed with exit code 137'
    'Network is unreachable'
    'temporarily unavailable'
    # RESILIENT-308: the audit aggregate ('audit' required check) exits 1 with
    # this signature when a matrix shard's RESULT was cancelled (concurrency /
    # timeout artifact), not because a gate actually failed. A shard that FAILS a
    # real gate reports result=failure, never result=cancelled — so matching the
    # cancelled-shard string is flake-safe.
    'result=cancelled'
    'at least one audit-shard failed'
)
if [[ -n "${CI_FLAKE_PATTERNS_FILE:-}" && -f "$CI_FLAKE_PATTERNS_FILE" ]]; then
    while IFS= read -r line; do
        [[ -n "$line" && "$line" != \#* ]] && FLAKE_PATTERNS+=("$line")
    done < "$CI_FLAKE_PATTERNS_FILE"
fi

# ── RESILIENT-306: KNOWN_FLAKES.yaml test-name matching ──────────────────────
# The catalog at docs/process/KNOWN_FLAKES.yaml `flakes:` is the fleet's single
# source of truth for cargo/nextest tests that flake (each entry carries a
# tracking_gap). The in-lane wrapper already consults it; this organ now does
# too, so a known test flake that slipped past the in-lane rerun (e.g. it also
# flaked on the retry) still gets a bounded post-hoc `gh run rerun`.
CATALOG_FILE="${CHUMP_KNOWN_FLAKES_FILE:-$REAPER_REPO_ROOT/docs/process/KNOWN_FLAKES.yaml}"

# Catalogued flake test-names from the `flakes:` section only (not check_flakes
# / playwright_flakes). Stops at the next top-level key.
_catalog_flake_tests() {
    [[ -f "$CATALOG_FILE" ]] || return 0
    awk '
        /^flakes:[[:space:]]*$/ { inlist=1; next }
        /^[A-Za-z_][A-Za-z0-9_]*:/ { inlist=0 }
        inlist && /^[[:space:]]*-[[:space:]]*test:[[:space:]]*/ {
            sub(/^[[:space:]]*-[[:space:]]*test:[[:space:]]*/, "");
            gsub(/"/, ""); sub(/[[:space:]]*#.*/, ""); sub(/[[:space:]]+$/, "");
            if (length($0)) print
        }
    ' "$CATALOG_FILE" 2>/dev/null | sort -u
}

# Failed test-names parsed from a CI log — cargo verbose, cargo --quiet
# failures-block, and nextest FAIL lines (mirrors cargo-test-with-rerun.sh).
_failed_test_names() {
    local log="$1" norm
    # `gh run view --log-failed` prefixes every line with
    # "<job><TAB><step><TAB><ISO-timestamp> " before the real log content, so
    # the raw-format patterns below would never anchor. Strip that prefix first.
    # A no-op on already-raw output (unit tests / in-lane use have no timestamp).
    norm="$(sed -E 's/^([^\t]*\t)*[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z //' <<<"$log" 2>/dev/null)"
    {
        grep -E '^test [A-Za-z_][A-Za-z0-9_:]+ \.\.\. FAILED' <<<"$norm" 2>/dev/null \
            | sed -E 's/^test ([A-Za-z_][A-Za-z0-9_:]+) \.\.\. FAILED.*/\1/'
        awk '/^failures:[[:space:]]*$/{f=1;next} /^test result:/{f=0} f && /^[[:space:]]{4}[A-Za-z_][A-Za-z0-9_:]+[[:space:]]*$/{gsub(/[[:space:]]/,"");print}' <<<"$norm" 2>/dev/null
        grep -E 'FAIL \[[^]]*\][[:space:]]+[^[:space:]]+[[:space:]]+[A-Za-z_]' <<<"$norm" 2>/dev/null \
            | sed -E 's/.*FAIL \[[^]]*\][[:space:]]+[^[:space:]]+[[:space:]]+([A-Za-z_][A-Za-z0-9_:]+).*/\1/'
    } | grep -E '^[A-Za-z_][A-Za-z0-9_:]+$' | sort -u
}

# Echoes a descriptor + returns 0 iff the log's failures are ALL catalogued
# test flakes (and at least one failed test was parsed). Fail-closed.
_known_flake_tests_match() {
    local log="$1" failed catalog name
    failed="$(_failed_test_names "$log")"
    [[ -z "$failed" ]] && return 1
    catalog="$(_catalog_flake_tests)"
    [[ -z "$catalog" ]] && return 1
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        grep -qxF "$name" <<<"$catalog" || return 1
    done <<<"$failed"
    echo "known-flake-test: $(echo "$failed" | tr '\n' ',' | sed 's/,$//')"
    return 0
}

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
warn()  { printf '\033[0;33m  WARN: %s\033[0m\n' "$*"; }
dry()   { printf '  [dry-run] %s\n' "$*"; }

green "=== ci-flake-rerun ==="
[[ $DRY_RUN -eq 1 ]] && info "Dry-run mode — no jobs will be rerun."

PRS_JSON=$(gh pr list --state open --json number,title,headRefName,statusCheckRollup --limit 50 2>/dev/null || echo "[]")
if [[ "$PRS_JSON" == "[]" || -z "$PRS_JSON" ]]; then
    info "No open PRs."
    trap - EXIT
    reaper_finish ok '{"reran":0,"skipped":0}'
    exit 0
fi

RERAN=0; SKIPPED=0

# Walk PRs → for each, find run-IDs of failing required checks → fetch
# the failed log → grep for any flake pattern → if any match, rerun once.
PRS=$(echo "$PRS_JSON" | python3 -c "
import json,sys,re
for p in json.load(sys.stdin):
    rollup = p.get('statusCheckRollup') or []
    failed = [c for c in rollup if (c.get('conclusion') or '').upper() in ('FAILURE','ERROR','CANCELLED','TIMED_OUT','STARTUP_FAILURE')]
    if not failed:
        continue
    # Map each run-id to whether ANY of its failed checks were CANCELLED/TIMED_OUT.
    # RESILIENT-308: a cancelled/timed-out required check is an inherent
    # concurrency/timeout flake (never a real code failure — that reports FAILURE),
    # and — critically — a CANCELLED job is NOT rerun by 'gh run rerun --failed',
    # so it needs a WHOLE-run rerun. Carry the flag so the shell picks the mode.
    run_cancel = {}   # run_id -> bool
    for c in failed:
        url = c.get('targetUrl') or c.get('detailsUrl') or ''
        m = re.search(r'/actions/runs/(\d+)/', url)
        if not m:
            continue
        rid = m.group(1)
        is_cancel = (c.get('conclusion') or '').upper() in ('CANCELLED','TIMED_OUT')
        run_cancel[rid] = run_cancel.get(rid, False) or is_cancel
    for rid, cancelled in run_cancel.items():
        print(f\"{p['number']}\t{rid}\t{1 if cancelled else 0}\t{p['title'][:60]}\")
")

while IFS=$'\t' read -r PR_NUM RUN_ID CANCELLED TITLE; do
    [[ -z "$PR_NUM" || -z "$RUN_ID" ]] && continue

    # Cooldown: have we already attempted rerun on this run-id?
    cd_file="$COOLDOWN_DIR/run-${RUN_ID}.ts"
    if [[ -f "$cd_file" ]]; then
        info "PR #$PR_NUM run $RUN_ID: skip (already attempted rerun)"
        SKIPPED=$((SKIPPED+1))
        continue
    fi

    # ── INFRA-304: per-PR flake-budget ──────────────────────────────────────
    # The per-run-id cooldown above stops one specific run from being rerun
    # twice. But the same PR can produce a fresh run-id every time the
    # author pushes (or every time something else reruns it). If a PR
    # accumulates N flake-class reruns across distinct run-ids, the test
    # is likely a real bug masquerading as a flake — observed 2026-05-02
    # when 6 PRs blocked simultaneously on the same flaky test
    # `two_concurrent_reserves_return_distinct_ids` until INFRA-253's
    # 1-line source fix unblocked the queue.
    #
    # Tracks per-PR rerun count in $COOLDOWN_DIR/pr-<N>.count. After
    # CHUMP_FLAKE_BUDGET (default 3) flake-class reruns, refuses further
    # auto-reruns and posts a one-time diagnostic comment to the PR
    # suggesting the operator file a gap.
    #
    # Bypass: CHUMP_FLAKE_BUDGET=0 → unlimited reruns (current behavior).
    flake_budget="${CHUMP_FLAKE_BUDGET:-3}"
    pr_count_file="$COOLDOWN_DIR/pr-${PR_NUM}.count"
    pr_count=0
    [[ -f "$pr_count_file" ]] && pr_count=$(cat "$pr_count_file" 2>/dev/null || echo 0)
    if (( flake_budget > 0 )) && (( pr_count >= flake_budget )); then
        warn "PR #$PR_NUM: flake-budget exceeded ($pr_count >= $flake_budget) — refusing auto-rerun"
        # Post a one-time diagnostic comment so the operator gets the
        # cognitive prompt to switch from "retry" to "look at the test".
        # Marker file prevents duplicate comments on subsequent skipped
        # rerun attempts.
        comment_marker="$COOLDOWN_DIR/pr-${PR_NUM}.commented"
        if [[ ! -f "$comment_marker" ]] && [[ $DRY_RUN -eq 0 ]]; then
            if gh pr comment "$PR_NUM" --body "⚠️ **Flake budget exceeded** (${pr_count}/${flake_budget} auto-reruns matched a known flake pattern). The same PR has now seen ${pr_count} flake-class reruns across distinct run-ids. The third rerun usually means it's a real bug, not transient noise — see INFRA-304 / the 2026-05-02 \`two_concurrent_reserves_return_distinct_ids\` incident.

Suggested action:
\`\`\`bash
chump gap reserve --domain INFRA --title 'flaky <test_name> — investigate after PR #${PR_NUM}'
\`\`\`

Bypass: \`CHUMP_FLAKE_BUDGET=0 scripts/ops/ci-flake-rerun.sh\` to keep retrying." >/dev/null 2>&1; then
                touch "$comment_marker"
                info "PR #$PR_NUM: posted flake-budget diagnostic comment"
            fi
        fi
        # Emit ambient ALERT so siblings see the budget hit live.
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        printf '{"event":"alert","kind":"flake_budget_exceeded","ts":"%s","pr":%s,"count":%s,"budget":%s}\n' \
            "$ts" "$PR_NUM" "$pr_count" "$flake_budget" \
            >> "$REAPER_LOCK_DIR/ambient.jsonl" 2>/dev/null || true
        SKIPPED=$((SKIPPED+1))
        continue
    fi

    matched=""
    # rerun_mode: "failed" reruns only failed jobs (default, cheap); "full" reruns
    # the WHOLE run — mandatory for CANCELLED jobs, which `--failed` silently skips.
    rerun_mode="failed"

    # ── RESILIENT-308: cancelled/timed-out required check = inherent flake ───────
    # The cancelled audit-shard class. A required check that ended CANCELLED or
    # TIMED_OUT is a concurrency/timeout artifact, not a real failure (real gate
    # failures report FAILURE). Rerun it without needing a log-text match — and
    # rerun the whole run, because a cancelled job is not in the `--failed` set.
    if [[ "$CANCELLED" == "1" ]]; then
        matched="cancelled/timed-out required check (concurrency/timeout flake)"
        rerun_mode="full"
    fi

    # Pull the failed-log payload and grep for known flakes.
    # RESILIENT-306: the old `gh ... | head -c 200000` propagated head's
    # pipe-close SIGPIPE (141) to gh, and `set -o pipefail` turned that into a
    # whole-script exit 141 — which is exactly why this organ's systemd service
    # sat in `failed` all night and never healed anything. Wrap the pipeline in
    # `|| true` inside the substitution so a truncated read is a success, not a
    # fatal SIGPIPE.
    if [[ -z "$matched" ]]; then
        log=$( { gh run view "$RUN_ID" --log-failed 2>/dev/null | head -c 200000; } || true )
        for pat in "${FLAKE_PATTERNS[@]}"; do
            if grep -qF "$pat" <<<"$log"; then
                matched="$pat"
                break
            fi
        done

        # RESILIENT-306: network patterns only catch infra flakes. The failure that
        # jammed the fleet was a KNOWN test flake (credible218) — a nextest/cargo
        # test that passes on rerun. Reuse docs/process/KNOWN_FLAKES.yaml (the same
        # catalog the in-lane wrapper consults): if EVERY failed test parsed from
        # the log is catalogued, treat it as a flake and rerun. Fail-closed — any
        # uncatalogued failed test means "real failure, leave alone."
        if [[ -z "$matched" ]]; then
            if desc=$(_known_flake_tests_match "$log"); then
                matched="$desc"
            fi
        fi
    fi

    if [[ -z "$matched" ]]; then
        info "PR #$PR_NUM run $RUN_ID: no flake match (patterns or catalog) — leaving alone  ($TITLE)"
        SKIPPED=$((SKIPPED+1))
        continue
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        dry "would rerun PR #$PR_NUM run $RUN_ID mode=$rerun_mode (matched: '$matched')  ($TITLE)"
        RERAN=$((RERAN+1))
        continue
    fi

    if { [[ "$rerun_mode" == "full" ]] && gh run rerun "$RUN_ID" >/dev/null 2>&1; } \
       || { [[ "$rerun_mode" != "full" ]] && gh run rerun "$RUN_ID" --failed >/dev/null 2>&1; }; then
        date +%s > "$cd_file"
        # INFRA-304: increment the per-PR flake-class rerun counter so
        # the budget check above eventually trips on persistent flakes.
        echo $((pr_count + 1)) > "$pr_count_file"
        green "  reran PR #$PR_NUM run $RUN_ID (matched flake: '$matched', PR-budget=$((pr_count + 1))/$flake_budget)"
        RERAN=$((RERAN+1))
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        printf '{"event":"alert","kind":"ci_flake_rerun","ts":"%s","pr":%s,"run":"%s","pattern":%s}\n' \
            "$ts" "$PR_NUM" "$RUN_ID" \
            "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$matched" 2>/dev/null || echo "\"$matched\"")" \
            >> "$REAPER_LOCK_DIR/ambient.jsonl" 2>/dev/null || true
    else
        warn "PR #$PR_NUM run $RUN_ID: gh run rerun failed"
        SKIPPED=$((SKIPPED+1))
    fi
done <<<"$PRS"

echo ""
green "=== ci-flake-rerun done: $RERAN reran, $SKIPPED skipped ==="

trap - EXIT
reaper_finish ok "{\"reran\":$RERAN,\"skipped\":$SKIPPED}"
