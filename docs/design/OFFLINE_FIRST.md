---
doc_tag: design-architecture
last_audited: 2026-05-15
audience: operator, fleet engineers, Mission Driver
purpose: Offline-first architecture — how Chump works with no internet, no GitHub, and in Pi-mesh deployments. Companion to GITHUB_LIAISON.md.
status: v1 — operator review requested; gaps filed as INFRA-1320 through INFRA-1323
---

# Offline-First Architecture

> **The core question:** If GitHub disappeared tomorrow, could Chump still do useful work? Today: **no**. Bot-merge.sh hard-crashes on `git push` failures, workers stall waiting for GitHub Actions CI that never resolves, gap ships fail. This doc designs the fix.

## Why This Matters

From `docs/process/CLAUDE_GOTCHAS.md` and the operator's memory:

> "Chump enables offline solo devs on local LLMs; bespoke coordination layer is load-bearing strategy, not tech debt."

This isn't aspirational — it's the design constraint that justifies every decision to build custom coordination rather than using GitHub Issues/Projects/Actions. The Pi mesh (4 Raspberry Pis, no internet, Llama running on each) is the target deployment. The airplane-with-MacBook is the minimum viable test.

**What already works offline:**
- LLM inference (`CHUMP_LOCAL_ONLY=1` + Ollama)
- Gap registry (`state.db` SQLite, local)
- File leases (`.chump-locks/`)
- Ambient events (`ambient.jsonl`)
- Pre-commit hooks (shellcheck, cargo test, clippy)
- Individual CI scripts (`scripts/ci/test-*.sh`)
- NATS coordination (on local network)
- Inference mesh (`CHUMP_CLUSTER_MODE=1`, Mac + iPhone)

**What currently breaks without internet:**
- `git push origin` → stalls/fails → worker dies
- `gh pr create` → fails → ship path dead
- GitHub Actions CI → never resolves → merges blocked forever
- Liaison polling → cache goes stale indefinitely
- `gh pr merge` → fails
- `gh auth token` → may fail (token refresh)

---

## Two Offline Scenarios

### Scenario A: Pi Mesh (local network, no internet)

```
[Pi 1: git origin + NATS] ←→ [Pi 2: worker] ←→ [Pi 3: worker] ←→ [Pi 4: worker]
      ↕ SSH/git                    ↕ NATS                ↕ NATS
  [state.db primary]          [local LLM]            [local LLM]
```

Workers push to Pi 1 (local git origin). NATS on the mesh coordinates claims. No internet required for any step. When internet returns (optionally), Pi 1 syncs to GitHub.

### Scenario B: Airplane Mode (completely isolated)

```
[MacBook: all workers, NATS, git local]
  - LLM: Ollama (local)
  - git: commits to local branches, push deferred
  - Coordination: NATS on loopback
  - CI: local scripts
  - Merge: local merge queue
  - Sync: push to GitHub when WiFi returns
```

The architecture is the same for both — they're points on a spectrum of network availability.

---

## The Missing Pieces

### 1. Local CI Gate

**Problem:** The current merge gate is "GitHub Actions must be green." Offline, that's never true.

**Solution:** A local CI runner that executes exactly what GitHub Actions runs, in the same order. This IS your CI. GitHub Actions is just a hosted executor of the same checks.

```bash
# scripts/ci/run-local-ci.sh (INFRA-1320)
# The complete local CI gate — runs everything GitHub Actions runs.
# Exit 0 = mergeable. Exit 1 = blocked.

set -euo pipefail

echo "=== Chump Local CI Gate ==="

# Tier 1: Fast checks (< 30s)
echo "[1/4] Fast checks..."
cargo fmt --check --quiet                              # formatting
shellcheck $(git diff --staged --name-only | grep '\.sh$') # staged files
bash scripts/ci/test-waste-spike-pause.sh              # FLEET-054
bash scripts/ci/test-cascade-rebase-debounce.sh        # INFRA-1310
# ... all scripts/ci/test-*.sh that don't need GitHub

# Tier 2: Rust checks (< 2min)
echo "[2/4] Rust..."
cargo clippy --all-targets --all-features -- -D warnings
cargo test --workspace --quiet

# Tier 3: Integration checks (< 5min)
echo "[3/4] Integration..."
bash scripts/ci/run-feature-smokes.sh
bash scripts/ci/run-stories.sh

# Tier 4: Gap registry health
echo "[4/4] Gap registry..."
chump gap audit-priorities
scripts/ci/gap-integrity-check.sh

echo "=== Local CI: PASS ==="
```

