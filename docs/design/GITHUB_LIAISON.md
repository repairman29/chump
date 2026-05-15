---
doc_tag: design-architecture
last_audited: 2026-05-15
audience: operator, fleet engineers, Mission Driver
purpose: Design and migration plan for the GitHub Liaison pattern — single-writer GitHub API client elected from the fleet, all other workers cache-only.
status: v1 — operator review requested; Phase 1 gap filed as INFRA-1312
---

# GitHub Liaison Architecture

> **Why this exists:** The fleet hit 44,000 self-throttle events in 23 hours (2026-05-14/15). Every worker calls GitHub independently. With 15+ workers sharing one token, secondary rate-limit rejections are a daily occurrence regardless of per-worker throttling. The root fix is not "throttle each worker better" — it's "stop multiplying the client count."

## TL;DR

Elect one process as the GitHub Liaison. It is the **sole reader** of the GitHub API. All other workers read from `.chump/github_cache.db`. The Liaison updates the cache via webhooks (primary) and targeted polls (fallback). Mutations (pr create, pr merge, update-branch) are handled directly by workers in Phase 1–2, then routed through the Liaison via NATS in Phase 3.

**Expected impact by phase:**

| Phase | Mechanism | API call reduction |
|---|---|---|
| 0 (today) | 15+ workers poll GitHub directly | baseline |
| 1 | Liaison election + cache-mandatory reads | ~80% read reduction |
| 2 | Webhook-first cache (liaison processes events) | ~97% read reduction |
| 3 | Mutation routing via NATS | ~50% mutation reduction |
| 4 | GitHub App token | separate 5000/hr quota bucket |

---

## Problem Analysis

### What we measured (2026-05-15 leaderboard)

```
gh pr merge        1,101 calls/24h   5,505 points  — 1101 attempts, 570 ships (48% retry waste)
queue-driver update-branch  832/24h   4,160 points  — cascade fires N_workers times per hot commit
gh pr list         1,478/24h   1,478 points  — N workers each independently scanning open PRs
gh pr view         1,461/24h   1,461 points  — per-PR fetch loops (N+1 pattern)
gh auth token        570/24h   1,140 points  — (already fixed by INFRA-1283 5-min cache)
```

**Acute fixes already shipped:**
- INFRA-1310: debounce cascade-rebase per SHA → eliminates the 280/hr update-branch burst
- INFRA-1311: bot-merge exponential backoff → halves retry-driven merge calls
- INFRA-1082: cache-first pr view/list migration → eliminates ~1461 pr view calls/day

**What those fixes don't address:** the structural N-workers multiplier. Even with perfect per-worker behavior, 15 workers × GitHub API = 15× the secondary rate limit pressure. The only structural fix is reducing N to 1 for reads.

### Why secondary rate limits are the real enemy

GitHub has two limits:
1. **Hourly quota**: 5000 GraphQL points/hr. We showed 4074/5000 remaining during throttle events — this is NOT the problem.
2. **Secondary (per-minute burst)**: GitHub rejects concurrent/burst requests that saturate their infrastructure, even within hourly quota. Multiple workers making simultaneous calls trip this even when each individual worker is "well-behaved."

The secondary limit scales with **number of concurrent clients using the same token**, not with per-client call rate. The fix is structural: 1 client, not 15.

---

## Architecture

### Core Principle

> The GitHub API is a **slow, rate-limited, eventually-consistent publish target** — not a coordination surface. Move real-time coordination to NATS + SQLite. GitHub is only touched when actually shipping code (mutations) or by the designated Liaison (reads).

### Components

