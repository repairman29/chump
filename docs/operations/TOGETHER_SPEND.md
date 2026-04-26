---
doc_tag: runbook
owner_gap:
last_audited: 2026-04-25
---

# Together.ai spend controls

Together serverless is **paid by default** (free-tier slots rotate; do not assume zero cost). This repo gates accidental spend and standardizes how to **request budget** before Lane B / eval jobs.

## Environment variables

| Variable | When required | Purpose |
|----------|----------------|---------|
| **`CHUMP_TOGETHER_JOB_REF`** | Any script that calls Together **chat** inference (`together:` judge/agent, or rescore with a `together:` judge) | Non-empty string tying the run to an **approved** ticket (Linear URL, issue id, email thread id, etc.). Logged in shell output for study drivers. |
| **`CHUMP_TOGETHER_CLOUD=1`** | `scripts/run-study*.sh` and `scripts/ab-harness/run-live-ablation.sh` when using the Together provider | **Opt-in** so a long-lived `TOGETHER_API_KEY` in `.env` does **not** silently override local `OPENAI_API_BASE` (MLX / vLLM / Ollama). With `1`, also requires **`CHUMP_TOGETHER_JOB_REF`**. |
| **`CHUMP_TOGETHER_ALLOW_UNTAGGED=1`** | CI or local emergency only | Bypasses the `CHUMP_TOGETHER_JOB_REF` check. **Do not** use for routine research runs. |

Implementation: `scripts/ab-harness/together_spend_gate.py`, `scripts/lib/together-study-inference.sh`.

## Budget request (copy into Linear / Slack / email)

Use one block per job; approver fills **Approved** and you export the ref before running.

```
Title: Together inference — <short name> (e.g. RESEARCH-018 pilot)

Approver: @<manager or research lead>
Approved budget (USD): $<cap>
Job ref (paste into CHUMP_TOGETHER_JOB_REF): <Linear issue URL when created>

What runs:
- Script(s): e.g. run-cloud-v2.py / run-study1.sh / run-live-ablation.sh
- Model(s) & judges: e.g. claude-haiku + together:meta-llama/…
- Scale: fixture name, --limit / --n-per-cell, mode ab|aa|abc

Est. cost method:
- Order-of-magnitude: trials × cells × (1 agent + J judges) × rough $/1M from Together pricing page
- Optional: paste a small pilot CSV line count × last export $/day

Prereg / lane:
- Lane A vs B per docs/research/RESEARCH_EXECUTION_LANES.md
- Link preregistered protocol if any

Rollback if over budget: stop run; revoke/rotate key if leaked; file deviation note in eval log.
```

## Operational habits

1. **Keep `TOGETHER_API_KEY` out of `.env` on machines** that only do local dev, or leave it unset and inject only when running a budgeted job.
2. **Prefer Lane A** (offline / local / Anthropic-only pilots) until `CHUMP_TOGETHER_JOB_REF` is approved — see [RESEARCH_EXECUTION_LANES.md](RESEARCH_EXECUTION_LANES.md).
3. **Dashboard:** filter [Together billing / usage](https://api.together.ai/settings/billing) by `api_key_id` to confirm which key burned credits.

## Scripts touched by the gate

- **Job ref only:** `run-cloud-v2.py`, `run-longitudinal-ab.py`, `run-spawn-lessons-ab.py`, `run-ablation-sweep.py`, `run-binary-ablation.py` (Together agent or OpenAI-judge on Together base), `run-coordination-ab.py` (`together:` judge), `rescore-jsonl.py`.
- **Cloud opt-in + job ref:** `run-study1.sh` … `run-study5.sh`, `run-live-ablation.sh` (`--provider together`).
