# Packaged desktop: out-of-the-box (OOTB) install vision

**Goal:** A novice double-clicks an installer (or drags one app), confirms a few prompts, and gets **Chump Cowork** running with **local inference** and **no terminal** — same UX bar as consumer desktop software.

**Today:** The Tauri shell auto-spawns `chump --web` when possible, but the user still supplies **Rust build**, **repo `.env`**, and a **running LLM backend** (Ollama, vLLM-MLX, etc.). See [TAURI_MACOS_DOCK.md](TAURI_MACOS_DOCK.md), [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md).

**This doc:** Product and engineering phases to close that gap (macOS first; Windows/Linux follow similar patterns).

---

## Success criteria (novice-grade)

| Criterion | Target |
|-----------|--------|
| Clicks to first chat | ≤ 5 (install → open → allow → maybe “Download model” → Done) |
| Terminal required | Never for the happy path |
| Inference | Default **Ollama** on `127.0.0.1:11434`, one **pinned default model** (documented size) |
| Updates | In-app or Sparkle-style check (phase 2+) |
| Trust | **Signed + notarized** macOS build for wide distribution (not ad-hoc only) |

---

## Architecture choices (decide early)

1. **Ollama delivery**
   - **A — Prerequisite:** Installer opens `ollama.com/download` or runs Ollama’s official pkg; app verifies `ollama` on PATH or `/usr/local/bin`.
   - **B — Bundled:** Ship Ollama inside the app bundle (larger DMG; upgrade path harder; legal/repackaging review).
   - **Recommendation:** **Phase 1 = A** (detect + guide + optional `open` official installer); **Phase 3** revisit B if product needs single artifact.

2. **Config and brain location**
   - Avoid requiring a **git clone** for end users: first run writes **`~/Library/Application Support/Chump/`** (or XDG on Linux) with generated `.env` (minimal: `OPENAI_API_BASE`, `OPENAI_MODEL`, no Discord).
   - **`CHUMP_HOME`** / working directory for spawned `chump` should point at that directory (or a subfolder with writable SQLite + optional `chump-brain/`).

3. **Binary layout**
   - Keep **embedded `chump`** next to `chump-desktop` in `Contents/MacOS/` (already the [macOS bundle script](../scripts/macos-cowork-dock-app.sh) pattern).
   - **LSEnvironment** should set **`CHUMP_BINARY`**, **`CHUMP_HOME`** (Application Support path), not only `~/Projects/Chump`.

4. **First-run wizard (in Tauri)**
   - Steps: Welcome → Check Ollama installed / offer to open installer → **`ollama pull <default-model>`** (progress UI via `Command` + parse stdout or `ollama list`) → Write minimal config → Start sidecar → Health green → Open chat.
   - Reuse IPC patterns from [TAURI_FRONTEND_PLAN.md](TAURI_FRONTEND_PLAN.md); new commands: `detect_ollama`, `pull_ollama_model`, `ensure_user_data_dir`.

5. **Default model**
   - Align with [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) (`qwen2.5:14b` or a **smaller** default for download size on first run, e.g. **7B**, with explicit “quality vs size” in wizard).
   - Show **approximate GB** before pull.

---

## Phased delivery

| Phase | Scope | Outcome |
|-------|--------|---------|
| **P0** | **Wizard shell + detection** | **Shipped:** Tauri first-run wizard in [`web/ootb-wizard.js`](../web/ootb-wizard.js) + [`desktop/src-tauri/src/ootb.rs`](../desktop/src-tauri/src/ootb.rs): Ollama `version` check, open download URL, **LM Studio / MLX / remote API** path (skip Ollama + custom `OPENAI_API_BASE`), back navigation, dialog a11y, engine gate defers while wizard is open. |
| **P1** | **User data dir + env generation** | **Shipped:** `~/Library/Application Support/Chump` (macOS) / XDG / `%APPDATA%\Chump` — `.env` with `CHUMP_HOME`, optional non-Ollama base URL; [`sidecar_repo_cwd`](../desktop/src-tauri/src/lib.rs) uses user-data `.env` when present. **Retail bundle:** [`scripts/macos-cowork-dock-app.sh`](../scripts/macos-cowork-dock-app.sh) with `CHUMP_BUNDLE_RETAIL=1` omits `CHUMP_HOME` / `CHUMP_REPO` from `LSEnvironment` so novices are not tied to a dev clone path. |
| **P2** | **Model pull from UI** | **Shipped:** `ollama pull` with **live stdout/stderr lines** (`ootb-pull-line` events) + scrollable log; model picker with **approximate GB**; skip pull if model exists or if using a non-Ollama API base. |
| **P2b** | **Finish quality** | **Shipped:** **Health-gated** start + **success overlay**, **Try again**, **Tab focus trap** + **`inert`** on gate/app while wizard is open, **two-step skip** confirmation, **Open Chump data folder** (`open` / `xdg-open` / `explorer`), **Copy pull log**, **window title** “First-time setup”, path preview on step 3, batched pull log lines, **`aria-live` assertive** on errors, human-readable pull/engine errors. Notarization: [MACOS_NOTARIZATION.md](MACOS_NOTARIZATION.md). |
| **P3** | **Release engineering** | **Partial:** [`.github/workflows/tauri-desktop.yml`](../.github/workflows/tauri-desktop.yml) produces an **unsigned** macOS `.app` artifact on push (path-filtered) + `workflow_dispatch`. **Still required for wide distribution:** Apple Developer **signing** + **notarization**; DMG or pkg; versioned download page. |
| **P4** | **Updates** | Sparkle or built-in “new version” check + delta DMG. |

---

## Risks and constraints

- **Notarization** requires a paid Apple Developer account and CI secrets; ad-hoc sign is fine for internal testers only.
- **`ollama pull`** needs network and disk; UI must handle slow links and resume.
- **Gatekeeper:** First open may still need “Open” once unless notarized; document in README for downloaders.
- **Advanced users** may still point at MLX/vLLM/mistral; wizard should offer “I already have an API base” with URL field.

---

## Related docs

- [MACOS_NOTARIZATION.md](MACOS_NOTARIZATION.md) — signing + notarization checklist (distribution)
- [TAURI_MACOS_DOCK.md](TAURI_MACOS_DOCK.md) — current `.app` build
- [TAURI_FRONTEND_PLAN.md](TAURI_FRONTEND_PLAN.md) — sidecar architecture
- [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) — Ollama defaults for manual path
- [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md) — metrics for OOTB success
- [PRODUCT_CRITIQUE.md](PRODUCT_CRITIQUE.md) — launch gate / external readiness

---

## Roadmap

Tracked in [ROADMAP.md](ROADMAP.md) under **External readiness** until shipped; execution can map to [ROADMAP_SPRINTS.md](ROADMAP_SPRINTS.md) as a named sprint when work starts.