```
┌─────────────────────────────────────────────────────────────────┐
│                         Fleet Workers (N)                        │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │  Worker A    │  │  Worker B    │  │  Worker C    │  ...     │
│  │  (Liaison)   │  │  (Reader)    │  │  (Reader)    │          │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘          │
│         │                 │                  │                   │
│    Reads+Writes      Cache reads only   Cache reads only        │
│         │                 │                  │                   │
│         ▼                 ▼                  ▼                   │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              .chump/github_cache.db (SQLite)             │   │
│  │  pr_state | check_runs | workflow_runs | branches        │   │
│  └─────────────────────────────────────────────────────────┘   │
│         │                                                        │
│    (Liaison only)                                               │
│         │                                                        │
└─────────┼────────────────────────────────────────────────────────┘
          │
          ▼
  ┌───────────────────────────────┐
  │       GitHub API              │
  │  (REST + GraphQL, one client) │
  └───────────────────────────────┘
          ▲
          │ (webhook push)
  ┌───────────────────────────────┐
  │  github-webhook-receiver.py   │
  │  (scripts/ops/, INFRA-1000)   │
  └───────────────────────────────┘
```

### Liaison Election

**Phase 1–2: lockfile (NATS-optional)**

Atomic `mkdir` on `.chump-locks/github-liaison.lock/`:

```bash
LIAISON_LOCK="$REPO_ROOT/.chump-locks/github-liaison.lock"
LIAISON_HEARTBEAT="$LIAISON_LOCK/heartbeat"  # file inside the lockdir

# Try to become liaison
if mkdir "$LIAISON_LOCK" 2>/dev/null; then
    IS_LIAISON=1
    # Write heartbeat immediately; refresh every 30s
    date -u +%Y-%m-%dT%H:%M:%SZ > "$LIAISON_HEARTBEAT"
else
    IS_LIAISON=0
    # Check if existing liaison is alive
    heartbeat=$(cat "$LIAISON_HEARTBEAT" 2>/dev/null || echo "")
    age=$(( $(date +%s) - $(date -d "$heartbeat" +%s 2>/dev/null || echo 0) ))
    if [[ $age -gt 90 ]]; then
        # Stale lock — steal it
        rm -rf "$LIAISON_LOCK" && mkdir "$LIAISON_LOCK" && IS_LIAISON=1
    fi
fi
```

Lock directory (not file) is used because `mkdir` is atomic on POSIX whereas `O_EXCL` file creation has edge cases on NFS. Heartbeat file inside the lock directory allows staleness detection without removing the lock.

**Phase 3+: NATS KV leader election**

When NATS is available, promote to `chump_gaps` KV bucket:

```rust
// chump-coord::liaison::try_elect()
kv.create("github-liaison-leader", session_id.as_bytes()).await?
// Key has TTL=60s; Liaison renews every 30s
// On renewal failure → voluntary abdication → another worker wins next election
```

### Read Path (workers, Phase 1+)

```bash
# In scripts/coord/lib/github_cache.sh

cache_lookup_pr() {
    local pr_number="$1"
    local row
    row=$(sqlite3 "$CACHE_DB" \
        "SELECT json FROM pr_state WHERE number=$pr_number AND \
         updated_at > datetime('now','-5 minutes')" 2>/dev/null)

    if [[ -n "$row" ]]; then
        echo "$row"
        return 0
    fi

    # Cache miss path (Phase 1: direct fallback; Phase 2+: request from liaison)
    if [[ "${CHUMP_LIAISON_STRICT:-0}" == "1" ]]; then
        # Strict mode: never call GitHub directly; wait up to 30s for liaison
        _request_liaison_fetch "pr" "$pr_number"
    else
        # Fallback mode: call GitHub directly (degraded, logs a warning)
        _emit_ambient "cache_miss_direct_fallback" "\"pr\":$pr_number"
        gh api "repos/$REPO/pulls/$pr_number" 2>/dev/null
    fi
}
```

`CHUMP_LIAISON_STRICT=1` is the migration knob. Start with `0` (fallback allowed), flip to `1` once liaison is proven stable for 7 days.

### Liaison Refresh Loop

