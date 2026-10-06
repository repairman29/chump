# Wiring detectors — "built but never wired" (ZERO-WASTE-126, ZERO-WASTE-127)

> ZERO-WASTE-036 slices. `scripts/ops/wiring-detectors.py` implements the three **strong**
> detectors of the wiring sweep (D1/D2/D4: *intent without invocation*) and three **weak**
> detectors (D3/D5/D6) that state their own false-positive floor. A thing declares that it should
> run, and nothing makes it run. Static, deterministic, no network; findings are suspects with
> their evidence attached, not verdicts.

```bash
scripts/ops/wiring-detectors.py --summary                 # all three, JSONL on stdout
scripts/ops/wiring-detectors.py --detector D1 --out d1.jsonl
scripts/ops/wiring-detectors.py --detector D4 --ambient .chump-locks/ambient.jsonl
scripts/ops/wiring-detectors.py --detector D3,D5,D6 --summary   # weak ones, with their floors
```

Each finding is one JSON record:
`{"detector","name","severity","artifact","detail","evidence":{...},"rank"}`; weak ones add `"tier":"weak"` and `"fp_floor"`.

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
daemon, test, exercised input, loud runner, non-required tier, used handler, read field, busy kind).

## Weak detectors (ranked below the strong ones)

D3/D5/D6 are lower confidence. In the combined output every weak finding is ranked **below** every
D1/D2/D4 finding (`rank`), is `info` severity, and carries its **false-positive floor** in `fp_floor`;
`--summary` prints the floor next to each detector's count.

| Detector | Name | Flags | False-positive floor |
|---|---|---|---|
| **D3** | `role-without-caller` | A `pub` Rust type/fn whose doc comment declares a role ("used by", "wired into", "entry point", "dispatcher"...) but whose name appears nowhere else in the Rust sources | Import-edge resolution is partial (re-exports, macros, string/registry dispatch, cross-crate use), so "no caller found" is weak evidence |
| **D5** | `producer-field-without-consumer` | A field of a `Serialize` struct that is never read: no `.field` access and no quoted `"field"` key anywhere in the repo | The consumer may be external (dashboard, another service, a human reading the JSON) |
| **D6** | `low-adoption-telemetry` | A registered, stable event kind in `EVENT_REGISTRY.yaml` with `expected_min_per_day >= 1` that appears at most once in the ambient log sample | Silence may only mean the capability runs on a node whose log is not in the sample. Needs `--ambient`/`ambient.jsonl`; without one it is reported as *skipped*, never as "no findings" |

Weak real instances (at the time of writing):

- **D3** — `check_wallclock` in `src/budget_tracker.rs` is documented as "used by" something, but
  its name is mentioned nowhere else in the Rust sources.
- **D5** — `WorkEnvelope.delivery_seq` in `crates/chump-coord/src/assign.rs` is a `Serialize` field
  nothing in the repo reads.
- **D6** — `gap_supervisor_heartbeat` is registered as expected 1440 times a day and appears zero
  times in the local ambient sample.

## Triage — one decision per finding (ZERO-WASTE-128)

`scripts/ops/wiring-triage.py` turns each finding into **exactly one** of three decisions
(first match wins):

| Decision | When | Action |
|---|---|---|
| `ALLOWLIST-DORMANT` | An allowlist entry matches the artifact (and detector) | Nothing — deliberately dormant. Recorded **who** decided and **why**; later scans do not re-flag it |
| `ARCHIVE-DEAD` | Zero references outside the artifact itself **and** untouched for `--dead-days` (default 90) | Archive or delete it |
| `WIRE` | Everything else — alive (referenced or recently touched) but not connected, or age unknown (it never deletes on missing evidence) | Wire it |

```bash
scripts/ops/wiring-triage.py                              # run the detectors, triage, print actionable findings
scripts/ops/wiring-triage.py --findings d.jsonl --show-allowlisted
scripts/ops/wiring-triage.py allow --artifact scripts/coord/x.sh --detector D1 \
    --by <who> --reason "kept for the manual failover drill"
```

The reasoned allowlist is `docs/process/wiring-allowlist.jsonl`
(`{artifact, detector, decided_by, reason, decided_at}` per line). `--by` and `--reason` are
required, and a hand-edited entry missing either is **not honored** — an owner-less, reason-less
allowlist is just silent dormancy. The allowlist file itself does not count as a reference to the
artifact it names. Allowlisted findings are suppressed from the output (but counted in the summary
on stderr) so a re-scan stays quiet. `scripts/ci/test-wiring-triage.sh` covers all three outcomes.

## Filing — one gap with a receipt per finding (ZERO-WASTE-129)

`scripts/ops/wiring-file.py` is the last stage: `wiring-detectors.py | wiring-triage.py | wiring-file.py`.
It files one gap per **actionable** finding (`WIRE` / `ARCHIVE-DEAD`; allowlisted items are never filed)
through the standard universal filer, `chump gap file <finding.json>` (`src/gap_file.rs`) — the portable
path that uses the same `finding.json` schema as the holler convention and spools + retries when the
endpoint is down. `CHUMP_WIRING_FILER` / `--filer-cmd` routes to a different filer (e.g. a holler wrapper).

- **Receipt**: the gap body carries the detector, artifact, evidence JSON, triage decision, the
  false-positive floor for weak detectors, and how to re-run; acceptance criteria say either "fixed and
  no longer flagged" or "decision recorded with `wiring-triage.py allow --by --reason`".
- **Stable dedupe hash**: `wiring:<12 hex of sha256(detector|artifact|decision)>` — derived only from what
  identifies the standing condition, never from volatile evidence (counts, ages), and written into the
  title (`[wiring:...]`), the body and the finding's `dedupe_hash`.
- **Update, don't refile**: a ledger (`.chump-locks/wiring-filed.jsonl`) maps hash to gap. A re-detected
  condition bumps `last_seen` / `seen_count` and does not call the filer again. A filer failure records
  nothing, so the next cycle retries. `--max-new` (default 10) caps new gaps per run; `--dry-run` previews.

`scripts/ci/test-wiring-file.sh` asserts the same finding run twice yields one gap, not two.

## Limits

- Suspects, not verdicts: a script may be scheduled by something outside the repo (a hand-installed
  crontab). Each record's `evidence` says exactly what was and wasn't found.
- D2 only trusts invocation corpora (scripts, workflows, source). A flag passed through `"$@"` or a
  variable looks unexercised — hence the *none-of-the-inputs* rule and `low` severity.
- D4 recognises runners by `scripts/…` path; checklists that name `chump <subcommand>` are out of scope.
