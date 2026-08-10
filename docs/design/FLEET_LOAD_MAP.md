# Fleet load map — get ChumpOS off the Mac, split across Helsinki + CJ

> Ground-truthed 2026-08-10 from all three machines. The goal: the Mac stops being
> load-bearing; Helsinki runs the OS; CJ is the GPU it calls.

---

## The core principle

The three machines are **not interchangeable** — place each job by its dominant property:

| Property of the job | Goes to | Why |
|---|---|---|
| Always-on, stable network, no GPU | **Helsinki** | Datacenter VM, fixed IP, never sleeps |
| GPU / inference | **CJ** | The only accelerator in the fleet (GTX 970) |
| Data-gravity (almanac index) | **Mac** (for now) | 111 repo DBs live here; moving them is its own project |
| Interactive / dev | **Mac** | Your daily driver + Claude sessions |

**CJ and Helsinki don't share load symmetrically — they complement.** Helsinki is the
always-on brain (CPU, coordination); CJ is the GPU muscle it calls. CJ *cannot* take
always-on infra (residential Wi-Fi + NAT, 8GB) — so it takes 0% of the broker/control
plane. And CJ takes only the **small** slice of inference — its GTX 970 is 4GB.

### Inference is tiered — CJ is only the smallest tier

CJ's 4GB caps it to tiny models. It does NOT do "all inference." The real ladder:

| Tier | Workload | Where | Cost shape |
|---|---|---|---|
| **Small / continuous** | embeddings, Whisper, 3B summaries | **CJ** (owned GPU) | free, already paid |
| **Bigger, occasional** | 7B–70B open models, medium reasoning | **serverless per-token** (Together / Fireworks / DeepInfra / Groq) | pay-per-token, **scales to zero** |
| **One-off heavy batch** | a drain/fine-tune too big for CJ | **rent cloud GPU by the hour** (RunPod / Vast.ai / Lambda) | ~$0.20–0.70/hr, killed when done |
| **Frontier reasoning / authoring** | the hard code, judgment | **Claude** | per-token API |

**Not on the ladder: AWS.** g5/p4/p5 are the most expensive per-hour and priced for an
enterprise ecosystem you don't need. Serverless-per-token providers are literally what
this use case is *made for* — skip AWS.

**Buy a bigger GPU only** when a break-even calc shows sustained local load is cheaper
owned than rented. Until then: CJ for small, serverless for medium, rent for one-offs.

---

## Current state (the mess)

```
                 ┌─────────────────────────────────────────┐
   MAC (M4,24GB) │ ⚠ LOAD-BEARING — should not be           │
   daily driver  │  • nats-server (one of TWO live brokers) │
   lid closes!   │  • webhook→smee→cache pipeline (LIVE now) │
                 │  • oauth-refresh, token-tether (auth)     │
                 │  • ~30 control-plane daemons (reapers…)   │
                 │  • almanac index + 4 crons + this session │
                 └─────────────────────────────────────────┘
   HELSINKI      ┌─────────────────────────────────────────┐
   (VM,8GB,      │  • chumpd + 7 workers (the shipper) ✓     │
    always-on)   │  • nats-server (the OTHER live broker)    │
   56G free,     │  • searxng (web search)                   │
   load ~1.0     │  • points at a DEAD broker IP (broken)    │
                 └─────────────────────────────────────────┘
   CJ (GPU,8GB,  ┌─────────────────────────────────────────┐
    home wifi)   │  • ollama: nomic-embed + llama3.2:3b ✓    │
                 │  • chumpd DISABLED — pure inference ✓     │
                 │  • 6.4G free, GPU idle-ready              │
                 └─────────────────────────────────────────┘
```

**Two things are actually broken right now:**
1. **Broker split-brain.** `CHUMP_NATS_URL` → `100.120.232.0:4222`, which is dead
   (not on the tailnet, unreachable). Mac and Helsinki each run a *separate* local
   nats-server. Coordination is not going through one broker.
2. **The Mac is single-point-of-failure** for auth + PR-cache + control plane, on a
   laptop that sleeps and moves. This is the root of every "lid-close killed the fleet."

---

## Target state (Mac freed)

```
   HELSINKI = THE OS                          CJ = THE GPU RESOURCE
   ┌──────────────────────────┐    calls      ┌────────────────────────┐
   │ • NATS broker (the ONE)  │ ────────────▶ │ • ollama embeddings    │
   │ • chumpd + workers       │   inference   │ • ollama summaries     │
   │ • control plane (reapers,│               │ • whisper (voice, later)│
   │   watchdogs, curators,   │ ◀──────────── │ • nothing always-on-    │
   │   deliberator, conductor)│   results     │   critical depends on it│
   │ • auth (oauth-refresh)   │               └────────────────────────┘
   │ • webhook→cache pipeline │
   └──────────────────────────┘
   MAC = dev + almanac index + interactive Claude. NOTHING load-bearing.
   Lid can close without touching the fleet.
```