```bash
# scripts/coord/github-liaison.sh (new — INFRA-1312)

liaison_refresh_loop() {
    local interval="${CHUMP_LIAISON_POLL_INTERVAL:-30}"

    while true; do
        # Renew heartbeat
        date -u +%Y-%m-%dT%H:%M:%SZ > "$LIAISON_LOCK/heartbeat"

        # Batch fetch all open PR states (1 API call, updates N rows)
        _refresh_pr_state_batch

        # Process any pending webhook events from the receiver's queue
        _drain_webhook_queue  # Phase 2+

        # Emit liaison health event
        _emit_ambient "github_liaison_heartbeat" \
            "\"prs_refreshed\":$REFRESHED,\"cache_age_max_s\":$MAX_AGE"

        sleep "$interval"
    done
}

_refresh_pr_state_batch() {
    local prs
    prs=$(gh api graphql -f query='
        query { repository(owner:"repairman29", name:"chump") {
            pullRequests(states:OPEN, first:100) {
                nodes { number title state mergeable mergeStateStatus
                        headRefName headRefOid isDraft autoMergeRequest { mergeMethod } }
            }
        }
    }' --jq '.data.repository.pullRequests.nodes[]' 2>/dev/null)

    # Batch upsert into pr_state
    echo "$prs" | while IFS= read -r pr_json; do
        local num; num=$(echo "$pr_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['number'])")
        sqlite3 "$CACHE_DB" \
            "INSERT OR REPLACE INTO pr_state(number,json,updated_at) \
             VALUES($num,'$(echo "$pr_json" | sed "s/'/''/g")',datetime('now'))"
    done

    REFRESHED=$(echo "$prs" | wc -l | tr -d ' ')
}
```

One GraphQL query fetches all 100 open PRs simultaneously — **1 API call every 30 seconds instead of 15+ workers × individual pr view calls**. That's a 97%+ reduction from the current 1461 calls/day pattern.

### Webhook Integration (Phase 2)

The webhook receiver (`scripts/ops/github-webhook-receiver.py`) already exists. Phase 2 wires it to the Liaison:

```
GitHub webhook → receiver.py → events queue (.chump-locks/webhook-events.jsonl)
                                     ↓
                               Liaison drains queue
                                     ↓
                            Immediate cache update
                                     ↓
                        All workers see fresh state in <1s
```

Polling interval extends from 30s → 300s (5 min) once webhooks are primary. Polling becomes a fallback for missed events only.

### Mutation Routing (Phase 3)

Workers continue to make mutations directly in Phase 1–2 (pr create, pr merge, update-branch). Phase 3 routes them through the Liaison via NATS request/reply:

```
Worker: publish chump.github.mutate.merge_pr {pr: 1234, method: "squash"}
           → awaits reply subject (timeout: 30s)

Liaison: receives mutation request
           → applies backoff (INFRA-1311 logic)
           → calls gh pr merge 1234 --squash
           → publishes result to reply subject

Worker: receives result, continues
```

Benefits: centralized rate limiting, backoff state shared across all workers, no per-worker backoff drift.

### GitHub App Token (Phase 4)

Create a GitHub App for `repairman29/chump`:
- App token has **separate** 5000 GraphQL points/hr quota from Jeff's user token
- App can subscribe to webhook events natively (no smee/ngrok needed in prod)
- Fleet workers use App token; Jeff's user token for interactive `gh` use only

