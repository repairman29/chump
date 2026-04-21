# run-live-ablation.sh — sanctioned runbook for EVAL-063 / EVAL-064 re-scores

## What this is

A wrapper around `scripts/ab-harness/run-binary-ablation.py` that closes the
live-API prerequisite trap documented in PR #279's A/A FAIL finding and
PR #282's acceptance-criteria gate on EVAL-063/EVAL-064.

## What problem it solves

PR #279 (EVAL-060 implementation) ran an A/A calibration of the binary-mode
ablation harness and found:

- 27/30 empty-output trials in Cell A
- 29/30 empty-output trials in Cell B
- Delta=−0.067 driven by 3 vs 1 random API connections, not real signal

The harness invokes the chump binary in a subprocess. When the binary's
provider env (`OPENAI_API_BASE` / `OPENAI_API_KEY` / `OPENAI_MODEL`) doesn't
resolve to a live endpoint, the binary exits 1 with no stdout. The LLM-judge
scorer can't score what doesn't exist, so all faculties measured in this
state get a noise-floor verdict regardless of the actual module behavior.

This wrapper makes that failure mode impossible by reach: it sets up the
provider env from `.env`, runs a 3-trial smoke sweep, and aborts before the
full n=50 sweep if any smoke trial fails the `exit_code==0 AND output_chars>50`
gate.

## Usage

```bash
# Default — n=50 per cell on Together free-tier Qwen3-Coder-480B
scripts/ab-harness/run-live-ablation.sh belief_state --faculty metacog

# Explicit n; useful for cheaper iteration during development
scripts/ab-harness/run-live-ablation.sh perception --n 10

# Anthropic provider (more expensive, needed for cross-architecture comparison)
scripts/ab-harness/run-live-ablation.sh blackboard --provider anthropic
```

## EVAL-063 mapping (Metacognition re-score, per gap acceptance)

```bash
for module in belief_state surprisal neuromod; do
    scripts/ab-harness/run-live-ablation.sh "$module" --faculty metacog || break
done
```

If any module fails the smoke gate, the loop aborts. Manually fix the endpoint
issue, re-run the failing module from the loop position. Estimated total cost
on Together: ~$0.90 (3 modules × ~$0.30 each).

## EVAL-064 mapping (Memory + Executive Function re-score)

```bash
scripts/ab-harness/run-live-ablation.sh spawn_lessons --faculty memory
scripts/ab-harness/run-live-ablation.sh blackboard    --faculty execfn
```

Estimated total cost: ~$0.60 (2 modules × ~$0.30 each).

## Provider choice rationale

`together` (default) selects `Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8`. This
is the same provider+model that shipped PR #224 end-to-end for COG-031 V9 —
known stable with the chump binary. Pay-per-token serverless: no idle cost,
~$2/M input tokens.

`anthropic` selects whatever model the chump binary defaults to (Sonnet 4.5
via the native Anthropic client). Use this only when the goal is to match
EVAL-026's original cross-architecture conditions — e.g. confirming the
−0.10 to −0.16 Metacognition prior signal under the same model lineage.

## Caveat in the results

When the runbook produces faculty-map updates, the new verdict must include
the provider+model footnote. Re-scores produced via `together-qwen3-coder-480b`
are not directly comparable to EVAL-026's Anthropic-only data. They confirm
or rebut "module signal under live API at all"; they don't replace EVAL-026
as cross-architecture validation.

## vllm-mlx Metal crash — why `--timeout 300` (INFRA-006 / INFRA-016)

If your `OPENAI_API_BASE` points at a local **vllm-mlx** server (default setup
for the MLX inference profile), do **not** use short per-trial timeouts. The
crash pattern:

1. The chump binary opens an HTTP connection to `http://127.0.0.1:8000/v1/chat/completions`.
2. vllm-mlx starts encoding to a Metal command buffer and generating tokens.
3. The ab-harness subprocess timeout fires before inference completes.
4. Python kills the chump subprocess; the HTTP connection drops mid-stream.
5. vllm-mlx's disconnect guard returns, but the Metal command buffer is still
   encoding. The completion handler runs after `commit()`, triggering a Metal
   assertion that kills the entire server process:
   ```
   A command encoder is already encoding to this command buffer
   Completed handler provided after commit call
   ```

The crash is in vllm-mlx itself (upstream `waybarrios/vllm-mlx`), not Chump.
Chump-side mitigation: **set `--timeout 300`** in every sweep that may hit a
local vllm-mlx endpoint. `run-live-ablation.sh` defaults to 300 as of INFRA-016.
The empirical inference floor is ~56s for a 9B-4bit model with a 20K-char
system prompt at 3.7 tok/s; 300s gives 5× headroom.

If you see the crash: `kill` any sweep processes, clear `sessions/cli/cli/messages.json`
if it's above ~50 messages (the long history inflates inference time), restart
the server, and re-run with `--timeout 300`. The underlying vllm-mlx bug remains
tracked in **INFRA-006** (open, blocked on upstream).

## Failure modes the runbook does NOT solve

- **Binary build broken.** `cargo build --release --bin chump` is run by the
  script if the binary is missing; if it fails, the script exits with cargo's
  status. Fix the build, re-run.
- **Together rate-limit.** Free-tier serverless can return 429 under
  contention. The harness records exit_code in the JSONL; if the smoke test
  hits a 429, the gate trips and the script aborts. Wait + retry.
- **Judge call fails.** PR #279 already added an `exit_code_fallback` scorer
  path for this case. The smoke gate only checks the binary trial; if the
  judge call fails on a smoke trial, the row gets an exit-code fallback
  score but the binary itself still exited 0 and produced output, so the
  gate passes. The downstream sweep result will note the fallback in its
  `scorer` field.
