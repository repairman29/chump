---
doc_tag: canonical
owner_gap: PRODUCT-375
last_audited: 2026-11-27
---

# Web Cockpit (`/v2/`) User Guide

Chump includes a zero-build, local-first browser cockpit served directly by `chump --web`—giving you live visibility into your task queue, active file leases, provider cascade slots, and agent streams without installing Node.js or external dashboards.

---

## 1. Quick Start

```bash
# Launch the local web server (default bind: 127.0.0.1:3000; customize with --port)
chump --web --port 3847
```

Open **http://127.0.0.1:3847/v2/** in your browser for the Sovereign Operator Cockpit (or **http://127.0.0.1:3847/site/** for the interactive Config Doctor and Fleet Simulator).

To require bearer authentication on mutating and workspace routes, set `CHUMP_WEB_TOKEN` before launching `chump --web`.

---

## 2. Cockpit Views (`/v2/`)

| View | Underlying Endpoint | What It Shows |
|------|---------------------|---------------|
| **Overview & Fleet Health** | `GET /api/fleet/health`, `GET /api/stack-status` | Four-pillar health grades (`Credible`, `Effective`, `Resilient`, `Zero-Waste`), active worker count, 24h ship count, and GitHub rate-limit headroom |
| **Task Queue (Gaps)** | `GET /api/gap-queue` | Priority-sorted tasks (`P0` → `P3`), claimability status, owning session IDs, and one-click claim or dispatch actions |
| **Providers & Cascade** | `GET /api/cascade-status` | Live status across configured OAuth, cloud API, and local Ollama/vLLM slots, including circuit-breaker states and RPM/RPD counters |
| **Interactive Chat** | `POST /api/chat` (SSE) | Streaming chat with real-time tool-call cards and inline Allow/Deny approval prompts (`POST /api/approve`) |
| **Roadmap** | `GET /api/roadmap` | Milestone progress parsed live from `docs/ROADMAP.md` and enriched against `.chump/state.db` |

---

## 3. Dispatching & Tracking a Task

### From the Browser

1. Open the **Queue** view and click an unclaimed task row to inspect its acceptance criteria and effort size.
2. Click **Dispatch** (`POST /api/gap/work/:id`).
3. Watch live phase transitions (`preflight` → `claim` → `execute-gap` → `ship`) streamed from `GET /api/gap/:id/stream`.

### From `curl` or Scripts

```bash
# Trigger background execution for INFRA-042
curl -fsS -X POST http://127.0.0.1:3847/api/gap/work/INFRA-042

# Poll structured workflow progress
curl -fsS http://127.0.0.1:3847/api/gap/INFRA-042/status
```

| Phase | `progress_pct` | Meaning |
|-------|:--------------:|---------|
| `preflight` | `10` | Dependency, branch, and lease collision checks |
| `claim` | `20` | Isolated git worktree and `.chump-locks/` lease created |
| `execute-gap` | `40` | Agent editing code and running local tests |
| `ship` | `80` | Branch pushed and pull request opened via `chump ship` |
| `done` | `100` | Pull request verified and merged |

---

## 4. Health & Binary Freshness (`GET /api/health`)

```bash
curl -fsS http://127.0.0.1:3847/api/health
```

```json
{
  "status": "ok",
  "service": "chump-web",
  "binary_version": "1.0.0",
  "build_sha": "38a6c3d9f",
  "build_date": "2026-11-27",
  "binary_age_secs": 420,
  "version_match": true
}
```

When developing on a source checkout, `version_match: false` warns you if the running `chump` binary is older than recent edits to `src/` so you know when to rebuild and restart.

---

## 5. Environment Reference

| Variable | Default | Purpose |
|----------|---------|---------|
| `CHUMP_WEB_HOST` | `127.0.0.1` | Bind address (prefer `127.0.0.1`; set `CHUMP_WEB_TOKEN` if binding beyond loopback) |
| `CHUMP_WEB_PORT` | `3000` | HTTP port (`--port` CLI flag takes precedence) |
| `CHUMP_WEB_TOKEN` | _(unset)_ | Optional Bearer token required on mutating and private `/api/*` endpoints |
| `CHUMP_REPO` | Current git root | Target repository root for queue and lease operations |
| `CHUMP_PWA_LOG` | _(unset)_ | Optional file path for per-request JSONL phase logging |

---

## Related Guides

- [HTTP & SSE API](api/WEB_API_REFERENCE.md)
- [Daemon & Service Operations](operations/OPERATIONS.md)
- [User Guide](USER_GUIDE.md)
