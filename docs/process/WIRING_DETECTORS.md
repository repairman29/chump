# Wiring detectors — "built but never wired" (ZERO-WASTE-126)

> ZERO-WASTE-036 slice. `scripts/ops/wiring-detectors.py` implements the three **strong**
> detectors of the wiring sweep: *intent without invocation*. A thing declares that it should
> run, and nothing makes it run. Static, deterministic, no network; findings are suspects with
> their evidence attached, not verdicts.

```bash
scripts/ops/wiring-detectors.py --summary                 # all three, JSONL on stdout
scripts/ops/wiring-detectors.py --detector D1 --out d1.jsonl
scripts/ops/wiring-detectors.py --detector D4 --ambient .chump-locks/ambient.jsonl
```

Each finding is one JSON record:
`{"detector","name","severity","artifact","detail","evidence":{...}}`.

| Detector | Name | Flags | Not flagged |
|---|---|---|---|
| **D1** | `no-scheduler` | A script whose header declares periodic intent (`every 10 min`, `hourly`, `nightly`, "runs from a timer/cron/launchd") that **no** launchd `.plist`, systemd `.timer`/`.service`, crontab/organ-manifest entry or scheduled workflow references — directly or via a scheduled script that calls it | `while true` daemons (launched, not scheduled); `test-*` and `archived/` scripts |
| **D2** | `never-invoked-on-documented-input` | A script whose usage text documents value-taking inputs (`--base <branch>`, `--out FILE`) of which **none** is ever passed by any invocation in scripts, CI or source | Scripts never invoked at all (that is the dormant-script detector's job); prose docs don't count as invocations; a script with at least one exercised input |
| **D4** | `no-execution-telemetry` | A required checklist (task list or table under a heading saying *must pass* / *mandatory* / *(required)*, or an item marked REQUIRED) whose runner script (named in the item, or in the doc's "Run with:" preamble) emits no ambient telemetry and never appears in the ambient log | Runners that emit ambient events or appear in the log |

## Real instances (at the time of writing)

Run against this repo, each detector produces a real finding:

- **D1** — `scripts/ci/check-heartbeat-health.sh` declares "every 20m", but the only scheduler
  mention is a documentation sentence pointing at an `.example` plist the repo never installs.
- **D2** — `scripts/ci/check-mass-deletion.sh` documents `--base <branch>`; CI and the one
  sibling script invoke it without ever passing `--base` (it silently relies on its default).
- **D4** — `docs/process/CAPABILITY_CHECKLIST.md`, "Tier 1 — Core (must pass)", is run with
  `scripts/ci/battle-qa.sh`, which emits no ambient events, so nothing can show a Tier 1 run happened.

These will disappear as they are fixed; `scripts/ci/test-wiring-detectors.sh` keeps the detectors
honest with fixtures shaped like these instances plus negative controls (wired, transitively wired,
daemon, test, exercised input, loud runner, non-required tier).

## Limits

- Suspects, not verdicts: a script may be scheduled by something outside the repo (a hand-installed
  crontab). Each record's `evidence` says exactly what was and wasn't found.
- D2 only trusts invocation corpora (scripts, workflows, source). A flag passed through `"$@"` or a
  variable looks unexercised — hence the *none-of-the-inputs* rule and `low` severity.
- D4 recognises runners by `scripts/…` path; checklists that name `chump <subcommand>` are out of scope.
