# mistral.rs benchmarks for your hardware

Use this with a **Gemini / human research plan** on machine specs: upstream `tune` suggests ISQ / memory tradeoffs; Chump scripts measure **end-to-end wall time** on the same binary you run in production.

## 1. Upstream CLI — `mistralrs tune`

Answers “what quantization / memory profile fits this GPU/RAM?” without Chump.

- **Install:** [mistral.rs — Installation](https://github.com/EricLBuehler/mistral.rs#installation) (separate from this repo).
- **Wrapper:** [`scripts/bench-mistralrs-tune.sh`](../scripts/bench-mistralrs-tune.sh) saves timestamped logs under `logs/` (or `MISTRALRS_TUNE_OUT`).
- **Map to Chump:** set **`CHUMP_MISTRALRS_ISQ_BITS`** from recommendations — see [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) §2b.8.

```bash
./scripts/bench-mistralrs-tune.sh Qwen/Qwen3-4B
MISTRALRS_TUNE_PROFILE=fast ./scripts/bench-mistralrs-tune.sh --json Qwen/Qwen3-4B
```

Optional: **`mistralrs doctor`** for environment diagnostics.

## 2. Chump in-process — wall-clock micro-bench

Measures **process start → one minimal completion → exit** per configuration (fresh process each time so ISQ / model reload is included). Uses the same code path as **`./target/release/chump "<prompt>"`** (minimal agent, no Discord/web).

- **Script:** [`scripts/bench-mistralrs-chump.sh`](../scripts/bench-mistralrs-chump.sh) → [`scripts/bench_mistralrs_chump.py`](../scripts/bench_mistralrs_chump.py).
- **Build:** `cargo build --release --features mistralrs-metal -p rust-agent` (Apple Silicon) or **`mistralrs-infer`** (CPU).
- **Auth / pin:** set **`HF_TOKEN`** and optionally **`CHUMP_MISTRALRS_HF_REVISION`** in the environment (or `.env`).

```bash
./scripts/bench-mistralrs-chump.sh --model Qwen/Qwen3-4B --isq 4,6,8 --runs 2 --warmup --summary \
  -o logs/mistralrs-chump-bench.csv
```

**Throughput logging (optional):** export **`CHUMP_MISTRALRS_THROUGHPUT_LOGGING=1`** when you want runner-side tok/s style logs on stderr (see [MISTRALRS_CAPABILITY_MATRIX.md](MISTRALRS_CAPABILITY_MATRIX.md)).

### CSV columns

| Column | Meaning |
|--------|---------|
| `run_group` | UUID prefix — ties one invocation together |
| `ts_utc` | Row timestamp |
| `host`, `platform` | Machine identity |
| `bench_model` | `CHUMP_MISTRALRS_MODEL` |
| `hf_revision` | From env if set |
| `isq_bits`, `paged_attn`, `force_cpu`, `moqe` | Knobs for that row |
| `run_kind` | `warmup`, `timed`, or `median` (if `--summary`) |
| `run_index` | Sequence within config |
| `wall_seconds` | Wall time for that process |
| `exit_code` | Subprocess exit |
| `stdout_bytes`, `stderr_bytes` | Size of captured output |

**Interpretation:** First timed run after `--warmup` is still “warm” weights on disk; cold vs warm matters for “time to first answer” in real use. Compare **median** rows across models/ISQ on the same machine.

### Advanced

- **`CHUMP_BENCH_BINARY`:** override path to `chump`.
- **`--prompt-file`:** long context / RAG-style prompt from a file (stay within Chump message limits).
- **Matrix:** `--paged 0,1`, `--force-cpu 0,1`, `--moqe 0,1` multiply configurations (can be slow).

## 3. Product-shaped checks (manual)

Scripts above are **micro** latency. For “best model for Chump,” add a fixed checklist: tool calls, multi-turn, streaming (`CHUMP_MISTRALRS_STREAM_TEXT_DELTAS`) — see [UI_MANUAL_TEST_MATRIX_20.md](UI_MANUAL_TEST_MATRIX_20.md) and [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) §2b.

## Related

| Doc / script | Role |
|--------------|------|
| [MISTRALRS_CAPABILITY_MATRIX.md](MISTRALRS_CAPABILITY_MATRIX.md) | Env knobs vs upstream |
| [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) §2b | Metal, `HF_TOKEN`, `tune` |
| [`scripts/check-mistralrs-infer-build.sh`](../scripts/check-mistralrs-infer-build.sh) | CI compile smoke |
