# 2026-05-23 — Curator-Opus Auto-Pilot Overnight Run

> Session retrospective for `curator-opus-ci-audit-2026-05-23`. Captures
> what shipped, what was learned, what's queued, and how the next curator
> picks up. Read this before resuming work tomorrow.
>
> Operator-shareable: this is the canonical artifact for reviewers
> (Marcus design, Gemini external, grant readers) to see what one
> overnight autopilot run produced.

## Session window + headline numbers

- **Start:** ~18:00 UTC (post-compaction resume from 2m cron loop)
- **End:** ongoing at time of writing (~23:10 UTC, expected to continue overnight)
- **Author lane:** RESILIENT + META-070 firewall + META-067 Track 3 demo polish
- **PRs opened by curator-opus-ci-audit:** 20+ (PR #2418 → #2461)
- **PRs merged by curator-opus-ci-audit:** measured live via `bash scripts/dev/lightning-demo-timeline.sh`
- **Median ship time (last 10):** ~10 minutes claim → merged
- **Fastest:** 2.2 min (doc-only, e.g. META-074 strategy)
- **Slowest:** 24.5 min (INFRA-1866 — Rust path triggered full cargo workflow)

## Named milestones

### 1. The 3-tier auto-fix stack landed in main
Discipline-by-automation, not discipline-by-friction:
- **INFRA-1831 #2420** — gaps-integrity preflight (catches malformed yaml at commit)
- **INFRA-1833 #2423** — auto-fmt-on-commit (chump-commit.sh runs cargo fmt before commit)
- **INFRA-1853 #2426** — auto-envvar append (new CHUMP_* refs auto-added to env-vars-internal.txt)

These three together would have prevented the entire cargo-fmt 11-PR fiasco
earlier in the day. The pattern: instead of failing CI on drift, the
commit-time wrapper fixes the drift and re-stages.

### 2. The 8-PR mandate-vs-suggest stack
Layered discipline architecture filed as INFRA-1833..1837 + telemetry:
- **INFRA-1834 #2434** — `--no-verify` push emits `kind=audit_no_verify`
- **INFRA-1835 #2432** — preflight tree-sha cache (makes the right path free)
- **INFRA-1836 #2439** — `CHUMP_NO_BYPASS=1` strict-mode helper library
- **INFRA-1837 #2438** — bypass-frequency auditor (daily shame loop)
- **INFRA-1872 #2436** — `ci_qa_score` daily telemetry (aggregate metric)
- **INFRA-1866 #2440** — flake-catalog tracking_gap audit (META-074 slice a)
- **INFRA-1869 #2453** — CI gate promotion log + no-regression guard (META-074 slice d)
- **INFRA-1809 #2447** — chump CLI startup hang firewall

Together: pretend-discipline is impossible; the right path is the easy path; every bypass is audited.

### 3. A2A foundation expanded
- **INFRA-1825 #2428** — CapabilityManifest publish loop (file-backed v0)
- **INFRA-1828 #2442** — 5 A2A RPC bash wrappers over INFRA-1115 transport (ask-eta / ask-overlap / ask-handoff / ask-progress / ask-capability)
- Pairs with previously-merged INFRA-1758/1759/1760/1761/1802/1803 (events / RPC / capability / scratchpad / mesh / consensus)

### 4. META-067 Track 3 demo polish quartet
Four PRs that wrap today's substrate into pitchable surfaces:
- **DOC-053 #2454** — `docs/DEMO_5MIN.md` (5-minute pitch narrative)
- **INFRA-1887 #2450** — `scripts/dev/lightning-demo-timeline.sh` (last-10 PR retrospective table)
- **INFRA-1894 #2458** — `scripts/dev/chump-dashboard-tui.sh` (one-shot live fleet dashboard)
- **INFRA-1895 #2461** — `scripts/dev/chump-pitch.sh` (one-command wrapper that runs all three)

Net result: `bash scripts/dev/chump-pitch.sh` is now the operator's
demo-in-a-command. No slide deck required.

### 5. META-073 schema trio (forward-looking coordination)
Three doc-only schema specs for the next sophistication layer:
- **META-075 #2451** — collision prediction event schema v1 (Track 1)
- **META-077 #2456** — skill-aware routing event schema v1 (Track 2)
- **META-079 #2457** — cross-agent lesson propagation format v1 (Track 3)
- Plus **META-083 #2443** — coordination failure-class taxonomy (reactive companion)

Schemas defined; implementations (META-076/078/080) are next.

### 6. Closed-trio preflight gates
Operator's lane assignment: pick from INFRA-1790/1792/1793 for fresh implementation.
- **INFRA-1792 #2416** — PR-scope preflight gate
- **INFRA-1790 #2449** — markdown intra-doc-links preflight gate
- **INFRA-1793 #2399** — no-claude-leak preflight gate (handoff lane)

## Lessons accumulated

Cross-pollinated from `docs/process/CURATOR_OPUS_LESSONS_2026-05-23.md`
(7 lessons from the overnight session). Highlights that bit me today:

- **Verify-at-source before citing** — saved by re-reading gap AC instead of trusting cached spec
- **`--acceptance-criteria` pipes are a footgun** — pipe is delimiter; nested `|` in enum values breaks parsing. Always rewrite as "X and Y" / "X or Y"
- **Python heredoc try/except discipline** — three times today, a `try:` without matching `except:` produced silent SyntaxError → script returned the wrong rc. Lesson: every `try:` in a heredoc needs a closing `except: pass`
- **JSON compact emit** — `json.dumps(..., separators=(',', ':'))` is mandatory for grep-matchable ambient events; the default `: ` spacing breaks `'"kind":"X"'` grep patterns
- **Bash `env=value cmd=$(...)` is a trap** — assignment binds to `cmd`, not the inner subshell. Always use `out=$(env=value cmd)`

## Gap registry deltas

- **Filed:** 10 META-073 sub-gaps (META-075..084 via `chump gap decompose META-073 --apply`)
- **Filed:** 3 product gaps (INFRA-1881 bootstrap, INFRA-1882 scan, INFRA-1883 PWA dashboard)
- **Filed:** 5 META-074 sub-gaps (INFRA-1866..1870 child-A slices) earlier in session
- **Filed:** DOC-053 (DEMO_5MIN), DOC-054 (this file), INFRA-1887/1894/1895 (demo trio)
- **Decomposed:** META-073 (P2/m parent → 10 P1 slices)

## Hand-off notes for tomorrow

If you (next curator session) pick up where I left off:

1. **#2418 INFRA-1800** is my oldest open PR. It went DIRTY multiple times; if still open, just rebase + push.
2. **META-073 Track-1/2/3 implementations** (META-076/078/080) are the next high-leverage Rust work. Each touches `crates/chump-coord/src/`. Today multiple siblings claimed `src` broadly — coordinate via `chump --leases` first.
3. **Product gaps INFRA-1881/1882/1883** (bootstrap / scan / PWA dashboard) are filed with crisp AC but unclaimed. They're the 2026 outcomes #1/#2/#3 demos. Operator deprioritized them in favor of META-070 firewall; check inbox for current direction.
4. **Watchdog `daemon_silent` / `reaper_silent` ALERTs** kept firing for daemons that were never installed (threshold = 0h). Suppress those at install time, not in-tree.
5. **DEMO_5MIN.md exists** — point Marcus/Gemini at `bash scripts/dev/chump-pitch.sh` instead of writing a fresh deck.

## Cross-references

- Parent epic: [META-067 — 2026 outcomes framework](../gaps/META-067.yaml)
- Sibling synthesis: [`2026-05-23-autonomy-cascade.md`](./2026-05-23-autonomy-cascade.md) — covers the early-day cargo-fmt cascade rescue
- Demo entry point: `bash scripts/dev/chump-pitch.sh`
- Lessons doc: [`../process/CURATOR_OPUS_LESSONS_2026-05-23.md`](../process/CURATOR_OPUS_LESSONS_2026-05-23.md)
- Mission framework: [`AGENTS.md`](../../AGENTS.md) + [`CLAUDE.md`](../../CLAUDE.md)
