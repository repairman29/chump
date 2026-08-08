---
doc_tag: canonical
owner_gap: DOC-089
last_audited: 2026-08-08
---

# ChumpBench — the proving ground (DOC-072)

> **Status:** spec of record for how we *prove* ChumpOS is ready — repeatably, measurably.
> **Siblings:** [CHUMP_FRONT_DOOR.md](./CHUMP_FRONT_DOOR.md) (the car's controls) ·
> [COTG_READINESS_BACKLOG.md](./COTG_READINESS_BACKLOG.md) (the outcome).
> **Filed:** 2026-07-29. **Author:** Chump (opus-4.8), at Jeff's direction.

## 0. The idea

A car proves out on a **test track** before it touches a public road — and a real proving
ground has **many courses**: different terrains, different obstacles, run again and again with a
stopwatch. ChumpOS needs the same. **The repos are our tracks.** Not *target* repos (a real
dreamer's work — that comes later), but a curated suite of repos we own or build that put
ChumpOS through every kind of terrain, so we can answer *"can it run sustained, hands-off?"* with
a number instead of a hope.

This is the missing third piece:
- **[Front door](./CHUMP_FRONT_DOOR.md)** = the car's controls (how ChumpOS meets a repo/vision).
- **ChumpBench** = the proving ground (the tracks it runs).
- **The zero-touch provenance stamp** (CREDIBLE-172) = the stopwatch (counts every human touch).

## 1. What makes a track (a repo alone is just a parking lot)

Three things turn a repo into a scoreable **track**:

1. **A plain-language task** — the on-ramp input, exactly as a non-technical person would say it
   ("add a dark-mode toggle", "CI is red, fix it", "build me a tool that renames photos by date").
2. **A known-good acceptance check** — the objective finish line, so a lap is **pass/fail**, not
   vibes. *This is the part everyone skips, and it is the whole point.* Without it you have a
   drive, not a lap.
3. **Instrumentation** — the human-touch counter running the whole lap (the CREDIBLE-172 stamp:
   every commit the OS makes is marked; anything a human had to reach in and do is not).

### Track schema (`e2e/chumpbench/<track>.yaml`)
```yaml
id: rescue-beast-ci
mode: RESCUE            # CREATE | IMPROVE | RESCUE | FINISH | COMPREHEND
repo: repairman29/BEAST-MODE   # or "bootstrap" for CREATE tracks
stack: javascript
state: red-ci          # empty | green | red-ci | no-tests | half-built | legacy
difficulty: medium     # tiny | small | medium
task: "The CI check 'Vercel – beast-mode' is failing and blocks all merges. Make it green."
acceptance:            # how a lap is objectively graded PASS
  kind: ci-green       # ci-green | test-passes | url-live | assertion | comprehension-accuracy
  check: "gh pr checks <pr> --json bucket | all == pass"
budget:
  max_wall_clock_min: 30
  max_human_touches: 0   # the bar; a lap with >0 touches is a partial pass
```

## 2. The suite must span real variety (a flat oval proves nothing)

Every track is tagged on four axes; the suite is "balanced" when it covers the spread, not when
it has N tracks:

| Axis | Values | Why |
|---|---|---|
| **Mode** | CREATE · IMPROVE · RESCUE · FINISH · COMPREHEND | the front-door modes — each is a different lap |
| **Stack** | rust · js/ts · python · html/static · … | ChumpOS can't only work on its own Rust |
| **State** | empty · green · red-ci · no-tests · half-built · legacy | the terrain the engine starts on |
| **Difficulty** | tiny · small · medium | start on easy laps; scale up as touch-count drops |

## 3. The first heat — 5 tracks, one per mode (from the portfolio + BEAST)

Drawn from the 81-repo portfolio (`~/Projects/PROJECT_MATRIX.md`) for real diversity. Each
track's exact acceptance check is finalized with a [repo-dossier](../../opportunity-library/)
pass at build time; the tasks below are the proposed first heat.

| # | Mode | Track (repo) | Stack | State | Proposed task | Acceptance |
|---|---|---|---|---|---|---|
| 1 | **RESCUE** | `repairman29/BEAST-MODE` | JS | red-ci | "CI is red and blocks all merges — fix the root cause." | CI goes green (already the accidental first lap, 2026-07-29) |
| 2 | **IMPROVE** | `repairman29/beast-mode-website` | HTML/static | green | "Add a dark-mode toggle that remembers the choice." | Playwright: toggle flips theme + persists on reload |
| 3 | **FINISH** | `repairman29/chump-chassis` | Rust | half-built | "Complete the scaffolded service: wire the stubbed endpoint + its test." | `cargo test` green + the endpoint returns 200 |
| 4 | **COMPREHEND** | `repairman29/MythSeeker` | TS | legacy | "Explain what this repo does and produce an onboarding map." | comprehension-accuracy: the map matches a dossier ground-truth (no hallucinated modules) |
| 5 | **CREATE** | *bootstrap* (new repo) | Python | empty | "Build me a CLI that renames photos by the date they were taken." | the tool installs + renames a fixture folder correctly |

**Why these five:** they cross all five modes, four stacks (JS, static, Rust, TS, Python), and
five states (red-ci, green, half-built, legacy, empty). RESCUE on BEAST is already proven, so it
anchors the suite as the known-passing lap; the other four are the honest unknowns.

## 4. The scorecard *is* readiness

Running the suite produces one scorecard. Per track:

| field | meaning |
|---|---|
| `result` | PASS (acceptance met) / FAIL / PARTIAL (met, but with human touches) |
| `human_touches` | commits/actions in the lap not marked zero-touch (CREDIBLE-172) — **the number** |
| `wall_clock_min` | how long the lap took |
| `mode`, `stack`, `state` | so we see *where* it struggles (e.g., "fails all Python", "needs a human on every RESCUE") |

**The readiness number** = aggregate **human-touches-per-lap across a full suite run**, trended
over time. Driven toward zero, that *is* "can it run sustained, hands-off." Not CI-green. Not a
merged PR. A course completed with no one reaching in.

Run it as a **regression track** — nightly, same suite — and watch the trend. A new capability
that drops touches-per-lap is real progress; one that doesn't, isn't.

## 5. The runner (`chump bench`)

```
chump bench run [--track <id>] [--suite first-heat] [--json]
```
For each track: comprehend the starting state → contract the task → route to the mode engine
(the front-door spine) → grade against `acceptance` → tally human touches from the zero-touch
stamps in the lap's commits. Emits a `chumpbench_lap` event per track and a `chumpbench_scorecard`
rollup. Dry-run by default; `--apply` actually drives the engines.

This reuses everything: the mode engines (`bootstrap`/`improve`/`consult`/…), the outcome-verify
scorekeeper (COTG-3.1), and the human-touch metric (CREDIBLE-171, on the now-reliable CREDIBLE-172
stamp). ChumpBench is the harness that runs them all as one measurable lap.

## 6. Build sequence

1. **Land the stamp (CREDIBLE-172, shipped) + the metric (CREDIBLE-171)** — no scorecard without
   the stopwatch.
2. **Track schema + the runner skeleton** — start with **RESCUE on BEAST** (already a passing lap)
   as the first green track, so the harness is proven on a known-good case before we add unknowns.
3. **Add the other four tracks** one mode at a time; each new track is "done" when it runs
   end-to-end and its touch-count is recorded (even if the count is ugly — an honest ugly number
   is the point).
4. **Wire the nightly regression run** + the trend. That trend line is the readiness dashboard we
   never actually had.

## 7. What this changes

- Gives COTG a **measurable finish line** it lacked: readiness stops being an argument and becomes
  a scorecard.
- Turns the 81-repo portfolio from "shelfware" into **the proving ground** — real, owned, diverse
  tracks at zero acquisition cost.
- Makes every future capability testable: does it move touches-per-lap? If not, it didn't help.
