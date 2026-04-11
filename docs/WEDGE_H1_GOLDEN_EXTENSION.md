# Golden path extension: H1 wedge (PWA task + optional autonomy)

**Prerequisite:** Complete [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) through **§5** (web up, `/api/health` OK, PWA loads). **Discord not required.**

This extension validates **“intent → durable task”** via the **web API** and optionally **one autonomy pass** on the same machine.

---

## Step A — Create a task via API (same as PWA would)

With `./run-web.sh` running:

```bash
chmod +x ./scripts/wedge-h1-smoke.sh
./scripts/wedge-h1-smoke.sh
```

Or manually (add `Authorization: Bearer "$CHUMP_WEB_TOKEN"` when the token is set):

```bash
curl -sS -X POST "http://127.0.0.1:${CHUMP_WEB_PORT:-3000}/api/tasks" \
  -H 'Content-Type: application/json' \
  -d '{"title":"My first wedge task"}'
```

Confirm JSON includes `"id": …`. List tasks:

```bash
curl -sS "http://127.0.0.1:${CHUMP_WEB_PORT:-3000}/api/tasks"
```

See [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) **Tasks**.

---

## Step B — Optional: one autonomy dry run (`--autonomy-once`)

Requires **Ollama (or configured API)** and a task in **`open`** state for assignee `chump` (or set `CHUMP_AUTONOMY_ASSIGNEE` / `--assignee`).

From repo root (web can be stopped for this; uses same `.env`):

```bash
./target/release/chump --autonomy-once
# or: cargo run -- --autonomy-once
```

Expect stdout like `status=… task_id=…`. Detail strings vary by outcome.

**Fixture-heavy CI path:** Prefer `./scripts/run-autonomy-tests.sh` and `cargo test` for determinism ([CHUMP_AUTONOMY_TESTS.md](CHUMP_AUTONOMY_TESTS.md)).

---

## Step C — Pilot metrics (N3 / N4)

After a week of use, run queries in [WEDGE_PILOT_METRICS.md](WEDGE_PILOT_METRICS.md).

---

## Related

- [MARKET_EVALUATION.md](MARKET_EVALUATION.md) §5 (H1 wedge)  
- [PWA_WEDGE_PATH.md](PWA_WEDGE_PATH.md) (surface audit)  
