#!/usr/bin/env bash
# worker.sh — INFRA-203 / INFRA-211: per-agent worker loop.
#
# One instance per fleet pane. Loops until killed:
#   1. git fetch + (best-effort) rebase main into a fresh worktree
#   2. ask musher.py / chump gap list for the next pickable gap
#      (filters: priority, domain, effort)
#   3. claim it via gap-claim.sh (atomic flock)
#   4. create a worktree at .claude/worktrees/<gap-id>-<sid>
#   5. spawn `claude -p <focused-prompt> --dangerously-skip-permissions`
#      with FLEET_TIMEOUT_S timeout — same surface as WorkBackend::Headless
#      in src/dispatch.rs (INFRA-191 Phase 2), used directly here because
#      `chump dispatch` does not yet expose the backend on the CLI.
#   6. on exit (success or failure): release lease, prune the worktree,
#      sleep IDLE_SLEEP_S if no gap was found, loop back.
#
# Env (set by run-fleet.sh, but each is overridable):
#   AGENT_ID                pane index (used in session id + logs)
#   REPO_ROOT               main checkout
#   FLEET_LOG_DIR           where to write per-cycle logs
#   FLEET_TIMEOUT_S         per-claude-call timeout (default 1800)
#   FLEET_PRIORITY_FILTER   default P0,P1
#   FLEET_DOMAIN_FILTER     default "" = any
#   FLEET_EFFORT_FILTER     default xs,s,m
#   FLEET_BACKEND           default chump-local — "claude" runs `claude -p`
#                           (original AUTO-013 path, Anthropic API).
#                           "chump-local" runs `chump --execute-gap` so
#                           every inference call fans out through the
#                           free-tier provider cascade (INFRA-259).
#   IDLE_SLEEP_S            default 60 — sleep when no pickable gap

set -uo pipefail   # NOT -e: we want the loop to recover from individual cycle failures

AGENT_ID="${AGENT_ID:-?}"
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
FLEET_LOG_DIR="${FLEET_LOG_DIR:-/tmp/chump-fleet-default}"
FLEET_TIMEOUT_S="${FLEET_TIMEOUT_S:-1800}"
FLEET_PRIORITY_FILTER="${FLEET_PRIORITY_FILTER:-P0,P1}"
FLEET_DOMAIN_FILTER="${FLEET_DOMAIN_FILTER:-}"
FLEET_AGENT_DOMAINS="${FLEET_AGENT_DOMAINS:-}"
FLEET_EFFORT_FILTER="${FLEET_EFFORT_FILTER:-xs,s,m}"
FLEET_BACKEND="${FLEET_BACKEND:-chump-local}"
IDLE_SLEEP_S="${IDLE_SLEEP_S:-60}"

mkdir -p "$FLEET_LOG_DIR"

log() { printf '[worker:%s %s] %s\n' "$AGENT_ID" "$(date -u +%H:%M:%S)" "$*"; }

# INFRA-206: per-agent domain affinity. If FLEET_AGENT_DOMAINS is set (comma-
# separated, e.g. "INFRA,EVAL,DOC"), agent K is assigned domains[(K-1) % N],
# overriding the fleet-wide FLEET_DOMAIN_FILTER for this worker only.
if [ -n "$FLEET_AGENT_DOMAINS" ] && [ "${AGENT_ID:-?}" != "?" ]; then
    _aff="$(DOMAINS="$FLEET_AGENT_DOMAINS" IDX="$AGENT_ID" python3 -c \
        "import os; d=[x.strip() for x in os.environ['DOMAINS'].split(',') if x.strip()]; \
print(d[(int(os.environ['IDX'])-1)%len(d)] if d else '')" 2>/dev/null || true)"
    if [ -n "$_aff" ]; then
        log "domain affinity: agent $AGENT_ID → $_aff (INFRA-206)"
        FLEET_DOMAIN_FILTER="$_aff"
    fi
fi

trap 'log "interrupted; exiting loop"; exit 0' INT TERM

# Hard rule from CLAUDE.md: never auto-pickup these — they need human judgment.
EXCLUDE_PREFIXES_REGEX='^(EVAL-|RESEARCH-|META-)'

cd "$REPO_ROOT"

# INFRA-333: heal any wedged-inode chump binary before we touch chump gap.
# Idempotent — fast no-op (probe < 5s) when binary is healthy. When the
# inode is wedged (INFRA-275 syspolicyd hang), the doctor moves it aside
# and replaces it with a fresh-inode copy, so the worker loop's `chump
# gap list` invocation below doesn't hang at _dyld_start. Failure is
# logged but non-fatal: the loop will surface the real problem on the
# first `chump gap` call if the heal didn't work.
"$REPO_ROOT/scripts/dev/chump-doctor.sh" >&2 || {
    log "WARN: chump-doctor failed; chump gap calls may hang"
}

