# ADB tool for Chump (roadmap)

Wireless ADB on Pixel phones (Android 11+) lets Chump control a device over Wi-Fi (e.g. Pixel 8 Pro on Tailscale) without a USB cable. This doc is the design and roadmap.

## Avoid USB after every reboot

Use **Wireless debugging** (Developer options), not the legacy **"ADB over network"** / `adb tcpip 5555` method. The legacy method resets on reboot so you have to plug in USB and run `adb tcpip 5555` again. With **Wireless debugging** turned on:

- The phone listens for ADB over Wi-Fi on every boot (no USB).
- Pair once (see below), then after each reboot you only run **connect** (e.g. `./scripts/adb-connect.sh` or `adb connect <ip>:<port>`).
- The connect **port** can change after reboot on some devices. If connect fails, open **Settings → Developer options → Wireless debugging** and use the IP:port shown there; update `.env` `CHUMP_ADB_DEVICE` or pass it to `adb-connect.sh` if needed.

## Connection lifecycle

1. **Pair (one-time):** On the phone: **Developer Options → Wireless debugging** → ON → "Pair device with pairing code." You get an IP:pairing_port and a 6-digit code. Run once (outside Chump):
   ```bash
   adb pair 100.121.127.45:45645
   # When prompted, enter the 6-digit code (e.g. 005495)
   ```
   Or use: `./scripts/adb-pair.sh 100.121.127.45:45645 005495`
2. **Connect (per-session / after reboot):** Use the **connect** port (shown on the Wireless debugging screen, not the pairing port):
   ```bash
   adb connect 100.121.127.45:34085
   ```
   Or from the Chump repo: `./scripts/adb-connect.sh` (uses `CHUMP_ADB_DEVICE` from `.env`), or `./scripts/adb-connect.sh 10.1.10.9:34085` to pass the address.
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

**From the Pixel:** Mabel can do OCR locally with `scripts/screen-ocr.sh` (tesseract). Install in Termux: `pkg install tesseract`; add `tesseract` to `CHUMP_CLI_ALLOWLIST`. See [ANDROID_COMPANION.md](ANDROID_COMPANION.md#ocr-on-pixel-screen-ocr). Mabel then reads notifications, foreground app, or any image path without a vision model.

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

## Scripts

- **One-time pairing:** `./scripts/adb-pair.sh <ip:pairing_port> <pairing_code>` — e.g. `./scripts/adb-pair.sh 100.121.127.45:45645 005495`. Prompts for the connect address and can add `CHUMP_ADB_DEVICE` to `.env`.
- **After reboot / reconnect:** `./scripts/adb-connect.sh` (uses `CHUMP_ADB_DEVICE` from `.env`) or `./scripts/adb-connect.sh <ip:port>` if the port changed. No USB needed when using Wireless debugging.

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
