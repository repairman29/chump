# Onboarding UX Roadmap

> Source: Gemini architectural review (2026-04-14). Addresses the novice-to-power-user
> gap for a local autonomous epistemic agent. Core philosophy: never make the user
> feel like they're operating a black box.

## 1. OOTB (Out Of The Box) GUI Wizard

**Problem:** Forcing users to install Rust, Llama.cpp, or Python dependencies before
the app opens. README with 15 `curl` commands = immediate bounce.

**Plan:**
- Single compiled Tauri binary (`.dmg` / `.exe`) — no prerequisites
- Step 1/2/3 GUI wizard on first launch (not a terminal)
- **Hardware scan** on startup: detect VRAM, Unified Memory, CPU cores
  - Auto-recommend model + quantization: "I see you have an M2 Mac with 32GB.
    I'll download the 4-bit Mistral-Instruct model (4.2GB). [Accept]"
  - No "which quantization do you want?" for novices
- Background model download with progress bar (not raw curl output)
- Integrate with existing `ootb.rs` (Tauri) and `setup-local.sh`

**Existing hooks:** `desktop/src-tauri/src/ootb.rs`, `setup-local.sh`

## 2. Blast Radius Introduction (Sandbox Tutorial)

**Problem:** "Is this thing going to delete my entire hard drive?" — novice fear of
giving terminal execution rights to an AI.

**Plan:**
- On first boot, auto-create `chump_sandbox_tutorial/` temp folder
- Guided first mission: "Ask me to write a Python script that calculates the
  Fibonacci sequence inside the sandbox folder."
- User sees: prompt -> UI flash -> diff -> "Approve" button
- **Lesson taught:** agent can't act without approval + how to use Diff Viewer
- All in a safe, disposable environment

**Existing hooks:** `sandbox_tool.rs`, approval system in `approval_resolver.rs`

## 3. Epistemic Training Wheels (Progressive Disclosure)

**Problem:** "Variational Free Energy" and "Noradrenaline" are jargon to novices.
The telemetry ribbon is powerful but intimidating.

**Plan:**
- **Level 1 (Novice Mode):** Hide neurochemical labels. Show simple "Confidence"
  meter: Green = Confident, Yellow = Thinking/Exploring, Red = Stuck/Confused
- **Level 2 (Developer Mode):** Settings toggle "Enable Telemetry" reveals actual
  Free Energy, DA/NA/5HT levels, surprise sparkline, regime history
- Default to Level 1, let users graduate

**Existing hooks:** `/api/cognitive-state`, telemetry ribbon in `web/index.html`,
`/api/neuromod-stream` SSE endpoint

## 4. "I'm Stuck" Escape Hatch (Context Injection)

**Problem:** Agent loops on a failing test 3+ times. Novice doesn't know how to
intervene, closes the app.

**Plan:**
- Detect high-entropy state (3+ consecutive failures)
- Friendly pop-up: "I'm having trouble resolving this test failure. Do you have
  any hints?"
- Simple text box for natural language hints
- Inject into `user_error_hints.rs` stream / blackboard
- **Lesson taught:** user is a *supervisor*, not just a prompter

**Existing hooks:** `user_error_hints.rs`, `/api/inject-hint` endpoint,
blackboard system, surprise tracker (failure detection)

## 5. "Look What I Did" Summary (Asynchronous Trust)

**Problem:** User walks away during a 10-minute autonomous task. No idea what
happened when they return.

**Plan:**
- Generate human-readable summary from `episode_db.rs` long-term memory
- "Morning Briefing" card on app open:
  "While you were away, I updated 4 dependencies and fixed the broken test in
  `src/main.rs`. I attempted to refactor the DB schema but rolled it back due
  to 12 cascading errors. [View Diff]"
- Surface in PWA dashboard and Tauri desktop

**Existing hooks:** `episode_db.rs`, `episode_tool.rs`, task system,
`/api/cognitive-state`, blackboard entries

## Priority Order

1. Sandbox Tutorial (2) — lowest effort, highest trust-building impact
2. Progressive Disclosure (3) — CSS/JS toggle on existing telemetry ribbon
3. Escape Hatch (4) — inject-hint endpoint already exists, just needs UI trigger
4. Morning Briefing (5) — episode_db exists, needs summary generation + card UI
5. OOTB Wizard (1) — highest effort, requires Tauri installer work + model registry
