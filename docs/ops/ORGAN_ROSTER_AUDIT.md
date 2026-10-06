# Organ roster audit — bootstrap-manifest.yaml vs organ-manifest.txt

INFRA-7765 (slice A of the one-command-install BOM unification, INFRA-7756;
design: [ONE_COMMAND_INSTALL.md](../strategy/ONE_COMMAND_INSTALL.md) section 1).

Every id in `scripts/setup/bootstrap-manifest.yaml` (macOS/launchd installer
roster), classified against `scripts/ops/organ-manifest.txt` (Linux/systemd
roster). Verdicts:

- **excluded (prerequisite)** — installs a binary/hook, not a supervised
  organ. Stays out of organ-manifest.txt entirely (design doc section 1).
- **matched-organ** — an existing organ-manifest.txt line is confirmed to
  back the SAME capability; its `platforms=` is widened in place rather than
  adding a duplicate line.
- **renamed-organ (partial/unconfirmed)** — meaningful overlap found but not
  a clean 1:1 match; given its own `platforms=launchd` line rather than
  force-merged, flagged for a dedicated follow-up.
- **confirmed-absent** — traced by `ExecStart=`/script and found to back a
  DIFFERENT script than anything in organ-manifest.txt, or not traced to any
  Linux unit at all. Given one `platforms=launchd` line so the gap is visible
  in the single declared roster instead of silently missing. Linux port is
  real feature work, tracked as backlog by this line, not solved here.