The Liaison is the natural place to hold the App token (it's the only process talking to GitHub reads).

---

## Migration Plan

### Phase 0 → 1: Liaison Election + Cache-Mandatory Reads

**Gap:** INFRA-1312 (file immediately, effort: m)

**Steps:**
1. Create `scripts/coord/github-liaison.sh` — election + refresh loop
2. Wire election into `scripts/dispatch/worker.sh` — after lease renewal, check if liaison; if yes, fork refresh loop as background job
3. Create `scripts/coord/lib/github_cache.sh` additions:
   - `cache_mandatory_lookup_pr` — strict mode that logs `cache_miss_direct_fallback` but still falls back (Phase 1)
   - `CHUMP_LIAISON_STRICT` knob (default `0`)
4. Register `github_liaison_heartbeat`, `cache_miss_direct_fallback` in EVENT_REGISTRY.yaml
5. CI test: launch 3 workers, verify only 1 becomes liaison, others are readers

**Deployment:**
```bash
# No config change needed — liaison elected automatically on next worker start
# Monitor: tail -f .chump-locks/ambient.jsonl | grep github_liaison
# Verify: watch for cache_miss_direct_fallback to decrease over 24h
# Gate: cache_miss_direct_fallback events < 10/hr before proceeding to Phase 2
```

**Rollback:** `rm -rf .chump-locks/github-liaison.lock` — all workers revert to direct API calls. Zero data loss.

---

### Phase 1 → 2: Webhook-First Cache

**Gap:** INFRA-1313 (file after Phase 1 stable, effort: m)
**Depends on:** `scripts/ops/github-webhook-receiver.py` running (INFRA-1000 umbrella)

**Steps:**
1. Add webhook event queue: receiver.py appends to `.chump-locks/webhook-events.jsonl`
2. Liaison drains webhook queue in `_drain_webhook_queue()`: parse event type, update `pr_state` / `check_runs` as appropriate
3. Extend Liaison poll interval from 30s → 300s
4. Handle missed-webhook detection: if `updated_at` for any open PR is stale > 5min, do targeted refresh

**Deployment:**
```bash
# Start webhook receiver if not already running
python3 scripts/ops/github-webhook-receiver.py &

# Configure GitHub webhook in repo settings → point to receiver URL
# (ngrok in dev, proper endpoint in prod)

# Monitor: webhook events flowing
tail -f .chump-locks/webhook-events.jsonl

# Verify: poll interval drops to 300s (check github_liaison_heartbeat events)
# Gate: webhook delivery rate > 95% of PR events before flipping CHUMP_LIAISON_STRICT=1
```

**Rollback:** set `CHUMP_LIAISON_POLL_INTERVAL=30` to revert to polling; webhooks become optional supplement.

---

### Phase 2 → 3: Mutation Routing via NATS

**Gap:** INFRA-1314 (file after Phase 2 stable, effort: l)
**Depends on:** NATS available (FLEET-034)

**Steps:**
1. Add NATS subjects: `chump.github.mutate.*`
2. Liaison subscribes and executes mutations with shared backoff state (uses INFRA-1311 logic)
3. Workers publish to subject instead of calling `chump_gh` directly for mutations
4. Timeout: 30s per mutation request; workers fall back to direct call on timeout
5. Backoff shared across all workers via Liaison — no more per-worker drift

**Deployment:**
```bash
# Requires NATS running (FLEET-034 prerequisite)
export CHUMP_MUTATION_ROUTING=liaison  # opt-in per-worker

# Monitor: mutation queue depth
# Gate: mutation success rate > 99% with routing before making default
```

**Rollback:** unset `CHUMP_MUTATION_ROUTING` — workers revert to direct calls.

---

### Phase 3 → 4: GitHub App Token

**Gap:** update INFRA-1076 with liaison context (already filed, effort: m)

**Steps:**
1. Create GitHub App for `repairman29/chump` at https://github.com/settings/apps
   - Permissions: Pull requests (read+write), Checks (read), Contents (read), Metadata (read)
   - Webhooks: subscribed to pull_request, check_suite, push, workflow_run
2. Store App credentials: `CHUMP_GH_APP_ID`, `CHUMP_GH_APP_PRIVATE_KEY_PATH` in env
3. Liaison generates installation access tokens (expiry 1hr, auto-renewed)
4. Workers use App token via `CHUMP_GH_TOKEN` env var; Liaison distributes via NATS KV
5. Jeff's user token remains for interactive `gh` use, completely separate from fleet

**Deployment:**
```bash
# Liaison-only change — workers just consume the token it distributes
# Gate: verify App token quota is separate from user token quota
# Monitor: rate_limit API shows separate counters for App vs user
```

**Rollback:** unset `CHUMP_GH_APP_ID` — Liaison reverts to user token.

---

## Measurement Gates

Each phase requires these metrics before proceeding:

| Gate | Measure | Tool |
|---|---|---|
| Phase 1 stable | `cache_miss_direct_fallback` < 10/hr | `grep cache_miss_direct_fallback ambient.jsonl \| tail -60 \| wc -l` |
| Phase 1 → 2 | Liaison elected and heartbeating continuously for 24h | `grep github_liaison_heartbeat ambient.jsonl \| tail -1` |
| Phase 2 stable | Webhook delivery rate > 95%, liaison poll interval = 300s | webhook events vs expected PR activity |
| Phase 2 → 3 | `gh_self_throttled` events < 100/day | `grep gh_self_throttled ambient.jsonl \| wc -l` |
| Phase 3 stable | Mutation success rate > 99% via NATS routing | `grep bot_merge_backoff_skipped ambient.jsonl` |
| Phase 4 | Rate limit quota shows separate App vs user counters | `curl .../rate_limit` with both tokens |

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Liaison dies → all workers stall | Med | High | Stale-lock detection (90s TTL). Workers revert to direct API within 90s. |
| Cache serves stale PR state | Low | Med | `updated_at` TTL check; Liaison refresh every 30s catches any webhook miss |
| NATS down in Phase 3 | Med | Med | Mutation routing falls back to direct call on NATS timeout |
| Webhook receiver not running | High | Low | Liaison detects via webhook age; increases poll rate automatically |
| macOS syspolicyd kills liaison script | Low | Low | Same issue as INFRA-275; Liaison is long-lived process, no restart needed |
| GitHub App approval lag | Med | None | Phase 4 is purely additive; Phases 1–3 work without it |

---

## Relation to Existing Gaps

| Gap | How this absorbs or supersedes it |
|---|---|
| INFRA-1000 (webhook umbrella) | Phase 2 is the concrete implementation of INFRA-1000 |
| INFRA-1076 (GitHub App) | Phase 4; Liaison is the natural home for App token |
| INFRA-1114 (consolidate gh callers) | Phase 1 makes this mostly moot — all reads go to cache |
| INFRA-1234 (extract gh wrappers to Rust) | Phase 3 Liaison is a better home for this logic than a Rust crate |
| FLEET-034 (NATS push distribution) | Phase 3 mutation routing is built on FLEET-034 infrastructure |
| A2A_ROADMAP.md Layer 1 | Liaison election is the first concrete use of NATS leader election |

---

## What This Unlocks Beyond Rate Limiting

1. **Cross-machine fleet**: when Liaison runs on one machine, workers on other machines read cache via shared SQLite (NFS/synced) or NATS KV. No GitHub credentials needed on worker machines.
2. **Offline mode**: workers operate fully offline (cache from last Liaison sync). Liaison reconnects when network returns and reconciles.
3. **Audit**: all GitHub reads and writes are funneled through one process → perfect observability of GitHub API usage.
4. **GitHub App multi-tenant**: each tenant gets their own App installation with independent quota. Fleet can serve multiple repos without quota sharing.
5. **Mean PR-time-to-merge**: eliminating retry waste (INFRA-1311) + instant webhook cache updates means merge pipeline latency drops from hours to minutes.

---

## Implementation Order

```
TODAY (Phase 1):
  [x] INFRA-1310 — cascade-rebase debounce (shipped PR #2006)
  [x] INFRA-1311 — bot-merge backoff (PR #2002, CI pending)
  [x] INFRA-1082 — cache-first pr view/list (PR #2005, CI pending)
  [ ] INFRA-1312 — GitHub Liaison election + refresh loop (file now, pick next)

THIS WEEK (Phase 2):
  [ ] INFRA-1313 — Liaison webhook integration
  [ ] Ensure github-webhook-receiver.py is running continuously (launchd)

NEXT WEEK (Phase 3, NATS-gated):
  [ ] INFRA-1314 — Mutation routing via NATS request/reply

MONTH 2 (Phase 4):
  [ ] INFRA-1076 update — GitHub App token via Liaison
```

The first three are already shipped or in CI. INFRA-1312 is the architectural keystone.
