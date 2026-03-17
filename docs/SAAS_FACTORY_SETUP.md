# SaaS Factory Setup — Corrections and Gotchas

This doc corrects common misconceptions from external "SaaS factory" or "Chump learning loop" guides. Use it when setting up portfolio/ship, learn heartbeats, and cost controls.

## Portfolio format

Use the format in [PROACTIVE_SHIPPING.md](PROACTIVE_SHIPPING.md): `## N. ProductName` with bullets **Phase:**, **Repo:**, **Playbook:**, **What shipping means right now:**, **Blocked:**, **Notes:**. The agent infers the slug from the product name (e.g. Chump Chassis → `chump-chassis`). Repo must exist on GitHub and be listed in `CHUMP_GITHUB_REPOS` so the agent can `github_clone_or_pull` and `set_working_repo`.

## Learn heartbeat: directives and output file

- **heartbeat-learn.sh does not read** any file under `chump-brain/directives/` or `research_focus.md`. It uses a fixed array of prompts and rotates through them (or runs `--chump-due` from the schedule DB).
- To get "market research" output: a dedicated prompt was added to the PROMPTS array in `heartbeat-learn.sh` that instructs the agent to append findings to `market_research.md` via `memory_brain append_file`. The path is relative to `CHUMP_BRAIN_PATH` (e.g. `market_research.md`). Creating only `directives/research_focus.md` does not change learn behavior unless you add a script that reads it and passes it as the prompt (see PROJECT_PLAYBOOKS or OPERATIONS).

## CHUMP_MAX_CONCURRENT_TURNS

- This env var is **Discord-only**. It limits how many **Discord-triggered agent turns** can run at once (message handling). When the cap is reached, additional messages are queued. It does **not** limit tool calls per round and does **not** apply to CLI or heartbeat runs.
- For cost control on **heartbeat-learn** (CLI): use cascade **RPM/RPD** limits, **logs/pause**, and **CHUMP_EXECUTIVE_MODE=0** for background heartbeats. A per-round tool-call cap for CLI/heartbeat would require a code change.

## CHUMP_HOME

- Do **not** set `CHUMP_HOME` to `chump-brain` (or any subdirectory of the repo) for the learn loop. `CHUMP_HOME` is used as the **cwd for run_cli**, repo root for file tools, .env loading, and clone base. Setting it to `chump-brain` breaks run_cli (no Cargo.toml there), .env, and clones. Keep `CHUMP_HOME` (or default) as the Chump repo root. Restrict learn behavior via the prompt and RPM/RPD/pause.

## Paths

- Use the actual Chump repo path in examples (e.g. `/Users/<you>/Projects/Chump`). `CHUMP_BRAIN_PATH` defaults to `chump-brain` and is resolved relative to the repo root unless set to an absolute path.

## Cascade and kill switch

- **RPM/RPD:** When a slot hits its limit it is skipped; the cascade tries the next slot or falls back to slot 0 (local). The round continues; there is no automatic "pause" except when no slot is available.
- **logs/pause:** Both heartbeat-ship and heartbeat-learn check for `logs/pause` (and `CHUMP_PAUSED`). `touch logs/pause` to stop rounds; `rm logs/pause` to resume.
- **CHUMP_EXECUTIVE_MODE=0** for background heartbeats keeps the run_cli allowlist and normal timeouts; use it for safe unattended runs.
