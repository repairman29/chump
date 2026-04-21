# Installing Chump via Homebrew

Chump can be installed on macOS (and Linux with Homebrew) using the official tap.

## Prerequisites

Before installing, ensure you have the following:

- **Rust toolchain** — Chump is built from source. Install via [rustup](https://rustup.rs/):
  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  ```
  Minimum required Rust version: 1.75 (stable).

- **sqlite3** — Chump uses SQLite for persistent state. On macOS this is bundled via Homebrew when you install chump. On Linux you may need to install `libsqlite3-dev` (Debian/Ubuntu) or `sqlite-devel` (Fedora/RHEL) first.

- **Homebrew** — Install from [brew.sh](https://brew.sh/) if you don't have it:
  ```bash
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  ```

## Install

```bash
brew tap repairman29/chump
brew install chump
```

This will:
1. Add the `repairman29/chump` tap (pointing to `https://github.com/repairman29/chump`).
2. Build the `chump` binary from source using `cargo build --release`.
3. Install the binary to your Homebrew prefix (e.g. `/opt/homebrew/bin/chump` on Apple Silicon).
4. Install `sqlite` as a runtime dependency.

The build takes 2–5 minutes on a modern machine (compiling Rust from scratch).

## Verify the install

```bash
chump --version
```

## Upgrade

```bash
brew update && brew upgrade chump
```

## Uninstall

```bash
brew uninstall chump
brew untap repairman29/chump
```

## Tap repository

The formula lives at `Formula/chump.rb` inside the main repo:
`https://github.com/repairman29/chump`

Homebrew locates it automatically when you run `brew tap repairman29/chump`.

## Notes

- The binary currently requires macOS code signing and notarization for Gatekeeper approval on macOS 13+. If you encounter a "cannot be opened because the developer cannot be verified" error, run:
  ```bash
  xattr -d com.apple.quarantine $(which chump)
  ```
  This will be resolved in a future release when CI signing is wired up.

- On Apple Silicon (M-series), the build defaults to `aarch64-apple-darwin`. Intel Macs build `x86_64-apple-darwin`. Cross-compilation is not required — Homebrew picks the native target automatically.
