# Reaper Audit — 2026-05-30

**Trigger:** INCIDENT 2026-05-30T15:46Z — `stale-pr-reaper.sh` (INFRA-1410 SLO) destroyed 28
in-flight PRs in 60 seconds while trunk was RED. Root cause: no trunk-RED awareness before
bouncing. RESILIENT-050 fixes the primary reaper.

**Scope:** 5 other reapers loaded via launchctl as of 2026-05-30:

| launchctl label | Script | Interval |
|---|---|---|
| `dev.chump.stale-gap-lock-reaper` | `scripts/ops/stale-gap-lock-reaper.sh` | 5 min |
| `dev.chump.cargo-target-reaper` | `scripts/ops/cargo-target-reaper.sh` | on-demand / launchd |
| `com.chump.claude-reaper` | `scripts/ops/reap-orphan-claude-procs.sh` | 5 min |
| `dev.chump.target-reaper` | `scripts/coord/target-dir-reaper.sh` | 30 min |
| `dev.chump.stale-branch-reaper` | `scripts/ops/stale-branch-reaper.sh` | daily / launchd |

**Classification:**

- **safe**: trunk-RED storm cannot cause this reaper to destroy legitimate in-flight work.
- **risky**: trunk-RED could indirectly trigger destruction but the blast radius is bounded/reversible.
- **vulnerable**: same bug class as RESILIENT-050 — trunk-RED causes destructions that would not happen if trunk were green.

---

## 1. stale-gap-lock-reaper — safe

**Script:** `scripts/ops/stale-gap-lock-reaper.sh`
**What it destroys:** `.chump-locks/.gap-*.lock` files and `state.db` lease rows for sessions
whose PID is dead or whose claim JSON has expired.

**Trunk-RED sensitivity:** None. This reaper operates entirely on local process state (PID
liveness via `ps -p`) and lease file TTLs. It has no knowledge of PR state or CI results. When
trunk is RED, the relevant agents are BLOCKED (PRs stuck in CI), not dead — their PIDs are live,
heartbeats are fresh, and leases are within TTL. The INFRA-1236 heartbeat-protection guard
specifically prevents reaping sessions whose heartbeat is fresher than `CHUMP_LEASE_HEARTBEAT_TTL_S`
(600s default), even if the originating PID has exited. The INFRA-1221 open-PR guard also blocks
reaping any claim where the gap has an open PR.

**Verdict: safe** — the two independent guards (heartbeat + open-PR) prevent trunk-RED-driven
false reaping.

---

## 2. cargo-target-reaper — safe

**Script:** `scripts/ops/cargo-target-reaper.sh`
**What it destroys:** Stale cargo build artifacts: `target/debug/.fingerprint/*`,
`target/debug/deps/lib*.rlib` (age-gated), `~/.cache/chump-fleet-target/` dirs, `/tmp/chump-*/target/`
for worktrees whose git parent no longer exists.

**Trunk-RED sensitivity:** None. This reaper has two hard safety guards applied before any
deletion: (1) aborts if any `cargo` or `rustc` process is detected active; (2) aborts if free
disk < 1GB. It operates on build artifact mtime, not PR or CI state. Trunk being RED means PRs
are blocked in CI queues — it has no effect on local build artifact age. No PR state is
consulted; nothing it deletes is PR-specific. Rebuilding from scratch is the recovery path and
takes 1-5 minutes.

**Verdict: safe** — build artifacts are reproducible; trunk-RED is orthogonal to artifact age.

---

## 3. claude-reaper (reap-orphan-claude-procs) — safe

**Script:** `scripts/ops/reap-orphan-claude-procs.sh`
**What it destroys:** Orphaned `claude` binary subprocesses (leaked by `/loop` and cron agents)
identified by ppid-chain analysis. Kills via SIGKILL after `REAP_AGE` seconds (default 3600s).