cycle=0
while :; do
    cycle=$((cycle + 1))
    log "cycle $cycle: fetching origin/main"
    git fetch origin main --quiet || log "WARN: git fetch failed; continuing"

    # ── Pick a gap ────────────────────────────────────────────────────────
    # We use `chump gap list --json` directly (musher.py has its own cooldown
    # heuristics; for fleet workers we want the simplest "highest-priority
    # unclaimed open gap matching filters" semantics so behavior is debuggable).
    gap_json="$(chump gap list --status open --json 2>/dev/null || echo '[]')"

    # Active leases (so we never try to claim something a sibling has).
    active_gaps="$(
        python3 - "$REPO_ROOT/.chump-locks" <<'PY' 2>/dev/null || true
import glob, json, sys, os
base = sys.argv[1]
for f in glob.glob(os.path.join(base, '*.json')):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    g = d.get('gap_id') or (d.get('pending_new_gap') or {}).get('id')
    if g:
        print(g)
PY
    )"

    # Pick highest-priority candidate. Use a tempfile so we can send the gap
    # JSON on stdin AND keep the python script as a heredoc.
    gap_json_file="$(mktemp -t fleet-gaps.XXXXXX)"
    printf '%s' "$gap_json" > "$gap_json_file"
    pick="$(FLEET_PRIORITY_FILTER="$FLEET_PRIORITY_FILTER" \
            FLEET_DOMAIN_FILTER="$FLEET_DOMAIN_FILTER" \
            FLEET_EFFORT_FILTER="$FLEET_EFFORT_FILTER" \
            EXCLUDE_RE="$EXCLUDE_PREFIXES_REGEX" \
            ACTIVE_GAPS="$active_gaps" \
            GAP_JSON_FILE="$gap_json_file" \
            WORKER_INDEX="$AGENT_ID" \
            COOLDOWN_DIR="$REPO_ROOT/.chump-locks/cooldown" \
            python3 "$REPO_ROOT/scripts/dispatch/_pick_gap.py" 2>/dev/null || true)"
    rm -f "$gap_json_file"

    if [ -z "$pick" ]; then
        log "no pickable gap (filters: prio=$FLEET_PRIORITY_FILTER domain=${FLEET_DOMAIN_FILTER:-any} effort=$FLEET_EFFORT_FILTER); sleeping ${IDLE_SLEEP_S}s"
        sleep "$IDLE_SLEEP_S"
        continue
    fi

    GAP_ID="$pick"
    log "picked gap $GAP_ID"

    # ── INFRA-361: pre-pick preflight ─────────────────────────────────────
    # Cheap check (~50ms) before paying the worktree-create + cold-cargo
    # cost (5–15min). If the gap is no longer available (claimed by a
    # sibling, done on main, ID missing from registry), skip and pick
    # again next cycle. Pre-fix worker.sh order was pick → worktree →
    # claim/preflight, which ate the build cost on every dead pick.
    if ! ( cd "$REPO_ROOT" && CHUMP_AMBIENT_GLANCE=0 CHUMP_SPECULATIVE=1 \
           scripts/coord/gap-preflight.sh "$GAP_ID" >/dev/null 2>&1 ); then
        log "skipping $GAP_ID: failed pre-pick preflight (claimed/done/missing); next cycle"
        continue
    fi

    # ── Worktree ──────────────────────────────────────────────────────────
    sid="$(date +%Y%m%d-%H%M%S)"
    gap_lower="$(printf '%s' "$GAP_ID" | tr '[:upper:]' '[:lower:]')"
    wt_name="${gap_lower}-fleet-${AGENT_ID}-${sid}"
    wt_path="$REPO_ROOT/.claude/worktrees/$wt_name"
    branch="chump/${wt_name}"

    log "creating worktree $wt_path on branch $branch"
    if ! git -C "$REPO_ROOT" worktree add -b "$branch" "$wt_path" origin/main >/dev/null 2>&1; then
        # INFRA-271: don't sleep 30s on worktree-add failure — most failures
        # here are transient (sibling worker briefly held a git lock, or the
        # branch we picked happened to collide with a stale leftover). Skip
        # the cycle and pick a different gap on the next iteration.
        log "WARN: worktree create failed for $GAP_ID; trying next pick"
        continue
    fi

    # ── Claim ─────────────────────────────────────────────────────────────
    # INFRA-271 + INFRA-193: enable speculative-execution claim. Two fleet
    # workers picking the same gap in the same second is the common case at
    # high FLEET_SIZE; with CHUMP_SPECULATIVE=1, gap-preflight allows both
    # claims, both workers ship in parallel, and bot-merge / closer-batcher
    # auto-closes the loser as superseded once the winner lands. Without this,
    # one worker would silently lose a cycle (~30+ seconds) per collision.
    if ! ( cd "$wt_path" && CHUMP_AMBIENT_GLANCE=0 CHUMP_SPECULATIVE=1 scripts/coord/gap-claim.sh "$GAP_ID" >/dev/null 2>&1 ); then
        log "WARN: gap-claim failed for $GAP_ID even speculative; cleaning up"
        git -C "$REPO_ROOT" worktree remove --force "$wt_path" 2>/dev/null || true
        git -C "$REPO_ROOT" branch -D "$branch" 2>/dev/null || true
        continue
    fi

    # ── Spawn agent (claude or chump-local) ───────────────────────────────
    cycle_log="$FLEET_LOG_DIR/agent-${AGENT_ID}-cycle${cycle}-${GAP_ID}.log"

    # Pick `timeout` (linux) or `gtimeout` (mac brew coreutils); fall back to none.
    if command -v timeout >/dev/null 2>&1; then
        TO="timeout ${FLEET_TIMEOUT_S}s"
    elif command -v gtimeout >/dev/null 2>&1; then
        TO="gtimeout ${FLEET_TIMEOUT_S}s"
    else
        TO=""
    fi

    case "$FLEET_BACKEND" in
        claude)
            # ── INFRA-371: inline gap briefing (cut token burn) ──────────
            # Pre-fix: prompt was "Ship gap X. Read CLAUDE.md and AGENTS.md
            # first..." which forced ~30K tokens of mandatory reads on every
            # spawn before any productive work. Squad on cycle 100+ wastes
            # this on every cycle.
            #
            # Post-fix: pre-assemble a tight briefing inline so claude has
            # everything it needs to ship without exploring the repo for
            # discipline rules. CLAUDE.md is still on disk and claude is
            # told it CAN read it for unusual cases — so back-compat for
            # genuinely tricky gaps.
            #
            # Estimated savings: ~20-25K tokens per spawn × 4 workers ×
            # 100+ cycles/day = $50-150/day at sonnet rates, even more
            # at haiku scale.
            #
            # Bypass: FLEET_INLINE_BRIEFING=0 reverts to the old terse-prompt
            # behavior (forces claude to discover everything itself).
            if [[ "${FLEET_INLINE_BRIEFING:-1}" == "1" ]]; then
                gap_yaml_path="$wt_path/docs/gaps/${GAP_ID}.yaml"
                gap_yaml="(gap YAML not found — read docs/gaps/${GAP_ID}.yaml)"
                [[ -f "$gap_yaml_path" ]] && gap_yaml=$(cat "$gap_yaml_path")
                prompt="Ship gap ${GAP_ID}.

