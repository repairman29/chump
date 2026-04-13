# RFC: Remote runner (phase 1) — universal power **P2.6**

**Status:** Proposed  
**Owners:** Chump core + security review before any default-on MVP  
**Related:** [ROADMAP_UNIVERSAL_POWER.md](../ROADMAP_UNIVERSAL_POWER.md) **P2.6**, [TOOL_APPROVAL.md](../TOOL_APPROVAL.md), [OPERATIONS.md](../OPERATIONS.md) (`run_cli` / Cursor), [HIGH_ASSURANCE_AGENT_PHASES.md](../HIGH_ASSURANCE_AGENT_PHASES.md) (trust boundary)

---

## Problem

Today, durable work and **`run_cli`**-style execution assume the **operator machine** (often a Mac) is where the repo and agent run. Pilots who want **“Chump drives the repo that lives on another host”** must SSH manually or copy context—no first-class, **governed** remote execution profile inside Chump.

---

## Goals (phase 1)

1. **Optional** remote execution context: bind to **Tailscale IP** or **SSH** to a **declared** host, never arbitrary internet.
2. **Default-deny:** read-only or **dry-run** profile until an explicit env gate and allowlist pass review.
3. **Same governance story** as local: `CHUMP_TOOLS_ASK`, approvals, audit lines—no “remote = trusted.”
4. **Operator-visible:** every remote invocation logs **host profile id**, **cwd**, and **command class** (no secrets in logs).

## Non-goals (phase 1)

- Replacing full interactive SSH shells or arbitrary file sync.
- Multi-tenant SaaS execution.
- Bypassing `tool_approval_request` for “convenience.”

---

## Design sketch

### Configuration (illustrative names)

| Env / config | Purpose |
|--------------|---------|
| `CHUMP_REMOTE_RUNNER=0` | Master kill switch (default). |
| `CHUMP_REMOTE_PROFILES` | Declarative list: `name=ssh:user@100.x.y.z:path` or `name=tailscale:machine:path` — **exact grammar TBD** in implementation PR. |
| `CHUMP_REMOTE_ACTIVE_PROFILE` | Which named profile tools may use when enabled. |
| `CHUMP_REMOTE_ALLOWLIST_TOOLS` | Comma list of tool names permitted remotely (e.g. `read_file,list_dir` only in v0). |
| `CHUMP_REMOTE_READONLY=1` | If set, reject any tool whose contract implies write/exec outside an explicit second flag. |

### Transport

- **Preferred:** **Tailscale** mesh (already private L3); Chump process issues **SSH** over tailnet to `user@tag-or-ip` with **ForceCommand** / `authorized_keys` restrictions on the server side (out of repo, but documented in OPERATIONS).
- **Alternative:** long-lived **reverse SSH** or **agent forwarding** — discouraged for v0; document threat model if ever enabled.

### API / UX (optional)

- `GET /api/remote/context` — lists **configured** profile names and active profile (no secrets).
- PWA **Providers** or **Settings**: read-only line “Remote profile: `lab` (read-only)” when enabled.

### Implementation order

1. **RFC + OPERATIONS runbook** (this doc + server-side SSH hardening checklist).
2. **Rust:** profile parse + validation + **no tool wiring** (fail closed).
3. **Restrict `run_cli` / delegate** paths only behind allowlist + approval — single tool class first.
4. **Integration test:** mock transport or loopback SSH fixture in CI (Linux job) if feasible; else scripted manual runbook only.

---

## Security checklist (before “Accepted”)

- [ ] Threat model written: who can reach the tailnet, who can approve tools, blast radius of a stolen token.
- [ ] Server-side: dedicated Unix user, minimal `PATH`, no login shell, command logging.
- [ ] Client-side: no private keys in repo; use **SSH agent** or OS keychain; document rotation.
- [ ] Audit: `tool_approval_audit` / job rows include **`remote_profile`** field (schema migration TBD).

---

## Acceptance (phase 1 “done”)

- Documented **happy path** + **failure modes** in [OPERATIONS.md](../OPERATIONS.md).
- **`CHUMP_REMOTE_RUNNER=0`** remains default; turning on requires explicit env + allowlist.
- At least one **automated** test or **scripted** CI step proving misconfiguration fails closed (exact test left to implementation PR).

---

## Changelog

| Date | Note |
|------|------|
| 2026-04-09 | Initial RFC (design-only; no runtime shipped in this commit). |