**Trunk-RED sensitivity:** None. The reaper identifies targets by walking the process tree from
the foreground Claude.app PID. Processes reachable from the foreground PID are live sessions and
are skipped; orphans (ppid chain does not reach fg_pid) older than `REAP_AGE` are killed. Trunk
being RED means CI is failing — but agents blocked on CI are live sessions reachable from the
fg_pid. An agent sitting idle while its PR is BLOCKED is not an orphan by this definition, so it
is protected.

The INFRA-1786 safety gate further requires `fg_pid` to be determinable before any kill is
attempted; if detection fails and `CHUMP_REAPER_HEADLESS` is unset, the script exits 3 (refuses
to act) rather than mass-reaping everything.

**Verdict: safe** — ppid-chain logic protects any session with a live fg_pid parent; trunk-RED
does not affect ppid ancestry.

---

## 4. target-dir-reaper — safe

**Script:** `scripts/coord/target-dir-reaper.sh`
**What it destroys:** `target/` directories inside idle worktrees when disk free < 50GB
(configurable). In critical mode (disk < 10GB), skips the idle-mtime check.

**Trunk-RED sensitivity:** Low. The reaper has a hard dependency guard: it only reaps a
worktree's `target/` if that worktree has **no active lease** in `.chump-locks/*.json`. An agent
with a BLOCKED PR holds a lease for the duration of its session. As long as the lease is alive,
the target/ dir is safe. The edge case: if an agent exits (session ends) while its PR is still
BLOCKED, the lease expires and the target/ becomes eligible for reaping. This is recoverable —
`cargo build` reconstructs the artifacts. The gap's PR and branch are unaffected; the agent can
restart and `git fetch` the existing branch.

**Verdict: safe** — lease guard prevents reaping active-session worktrees; artifacts are
reconstructible in < 5 minutes.

---

## 5. stale-branch-reaper — safe

**Script:** `scripts/ops/stale-branch-reaper.sh`
**What it destroys:** Remote git branches whose PR is MERGED or CLOSED (not just BLOCKED) and
whose PR was closed/merged > `CHUMP_BRANCH_REAPER_AGE_DAYS` ago (default 7 days).

**Trunk-RED sensitivity:** None. The critical safety invariant here is the PR state check: the
reaper explicitly fetches all **open** PRs first (`gh pr list --state open`) and skips any branch
that has an open PR. BLOCKED PRs are open PRs. A branch whose PR is BLOCKED is therefore
completely exempt from this reaper. Only branches with MERGED or CLOSED PRs (and a 7-day age
buffer) are deleted.

The trunk-RED storm scenario requires PRs to be BLOCKED (open, failing CI). The branch-reaper
does not touch branches with open PRs by construction.

**Verdict: safe** — open-PR guard is the primary shield; BLOCKED is a subset of open.

---

## Summary

| Reaper | Verdict | PR-state-aware | Lease-aware | Trunk-RED immune |
|---|---|---|---|---|
| stale-gap-lock-reaper | safe | yes (open-PR guard) | yes (heartbeat + PID) | yes |
| cargo-target-reaper | safe | no (artifacts only) | no (process check instead) | yes |
| claude-reaper | safe | no (PID tree only) | no (ppid chain instead) | yes |
| target-dir-reaper | safe | no | yes (lease file) | yes |
| stale-branch-reaper | safe | yes (open-PR skip) | no | yes |

**No follow-up gaps required** from this audit. All 5 secondary reapers are safe under the
trunk-RED storm pattern because their destruction criteria either require an open PR to be absent
(stale-gap-lock, stale-branch), operate purely on local process state (claude-reaper), or
require the worktree to have no active lease (target-dir).

The primary reaper (`stale-pr-reaper.sh`) was the only one with the vulnerability, now fixed by
RESILIENT-050.

---

*Audited by:* agent session `claim-resilient-050-48918-1780156581`
*Audit date:* 2026-05-30
*Related gap:* RESILIENT-050
