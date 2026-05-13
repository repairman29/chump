# PWA Deployment Guide

The Chump PWA is embedded in the `chump` binary. The web UI is served by
`chump --web` (default port 3000).

## Quick start

```bash
chump --web              # serve on port 3000
chump --web --port 3001  # alternate port
```

Open http://localhost:3000 in a browser.

## Binary / server compatibility (CREDIBLE-022)

The web server IS the `chump` binary — there is no separate server process.
However, in development workflows, the source can drift ahead of the installed
binary if you edit `src/web_server.rs` without rebuilding.

### Startup warning

At PWA startup, `chump --web` checks whether `src/web_server.rs` was modified
more than 2 hours after the binary's build date. If so, it emits:

```
[web] WARNING: src/web_server.rs is Xh newer than the installed binary
(built YYYY-MM-DD). Run `cargo install --force` or `cargo build` to rebuild.
```

Resolve by rebuilding:

```bash
cargo build --release --bin chump
# or to install to PATH:
cargo install --force --path .
```

The check is silently skipped when the source tree is not present (production
installs via Homebrew or binaries downloaded from GitHub releases).

### GET /api/health

The health endpoint reports binary metadata:

```json
{
  "status": "ok",
  "service": "chump-web",
  "binary_version": "0.1.1",
  "build_sha": "abc1234",
  "build_date": "2026-05-12",
  "binary_age_secs": 3600,
  "version_match": true
}
```

| Field | Description |
|---|---|
| `binary_age_secs` | Seconds since the binary's baked build date (null if unknown) |
| `version_match` | `true` unless `CHUMP_BINARY_VERSION` env var is set and differs from running version |
| `build_sha` | 12-char git SHA from build time |
| `build_date` | `YYYY-MM-DD` of the commit this binary was built from |

### CHUMP_BINARY_VERSION

Operators can assert an expected version at deployment time:

```bash
CHUMP_BINARY_VERSION=0.1.1 chump --web
```

If the running binary's version differs, `/api/health` returns
`"version_match": false` — useful for health-check automation.

## Environment variables

| Env var | Default | Description |
|---|---|---|
| `CHUMP_WEB_PORT` | 3000 | HTTP port for the web server |
| `CHUMP_BIN` | `chump` | Path to the chump binary for spawning workers |
| `CHUMP_REPO` | cwd | Path to the repository root |
| `GH_TOKEN` | (keyring) | GitHub token for agent operations |
| `CHUMP_BINARY_VERSION` | — | Expected version for health check `version_match` |
