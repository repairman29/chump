# Chump Cowork: macOS Dock / Finder icon

The Tauri shell is **`chump-desktop`**. When you open it from **Terminal**, `chump` usually sits beside it under `target/debug/` and **`CHUMP_HOME`** may already be set. When you open a **`.app`** from the Dock, macOS does **not** load your shell profile and the bundle may not see your repo **`.env`** unless we configure it.

## One-shot build (recommended)

From the Chump repo root on a Mac:

```bash
chmod +x ./scripts/macos-cowork-dock-app.sh
./scripts/macos-cowork-dock-app.sh
```

Optional:

- **`CHUMP_HOME=/path/to/Chump`** if the repo is not the default (script parent).
- **`OPEN_APP=1`** to open the app when the script finishes.

The script:

1. Builds **`chump`** release (workspace).
2. Runs **`cargo tauri build`** (install **`cargo install tauri-cli`** once if needed).
3. Copies **`target/release/chump`** into **`Chump.app/Contents/MacOS/chump`** next to the desktop binary.
4. Merges **`LSEnvironment`** into **`Info.plist`**: **`CHUMP_HOME`**, **`CHUMP_REPO`**, **`CHUMP_BINARY`**, and a **`PATH`** that includes **`~/.local/bin`** (for **`vllm-mlx`** when the sidecar auto-starts).
5. Re-signs the bundle ad hoc so Gatekeeper is less confused after the plist edit.

Then **drag `Chump.app`** from the build output (under `desktop/src-tauri/target/release/bundle/macos/` or `target/release/bundle/macos/`) to **Applications** or the **Dock**. First launch: if macOS blocks it, use **Right-click → Open** once.

## Prerequisites

- **Rust** + **Xcode Command Line Tools**
- **`cargo install tauri-cli`** (the script installs it if missing)
- Repo **`.env`** at **`CHUMP_HOME`** (MLX **8001** / **8000**, etc.)
- **vLLM-MLX** on the port in **`.env`** when you expect chat to work (or start it after opening the app)

## How it works at runtime

- **`CHUMP_BINARY`** points at **`Contents/MacOS/chump`** so auto-spawn does not depend on the main executable’s name.
- **`CHUMP_HOME`** / **`CHUMP_REPO`** point at the git checkout so **`load_dotenv()`** loads **`.env`** for MLX.
- The desktop crate also falls back to **`$HOME/Projects/Chump`** on macOS if env is missing (common clone path).

## Dev without a bundle

```bash
cargo build -p chump-desktop && cargo build --bin chump
CHUMP_HOME="$PWD" cargo run --bin chump -- --desktop
```

See also [TAURI_FRONTEND_PLAN.md](TAURI_FRONTEND_PLAN.md) and [OPERATIONS.md](OPERATIONS.md) (Desktop row).
