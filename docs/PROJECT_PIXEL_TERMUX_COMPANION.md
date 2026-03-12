# Chump's First Project: Pixel Termux Bot Companion

**Goal:** Get a Rust-based bot companion up and running in Termux on the Pixel that can work with Chump on projects. Chump gives it access to build tools and AI agents that run in Rust on the device; the companion collaborates with Chump (tasks in, results out, or a simple sync protocol).

**Why this first:** The Pixel is already connected via ADB (Tailscale). Termux provides a Linux environment on the phone where we can install Rust/cargo and run a small agent. Once the companion is running, Chump can delegate device-local work (builds, tests, file ops, or a second lightweight agent) and coordinate with it.

---

## What Chump Already Has

- **ADB tool** (see [ROADMAP_ADB.md](ROADMAP_ADB.md)): `status`, `connect`, `disconnect`, `shell`, `input`, `screencap`, `ui_dump`, `list_packages`, `logcat`, `battery`, `getprop`, `push`, `pull`, `install`, `uninstall`.
- **Device:** Pixel 8 Pro on Tailscale at `CHUMP_ADB_DEVICE` (e.g. `100.121.127.45:34085`). Use `adb` action `status` / `connect` to ensure the phone is online.

Chump uses the `adb` tool to run shell commands on the device, push/pull files, and drive the UI. To run commands **inside Termux** (where Rust and build tools live), see "Running commands in Termux from ADB" below.

---

## Running Commands in Termux from ADB

Termux installs under `/data/data/com.termux/files/usr`. The Android shell (from `adb shell`) is not Termux's environment. Two ways to run commands in Termux from Chump:

### 1. RUN_COMMAND Intent (recommended for automation)

Termux supports running a command from an external app via the **RUN_COMMAND** Intent. One-time setup on the phone:

1. In Termux: create or edit `~/.termux/termux.properties` and set `allow-external-apps=true`.
2. In Android **Settings → Apps → Termux → Additional permissions**, enable **Run commands from external apps** (or the permission Termux documents for RUN_COMMAND).

Then from the host (Chump can do this via `adb shell`), trigger a command in Termux with:

```bash
adb shell am startservice -n com.termux/.RunCommandService \
  -a com.termux.RUN_COMMAND \
  --es com.termux.RUN_COMMAND "pwd"
```

Replace `"pwd"` with the full command string (e.g. `"cd ~/projects/companion && cargo build"`). The command runs in Termux's home directory and environment. Chump can use the `adb` tool with action `shell` and a command that invokes this `am startservice` pattern (or a small wrapper script pushed to the device).

### 2. Direct Termux bash (when RUN_COMMAND is not set up)

If the device has Termux installed but RUN_COMMAND is not enabled, Chump can still run commands in the **Android** shell that touch Termux's filesystem (e.g. `adb shell` to list `/data/data/com.termux/files/home`). Running Termux's bash directly from ADB shell often fails due to UID/permissions unless the app is debuggable. So for a reliable "run in Termux" path, use the Intent method above.

---

## Phases for Chump

### Phase 1: Termux + Rust on the Pixel

