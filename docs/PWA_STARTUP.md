# PWA / Web Server Startup Checklist

Reference for operators running `chump --web` or the Tauri desktop app.

The web server validates required environment before binding to the port
(EFFECTIVE-013). Misconfigurations are reported to stderr and cause an immediate
`exit(1)` — the server never starts listening.

---

## Required environment

| Variable | Required? | Validation |
|----------|-----------|------------|
| `CHUMP_REPO` | If set | Must be an existing directory |
| `CHUMP_BIN` | If set as absolute path | Must exist and be executable |
| `GH_TOKEN` or `GITHUB_TOKEN` | Recommended | Warning only if absent; agent falls back to keyring |

### CHUMP_REPO

Path to the Chump repository checkout. Used by the PWA's claim/execute/ship
API endpoints to locate `docs/gaps/`, `scripts/coord/`, and `.chump/state.db`.

```
export CHUMP_REPO=/path/to/chump
```

If set to a path that does not exist the server exits immediately:

```
[web] CHUMP_REPO not found: /path/to/chump
```

### CHUMP_BIN

Path (absolute) or name of the `chump` binary invoked by the PWA for dispatch.
Defaults to `chump` (resolved from `$PATH` at spawn time, not at startup).

When set to an absolute path, the server checks existence and execute permission:

```
export CHUMP_BIN=/usr/local/bin/chump
```

Error when path is wrong:

```
[web] CHUMP_BIN not found or not executable: /usr/local/bin/chump
```

### GH_TOKEN / GITHUB_TOKEN

Personal access token used by `gh` CLI for PR creation and status polling.
If neither is set the server continues but emits:

```
[web] WARNING: GH_TOKEN not set, agent will use keyring (set GH_TOKEN or GITHUB_TOKEN if keyring is unavailable)
```

---

## Smoke tests

Verify validation fires correctly before deploying:

```bash
# (a) CHUMP_REPO not found → exit 1
CHUMP_REPO=/nonexistent cargo run --bin chump -- --web 2>&1 | grep 'CHUMP_REPO not found' && echo PASS

# (b) CHUMP_BIN absolute path missing → exit 1
CHUMP_BIN=/nonexistent/chump cargo run --bin chump -- --web 2>&1 | grep 'CHUMP_BIN' && echo PASS

# (c) GH_TOKEN missing → warning, server starts
env -u GH_TOKEN -u GITHUB_TOKEN cargo run --bin chump -- --web 2>&1 | grep 'WARNING: GH_TOKEN not set' && echo PASS
```

---

## Common startup failures

| Symptom | Cause | Fix |
|---------|-------|-----|
| `CHUMP_REPO not found: …` | Path in `CHUMP_REPO` does not exist | Set `CHUMP_REPO` to a valid repo checkout |
| `CHUMP_REPO is not a directory: …` | `CHUMP_REPO` points to a file | Fix the path |
| `CHUMP_BIN not found or not executable: …` | `CHUMP_BIN` absolute path missing or missing +x | Run `chmod +x $CHUMP_BIN` or fix the path |
| Port 3000 in use | Another process bound the port | Set `CHUMP_WEB_PORT=3001` (or the server auto-increments) |
