# Chump P&E Suite — Installable Package Design

**Authored:** 2026-05-30  
**Gap:** [INFRA-2228](../gaps/INFRA-2228.yaml) — META-127 C5  
**Umbrella:** [META-127](../gaps/META-127.yaml) — AI Agent Suite for fleet P&E management  
**See also:** [CURATOR_SUITE_AUDIT_2026-05-29.md](CURATOR_SUITE_AUDIT_2026-05-29.md) (harvester's audit; gold-standard pattern, calibration loop gap, v1/v1.1 split), [MARKET_POSITIONING_2026-05-27.md](MARKET_POSITIONING_2026-05-27.md) (Marcus M-B canonical demo context), [PRODUCTIZATION_PLAN_2026-05-22.md](PRODUCTIZATION_PLAN_2026-05-22.md)  
**Status:** design doc — pending operator decision on pricing/distribution before implementation begins

---

## 1. Vision

One command. Any repo. An AI P&E team is running before the terminal prompt returns.

```
chump-pe-suite install <path/to/repo>
```

That command deposits 14 curator role documents into `.claude/agents/`, copies 7 canonical loop scripts into `.claude/scripts/coord/`, bootstraps an inbox directory, installs launchd daemons (or systemd on Linux), wires NATS subjects, and emits `kind=suite_installed` to the ambient stream. From that point forward, the repo has a standing P&E team: CI auditor, harvester, infra watcher, observability curator, decomposer, md-links guardian, handoff coordinator, external-collab tracker, orchestrator, target curator, context keeper, scout, and two new roles shipping with this suite.

The Marcus M-B canonical demo becomes: "here is your AI P&E team, watch them deliberate on a real question." Not a product demo of a single agent. A team demo — curators weighing in, filing gaps, reaching consensus, handing off — the same 5-minute consensus pattern that surfaced the META-125-is-a-port finding, productized and reproducible on any repo.

The 2-axis design (META-127 framing):
- **Axis 1** — Audit and standardize the existing 9 curators (done in C1/C2, shipped via PR #2776 INFRA-2214 template + PR #2757 INFRA-2209 consensus discipline).
- **Axis 2** — Package the resulting suite so the install command works on a cold repo.

---

## 2. v1 Scope (Chump-specific, ships first)

v1 is explicitly Chump-flavored. It does not attempt full generalization. That scope is deferred to v1.1 (Section 3).

**What ships in v1:**

- 14 role documents hardcoded to Chump paths:
  - 9 original curators (ci-audit, decompose, external-collab, handoff, harvester, infra-watcher, md-links, observability, target)
  - 3 new roles filing with META-127 C3: orchestrator, context-keeper, scout
  - 2 operator-approved adds from the C3 audit: fleet-brief, and one additional role TBD by operator before v1 ships
- 7 loop scripts (`scripts/coord/*-loop.sh`): ci-audit, decompose, external-collab, handoff, infra-watcher, md-links, observability — plus harvester and orchestrator loops when those land
- Inbox directory at `.chump/inbox/<role>/`
- Standardized role-doc template (INFRA-2214 schema: Lane scope, Inbox watcher, 5-step protocol, Discipline rules, Don't section, Cross-references, Self-audit checklist, Confidence calibration loop)
- Consensus discipline doctrine (`INFRA-2209`: every role has a `Confidence: N%` header on FEEDBACK; false-positives feed back into role calibration)
- `kind=suite_installed` ambient event with role-count + timestamp

**Hardcoded assumptions (v1 only):**
- NATS substrate reachable at `CHUMP_NATS_URL`
- Canonical state at `.chump/state.db`
- Ambient stream at `.chump-locks/ambient.jsonl`
- Role names prefixed `curator-opus-*` (matching Chump's naming scheme)
- Loop scripts assume `chump` CLI present on PATH

v1 target: any Chump operator (today: Jeff + any contributor who clones the repo) can install on a secondary checkout in under 5 minutes. The Marcus demo is the acceptance test.

---

## 3. v1.1 Scope (Repo-agnostic — deferred)

Harvester's audit (2026-05-29) named this the right split: ship Chump-specific v1 fast, then generalize when a second real customer (Marcus or beyond) needs it.

**Deferred to v1.1:**

- Per-repo state path configuration (override `.chump/state.db` location)
- Configurable ambient stream path (override `.chump-locks/ambient.jsonl`)
- Generic role name prefix (drop `curator-opus-*`, allow `<org>-<role>` naming)
- Non-NATS substrate fallback (file-based inbox when NATS unavailable)
- Role registry config file (YAML manifest listing which roles are active)
- Cross-repo install (target a repo that has no Chump substrate yet — requires bundling a substrate bootstrap step)

The v1 → v1.1 gate is: at least one external operator (Marcus or a pilot customer) has run a v1 install and given feedback. Generalize from real friction, not imagined requirements.

---

## 4. Substrate Dependencies (v1)

The following must be operational before `chump-pe-suite install` succeeds. The installer checks each and exits non-zero with a named error if any is missing.

| Dependency | Check | Why Required |
|---|---|---|
| NATS broker | `CHUMP_NATS_URL` resolvable | Loop scripts subscribe to `chump.curator.<role>.*` subjects for consensus + inbox delivery |
| `chump-coord` (NATS-KV) | `chump-coord --version` exits 0 | Atomic claim CAS + work-board + ambient event publish |
| `chump-disk-inventory-daemon` (INFRA-2193) | daemon process alive | Prevents disk-full silent stalls during curator runs |
| `chump preflight` (INFRA-1670) | `chump preflight --check-only` exits 0 | Loop scripts call preflight before any gap is filed to catch fmt/clippy drift |
| `bot-merge.sh` | `scripts/coord/bot-merge.sh --help` exits 0 | Curator-filed gaps ship through the standard auto-merge pipeline |
| `chump-fleet-bootstrap.sh` | `bash scripts/setup/chump-fleet-bootstrap.sh --check` exits 0 | Launchd plists + git hooks installed; without this, curator loops are dormant |

The installer does not install these dependencies — that is the operator's responsibility (or a future `chump-pe-suite bootstrap` subcommand, out of v1 scope). It validates and fails early with a clear message for each missing substrate.

---

## 5. Installer Flow

```
chump-pe-suite install <repo-path>
```

Step-by-step:

1. **Validate target** — confirm `<repo-path>` is a git repo root; confirm Chump substrate present (`.chump/state.db` exists). Exit non-zero with `ERROR: not a chump repo — run chump-fleet-bootstrap.sh first` if absent.

2. **Substrate check** — run each dependency check from Section 4. Collect failures, report all at once, exit non-zero if any fail.

3. **Create directories**
   ```
   mkdir -p <repo>/.claude/agents/
   mkdir -p <repo>/.claude/scripts/coord/
   mkdir -p <repo>/.chump/inbox/{ci-audit,decompose,external-collab,handoff,harvester,infra-watcher,md-links,observability,target,orchestrator,context-keeper,scout,fleet-brief}/
   ```

4. **Copy role documents** — copy all 14 `.claude/agents/*.md` files from the Chump source. Existing files prompt `[overwrite y/N]` unless `--force` is passed. Record which files were installed vs skipped.

5. **Copy loop scripts** — copy matching `scripts/coord/*-loop.sh` files. Same overwrite prompt.

6. **Install launchd daemons (macOS)** — for each role that has a loop script, generate a `com.chump.curator.<role>.plist` from a template and install to `~/Library/LaunchAgents/`. On Linux: write systemd unit files to `~/.config/systemd/user/`. Skip if `--no-daemons` flag set.

7. **Bootstrap inbox** — run `scripts/coord/chump-inbox.sh bootstrap` for each role to initialize inbox state in NATS KV. On NATS unavailable: write placeholder files and emit a warning.

8. **Emit install event**
   ```json
   {"ts":"<ISO8601>","kind":"suite_installed","role_count":14,"repo":"<repo-path>","version":"1.0.0"}
   ```
   Written to `<repo>/.chump-locks/ambient.jsonl`.

9. **Print summary** — list installed roles, skipped roles (overwrite declined), and any substrate warnings. Final line: `Chump P&E Suite v1.0 installed. Run 'chump-pe-suite status' to verify.`

Total wall-clock target: under 5 minutes on a warm machine with all dependencies met.

---

## 6. Operator Surface

```
chump-pe-suite status
```

Tabular output per active curator:

```
ROLE                  DAEMON     LAST-TICK         INBOX   RECENT-FEEDBACK
ci-audit              running    2026-05-30T14:22  0       INFRA-2231: 3 flake, 1 logic-bug
harvester             running    2026-05-30T14:20  2       META-128: port candidate from fleet-recorder
infra-watcher         running    2026-05-30T14:18  0       (none last 1h)
observability         stopped    —                 —       WARN: daemon not running
md-links              running    2026-05-30T13:55  0       DOC-053: 4 stale gap refs
...
```

Columns:
- **ROLE** — curator name
- **DAEMON** — running / stopped / disabled
- **LAST-TICK** — timestamp of most recent `kind=curator_heartbeat` event in ambient stream
- **INBOX** — count of unread messages in `.chump/inbox/<role>/`
- **RECENT-FEEDBACK** — latest FEEDBACK line from the last curator run (truncated to 80 chars)

Exits non-zero if any daemon shows `stopped` or if any role has no tick in the last 2 hours.

Additional subcommands (v1):
- `chump-pe-suite restart <role>` — restart a specific curator daemon
- `chump-pe-suite logs <role> [--lines N]` — tail the loop script log
- `chump-pe-suite uninstall` — remove daemons and role docs (with confirmation prompt)

---

## 7. Success Criteria

The suite ships when all of the following are true:

1. **5-minute install** — a fresh clone of the target repo + `chump-pe-suite install .` completes without errors in under 5 minutes on a machine that has all substrate dependencies met. Measured by the installer's own elapsed-time output.

2. **80% consensus rate** — over any rolling 5-day window, at least 80% of P&E decisions (gap prioritization, design direction, gap filing) surface through at least one curator FEEDBACK before the operator acts. Measured by: count of gaps filed with a `Curator-FEEDBACK:` trailer vs. total gaps filed.

3. **Under 5-minute decision-to-resolution** — from the moment a question is posted to the curator inbox to a consensus FEEDBACK response, elapsed wall-clock is under 5 minutes. Measured by the `kind=consensus_decision` event's `elapsed_ms` field (META-125 pipeline, when landed).

4. **Demo-able on Marcus repo** — the suite installs on a Marcus-provided repo (or the demo repo from ROADMAP_MARCUS.md M-B milestone) and at least 3 curators deliver substantive FEEDBACK within one session. Acceptance is operator judgment, not automated.

5. **Voice-lint clean** — `scripts/ci/test-voice-lint.sh docs/strategy/INSTALLABLE_SUITE_2026-05-30.md` exits 0.

---

## 8. Operator Pending Decisions

The following require operator input before v1 ships. None blocks writing this doc; all block cutting a v1 release.

**Pricing and licensing.** The suite is currently MIT-licensed as part of Chump. Three options:
- Keep MIT, build reputation, monetize consulting/hosting
- Dual-license: MIT for open-source repos, commercial for private repos (common OSS model)
- Source-available: BUSL or similar, converting to MIT after 4 years

The choice determines whether `chump-pe-suite install` can be run on a customer's proprietary codebase. Recommendation: decide before Marcus M-B demo so the pitch is clear.

**Telemetry.** The `kind=suite_installed` event + heartbeats are local-only by default. An opt-in telemetry path (phone-home on install, aggregate usage stats) would let the operator track adoption. Options:
- No telemetry (default, privacy-respecting, simpler)
- Opt-in on install (`chump-pe-suite install --telemetry`) with clear disclosure
- Opt-out (default on, with `--no-telemetry` escape hatch) — not recommended for open-source tooling

Recommendation: opt-in, collected at install time, stored in a simple webhook receiver.

**Distribution channel.** Three viable paths for v1:
- `cargo install chump-pe-suite` — cleanest for Rust shops, requires crates.io publish
- Homebrew formula (`brew install chump/tap/chump-pe-suite`) — best for macOS-first operators
- `curl | bash` installer script — widest reach, worst trust surface; avoid unless others aren't feasible

Recommendation: Homebrew for v1 (matches the Chump operator profile: macOS-first, comfortable with `brew`). Add `cargo install` as a parallel path when the crate boundary is stable.

---

## Related Docs

- [`AGENTS.md`](../../AGENTS.md) §On-demand docs — link from here once this doc ships
- [`CLAUDE.md`](../../CLAUDE.md) §On-demand docs — add entry after this merges
- [`docs/gaps/META-127.yaml`](../gaps/META-127.yaml) — umbrella gap; this doc closes C5
- [`docs/strategy/CURATOR_SUITE_AUDIT_2026-05-29.md`](CURATOR_SUITE_AUDIT_2026-05-29.md) — harvester's quality audit; gold-standard pattern + v1/v1.1 split rationale
- [`docs/strategy/MARKET_POSITIONING_2026-05-27.md`](MARKET_POSITIONING_2026-05-27.md) — strategic context; Opportunity 4 (SWE autonomy) + Marcus M-B arc
- [`docs/strategy/PRODUCTIZATION_PLAN_2026-05-22.md`](PRODUCTIZATION_PLAN_2026-05-22.md) — three-initiative sprint; quality firewall + forward coordination + consumer gate
- [`docs/process/CONSENSUS_DISCIPLINE.md`](../process/CONSENSUS_DISCIPLINE.md) — INFRA-2209; the doctrine every curator carries into consensus