- Use `adb` to ensure device is connected.
- **If Termux is not installed:** use `adb install` (or ask the user to install Termux from F-Droid) and optionally Termux:API for extras.
- **Inside Termux** (user can do this once, or Chump can drive it via RUN_COMMAND if configured): install Rust and basic build tools:
  - `pkg update && pkg install -y rust clang make` (or follow Termux's Rust docs).
  - `cargo --version` to confirm.
- Chump can push a minimal `main.rs` or a tiny Rust project to the device (e.g. to `/sdcard/Download/companion` or a path Termux can read), then run `cargo build` in Termux via RUN_COMMAND.

### Phase 2: Minimal companion binary

- Define a minimal protocol: e.g. the companion reads a "task" file (path Chump pushes via `adb push`), runs a single command or small script, writes a "result" file, and exits (or loops).
- Chump: `adb push task.txt /sdcard/Download/companion/in.txt`, then RUN_COMMAND to run the companion binary (e.g. `~/companion/run.sh`), then `adb pull` the result file.
- Companion can be a Rust CLI that: reads `in.txt`, parses a simple verb (e.g. `run_cli`, `cargo_build`), runs it in Termux, writes stdout/stderr to `out.txt`.

### Phase 3: Companion as collaborator

- Expand the protocol: task queue (e.g. Chump pushes multiple tasks; companion processes and reports back), or a tiny HTTP/WebSocket server in the companion so Chump can POST tasks and GET results.
- Companion gets access to build tools (cargo, rustfmt, clippy) and optionally a small local model or API-backed agent in Rust so it can do more than run_cli (e.g. summarize logs, suggest next step). Chump and the companion work on the same project: Chump on the Mac, companion on the Pixel, with file sync or a simple RPC.

---

## Docs Chump Should Use (grep / read when starting)

**In this repo (Chump):**

| Doc | Use for |
|-----|--------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | What Chump is, tools, soul, memory, delegate |
| [CHUMP_PLAYBOOK.md](CHUMP_PLAYBOOK.md) | When to use which tool (routing table, wiki, memory) |
| [CHUMP_FULL_TOOLKIT.md](CHUMP_FULL_TOOLKIT.md) | CLI arsenal, what to install (Rust/cargo, ripgrep, jq, etc.) — same ideas apply in Termux |
| [CHUMP_BRAIN.md](CHUMP_BRAIN.md) | State, ego, episode, memory_brain — store learnings about the Pixel/Termux setup |
| [tools_index.md](tools_index.md) | Native + CLI tool index; add Termux/companion notes when you learn them |
| [ROADMAP_ADB.md](ROADMAP_ADB.md) | ADB tool actions, config, safety, pairing |
| [OPERATIONS.md](OPERATIONS.md) | Run/serve, env reference, troubleshooting |
| [CLOSING_THE_GAPS.md](CLOSING_THE_GAPS.md) | Continuity, context assembly, session close — relevant for multi-session work with the companion |
| [AUTONOMOUS_PR_WORKFLOW.md](AUTONOMOUS_PR_WORKFLOW.md) | How to work on issues/PRs; adapt for "companion project" tasks |
| [SETUP_AND_RUN.md](SETUP_AND_RUN.md), [SETUP_QUICK.md](SETUP_QUICK.md) | General run/setup patterns |

**In Maclawd (sibling repo) — for reference only; Chump runs from Chump repo):**

- `docs/automation/auth-monitoring.md` — mentions Termux widgets and scripts (`termux-auth-widget.sh`, `termux-sync-widget.sh`); shows Termux script shebang and widget usage.
- `scripts/termux-*.sh` — examples of scripts that run inside Termux (shebang `#!/data/data/com.termux/files/usr/bin/bash`); Chump can push similar scripts to the device and run them via RUN_COMMAND.

**External (Chump can read via read_url or web_search if needed):**

- Termux wiki: RUN_COMMAND Intent, packaging Rust.
- Termux packages: `pkg search rust`, `pkg install rust`.

---

## Quick start for Chump

1. **Check device:** `adb` action `status`; if offline, `connect`.
2. **Check Termux:** `adb` action `shell` with command e.g. `ls /data/data/com.termux/files/usr/bin 2>/dev/null || echo "Termux not found"`. If the user hasn’t installed Termux yet, suggest installing from F-Droid and enabling RUN_COMMAND (see above).
3. **Run a command in Termux:** use RUN_COMMAND Intent via `adb shell am startservice ...` (see above), or document the exact `adb shell` command for the user to run once.
4. **Push a minimal Rust project:** use `adb push` to put a `Cargo.toml` and `src/main.rs` on the device (path under `/sdcard/Download` or a path Termux can read); then RUN_COMMAND to run `cargo build` in that directory inside Termux.
5. **Store learnings:** use `memory` and `memory_brain` to record what worked (paths, Intent format, errors). Use `ego` / `episode` so the next session knows the current state of the companion project.

---

## Summary

| Item | Notes |
|------|--------|
| **Goal** | Rust bot companion in Termux on the Pixel that works with Chump on projects. |
| **Chump’s access** | ADB tool (shell, push, pull, screencap, input, etc.). Run commands in Termux via RUN_COMMAND Intent. |
| **First steps** | Ensure Termux + Rust in Termux; push minimal Rust binary; define task-in/result-out; then expand to a collaborator. |
| **Docs** | Grep/read the Chump docs above (and Maclawd Termux scripts for examples). Use memory_brain and episode to persist progress. |
