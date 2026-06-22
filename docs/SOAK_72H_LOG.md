---
doc_tag: ops
last_audited: 2026-05-02
---

# SOAK_72H_LOG.md — daily-driver soak runs

This file records 72h soak runs of the Chump stack. The unchecked
roadmap item "Overnight / 72h soak" in `docs/archive/strategy-2026-04/ROADMAP-superseded.md` (under
"Architecture vs proof") closes when at least one full 72h run completes
with no regressions in the metrics tracked below.

**Procedure:** see [`docs/operations/INFERENCE_STABILITY.md`](operations/INFERENCE_STABILITY.md) §Soak.

**Capture script:** [`scripts/eval/soak-checkpoint.sh`](../scripts/eval/soak-checkpoint.sh)

**Recommended cadence:** T0 (pre-flight) → +4h → +8h → ... → +72h (every 4h
or every hour for finer granularity; both work).

**Metrics tracked per checkpoint:**
- `memory_db` size + WAL behavior
- `logs/` and `sessions/` directory growth
- Model server reachability (`/api/health`, `/api/stack-status`)
- Chump process RSS
- Ship heartbeat status
- SQLite errors in last 500 log lines

**Pass criteria for closing the roadmap item:**
- `memory_db` does NOT grow unbounded (WAL checkpoint is happening)
- `logs/` size growth is sub-linear or rotated cleanly
- Model server reachable at >95% of checkpoints
- Chump RSS does not leak (steady-state ±20% over 72h)
- 0 unhandled SQLite errors


---

## Soak run: 2026-05-03T04:21:07Z (T0 — pre-flight)

| Check | Value |
|-------|-------|
| Time (UTC) | 2026-05-03T04:21:07Z |
| memory_db size | 1.0M |
| WAL | 3.9M |
| logs/ size | 203M |
| sessions/ size | 8.7M |
| Model server | web_ok |
| Chump RSS | 3.9M |
| Ship heartbeat | stopped |
| SQLite errors (last 500 lines) | 0 |


### Checkpoint: 2026-05-10T20:23:46Z (T0+184h)

| Metric | Value |
|--------|-------|
| memory_db size | 1.3M |
| WAL | 0B |
| logs/ size | 258M |
| sessions/ size | 4.9M |
| Model server | web_ok |
| Chump RSS | 843.9M |
| Ship heartbeat | stopped |
| SQLite errors (last 500 lines) | 0 |
| Largest logs | 18M vllm-mlx-8000.log;9.0M ollama-serve.log;7.9M farmer-brown-launchd.out.log; |


### Checkpoint: 2026-05-14T04:48:17Z (T0+264h)

| Metric | Value |
|--------|-------|
| memory_db size | 1.4M |
| WAL | 4.1M |
| logs/ size | 283M |
| sessions/ size | 9.9M |
| Model server | web_ok |
| Chump RSS | 1.6M |
| Ship heartbeat | stopped |
| SQLite errors (last 500 lines) | 0 |
| Largest logs | 20M vllm-mlx-8000.log;9.3M ollama-serve.log;8.8M farmer-brown-launchd.out.log; |


### Checkpoint: 2026-05-14T14:37:54Z (T0+274h)

| Metric | Value |
|--------|-------|
| memory_db size | 1.5M |
| WAL | 0B |
| logs/ size | 284M |
| sessions/ size | 4.9M |
| Model server | web_ok |
| Chump RSS | 1.2M |
| Ship heartbeat | stopped |
| SQLite errors (last 500 lines) | 0 |
| Largest logs | 20M vllm-mlx-8000.log;9.3M ollama-serve.log;8.8M farmer-brown-launchd.out.log; |


### Checkpoint: 2026-05-14T14:45:44Z (T0+274h)

| Metric | Value |
|--------|-------|
| memory_db size | 1.5M |
| WAL | 0B |
| logs/ size | 284M |
| sessions/ size | 4.9M |
| Model server | web_ok |
| Chump RSS | 1.2M |
| Ship heartbeat | stopped |
| SQLite errors (last 500 lines) | 0 |
| Largest logs | 20M vllm-mlx-8000.log;9.3M ollama-serve.log;8.8M farmer-brown-launchd.out.log; |


### Checkpoint: 2026-06-21T15:45:41Z (T0+1187h)

| Metric | Value |
|--------|-------|
| memory_db size | 1.6M |
| WAL | 3.9M |
| logs/ size | 520M |
| sessions/ size | 8.9M |
| Model server | web_ok |
| Chump RSS | 13.7M |
| Ship heartbeat | stopped |
| SQLite errors (last 500 lines) | 0 |
| Largest logs | 40M vllm-mlx-8000.log;17M farmer-brown-launchd.out.log;14M farmer-brown.log; |


### Checkpoint: 2026-06-21T19:45:53Z (T0+1191h)

| Metric | Value |
|--------|-------|
| memory_db size | 1.6M |
| WAL | 3.9M |
| logs/ size | 519M |
| sessions/ size | 8.9M |
| Model server | web_ok |
| Chump RSS | 13.0M |
| Ship heartbeat | stopped |
| SQLite errors (last 500 lines) | 0 |
| Largest logs | 40M vllm-mlx-8000.log;17M farmer-brown-launchd.out.log;14M farmer-brown.log; |

