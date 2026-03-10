# Chump Autonomy Tiers and Tests

A tiered test suite that validates Chump’s capabilities. Passing a tier **releases** the next level of autonomous behavior (longer runs, more tools, less hand-holding).

## Tiers and What They Unlock

| Tier  | Name       | What’s tested                                     | Unlocks                                                                  |
| ----- | ---------- | ------------------------------------------------- | ------------------------------------------------------------------------ |
| **0** | Baseline   | Model server on 8000/8001 responds.               | Single-shot `--chump`; preflight passes.                                 |
| **1** | Tools      | Calculator and memory (store + recall) work.      | Interactive Chump; CLI + memory in normal use.                           |
| **2** | Research   | Web search (Tavily) returns and can be used.      | Heartbeat self-improvement (web_search + memory).                        |
| **3** | Multi-step | One task uses two tools (e.g. search then store). | Longer heartbeat duration; delegate tool if enabled.                     |
| **4** | Sustain    | Full heartbeat round completes; server stays up.  | Unattended heartbeat; 8h/overnight runs; Chump “certified” for autonomy. |

## Tests (run via `scripts/run-autonomy-tests.sh`)

- **Tier 0:** `./scripts/check-heartbeat-preflight.sh` → 8000 or 8001 returns 200.
- **Tier 1:**
  - **1a** – Chump prompt: “What is 13 times 7? Reply with only the number.” → output contains `91` or calculator tool use.
  - **1b** – Chump prompt: “Remember this: autonomy-test-key = tier1-memory-ok. Then say exactly: MEMORY_STORED.” → output contains `MEMORY_STORED` or confirms store; optional second prompt to recall and say `MEMORY_RECALLED`.
- **Tier 2:** Chump prompt: “Use web_search to find one fact about Rust 2024 edition. In one sentence, what did you find? Then say DONE_RESEARCH.” → output contains `DONE_RESEARCH` or shows web_search / Tavily use. Requires `TAVILY_API_KEY` in `.env`.
- **Tier 3:** Chump prompt: “Look up one short fact about macOS launchd with web_search, then store that single fact in memory with the key launchd-fact. Reply with exactly: MULTI_STEP_OK.” → output contains `MULTI_STEP_OK` and evidence of both tools (search + memory store). Requires Tavily.
- **Tier 4:** Run `./scripts/test-heartbeat-learn.sh` (1m, one round). Preflight passes, Round 1 completes (ok or finished), server still responds on 8000 after. Requires Tavily and model on 8000/8001.

## Autonomy state

After a full run, the script writes the **highest tier passed** to:

- `CHUMP_AUTONOMY_TIER` in `logs/autonomy-tier.env` (sourced by optional integration scripts).

Scripts (e.g. heartbeat-learn, ChumpMenu) can read this to:

- Allow **8h heartbeat** only when tier ≥ 4.
- Allow **delegate tool** by default when tier ≥ 3.
- Show “Chump autonomy: Tier N” in status UIs.

## Running the suite

From `rust-agent`:

```bash
./scripts/run-autonomy-tests.sh
```

- Sources `.env` if present.
- Uses `target/release/rust-agent` if built, else `cargo run`.
- Stops at first failing tier; exit 0 only if all tiers pass.
- Optional: `AUTONOMY_TIER_MIN=2` to run only tiers 0–2 (e.g. skip Tavily/sustain).

## Requirements by tier

| Tier | Model (8000/8001) | TAVILY_API_KEY | Notes                 |
| ---- | ----------------- | -------------- | --------------------- |
| 0    | Yes               | No             | Preflight only.       |
| 1    | Yes               | No             | Calc + memory.        |
| 2    | Yes               | Yes (.env)     | One web_search.       |
| 3    | Yes               | Yes            | Multi-step.           |
| 4    | Yes               | Yes            | Heartbeat smoke test. |