---

## What's needed — phased, each phase independently shippable

### Phase 0 — Fix the broker (foundational, do first)
- [ ] Identify/kill the dead `100.120.232.0` reference; pick **one** broker = Helsinki
      (`100.101.188.30:4222`), stable tailnet IP, always-on.
- [ ] Point every node's `CHUMP_NATS_URL` at Helsinki. Remove the Mac's nats-server.
- [ ] Verify `chump-coord watch` sees all nodes through the one broker.
- **Risk:** low. **Unblocks:** everything else (coordination must be sane first).

### Phase 1 — Auth → Helsinki
- [ ] Run `oauth-refresh` + `token-tether` + `auth-floor-setenv` as systemd units on
      Helsinki (workers there need a live token).
- [ ] Verify `scripts/coord/auth-status.sh` is green on Helsinki.
- **Risk:** medium (auth is load-bearing). **Test:** Helsinki ships a PR end-to-end.

### Phase 2 — PR-cache pipeline → Helsinki
- [ ] Move `smee-tunnel` + `github-webhook-receiver` + `github-cache-reconcile` +
      `github_cache.db` to Helsinki (new smee channel, receiver as systemd unit).
- [ ] Fleet scripts read the cache from Helsinki (or a tailnet-shared path).
- **Risk:** medium. **Test:** a real PR event lands in Helsinki's cache within seconds.

### Phase 3 — Control plane → Helsinki
- [ ] Port the ~30 reaper/watchdog/shepherd/curator/deliberator/conductor plists to
      systemd units on Helsinki. Most act on local worktree/disk state → they belong
      where the workers run.
- [ ] Remove them from Mac launchd (archive, don't delete).
- **Risk:** medium; do in small batches, watch ambient for gaps in coverage.

#### Phase 3 cost-decision gate — cap workers before bumping RAM, measure before spending

Helsinki RAM is a **recurring monthly cost** (~$13–15/mo ≈ $160–180/yr for CPX31→CPX41),
unlike CJ's one-time $20 stick. So do NOT provision speculatively. Ground truth
2026-08-10: Helsinki has **6.5GB free / 8GB swap barely touched** even with 7 workers +
cargo builds — the control-plane daemons are *light* (periodic scripts, ~200–400MB total),
so migrating them should barely move the needle.

The memory variable is **concurrent worker cargo builds**, not the daemons. Decision order:
1. Migrate the control plane; watch peak memory + swap under real load for a few days
   (`free`, `journalctl` for OOM).
2. If it gets tight, **cap Helsinki worker count** (7 → 4–5) first — workers are the
   tunable, daemons are cheap. The 8GB swapfile already cushions spikes at $0.
3. Bump the instance **only** if peak pushes swap hard *with workers already capped*.

Cost-optimal architecture: keep Helsinki on the cheap tier by (a) using CJ's already-paid
GPU for the small inference tier so Helsinki never holds a model, and (b) capping worker
concurrency to fit 8GB. The $20 CJ stick + a worker cap beat $180/yr on Helsinki — spend
there first. (Hetzner tier inferred from specs; confirm CPX31→CPX41 delta on the console.)

### Phase 4 — CJ inference, formalized (mostly done)
- [x] ollama enabled at boot, chumpd disabled, tailnet-only.
- [ ] Node registry entry: `role: inference, accelerator: gtx970-4gb`.
- [ ] All inference consumers point at CJ: almanac embed ✓, summaries (via the
      `com.jeffadkins.almanac.summarize` launchd job repointed at CJ), whisper later.

### Phase 5 — almanac (the data-gravity decision)
- Index (111 repo DBs) lives on the Mac. Two options:
  - **(a) Keep on Mac**, run the summarize/embed crons on the Mac driving CJ's GPU.
    Simple, but the Mac must be awake for refreshes.
  - **(b) Migrate the index to Helsinki** so it's always-on and Helsinki drives the
    drain against CJ with no Mac dependency. Cleaner; a real migration.
- Recommend (a) now, (b) as a follow-on. Either way the summarize **driver runs
  once, durably** (a launchd/systemd unit) — not hand-launched (tonight's mistake).

---

## The honest constraints

- **Helsinki is also 8GB.** Piling broker + workers + 30 daemons onto it risks the same
  memory wall CJ hit. Phase 3 may force a Helsinki worker-count cap or a RAM bump.
  The fleet has *two* 8GB boxes doing heavy work — memory is the recurring ceiling.
- **CJ is residential.** Fine for inference (Helsinki retries on a Wi-Fi blip); never
  put anything on CJ that others need 24/7 with zero tolerance.
- **This is a multi-session migration.** Each phase is independently verifiable — do
  them in daylight, one at a time, watching ambient after each. Not a single big cutover.