| bootstrap-manifest.yaml id | verdict | organ-manifest.txt unit | trace |
|---|---|---|---|
| `chump-binary` | excluded (prerequisite) | — | installs the `chump` CLI itself; not a supervised organ. |
| `chump-plan-binary` | excluded (prerequisite) | — | installs the `chump-plan` binary; the organ is `chump-planner-launchd` below. |
| `git-hooks` | excluded (prerequisite) | — | per-worktree git hook install; not a supervised organ. |
| `ambient-hooks` | excluded (prerequisite) | — | writes Claude session-hook config (`~/.claude/settings.json`); not a systemd/launchd-supervised organ. |
| `almanac-ftue-hook` | excluded (prerequisite) | — | one-time `chump-ftue-hook.sh` run that writes the almanac MCP entry into `chump-mcp.json`; split out of `almanac-code-intel`'s install line after this audit's first pass (added to bootstrap-manifest.yaml concurrently during INFRA-7765). Same FTUE-hook capability, not a separate supervised organ. |
| `chump-planner-launchd` | confirmed-absent | `chump-planner.timer` (new) | hourly `gap-priority.json` writer (INFRA-1257). No Linux unit found by name or script match. |
| `curator-launchd` | confirmed-absent | `chump-opus-curator.timer` (new) | `opus-curator.sh`. ExecStart trace: `chump-rca-reflex.service` runs `recurring-gap-pattern-detector.sh` — a different script. Genuinely absent, not renamed. |
| `conductor-launchd` | confirmed-absent | `chump-conductor.timer` (new) | `install-conductor-launchd.sh`. Closest Linux organs (`chump-organ-success-verifier`/`chump-effect-verifier`) verify effects, they don't propose self-rescue consensus. Different capability. |
| `paramedic-launchd` | confirmed-absent | `chump-paramedic.timer` (new) | `install-paramedic.sh`. No PR-rescue timer in organ-manifest.txt (shepherd is an agent role, not a systemd unit). |
| `self-doctor-launchd` | confirmed-absent | `chump-self-doctor.timer` (new) | `install-self-doctor.sh`, runs `fleet doctor --heal` every 5min. `chump-process-organ-heal.service` heals organ PROCESSES, not gap-dispatch via fleet doctor — different capability. |
| `queue-health-monitor-launchd` | confirmed-absent | `chump-queue-health-monitor.timer` (new) | `queue-health-monitor.sh`, hourly `.chump/health.jsonl` writer. No Linux unit found. |
| `github-liaison-launchd` | confirmed-absent | `chump-github-liaison.timer` (new) | `install-github-liaison.sh`, refreshes `.chump/github_cache.db` every 60s. No Linux unit found. |
| `stale-branch-reaper-launchd` | confirmed-absent | `chump-stale-branch-reaper.timer` (new) | Daily remote-branch reaper. `chump-stale-worktree-reaper.timer` reaps WORKTREES, not branches — different target, no match. |
| `pr-watch-shepherd-launchd` | confirmed-absent | `chump-pr-watch-shepherd.timer` (new) | 10-min DIRTY-after-arm PR recovery sweep. No Linux unit found. |
| `distill-pr-skills-launchd` | confirmed-absent | `chump-distill-pr-skills.timer` (new) | Hourly shipped-PR-to-skill-target distiller. No Linux unit found. |
| `ci-health-gate-launchd` | confirmed-absent | `chump-ci-health-gate.timer` (new) | `ci-health-gate.sh`, 5-min fleet auto-pause on CI jam. No Linux unit found. |
| `fleet-recorder-launchd` | confirmed-absent | `chump-fleet-recorder.service` (new) | Captures NATS+ambient events to `.chump/fleet_events.db`. `chump-fleet-server.service` SERVES that db's query API but does not itself CAPTURE the events — sibling, not the same organ. |
| `fleet-server-launchd` | **matched-organ** | `chump-fleet-server.service` (existing, `platforms=` widened to `systemd,launchd`) | Exact match confirmed by design doc: same HTTP+WS query server on 127.0.0.1:7070, same capability, was just declared in two unlinked files. |
| `daemon-activator-launchd` | confirmed-absent | `chump-daemon-activator.timer` (new) | 5-min auto-loader for new `install-*.sh`/`*.plist` since last checkpoint. No Linux unit found. |
| `ghost-pr-closer-launchd` | confirmed-absent | `chump-ghost-pr-closer.timer` (new) | Closes DIRTY/CONFLICTING PRs whose gap is already `done`. `chump-gap-closure-reconcile.timer` closes GAPS from GitHub truth (inverse direction) — different capability. |
| `main-worktree-drift-detector-launchd` | confirmed-absent | `chump-main-worktree-drift-detector.timer` (new) | 30-min untracked-yaml/behind-origin drift alarm. No Linux unit found. |
| `trunk-sentinel-launchd` | confirmed-absent | `chump-trunk-sentinel.timer` (new) | 60s trunk-red watcher, escalates fix-class actions DURING a red window. `chump-trunk-recovery-reviver.timer` reopens rot-reaped PRs AFTER a red→green recovery — the reverse-direction sibling, not a match. |
| `pr-shepherd-daemon-launchd` | confirmed-absent | `chump-pr-shepherd.timer` (new) | 60s PR classifier/auto-rebaser/auto-armer across 8 states. `chump-pr-lander.timer` only arms already-green PRs (RESILIENT-288) — a narrower capability, not a match. |
| `quartermaster-audit-launchd` | confirmed-absent | `chump-quartermaster-audit.timer` (new) | 5-min shelfware-audit (merged artifact vs curator-doc coverage). No Linux unit found. |
| `auto-deploy-launchd` | confirmed-absent | `chump-auto-deploy.timer` (new) | 20-min binary-tracks-main redeploy via `refresh-runner-binary.sh`. Design doc explicitly rules out `chump-organ-deploy.timer` as a match — that one places unit files as root; this one rebuilds/redeploys the `chump` binary. Different capability. |
| `almanac-code-intel` | **renamed-organ (partial/unconfirmed)** | `chump-almanac-code-intel.timer` (new, `platforms=launchd`) | `install-almanac-organ.sh` already self-installs as `systemd --user` on Linux TODAY (grouped with `install-oauth-refresh-systemd.sh`/`install-fleet-health-sentinel.sh` in the design doc as already-rootless installers) — but that unit is not organ-manifest.txt-tracked, and is a DIFFERENT capability from `chump-almanac-liveness.timer` (which is the systemd complement to a THIRD, not-in-bootstrap-manifest launchd organ, `almanac-summarize-watchdog`/RESILIENT-354 — freshness-checking, not indexing/MCP-wiring). Left unmerged pending a dedicated follow-up rather than guessing a 1:1 match. |
| `chump-coord-assign-launchd` | confirmed-absent | `chump-coord-assign.service` (new) | FLEET-034 push-routing daemon (RESILIENT-271). Installer shipped and mapped in `optional-installers-allowlist.txt` (audit-only) but never registered in bootstrap-manifest.yaml OR organ-manifest.txt until now. No Linux unit found. |
| `a2a-dead-letter-reaper-launchd` | confirmed-absent | `chump-a2a-dead-letter-reaper.timer` (new) | 30-min dead-letter reaper for unread dormant-inbox A2A messages (INFRA-1946). No Linux unit found. |
| `decomposition-hint-tracker-launchd` | confirmed-absent | `chump-decomposition-hint-tracker.timer` (new) | Daily PR-decomposition-hint analytics (FLEET-026/INFRA-1564). No Linux unit found. |
| `refresh-model-prices-launchd` | confirmed-absent | `chump-refresh-model-prices.timer` (new) | Weekly pricing-doc diff against LiteLLM upstream (INFRA-731/739). No Linux unit found. |
| `fleet-version-skew-detect-launchd` | confirmed-absent | `chump-fleet-version-skew-detect.timer` (new) | 6h working-tree-drift ALERT (INFRA-609/RESILIENT-155). No Linux unit found. |
| `mission-grade-cron` | confirmed-absent (mechanism exists, unmanaged) | `chump-mission-grade.timer` (new, `platforms=launchd` only) | Genuinely cross-platform BY DESIGN — delegates to `chump cron install`, which already renders a systemd **--user** timer of this exact name on Linux (INFRA-2057). Not a missing capability; a SCOPE mismatch: this system-scope organ-reconcile can't manage a `--user` unit until slice B's rootless rendering lands, so it stays `platforms=launchd`-only here rather than widened to `systemd` (which would make this reconcile wrongly attempt a system-scope `enable` against a unit that only ever exists at `--user` scope). |

