# PWA-first H1 wedge path (audit)

**Wedge H1:** intent → durable task → autonomy / Cursor → verifiable done ([MARKET_EVALUATION.md](MARKET_EVALUATION.md) §5).

**Audit question:** Can a pilot complete **task create + list + (optional) autonomy** without **Discord**?

---

## Surface checklist

| Step | Discord required? | PWA / web path |
|------|-------------------|----------------|
| First chat + health | No | [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) |
| Create task | No | `POST /api/tasks` ([WEB_API_REFERENCE.md](WEB_API_REFERENCE.md)); PWA UI if exposed |
| List / update task | No | `GET/PUT /api/tasks` |
| Morning-style summary | No | `GET /api/briefing` |
| Approve risky tool | No | `POST /api/approve` |
| Autonomy loop | No | CLI `chump --autonomy-once` or cron ([OPERATIONS.md](OPERATIONS.md)) |
| Cursor delegation | No | Tool `run_cli` from web agent turn (same as Discord) |

**Verdict:** H1 does **not** require Discord. Discord is an **alternate control plane** for users who already live there.

---

## Copy and UX gaps (status)

1. **README / golden path:** **Done** — README states web-first onboarding; [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) states Discord optional and fleet as upsell.
2. **PWA tasks tab:** **Done** — [web/index.html](../web/index.html) Tasks sidecar includes wedge hint (`wedge-h1-smoke.sh`, `WEDGE_H1_GOLDEN_EXTENSION.md`).
3. **Fleet:** Keep Pixel/Mabel CTAs out of first-run copy; defer to Horizon 2 per [ECOSYSTEM_VISION.md](ECOSYSTEM_VISION.md).

---

## Intent calibration parity (PWA vs [INTENT_CALIBRATION.md](INTENT_CALIBRATION.md))

Chat uses the same agent stack as Discord; slash presets in [web/index.html](../web/index.html) cover common phrases. **Phase 2 audit (2026-04-10):**

| Id | Expected | PWA / web support |
|----|----------|-------------------|
| IC01–IC02 | task_create | **Yes** — `New task` button, `POST /api/tasks`, chat insert `/task ` |
| IC03 | status_answer | **Partial** — tasks list in sidecar; no dedicated “status of task N” UI |
| IC04 | memory_or_task | **Partial** — agent may use memory tools in chat; no separate reminder UI |
| IC05 | run_cli | **Yes** — agent tools when policy allows (same as Discord) |
| IC06 | delegate_cursor | **Yes** — via `run_cli` / agent in chat |
| IC07 | focus_task | **Partial** — user can pick task in UI; no “work on task 3” voice shortcut |
| IC08 | self_reboot | **N/A** — typically Discord/ops; not exposed in PWA |
| IC09 | clarify | **Yes** — model behavior |
| IC10 | memory_store | **Yes** — agent memory tools |

**No code change this pass:** no single IC failed repeatedly in production data; re-open if calibration sessions flag one ID ≥3 failures.

---

## Automated coverage (CI / local parity)

| Check | What it exercises |
|-------|-------------------|
| `bash scripts/run-ui-e2e.sh` (repo root) | Playwright against live `chump --web`: health, chat, **`/task`** quick path → “Created task” (H1 core). Requires Chromium install via Playwright. |
| `node scripts/run-web-ui-selftests.cjs` | SSE block parser + inline script assumptions (CI `test` job). |
| `bash scripts/verify-external-golden-path.sh` | Cold-adopter smoke without Discord ([EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md)). |
| `bash scripts/wedge-h1-smoke.sh` | Documented H1 extension ([WEDGE_H1_GOLDEN_EXTENSION.md](WEDGE_H1_GOLDEN_EXTENSION.md)). |

**Cowork (Tauri) desktop:** Linux CI runs `e2e-tauri/run.mjs` (WebDriver) for the same **`/task`** confirmation path; macOS operators should also run **`bash scripts/run-tauri-e2e.sh`** when changing desktop/web chat IPC. Manual matrix: [UI_MANUAL_TEST_MATRIX_20.md](UI_MANUAL_TEST_MATRIX_20.md).

---

## Related

- [WEDGE_H1_GOLDEN_EXTENSION.md](WEDGE_H1_GOLDEN_EXTENSION.md)  
- [WEDGE_PILOT_METRICS.md](WEDGE_PILOT_METRICS.md)  