This exists in pieces today (`cargo test`, individual `scripts/ci/test-*.sh`, pre-commit hooks). The gap is a unified runner that mimics what `.github/workflows/ci.yml` does, runnable without network.

**Offline-CI contract:** Any check that requires GitHub API, external network, or cloud services is **excluded** from `run-local-ci.sh`. It goes in `run-remote-ci.sh` instead. The split makes offline status explicit.

---

### 2. Local Merge Queue

**Problem:** `bot-merge.sh` is entirely built around the GitHub PR state machine:
1. Push branch → GitHub
2. Create PR → GitHub
3. Wait for GitHub Actions CI → GitHub
4. Call `gh pr merge` → GitHub

All four steps require GitHub. Zero of them work offline.

**Solution:** A local merge queue built on NATS KV + local git.

```
NATS KV key: "chump.merge-queue.lock"
             (TTL=120s, renewed by active merger)

Queue entry: "chump.merge-queue.pending.<gap-id>"
             value: {"gap":"INFRA-1234","branch":"chump/infra-1234-claim","worker":"..."}
```

Merge flow:

```bash
# scripts/coord/local-merge-queue.sh (INFRA-1321)

local_gap_ship() {
    local gap_id="$1"
    local branch="$2"

    # Step 1: Run local CI
    echo "[$gap_id] Running local CI..."
    bash scripts/ci/run-local-ci.sh || { echo "CI failed — not merging"; return 1; }

    # Step 2: Acquire merge lock (NATS KV CAS; falls back to file lock)
    echo "[$gap_id] Acquiring merge queue lock..."
    _acquire_merge_lock "$gap_id" || return 1

    # Step 3: Rebase onto current local main
    git fetch origin main 2>/dev/null || true  # best-effort network fetch
    git rebase origin/main || git rebase main  # works offline with local main

    # Step 4: Run CI again (post-rebase)
    bash scripts/ci/run-local-ci.sh || { _release_merge_lock; return 1; }

    # Step 5: Merge to local main
    git checkout main && git merge --squash "$branch"
    git commit -m "$(git log $branch -1 --format='%s') [local-merge]"

    # Step 6: Record in gap registry
    chump gap ship "$gap_id" --local-merge --sha "$(git rev-parse HEAD)"

    # Step 7: Emit ambient event
    _emit_ambient "gap_merged_local" "\"gap\":\"$gap_id\",\"sha\":\"$(git rev-parse HEAD)\""

    # Step 8: Queue push for when network returns
    _queue_push_when_connected "main"

    _release_merge_lock
    echo "[$gap_id] Merged locally. Will push to GitHub when connected."
}
```

**The "queue push" pattern:** instead of failing on `git push`, enqueue the push in `.chump-locks/pending-push.jsonl`. A background daemon (`scripts/coord/network-sync-daemon.sh`) watches for network and flushes the queue.

---

### 3. Network Sync Daemon

**Problem:** When working offline, commits pile up locally. When network returns, they need to be synced in order, with PRs created retroactively if desired.

```bash
# scripts/coord/network-sync-daemon.sh (INFRA-1322)

sync_loop() {
    while true; do
        if _network_available; then
            _flush_pending_pushes
            _create_retroactive_prs  # optional, controlled by CHUMP_RETROACTIVE_PRS=1
            _sync_github_cache       # bring Liaison cache up to date
        fi
        sleep 30
    done
}

_network_available() {
    # Fast check: can we reach GitHub at all?
    curl -sf --max-time 3 https://api.github.com/zen >/dev/null 2>&1
}

_flush_pending_pushes() {
    local queue=".chump-locks/pending-push.jsonl"
    [[ -f "$queue" ]] || return 0

    while IFS= read -r entry; do
        local branch; branch=$(echo "$entry" | python3 -c "import sys,json; print(json.load(sys.stdin)['branch'])")
        if git push origin "$branch" --force-with-lease 2>/dev/null; then
            _emit_ambient "pending_push_synced" "\"branch\":\"$branch\""
        fi
    done < "$queue"

    # Clear the queue
    rm -f "$queue"
}
```

**Retroactive PRs:** with `CHUMP_RETROACTIVE_PRS=1`, the sync daemon creates GitHub PRs for all locally-merged gaps when reconnecting. This provides the audit trail in GitHub even for offline work.

Without retroactive PRs (`CHUMP_RETROACTIVE_PRS=0`, default offline), the gap registry in `state.db` IS the audit trail. GitHub is just a remote backup.

