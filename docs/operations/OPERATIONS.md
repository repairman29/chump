---
doc_tag: canonical
owner_gap: PRODUCT-375
last_audited: 2026-11-27
---

# Daemon & Service Operations

Chump v1.0 ships a pure-Rust background supervisor (`chumpd`) and unified service manager (`chump service` + `chump up`) that run natively on **macOS, Linux, and Windows**—with zero `tmux`, bash daemon loops, or Unix-only socket dependencies.

---

## 1. Supervisor Architecture (`chumpd`)

`chumpd` (`crates/chumpd`) manages three continuous background duties using minimal idle CPU and memory:

1. **Worker Pool Lifecycle:** Spawns and monitors up to `desired_workers` child processes using OS-native process groups (`crates/chump-pal` Unix PGIDs and Windows Job Objects) so stopped workers never leave orphan compiler processes behind.
2. **Dead-PID & Expired Lease Reaping:** Scans `.chump-locks/*.json` on a steady cadence and reaps locks whose TTL has expired or whose owning PID no longer exists, recording `stale_lease_reaped` in `.chump-locks/ambient.jsonl`.
3. **OAuth Credential Sync:** Refreshes subscription OAuth tokens every 5 minutes into `~/.chump/oauth-token.json` (`0600` atomic temp-file + rename) so long-running worker pools do not fail mid-PR on expired tokens.

Control-plane IPC binds strictly to loopback (`127.0.0.1:<port>`, recorded in `.chump/chumpd.addr`).

---

## 2. Native OS User Service Management (`chump service`)

Register `chumpd` as a login/boot user service with a single command on any supported OS:

```bash
# Preview generated OS service unit without writing files
chump service install --dry-run

# Install and enable user service
chump service install

# Check live service registration and supervisor health
chump service status

# Remove user service cleanly
chump service uninstall
```

### OS Service Targets

| Operating System | Native Mechanism | Installed Artifact |
|------------------|------------------|--------------------|
| **macOS** | `launchctl` (`LaunchAgents`) | `~/Library/LaunchAgents/com.chump.chumpd.plist` |
| **Linux** | `systemd --user` | `~/.config/systemd/user/chumpd.service` |
| **Windows** | Task Scheduler (`schtasks`) | User Scheduled Task `ChumpDaemon` |

> **Linux headless servers:** Run `loginctl enable-linger $USER` once if you want `systemd --user` services to stay active after SSH logout.

---

## 3. Foreground & On-Demand Launch (`chump up`)

When developing interactively or inside containers without an init system:

```bash
chump up                  # Start chumpd in the background if not already running
chump up --foreground     # Run supervisor in the current terminal (Ctrl-C stops cleanly)
chump up --status         # Query loopback IPC status of the running supervisor
```

### Runtime Autonomy & Kill-Switch (`chump fleet`)

Control worker concurrency dynamically without editing service files:

```bash
chump fleet status        # Show active claims, worker health, and 24h ship throughput
chump fleet level 3       # Supervised parallel execution
chump fleet level 0       # Immediate fail-closed STOP (pauses new dispatches instantly)
```

You can also pause any local agent loop immediately by setting `CHUMP_PAUSED=1` or creating `logs/pause`.

---

## 4. Web Cockpit & Bearer Auth (`chump --web`)

Launch the local HTTP + SSE cockpit (`src/web_server.rs`):

```bash
chump --web --port 3847
```

- **Default bind:** `127.0.0.1` (`[web] bind_addr` in `~/.chump/config.toml`). Keep `127.0.0.1` on developer laptops.
- **Authentication (`CHUMP_WEB_TOKEN`):** Whenever exposing the cockpit across a private VPN/LAN or reverse proxy, set `CHUMP_WEB_TOKEN` to a strong random secret (`openssl rand -hex 32`). Mutating and workspace-sensitive `/api/*` routes require `Authorization: Bearer <CHUMP_WEB_TOKEN>`.
- **Optional Web Push notifications:** Set `CHUMP_VAPID_PUBLIC_KEY`, `CHUMP_VAPID_PRIVATE_KEY_FILE`, and `CHUMP_WEB_PUSH_AUTONOMY=1` to receive browser push alerts when long-running autonomous tasks complete or block.

---

## 5. Preflight

Run preflight checks before pushing code or after changing model/infrastructure configuration:

```bash
# 1. Repository code preflight (rustfmt, clippy -D warnings, compile check, scoped tests)
chump preflight

# 2. Config & auth validation
chump config validate

# 3. Live web & model stack probe (when chump --web is running)
curl -fsS http://127.0.0.1:3847/api/health
curl -fsS http://127.0.0.1:3847/api/stack-status
```

In a source checkout, `bash scripts/ci/chump-preflight.sh` automates the HTTP health + `stack-status` readiness check for CI and pre-deployment smoke tests.

---

## 6. Logs, Disk Floors & Observability

| Artifact | Location | Purpose |
|----------|----------|---------|
| `ambient.jsonl` | `<repo>/.chump-locks/ambient.jsonl` | Structured RFC3339 coordination, claim, ship, and circuit events |
| `.chump-locks/*.json` | `<repo>/.chump-locks/` | Active session path and symbol leases |
| `.chump/state.db` | `<repo>/.chump/state.db` | Canonical SQLite WAL task queue and PR linkage |
| `chump.log` | `<repo>/logs/chump.log` | Structured runtime log with automatic credential redaction |

**Automatic disk-floor protection:** Set `disk_floor_gb = 5.0` (default) under `[fleet]` in `~/.chump/config.toml`. If free disk space drops below the configured floor, `chumpd` refuses to create new worktrees or start heavy Cargo builds until space is reclaimed (see [Storage & Worktree Hygiene](STORAGE_AND_ARCHIVE.md)).

---

## Related Guides

- [5-Minute Clean Setup](../process/EXTERNAL_GOLDEN_PATH.md)
- [Inference Stability](INFERENCE_STABILITY.md)
- [Storage & Worktree Hygiene](STORAGE_AND_ARCHIVE.md)
- [HTTP & SSE API](../api/WEB_API_REFERENCE.md)
