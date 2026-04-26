---
doc_tag: runbook
owner_gap:
last_audited: 2026-04-25
---

# Packaging and Notarization

How Chump binaries and the macOS desktop app are packaged and released.

## Release pipeline

Releases are automated via `cargo-dist` ([.github/workflows/release.yml](../.github/workflows/release.yml)). Triggered by pushing a semver tag (e.g. `1.2.3` or `v1.2.3`):

```bash
git tag 1.2.3
git push origin 1.2.3
```

`cargo-dist` runs `dist plan` to determine what artifacts to build, builds them across target platforms, and uploads to a GitHub Release with auto-generated release notes from CHANGELOG.

## Artifacts produced

| Artifact | Platform | Notes |
|----------|----------|-------|
| `chump-x86_64-unknown-linux-gnu.tar.gz` | Linux x86_64 | CLI binary |
| `chump-aarch64-apple-darwin.tar.gz` | macOS ARM64 | CLI binary |
| `chump-x86_64-pc-windows-msvc.zip` | Windows | CLI binary |
| SHA256 checksums | All | `dist-manifest.json` |

## Tauri desktop app (macOS)

The `chump-desktop` crate (`desktop/src-tauri/`) wraps the web UI in a macOS native app shell.

### Local build

```bash
cargo build -p chump-desktop
cargo run --bin chump -- --desktop   # re-execs chump-desktop next to chump binary
```

The WebView loads `web/` assets; API calls go to `CHUMP_DESKTOP_API_BASE` (default `http://127.0.0.1:3000`).

### macOS Dock icon setup

```bash
./scripts/macos-cowork-dock-app.sh
```

Creates a Dock icon that launches the desktop app and ensures a single instance (a new launch focuses the existing window instead of stacking shells).

### MLX / vLLM dev fleet check

Before building a release desktop app:

```bash
./scripts/tauri-desktop-mlx-fleet.sh
```

Checks: `8000/v1/models` reachable, `cargo test`/`clippy` for `chump-desktop`, `cargo check --bin chump`. Optional: `CHUMP_TAURI_FLEET_USE_MAX_M4=1`, `CHUMP_TAURI_FLEET_WEB=1`, `CHUMP_TAURI_FLEET_SKIP_FMT=1`.

## Code signing and notarization

> **TODO:** Document the macOS code signing identity, `notarytool` submission steps, stapling, and Gatekeeper validation. This is required for distributing `.app` bundles to users outside the Mac App Store.

Steps that need documentation:
1. Obtain a **Developer ID Application** certificate from Apple Developer Program
2. Configure signing in `cargo-dist` / Tauri build
3. Submit to Apple Notary Service via `xcrun notarytool submit`
4. Staple the notarization ticket: `xcrun stapler staple`
5. Verify: `spctl -a -v Chump.app`

## Autonomous publish (`CHUMP_AUTO_PUBLISH`)

When `CHUMP_AUTO_PUBLISH=1`, the heartbeat agent may autonomously:
- Bump `Cargo.toml` version
- Update `CHANGELOG.md`
- Create a git tag and push with `--tags`

This triggers the release workflow. Use only when `CHUMP_AUTO_PUBLISH=1` is intentionally set — it creates a public release.

## See Also

- [release.yml](../.github/workflows/release.yml)
- [Operations](OPERATIONS.md)
- [Tauri desktop](OPERATIONS.md#run) — Desktop (Tauri) section