---

### 4. GitHub Interaction Mode Knob

A single env var controls the fleet's GitHub posture:

```bash
# CHUMP_GITHUB_MODE controls how much the fleet relies on GitHub:
#
#   full         (default) — current behavior: PRs, bot-merge, CI waits on GitHub Actions
#   liaison      — INFRA-1317: reads via cache only, mutations still direct
#   publish-only — workers push + create PRs but never poll GitHub for state
#   offline      — no GitHub contact at all; local merge queue + pending push queue
#
export CHUMP_GITHUB_MODE="${CHUMP_GITHUB_MODE:-full}"
```

Mode behavior matrix:

| Capability | full | liaison | publish-only | offline |
|---|---|---|---|---|
| Read PR state | direct API | cache-only | cache-only | cache-only (stale ok) |
| Create PR | yes | yes | yes | queued |
| Merge PR | bot-merge | bot-merge | bot-merge | local merge queue |
| CI gate | GitHub Actions | GitHub Actions | GitHub Actions | `run-local-ci.sh` |
| Push on ship | immediate | immediate | immediate | queued (pending-push) |
| Works without internet | ❌ | ❌ | ❌ | ✅ |

The `offline` mode is the target for Pi mesh and airplane deployments.

**Auto-detection (INFRA-1323):** If `CHUMP_GITHUB_MODE` is unset AND GitHub is unreachable at startup, automatically switch to `offline` mode and emit `kind=fleet_github_offline` to ambient.jsonl. Workers see this event and switch to local merge queue. When network returns, switch back to `full` and flush the pending push queue.

---

## Pi Mesh Deployment

### Hardware target

```
Pi 1: git origin + NATS broker + state.db primary
Pi 2: worker (Llama 70B, 8GB RAM)
Pi 3: worker (Llama 70B, 8GB RAM)
Pi 4: worker (Llama 70B, 8GB RAM)
```

### Setup

```bash
# On Pi 1 (coordinator):
git init --bare /srv/git/chump.git
nats-server -config /etc/nats/server.conf &
# state.db is primary here; other Pis rsync from it

# On Pi 2-4 (workers):
git clone pi1:/srv/git/chump.git
export CHUMP_GITHUB_MODE=offline
export CHUMP_NATS_URL=nats://pi1:4222
export CHUMP_LOCAL_ONLY=1           # use local Llama, not Anthropic
export OPENAI_API_BASE=http://pi1:8000/v1  # Pi 1 hosts the model server
scripts/dispatch/worker.sh
```

### What "CI" means on the Pi mesh

The CI gate for a Pi mesh merge is `run-local-ci.sh`. There's no "GitHub Actions" — the tests ARE the CI. This is fundamentally the correct model. GitHub Actions is an executor, not a definer of correctness. If your tests pass locally, the code is correct.

For multi-Pi validation, you can optionally run the test suite on each Pi in parallel (CI-as-distributed-test), coordinated via NATS. But for a 4-Pi mesh with local LLMs, the overhead isn't worth it — one node runs CI, results propagate via NATS.

### State sync across Pis

```
state.db primary: Pi 1
state.db replicas: Pi 2-4 (read-mostly, pull from Pi 1 every 60s)
Conflict resolution: NATS KV is authoritative for gap claims;
                     state.db is eventually consistent
```

For the merge queue, only Pi 1 writes to the primary state.db. Workers on Pi 2-4 request merges via NATS (`chump.merge-queue.pending.*`), Pi 1 executes and broadcasts the result.

---

## CI Design: Local vs Remote Checks

The key split: separate what CI **checks** from what **hosts** the check.

```
scripts/ci/
  run-local-ci.sh       ← everything that works offline (INFRA-1320)
  run-remote-ci.sh      ← checks requiring GitHub API, external services
  
  Individual test scripts are categorized:
    test-*.sh             ← offline-capable (most of them)
    test-*-gh-*.sh        ← requires GitHub API (tagged explicitly)
```

**Why most CI tests are already offline-capable:**
- `scripts/ci/test-waste-spike-pause.sh` — stubs chump binary, no network
- `scripts/ci/test-cascade-rebase-debounce.sh` — pure bash, no network
- `cargo test` — pure Rust, no network
- `cargo clippy` — pure Rust, no network
- `shellcheck` — pure static analysis

The ones that need network are the integration tests that actually push to GitHub or wait for GitHub Actions. Those go in `run-remote-ci.sh`. They're still run in GitHub Actions CI but are not required for offline merges.

