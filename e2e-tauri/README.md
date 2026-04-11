# Cowork (Tauri) WebDriver E2E

This exercises the **real desktop shell** (`chump-desktop`) using [Tauri’s WebDriver stack](https://v2.tauri.app/develop/tests/webdriver/): **`tauri-driver`** + the platform native WebDriver server.

## Platform support (upstream)

| OS | Status |
|----|--------|
| **Linux** | Supported (`WebKitWebDriver` from `webkit2gtk-driver`). CI runs here. |
| **Windows** | Supported (Edge WebDriver + `tauri-driver`). Not wired in this repo yet. |
| **macOS** | **Not supported by Apple** for WKWebView — there is no official desktop WebDriver. Options: run Linux E2E in CI/Docker, or evaluate community tools (e.g. `tauri-plugin-webdriver-automation` + `tauri-wd` on macOS). |

## Local (Linux only)

```bash
# system packages (Debian/Ubuntu example — see CI workflow for the exact set)
sudo apt-get install -y webkit2gtk-4.1 libwebkit2gtk-4.1-dev libayatana-appindicator3-dev \
  webkit2gtk-driver xvfb build-essential pkg-config libssl-dev librsvg2-dev

cargo install tauri-driver --locked
./scripts/run-tauri-e2e.sh
```

On **macOS**, `scripts/run-tauri-e2e.sh` prints a skip message and exits `0` so local scripts do not fail; use the PWA Playwright suite (`scripts/run-ui-e2e.sh`) for local UI automation, or rely on the **Linux** Cowork job in GitHub Actions.
