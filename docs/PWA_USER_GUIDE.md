# PWA User Guide — Chump Web Interface

How to use the Chump Progressive Web App (PWA) to browse the gap queue,
dispatch autonomous work, and monitor in-flight agent progress.

---

## Quick start

```bash
# Start the web server (defaults to port 3000)
chump --web

# Custom port and repo path
CHUMP_WEB_PORT=8080 CHUMP_REPO=/path/to/chump chump --web
```

Open **http://localhost:3000** in your browser.

---

## Gap queue view

The front page shows the open gap queue, pulled from `GET /api/gap-queue`:

```
┌────────────────────────────────────────────────────────────────┐
│  Chump Gap Queue                          [3 open / 2 in-flight]│
├─────────────┬────────────────────────────────┬──────┬──────────┤
│  Gap ID     │  Title                         │ Pri  │ Status   │
├─────────────┼────────────────────────────────┼──────┼──────────┤
│  INFRA-630  │  CREDIBLE: UUID gap-id compat  │  P1  │  open    │
│  FLEET-048  │  CREDIBLE: operator impact…    │  P1  │  open    │
│  COG-055    │  EFFECTIVE: wire surprisal EMA │  P2  │  open    │
└─────────────┴────────────────────────────────┴──────┴──────────┘
```

Gaps are sorted by priority (P0 first, then P1, P2, P3). Gaps with
unresolved dependencies are shown greyed out and cannot be dispatched.

---

## Dispatching a gap

### Via the web UI

1. Click on a gap row to expand its details (title, acceptance criteria, effort).
2. Click the **Dispatch** button.
3. The server calls `POST /api/gap/work/:id` and returns a `request_id`.
4. A progress panel opens automatically, polling `GET /api/gap/:id/status`.

### Via the API (curl)

```bash
# Trigger autonomous work on INFRA-630
curl -s -X POST http://localhost:3000/api/gap/work/INFRA-630 | python3 -m json.tool
```

Response:
```json
{
  "status": "accepted",
  "gap_id": "INFRA-630",
  "request_id": "a1b2c3d4e5f6"
}
```

The `request_id` is a 12-character identifier. Pass it to support for triage
if something goes wrong.

---

## Monitoring workflow progress

After dispatching, the gap moves through four phases. Poll
`GET /api/gap/:id/status` to track progress:

```bash
watch -n 5 "curl -s http://localhost:3000/api/gap/INFRA-630/status | python3 -m json.tool"
```

Example response during execution:

```json
{
  "gap_id": "INFRA-630",
  "gap_status": "open",
  "workflow_phase": "execute-gap",
  "workflow_status": "started",
  "progress_pct": 40,
  "error": null
}
```

### Phase progression

| Phase        | progress_pct | What is happening                                      |
|--------------|:------------:|--------------------------------------------------------|
| `preflight`  | 10           | Branch, worktree, lease checks                         |
| `claim`      | 20           | Worktree created, branch pushed                        |
| `execute-gap`| 40           | Agent is writing code / tests                          |
| `ship`       | 80           | PR created, auto-merge armed                           |
| _(done)_     | 100          | PR merged, gap shipped                                 |

When `progress_pct` is 100 and `workflow_status` is `"success"`, open the
PR link on GitHub. It should be auto-merged within minutes once CI passes.

### Real-time log stream (CHUMP_PWA_LOG)

For richer observability, set `CHUMP_PWA_LOG` before starting the server:

```bash
CHUMP_PWA_LOG=/tmp/chump-pwa.log chump --web
```

Each phase emits a JSON line:

```json
{"ts":"2026-05-12T14:30:00.000Z","request_id":"a1b2c3d4e5f6","gap_id":"INFRA-630","phase":"execute-gap","status":"started","duration_ms":null}
{"ts":"2026-05-12T14:45:22.000Z","request_id":"a1b2c3d4e5f6","gap_id":"INFRA-630","phase":"ship","status":"success","duration_ms":912543}
```

Tail it for live updates:

```bash
tail -f /tmp/chump-pwa.log | python3 -m json.tool
```

---

## Claiming a gap manually (for human work)

If you want to reserve a gap for human work rather than autonomous dispatch:

```bash
# Via API
curl -s -X POST http://localhost:3000/api/gap/claim/INFRA-630 | python3 -m json.tool

# Via CLI (equivalent)
chump claim INFRA-630
```

The gap will appear as `in-flight` in the gap queue until you ship it.

---

## Health check

The server exposes `/api/health` for uptime monitoring and binary freshness:

```bash
curl -s http://localhost:3000/api/health | python3 -m json.tool
```

```json
{
  "status": "ok",
  "service": "chump-web",
  "binary_version": "0.4.2",
  "build_sha": "5c130816",
  "build_date": "2026-05-12",
  "binary_age_secs": 3600,
  "version_match": true
}
```

If `binary_age_secs` exceeds 7200 (2 hours) and the source code is newer
than the binary, the server logs a drift warning. Rebuild with `cargo build`
and restart to clear it.

---

## Troubleshooting

### "Server returns 404 for /api/gap/work/…"

Check that the gap ID exists:
```bash
chump gap show INFRA-630
```
If it returns nothing, the gap is not registered. Run `chump gap list`.

### "Dispatch accepted but progress_pct stays at 0"

The workflow runs asynchronously in a background thread. If phase events
don't appear after 30 seconds, check:

```bash
tail -20 .chump-locks/ambient.jsonl | grep INFRA-630
```

Look for `gap_workflow_phase` events. If none appear, the agent may have
crashed — check `chump --web` stdout for `FAILED` or `Error` lines.

### "Workflow shows error in progress response"

The `error` field in `/api/gap/:id/status` contains the phase and
failure description, e.g. `"preflight lease_overlap"`. Common causes:

| Error                  | Cause                                    | Fix                               |
|------------------------|------------------------------------------|-----------------------------------|
| `preflight …`          | Dependency not met, gap already claimed  | Check `chump gap show <ID>`       |
| `claim …`              | Git / worktree failure                   | Check free disk space             |
| `execute-gap FAILED`   | Agent tool call failed or CI error       | Re-dispatch; check ambient.jsonl  |
| `ship FAILED`          | Push rejected or PR creation failed      | Run `gh auth status`              |

### "PWA shows stale binary warning"

The server detected that `src/web_server.rs` is newer than the running
binary. Rebuild and restart:

```bash
cargo build && chump --web
```

### "Port already in use"

```bash
CHUMP_WEB_PORT=8080 chump --web
```

Or find and kill the existing process:
```bash
lsof -ti :3000 | xargs kill
```

### "CHUMP_REPO not configured"

The agent can't locate the Chump checkout. Set `CHUMP_REPO`:
```bash
CHUMP_REPO="$(pwd)" chump --web
```

---

## Environment reference

| Variable             | Default          | Purpose                                              |
|----------------------|-----------------|------------------------------------------------------|
| `CHUMP_WEB_PORT`     | `3000`           | Port the web server binds to                         |
| `CHUMP_REPO`         | _(auto-detect)_  | Path to Chump repo used for gap dispatch             |
| `CHUMP_BIN`          | `chump`          | Path to chump binary used for dispatch calls         |
| `CHUMP_PWA_LOG`      | _(not set)_      | Path for per-request phase log (JSONL)               |
| `GH_TOKEN`           | _(keyring)_      | GitHub token for agent commits/PRs                   |

See [PWA_STARTUP.md](PWA_STARTUP.md) for the full startup validation reference.
See [docs/process/PWA_DEPLOYMENT.md](process/PWA_DEPLOYMENT.md) for binary
freshness and `CHUMP_BINARY_VERSION` deployment details.
