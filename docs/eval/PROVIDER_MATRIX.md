# EVAL-089 — Provider matrix bake-off

One-shot grading rig for the `chump-local` dispatch backend (COG-025).
Runs the same `chump --execute-gap <GAP-ID>` task against every
OpenAI-compatible provider configured in `.env`, captures one JSON status
row per provider, then prints a verdict table. Lets us see which
**model × provider** pairs can actually carry an end-to-end PR rather
than guessing from anecdote.

This is **not** a long-running service. It's a benchmark you re-run
when you've added a new provider or changed the dispatch prompt. It
does not retry on 429 — saturation gets recorded as data, not retried
into a hidden success.

## Files

| Path | What |
|---|---|
| `scripts/eval/provider-matrix.sh` | Driver — one worktree per provider, captures stdout/stderr, classifies outcome. |
| `scripts/eval/provider-matrix-summary.sh` | Reads `.chump/bakeoff/<GAP-ID>/*.json`, prints verdict table. |
| `.chump/bakeoff/<GAP-ID>/<provider>.json` | Per-provider status row written by the driver. |
| `.chump/bakeoff/<GAP-ID>/<provider>.{stdout,stderr}.log` | Raw logs for the run. |

## Outcomes (in rank order, best first)

| Outcome | Meaning | Model verdict? |
|---|---|---|
| `ship` | Agent opened a PR. | Yes — model + provider both work. |
| `exit0_no_pr` | Agent exited cleanly without shipping. | Yes — model gave up. |
| `tool_storm` | Circuit-breaker tripped on bad tool calls. | Yes — model can't call tools. |
| `rate_limited` | Provider returned 429 / queue_exceeded. | **No** — provider saturation. Re-run later. |
| `error` | Infra failure (worktree, claim, process). | No — fix harness and rerun. |
| `skip` | Provider config absent in `.env`. | N/A. |

## Usage

```bash
# Build chump first — the harness uses the release binary, won't build for you:
cargo build --release --bin chump

# Run every provider whose <PFX>_API_KEY is set:
scripts/eval/provider-matrix.sh INFRA-080

# Run only a subset (case-insensitive):
scripts/eval/provider-matrix.sh INFRA-080 GROQ NVIDIA

# Aggregate the results:
scripts/eval/provider-matrix-summary.sh INFRA-080

# Or pull the raw JSON:
scripts/eval/provider-matrix-summary.sh INFRA-080 --json | jq .
```

## Adding a provider

Each provider declares a triple of env vars in `.env`:

```bash
<PFX>_API_BASE   # OpenAI-compatible base URL (e.g. https://api.example.com/v1)
<PFX>_API_KEY    # auth token
<PFX>_MODEL      # model id to send
```

Then add the prefix to the `PROVIDERS` array at the top of
`scripts/eval/provider-matrix.sh`. That's it — the harness takes care of
worktree creation, gap claim, env mapping (`<PFX>_*` → `OPENAI_*`),
outcome classification, and cleanup.

`.env.example` has commented stub blocks for the nine providers
currently on the matrix. Uncomment + fill in the key to enable a slot.

## Why a separate worktree per run

Provider runs are **serial** — gap claims are per-gap, not per-worktree,
so two providers can't legally hold the same gap at once. We still spawn
a fresh worktree per run for two reasons:

1. **Branch hygiene.** Each provider's PR (if it ships) lands on its own
   branch with its own author identity (`Chump Dispatched (<PFX>)`).
2. **Idempotency.** A leftover worktree from a crashed prior run is
   nuked on entry, so re-running the matrix is safe.

## Cost honesty

Multi-turn agent loops accumulate input tokens per turn. A single
`--execute-gap` run can move 300k–5M input tokens depending on outcome.
Free-tier providers (Groq, Cerebras, OpenRouter `:free`, GitHub Models,
Gemini) are the right default for grading; reach for paid (Together,
Hyperbolic, NVIDIA-paid, DeepSeek) only when a free slot can't even be
graded due to persistent 429s.

## Known flakiness

- **OpenRouter `:free` models** route to upstream providers
  (Venice, Together, Lambda…) that may all be saturated globally. A
  429 here means "no free capacity right now," not "model failed."
- **Cerebras free tier** has a global queue (`queue_exceeded`) — same
  caveat.
- **DeepSeek** signup credit is no longer auto-granted; expect HTTP 402
  "Insufficient Balance" until you top up ~$2.

## See also

- `docs/process/COG-025-DISPATCH-BACKENDS.md` — backend selection
  contract.
- `docs/PROVIDER_CASCADE.md` — runtime priority routing (different
  envs: `CHUMP_PROVIDER_N_*`).
- `crates/chump-orchestrator/src/dispatch.rs` — backend implementation.
