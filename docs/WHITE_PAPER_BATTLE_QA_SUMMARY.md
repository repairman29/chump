# Battle QA (executive summary)

**Battle QA** is a large scripted suite (**500 user-style queries** by default) that drives the Chump CLI through realistic tool and reasoning paths. It is the project’s primary **regression hammer** before “ready for battle” releases.

## What it proves

- End-to-end CLI behavior under diverse prompts (not only unit tests).
- Stability of tool wiring, timeouts, and failure modes across many turns.
- A repeatable **pass/fail** report (`logs/battle-qa-report.txt`, failure detail in `logs/battle-qa-failures.txt`).

## How it is run (operator sketch)

From repo root, typical entrypoints:

- `./scripts/run-battle-qa-full.sh` — full run plus report.
- `./scripts/battle-qa.sh` — direct runner; use `BATTLE_QA_MAX=50` for smoke.
- `./scripts/run-battle-sim-suite.sh` — related sim / baseline vector (see `BATTLE_QA.md`).

Self-heal loops (Chump editing the repo and re-running until green) are documented in **`BATTLE_QA_SELF_FIX.md`**.

## Config variants

The same scripts can run against **default** (e.g. Ollama on 11434) vs **max_m4** (vLLM-MLX, in-process embeddings) via `./scripts/run-tests-with-config.sh` — see full **`BATTLE_QA.md`**.

## Full detail

For limits, environment variables, iteration flags, and triage workflow, use the repository copy of **`docs/BATTLE_QA.md`** (not fully reproduced in this PDF).
