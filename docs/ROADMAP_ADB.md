# ADB tool for Chump (roadmap)

Wireless ADB on Pixel phones (Android 11+) lets Chump control a device over Wi-Fi (e.g. Pixel 8 Pro on Tailscale) without a USB cable. This doc is the design and roadmap.

## Connection lifecycle

1. **Pair (one-time):** On the phone: **Developer Options → Wireless debugging** → "Pair device with pairing code." You get an IP:pairing_port and a 6-digit code. Run once (outside Chump):
   ```bash
   adb pair 100.121.127.45:45645
   # When prompted, enter the 6-digit code (e.g. 005495)
   ```
2. **Connect (per-session):** After pairing, use the **connect** port (shown on the wireless debugging screen, not the pairing port):
   ```bash
   adb connect 100.121.127.45:34085
   ```
3. **Config for Chump:** In `.env` set the device to the **connect** address (IP:port):
   ```bash
   CHUMP_ADB_ENABLED=1
   CHUMP_ADB_DEVICE=100.121.127.45:34085
   ```
   Example: Pixel 8 Pro on Tailscale — pairing code `005495`, pairing port `100.121.127.45:45645`, connect port `34085` → `CHUMP_ADB_DEVICE=100.121.127.45:34085`.

4. **Heartbeat/reconnect:** Wi-Fi can drop. Use the `adb` tool action `status` to check; use `connect` to reconnect.

## Tool: `adb`

One tool with an `action` enum (like other Chump tools). Actions:

| Action | What it runs | Use case |
|--------|--------------|----------|
| `status` | `adb devices` | Check if phone is connected/online |
| `connect` | `adb connect $DEVICE` | Reconnect after Wi-Fi drop |
| `shell` | `adb -s $DEVICE shell <command>` | General shell (dumpsys, getprop, am, pm, settings) |
| `input` | `adb shell input <tap\|swipe\|text\|keyevent>` | UI automation — tap, type, navigate |
| `screencap` | `adb shell screencap -p` + pull | See what's on screen (path returned for vision/OCR) |
| `list_packages` | `adb shell pm list packages` | Discover installed apps |
| `logcat` | `adb logcat -d -t <lines>` | Recent logs (optional) |
| `push` / `pull` | `adb push` / `adb pull` | File transfer |
| `install` | `adb install <apk>` | Install APK (destructive; optional confirmation gate) |

## Safety and config

- **Blocklist:** Dangerous shell commands are blocked (e.g. `rm -rf /`, `factory_reset`, `su `, `reboot bootloader`, `dd `). See `adb_tool.rs` for the full list.
- **Timeout / output cap:** Same idea as `run_cli` — default 30s timeout, 4000 chars max output (configurable via `CHUMP_ADB_TIMEOUT`, `CHUMP_ADB_MAX_OUTPUT`).
- **Optional allowlist:** `CHUMP_ADB_ALLOWLIST=input,screencap,shell,status` restricts to only those actions.
- **Optional confirmation:** `CHUMP_ADB_CONFIRM_DESTRUCTIVE=1` can gate install/push (Phase 2).

## Closed-loop screen control (Phase 2)

1. **screencap** → PNG saved under repo `logs/` (path returned).
2. Chump (or delegate) analyzes the screenshot — vision model or OCR (tesseract).
3. Chump decides next **input** action (tap, swipe, type).
4. Repeat.

Optional: `ui_dump` action (`adb shell uiautomator dump`) for structured view hierarchy (XML) instead of or alongside screenshots.

## Config summary (.env)

```bash
CHUMP_ADB_ENABLED=1
CHUMP_ADB_DEVICE=100.121.127.45:34085
CHUMP_ADB_TIMEOUT=30
CHUMP_ADB_MAX_OUTPUT=4000
# CHUMP_ADB_ALLOWLIST=input,screencap,shell,status
# CHUMP_ADB_CONFIRM_DESTRUCTIVE=1
```

## Pairing script

One-time pairing (interactive): run from the Chump repo root:

```bash
./scripts/adb-pair.sh <ip:pairing_port> <pairing_code>
```

Example: `./scripts/adb-pair.sh 100.121.127.45:45645 005495`. The script will prompt for the connect address (e.g. `100.121.127.45:34085`) and can add `CHUMP_ADB_DEVICE` to `.env`.

## Implementation phases

- **Phase 1 (done):** `status`, `connect`, `disconnect`, `shell`, `input`, `screencap`, `ui_dump`, `list_packages`, `logcat`, `battery`, `getprop`, `install`, `uninstall`, `push`, `pull`. Blocklist. Timeout/output cap. Optional `CHUMP_ADB_CONFIRM_DESTRUCTIVE` for install/push/uninstall. `log_adb` in chump.log. Conditional registration when `CHUMP_ADB_ENABLED=1` and `CHUMP_ADB_DEVICE` set. Pairing script: `scripts/adb-pair.sh`.
- **Phase 2:** Closed-loop control — pipe screenshots to vision model or OCR; optional `screen_read` action.
- **Phase 3:** Automation recipes in memory (multi-step procedures replayed via input/screencap).

## Pixel Termux companion (Chump's first project)

To give Chump access to build tools and a Rust agent **on the Pixel in Termux**, see [PROJECT_PIXEL_TERMUX_COMPANION.md](PROJECT_PIXEL_TERMUX_COMPANION.md). That doc describes running commands inside Termux from ADB (RUN_COMMAND Intent), setting up Rust in Termux, and getting a minimal bot companion up so it can work with Chump on projects. Use the adb tool for shell, push, pull, and (once configured) RUN_COMMAND to drive Termux.

## Example interaction

**User:** What's on my phone screen right now?

**Chump:**  
→ `adb` action `status`  
→ `adb` action `screencap` (reads path, can use vision/OCR)  
→ "Your phone shows the home screen; time 3:42 PM, 2 notifications."

**User:** Open Settings and check battery.

**Chump:**  
→ `adb` action `input` tap at Settings icon  
→ `adb` action `screencap` to confirm  
→ `adb` action `shell` with `dumpsys battery`  
→ "Battery 73%, not charging. Temperature 28.4°C."