## Totals

- 32 ids in bootstrap-manifest.yaml (31 at audit start + `almanac-ftue-hook`, added concurrently by another fleet PR during this slice — folded into this audit rather than re-run from scratch).
- 5 excluded as prerequisites (not supervised organs).
- 1 matched-organ (`fleet-server-launchd` → widened existing line).
- 1 renamed-organ, partial/unconfirmed (`almanac-code-intel` — follow-up filed).
- 25 confirmed-absent (one new `platforms=launchd` line each, backlog visible
  in-repo instead of silently missing).

## Non-goals

This audit does not implement any Linux port for the confirmed-absent
capabilities above — that is real feature work (per
[ONE_COMMAND_INSTALL.md](../strategy/ONE_COMMAND_INSTALL.md)'s own
non-goals section), tracked as visible backlog by each new
`organ-manifest.txt` line's `# ... Linux port: TODO` comment. It also does
not resolve the `almanac-code-intel` reconciliation ambiguity noted above —
filed as a separate follow-up rather than guessed here.

## RESILIENT-1534 — the 14 "dark" enabled organs: root cause per organ

After re-arming the hub guardians, 14 manifest-`enabled` organs would not
`systemctl start`. Diagnosis (static, from the manifest and the unit tree): none
of them is a broken systemd unit — **all 14 are `platforms=launchd` rows (Mac
organs folded in by INFRA-7765) that have no Linux/systemd unit**, so they can
never be active on a systemd hub. Two defects made them look like faults:

1. **`organ-deploy`'s post-deploy audit counted every `enabled` row**, ignoring
   `platforms=` and `requires=`, so a correctly-scoped-off Mac organ was logged
   "STILL DARK" forever. The audit now classifies each organ with
   `organ_dark_cause` (`scripts/ops/lib/organ-manifest-lib.sh`): `active`,
   `scoped-off:platforms=…`, or UNEXPECTED-DARK with a named cause
   (`unmet-requires:…`, `unit-missing`, `unit-not-installed`, `exec-missing:…`,
   `inactive`). Nothing is skipped silently; `organ-deploy.sh --audit-only` runs
   just the audit and exits 1 while any UNEXPECTED-DARK organ remains.
2. **The manifest parser read `# comment` text as fields.** Rows that quote field
   names in their comment overwrote the real value —
   `chump-mission-grade.timer`'s `platforms=launchd` was clobbered by the comment's
   `platforms= stays launchd-only` (empty, so default `systemd`), making the reconcile
   try to enable a unit that only exists at `--user` scope. `organ_manifest_parse`
   (and the fleet-doctor roll-call reader) now stop at the first `#` token.

| Organ (`chump-<name>.timer`) | Root cause | Disposition |
|---|---|---|
| github-liaison | launchd-only; no Linux unit (port TODO) | scoped off the hub (`platforms=launchd`) |
| quartermaster-audit | launchd-only; no Linux unit (port TODO) | scoped off |
| ghost-pr-closer | launchd-only; no Linux unit (port TODO) | scoped off |
| daemon-activator | launchd-only; no Linux unit (port TODO) | scoped off |
| main-worktree-drift-detector | launchd-only; no Linux unit (port TODO) | scoped off |
| planner | launchd-only; no Linux unit; also `requires=bin:chump-plan` | scoped off |
| stale-branch-reaper | launchd-only; no Linux unit (port TODO) | scoped off |
| distill-pr-skills | launchd-only; no Linux unit (port TODO) | scoped off |
| almanac-code-intel | launchd-only in the manifest; Linux self-installs as `systemd --user` via `install-almanac-organ.sh`, untracked | scoped off (reconciliation follow-up noted in the row) |
| a2a-dead-letter-reaper | launchd-only; no Linux unit (port TODO) | scoped off |
| decomposition-hint-tracker | launchd-only; no Linux unit (port TODO) | scoped off |
| refresh-model-prices | launchd-only; no Linux unit (port TODO) | scoped off |
| fleet-version-skew-detect | launchd-only; no Linux unit (port TODO) | scoped off |
| mission-grade | cross-platform by design (`chump cron install` renders a `--user` timer on Linux), but the comment mis-parse made the row look `systemd` | scoped off at system scope; parser fixed |

Any organ whose Linux port later ships flips to `platforms=systemd,launchd`
(or drops the field) in the same PR as its unit, and the audit then holds it to
"active" like every other organ. `scripts/ci/test-resilient-1534-organ-dark-audit.sh`
asserts all 14 classify as `scoped-off:platforms=launchd` on a systemd host.