---

## Gap-to-Ship Flow: Offline vs Online

**Online (current, GitHub-dependent):**
```
write code → commit → git push → gh pr create → CI (GitHub Actions) → gh pr merge → gap ship
```

**Offline (target):**
```
write code → commit → run-local-ci.sh → local merge queue (NATS) → git merge local main
                                                                           ↓
                                                              pending-push queue
                                                                           ↓
                                                         (when connected) git push + gh pr create (optional)
```

**The key insight:** the code quality gate (CI) and the code persistence gate (merge to main) are decoupled from GitHub's involvement. GitHub becomes an async publication channel, not a merge authority.

---

## Migration Plan

### Phase 0 → 1: Local CI runner (INFRA-1320)

**What:** `scripts/ci/run-local-ci.sh` that mirrors GitHub Actions CI checks.

**Why first:** Every subsequent step depends on having a trustworthy local CI gate.

**Deployment:**
```bash
# Test it works:
bash scripts/ci/run-local-ci.sh

# Wire into pre-push for offline mode:
# (only fires when CHUMP_GITHUB_MODE=offline)
```

**Gate to next phase:** `run-local-ci.sh` exits 0 on a clean branch (no false negatives), and fails correctly on a broken branch.

---

### Phase 1 → 2: Local merge queue (INFRA-1321)

**What:** `scripts/coord/local-merge-queue.sh` + `chump gap ship --local-merge`.

**Why second:** With local CI, we can trust locally-merged code. Now we need the coordination mechanism.

**Deployment:**
```bash
export CHUMP_GITHUB_MODE=offline
# Workers automatically use local-merge-queue.sh instead of bot-merge.sh
```

---

### Phase 2 → 3: Network sync daemon (INFRA-1322)

**What:** `scripts/coord/network-sync-daemon.sh` — background daemon that flushes pending pushes and syncs cache when network returns.

**Deployment:**
```bash
# Start daemon (launchd plist also provided):
scripts/coord/network-sync-daemon.sh &
```

---

### Phase 3 → 4: Auto-detect offline mode (INFRA-1323)

**What:** If GitHub unreachable at startup → automatically set `CHUMP_GITHUB_MODE=offline`. Emit `fleet_github_offline`. When network returns, emit `fleet_github_online` + flush queues.

**Deployment:** Zero config needed. Worker.sh auto-detects at startup.

---

## Relation to GitHub Liaison (GITHUB_LIAISON.md)

The Liaison and offline-first designs are complementary layers:

```
GitHub Liaison (GITHUB_LIAISON.md):
  "If you ARE connected, use GitHub as efficiently as possible"
  → 1 client, cache-first, webhook-driven

Offline-first (this doc):
  "If you are NOT connected, work just as well without GitHub"
  → local CI, local merge queue, pending push queue

Together:
  Connected + Liaison = efficient GitHub use
  Disconnected + offline-first = zero GitHub dependency
  Reconnecting = sync daemon bridges the two
```

Both treat GitHub as infrastructure, not as a coordination authority. The gap registry, NATS KV, ambient.jsonl, and state.db are the actual coordination surfaces — GitHub is just a widely-used git remote with a nice web UI.

---

## Filed Gaps

| Gap | Title | Phase | Effort |
|---|---|---|---|
| INFRA-1320 | Local CI runner (`run-local-ci.sh`) | 0→1 | s |
| INFRA-1321 | Local merge queue (NATS KV + `local-merge-queue.sh`) | 1→2 | m |
| INFRA-1322 | Network sync daemon (pending push + cache flush) | 2→3 | s |
| INFRA-1323 | Auto-detect offline mode + graceful degradation | 3→4 | m |

---

## What the Pi Mesh Unlocks

Once offline-first lands, the Pi mesh is deployable:

1. **Cost**: 4× Raspberry Pi 5 (8GB) ≈ $300. Inference at ~8 tok/s per Pi for 7B models, ~2 tok/s for 13B. Enough for Haiku-equivalent quality on coding tasks.
2. **Privacy**: code never leaves the local network. Third-party content can be processed without `CHUMP_ROUND_PRIVACY=safe`.
3. **Reliability**: no GitHub outage, no Anthropic outage, no rate limits. The fleet just runs.
4. **Economics**: zero per-token cost after hardware. NSF/DARPA/Mozilla grant compatibility (no commercial API dependency).

The 5-year break-even analysis from the operator's hardware economics memo applies here too — the offline-first architecture is what makes the hardware investment rational.
