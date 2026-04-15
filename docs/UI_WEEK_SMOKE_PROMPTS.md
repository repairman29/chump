# UI week smoke prompts (PWA, ChumpMenu Chat, Tauri desktop)

Use these for a **one-week** internal dogfood before calling the engine “release ready” with your new UI. Each item has a **Verify** line: what you should see in the UI, network tab, or `logs/chump.log`.

**Fast matrix (20 pass/fail rows, Mac + real engine):** [UI_MANUAL_TEST_MATRIX_20.md](UI_MANUAL_TEST_MATRIX_20.md).

**Prereqs:** Model server up ([INFERENCE_PROFILES.md](INFERENCE_PROFILES.md)); web: `./run-web.sh` or `chump --web`; optional `CHUMP_WEB_TOKEN` if you enforce auth. **Tauri desktop:** start the web backend first, then `chump --desktop` — see [TAURI_FRONTEND_PLAN.md](TAURI_FRONTEND_PLAN.md) “HTTP sidecar”.

---

## Day checklist (5–15 min)

| Day | Focus |
|-----|--------|
| D1 | Health + one chat turn + `logs/chump.log` tail (or `./scripts/tail-model-dogfood.sh` — [MODEL_TESTING_TAIL.md](MODEL_TESTING_TAIL.md)) |
| D2 | Task tool create/list/complete |
| D3 | Approvals (`CHUMP_TOOLS_ASK`) Allow + Deny |
| D4 | `patch_file` or `write_file` + audit lines |
| D5 | Error recovery (bad `read_file` then fix) |
| D6 | Thinking / no tag leak in visible reply |
| D7 | Retro: 3 friction items → doc or task |

---

## A. Cold path and inference

### 1. Health sanity

**Prompt:** “If anything is wrong with connectivity, say what you’d check first; do not use tools.”

**Verify:** `GET /api/health` (browser or `curl`) returns JSON with model/version fields per [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md). Tauri: `invoke('health_snapshot')` returns the same body when the sidecar is up.

### 2. Model identity

**Prompt:** “Reply with one line: which model you believe you are running on (name only). Do not use tools.”

**Verify:** Answer matches `OPENAI_MODEL` / provider; wrong base URL shows obvious mismatch.

### 3. Long context honesty

**Prompt:** “Summarize this repo’s purpose in 3 bullets from memory only; if unsure, say you’re unsure.”

**Verify:** No hallucinated paths; optional check `RUST_LOG` for `agent_loop` if enabled.

---

## B. Task planner

### 4. Task list

**Prompt:** “Use the **task** tool to list open tasks, then propose the single highest-leverage next task in one sentence.”

**Verify:** Tool runs; SQLite / sidecar Tasks UI updates if wired.

### 5. Task write + read-back

**Prompt:** “Create a task titled `UI week smoke D1` with a short description, list tasks again, then mark that task complete.”

**Verify:** Rows appear and status changes; no duplicate IDs in errors.

### 6. Checklist (planner story)

**Prompt:** “Break down ‘verify tool approvals on web’ into 3 concrete checklist items using the task tool, then show me the checklist.”

**Verify:** Three items visible; aligns with Cowork “execution sidebar” direction in [TAURI_FRONTEND_PLAN.md](TAURI_FRONTEND_PLAN.md).

---

## C. Approvals and audit

Set **`CHUMP_TOOLS_ASK=run_cli,patch_file`** (or your policy) per [TOOL_APPROVAL.md](TOOL_APPROVAL.md).

### 7. Low-risk CLI (optional auto)

**Prompt:** “Run `cargo check -p rust-agent` in the repo and report pass/fail.”

**Verify:** If `CHUMP_AUTO_APPROVE_LOW_RISK=1`, approval may auto-skip; `tool_approval_audit` line in `chump.log` still appears.

### 8. Explicit approval

**Prompt:** “Run `echo ui-week-approval-test` via run_cli.”

**Verify:** Approval UI (PWA / ChumpMenu); after Allow, output contains the echo; audit line `result=allowed`.

### 9. Deny / high risk

**Prompt:** “If you were to run a destructive shell command on this machine, what would you refuse? Do not run any destructive command.”

**Verify:** If the model proposes `rm -rf` / similar, UI shows **high** risk; Deny produces `DENIED` and `result=denied` in log.

### 10. patch_file audit

**Prompt:** “Read `README.md`, propose a trivial comment-only unified diff, apply with patch_file, then confirm the file changed.”

**Verify:** `patch_file` lines in `chump.log` (including `pre_execute` / outcome); git shows diff if applicable.

---

## D. Streaming, thinking, errors

### 11. No thinking leak

**Prompt:** “Solve a tiny logic puzzle in `<thinking>...</thinking>` then give the final answer with **no** XML tags in the user-visible part.”

**Verify:** Bubble has no raw `<thinking>`; optional expanded reasoning block is OK if your client adds it.

### 12. Tool error recovery

**Prompt:** “Call read_file with path `this-file-does-not-exist-12345.txt`, then recover by listing the repo root and reading a real file.”

**Verify:** First tool error, second turn succeeds; timeline shows failure then success.

### 13. Concurrency (optional)

Send **three** short messages quickly.

**Verify:** No interleaved assistant bubbles; or queue message if `CHUMP_MAX_CONCURRENT_TURNS=1`.

---

## E. Week discipline

### 14. Daily standup

**Prompt:** “What broke yesterday in the UI or engine? What is the smallest fix or doc update? Log one line in the episode tool or a task.”

**Verify:** Episode or task row exists.

### 15. Friday retro

**Prompt:** “List top 3 friction points for a friend installing Chump web-only; map each to an existing doc or a missing doc.”

**Verify:** Notes go to [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md) or a task.

---

## Tauri desktop only (after IPC bridge)

1. Start **`chump --web`** on port **3000** (or set `CHUMP_DESKTOP_API_BASE` on the shell that launches `chump-desktop`).
2. Launch **`chump --desktop`**. Open devtools console: expect `[chump] desktop API root: http://127.0.0.1:3000` (or your base).
3. Send one chat message; **Verify:** Network requests go to `127.0.0.1:3000`, SSE streams (chat stays on **`__CHUMP_FETCH`** / `fetch` for streaming).
4. **Verify:** `invoke('health_snapshot')` returns the same JSON as `GET /api/health` on the sidecar.
5. **Optional (native IPC):** From devtools, with a pending approval `request_id` from SSE:  
   `invoke('resolve_tool_approval', { requestId: '<uuid>', allowed: true, token: '<bearer or null>' })`  
   **Verify:** `{"ok":true}` and the agent turn continues (same as `POST /api/approve`).
6. **Optional (native IPC, non-streaming):** `invoke('submit_chat', { bodyJson: JSON.stringify({ message: 'hi', session_id: '...' }), token: null })`  
   **Verify:** Returns raw **SSE text** (full stream as one string); use for harnesses only — UI should keep streaming `fetch` for chat.

See [`web/desktop-bridge.js`](../web/desktop-bridge.js) and [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) (SSE + Tauri desktop sections).

---

## Appendix: Results log (optional)

During the week, append one line per day: `date | pass/fail | note`. Prefer a **local** path (e.g. `logs/ui-week-notes.md` if you gitignore `logs/`) or a **task** row — not required in git.

| Date | Pass/Fail | Note |
|------|-----------|------|
| | | |
