# 20 manual UI tests (your Mac, real engine)

Run these against **your** repo, **your** `.env`, and **your** usual ports (default web **3000**, MLX/vLLM per [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md)). Treat each row as pass/fail; note the build path (browser PWA vs **Chump.app**).

**Prep (once):** `./run-web.sh` *or* `cargo run --release --bin chump -- --web --port 3000` from repo root; model endpoint reachable (`curl` to `/v1/models` as in [OPERATIONS.md](OPERATIONS.md)). For Cowork, use a **fresh** `Chump.app` build that loads current `web/`.

---

| # | Test | You do | Pass if |
|---|------|--------|-----------|
| 1 | **Health** | In Terminal: `curl -sS http://127.0.0.1:3000/api/health \| jq .` | JSON with `"status":"ok"` (or your configured health shape). |
| 2 | **Stack / inference** | `curl -sS http://127.0.0.1:3000/api/stack-status \| jq .` | `inference` object present; for local `OPENAI_API_BASE`, `models_reachable` matches reality (true when MLX/vLLM is up). |
| 3 | **PWA first reply** | Browser: `http://127.0.0.1:3000` → New chat → send: *“Reply with one word: pong.”* | Assistant bubble shows real text (not the “No reply text…” stub); status clears. |
| 4 | **Cowork first reply** | Open **Chump.app** with web engine up → same one-line ping. | Same as #3; header **Live** (or reconnects then Live). |
| 5 | **Engine gate** | Quit `chump --web`; open **Chump.app** (or refresh Cowork). | Blocking gate appears; **Offline** or equivalent; copy/retry affordances visible. |
| 6 | **Recover from gate** | With gate visible: **Start engine & retry** (or start `./run-web.sh` then Retry). | Gate dismisses; **Live**; you can send #3 again successfully. |
| 7 | **Single instance** | With Cowork already running: click **Chump** in Dock again (or launch app from Finder again). | No second main window; existing window **comes forward** (not a stack of dead shells). |
| 8 | **Settings self-tests** | ⚙ → **Run UI self-tests (SSE checks)**. | Toast “passed”; DevTools console shows `[ui-selftest] ok: …` lines with **no** `FAIL:`. |
| 9 | **`/selftest`** | In message box: type `/` → choose **selftest** (or run `/selftest` flow your palette uses). | Same toast/console outcome as #8. |
|10 | **Theme persistence** | Settings → Theme **Light** → Save → hard refresh (`⌘R`). | UI stays light; flip back to Dark and verify again. |
|11 | **Two chats + search** | New chat → send “alpha”; New chat → send “beta”; open sessions drawer; use **Search chats** for `beta`. | Correct session filters; switching sessions shows the right history. |
|12 | **Rename + delete session** | Sessions list → **Rename** one chat; then **Delete** a disposable session. | Title updates; deleted chat gone after refresh. |
|13 | **Tasks sidecar** | Open sidecar → **Tasks**; in chat send `/task UI manual matrix spot check` (or any title). | Task appears in sidecar list; counts or rows update without full reload breaking UI. |
|14 | **Providers sidecar** | Sidecar → **Providers**; wait one refresh cycle. | Either slot stats / circuit info loads, or a clear empty/error state (no infinite spinner). |
|15 | **Briefing** | Sidecar → **Briefing** (or slash flow to briefing if you use that). | Panel loads content or a readable error (401 → set token in Settings). |
|16 | **Small attachment** | Attach a tiny `.txt` (or `.md`) → short message referencing it → Send. | User bubble shows chip; assistant can answer without upload errors in toast. |
|17 | **Stop mid-stream** | Ask for something long (*“Write 20 numbered tips…”*); click **Stop** while streaming. | Stream stops; bubble not stuck forever in “Thinking…”; Send works again. |
|18 | **Edit + Retry** | Send a message; use **Edit** on user bubble → change text → send; on assistant use **Retry** once. | Edited path works; retry re-runs without duplicating broken UI. |
|19 | **Bot switch** | Header bot pill: switch **Chump** ↔ **Mabel** (or `/bot` palette); send one short message each. | Indicator matches; replies reflect the selected bot (or a clear config error if Mabel unset). |
|20 | **Process sanity** | Terminal: `./scripts/chump-macos-process-list.sh` while Cowork open; then quit Cowork; run again. | With one app: one `chump-desktop` while open; **zero** `chump-desktop` after quit (allow a second or two). `chump --web` lines match what you intend to keep running. |

---

## Mobile PWA (touch) — universal power **P5.2**

Run on a **real phone or narrow browser** (width ≤720px) against the same engine as the table above. Goal: approvals, navigation, and composer remain usable without a pointer device. See also [DESKTOP_PWA_PARITY_CHECKLIST.md](DESKTOP_PWA_PARITY_CHECKLIST.md).

| # | Test | You do | Pass if |
|---|------|--------|-----------|
| M1 | **Sessions chrome** | Tap ☰, **New chat**, search field, open a session row. | No mis-taps from undersized hit areas; drawer opens/closes predictably. |
| M2 | **Header controls** | Tap bot pill, ⚙, sidecar ▤. | Each control responds on first tap; chrome uses enlarged targets at ≤720px. |
| M3 | **Composer + send** | Tap attach 📎, type a short message, tap **↑** send. | Focus stays sane; Send not obscured by iOS safe-area (if installed to home screen). |
| M4 | **Tool approval card** | Trigger a turn that requests approval (`CHUMP_TOOLS_ASK` includes a tool you invoke). | **Allow once** / **Deny** are easy to hit; no accidental double-submit. |
| M5 | **Composer lock** | While approval is showing, try to type/send. | Message area and Send stay disabled until the turn completes (no stuck lock after Allow/Deny — same as desktop). |
| M6 | **Large attachment guard** | Attempt a multi‑MB photo or several files at once (within your server limits). | Clear toast or error (not a silent hang); if policy rejects size, copy is readable on small screen. |
| M7 | **Offline banner** | Airplane mode on → open PWA. | Orange offline banner appears; queued message path matches expectations ([OPERATIONS.md](OPERATIONS.md) / wedge docs). |
| M8 | **Scroll-to-bottom FAB** | Scroll chat up until the **↓** FAB appears; tap it. | Lands at latest messages; composer still accepts focus and send on first tap (mobile WebKit guard). |

Record pass/fail and build (Safari vs Chrome Android) in a dated note under [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md) if you find friction worth fixing.

---

## Optional deep checks (not counted in the 20)

- **`?ui_selftest=1`** on the PWA URL: auto-runs the SSE suite after load; toast + console.
- **`CHUMP_WEB_TOKEN`:** set wrong token in Settings → send chat → expect **401** text in bubble, then fix token and retry.
- **Long chat:** paste ~30 lines → scroll up until **scroll-to-bottom** FAB appears → tap it → lands at bottom; input still accepts clicks (WKWebView regression guard).

---

## What “pass” means for you

These are **integration / UX** checks on your machine, not replacements for `cargo test` or battle QA. If several fail together, suspect **ports** (3000 vs bound marker), **two `chump --web` processes**, **stale `Chump.app`**, or **inference** down before blaming the WebView.

**Related:** broader scripted prompts in [UI_WEEK_SMOKE_PROMPTS.md](UI_WEEK_SMOKE_PROMPTS.md).