The gap is already claimed for this session; lease is in .chump-locks/.
You are in worktree ${wt_path}. Pre-flight has already run — do NOT re-run
'chump gap list', 'gap-doctor', 'install-ambient-hooks', or 'chump-coord
watch'. Spend tokens on the implementation, not on discovery.

══ GAP YAML (canonical) ══
${gap_yaml}

══ HARD RULES (full text in CLAUDE.md if you need it) ══
- Work ONLY in this worktree: ${wt_path}
- Commit via: scripts/coord/chump-commit.sh <files…> -m \"msg\"
- Ship via:   scripts/coord/bot-merge.sh --gap ${GAP_ID} --auto-merge
  (this rebases, runs tests, pushes, opens PR, arms auto-merge,
  auto-closes the gap with --update-yaml)
- If bot-merge.sh hangs/dies: fall back to manual ship —
    git push -u origin <branch>
    gh pr create --base main --title \"...\" --body \"...\"
    chump gap ship ${GAP_ID} --closed-pr <PR#> --update-yaml
    git push (commit the close)
    gh pr merge <PR#> --auto --squash
- Never push directly to main. Never use git commit --no-verify.
- Never hand-edit docs/gaps/*.yaml — use 'chump gap set' / 'chump gap ship'.
- If you spot a real bug along the way, file it: 'chump gap reserve --domain INFRA --title \"...\"'

When done, reply with the PR number only (e.g. \"#1234\")."
            else
                prompt="Ship gap $GAP_ID in this repository. Read CLAUDE.md and AGENTS.md first. The gap is already claimed for this session; the lease is in .chump-locks/. Implement the gap per its description, commit via scripts/coord/chump-commit.sh, and ship via scripts/coord/bot-merge.sh --gap $GAP_ID --auto-merge. Reply with the PR number only."
            fi
            # INFRA-364: default to haiku for cost. Operator had \$92 of unused
            # workspace API credit while the squad burned the \$20/mo subscription
            # cap. Sonnet is ~10× haiku per token; for fleet's "ship a small
            # gap" workload haiku is plenty. Override via FLEET_MODEL=sonnet
            # for harder gaps. Empty string = let claude config default win
            # (back-compat).
            FLEET_MODEL="${FLEET_MODEL-haiku}"
            _model_arg=()
            [[ -n "$FLEET_MODEL" ]] && _model_arg=(--model "$FLEET_MODEL")
            log "spawning claude -p (timeout ${FLEET_TIMEOUT_S}s, backend=claude, model=${FLEET_MODEL:-default}) → $cycle_log"
            (
                cd "$wt_path" || exit 99
                # Same surface as src/dispatch.rs WorkBackend::Headless.
                # shellcheck disable=SC2086
                $TO claude -p "$prompt" --dangerously-skip-permissions "${_model_arg[@]}"
            ) >"$cycle_log" 2>&1
            rc=$?
            ;;
        chump-local)
            log "spawning chump --execute-gap $GAP_ID (timeout ${FLEET_TIMEOUT_S}s, backend=chump-local) → $cycle_log"
            (
                cd "$wt_path" || exit 99
                # COG-025: route inference through src/provider_cascade.rs
                # so this gap is carried by free-tier providers (Cerebras,
                # Groq, Together, etc.). Reflection rows tag backend=chump-local
                # so COG-026 A/B can split outcomes.
                # shellcheck disable=SC2086
                $TO chump --execute-gap "$GAP_ID"
            ) >"$cycle_log" 2>&1
            rc=$?
            ;;
        *)
            log "ERROR: unknown FLEET_BACKEND=$FLEET_BACKEND; skipping cycle"
            rc=2
            ;;
    esac

    if [ $rc -eq 0 ]; then
        log "$FLEET_BACKEND exited cleanly for $GAP_ID"
    elif [ $rc -eq 124 ]; then
        log "WARN: $FLEET_BACKEND timed out (${FLEET_TIMEOUT_S}s) on $GAP_ID"
    else
        log "WARN: $FLEET_BACKEND exited rc=$rc on $GAP_ID"
        # INFRA-361: write cooldown record so siblings + future cycles
        # don't immediately re-pick this gap. Worker 4 was observed
        # re-picking INFRA-340 6 times in 5 minutes pre-fix. Default 30
        # min; override via FLEET_RC1_COOLDOWN_S. Only fires for genuine
        # rc!=0/124 — clean exits and timeouts skip cooldown.
        cooldown_s="${FLEET_RC1_COOLDOWN_S:-1800}"
        cooldown_dir="$REPO_ROOT/.chump-locks/cooldown"
        mkdir -p "$cooldown_dir" 2>/dev/null || true
        cooldown_until=$(( $(date +%s) + cooldown_s ))
        printf '{"gap_id":"%s","rc":%d,"until":%d,"agent":"%s","ts":"%s"}\n' \
            "$GAP_ID" "$rc" "$cooldown_until" "$AGENT_ID" \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            > "$cooldown_dir/${GAP_ID}.json" 2>/dev/null || true
        log "cooldown: $GAP_ID skipped for ${cooldown_s}s after rc=$rc"
    fi

    # ── Release lease + prune worktree ────────────────────────────────────
    # The lease will TTL-expire on its own; we also try to remove it cleanly.
    rm -f "$REPO_ROOT/.chump-locks/"*"${GAP_ID}"*.json 2>/dev/null || true

    # Worktree cleanup — keep it on disk if claude actually shipped a PR
    # (operator may want to inspect), otherwise remove. Simple proxy: if the
    # branch has been pushed (gone-status), prune; else leave for inspection.
    if git -C "$REPO_ROOT" branch -vv 2>/dev/null | grep -E "$branch" | grep -q ': gone\]'; then
        git -C "$REPO_ROOT" worktree remove --force "$wt_path" 2>/dev/null || true
        git -C "$REPO_ROOT" branch -D "$branch" 2>/dev/null || true
        log "cleaned up worktree $wt_name (branch was gone — PR landed)"
    else
        log "leaving worktree $wt_name on disk (rc=$rc; inspect if needed)"
    fi

    # Brief gap between cycles so we don't hammer the API on a hot-loop bug.
    sleep 5
done
