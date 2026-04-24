# Activation funnel

**Status:** shipped PRODUCT-015, 2026-04-24.
**Purpose:** the CPO-level gate that controls whether research-credibility
reviews (EXPERT_REVIEW_PANEL.md) are worth commissioning yet. If users are not
activating, research credibility is premature.

## The three events

Chump writes three event kinds into `.chump-locks/ambient.jsonl`. They share the
same shape as other ambient events (`ts`, `session`, `worktree`, `event`) with
`event=activation` and one of the three `kind` values:

| Kind                     | When it fires                                                               | Dedup marker                        |
|--------------------------|-----------------------------------------------------------------------------|-------------------------------------|
| `activation_install`     | First successful `chump init`                                               | `.chump/activation/installed_at`    |
| `activation_first_task`  | First task transitions to `done` via `task_db::task_complete`               | `.chump/activation/first_task_at`   |
| `activation_return_d2`   | Any non-`init` session start where install was > 24h ago                    | `.chump/activation/d2_return_at`    |

Each event fires **at most once per install**. The marker file is the dedup
check — its presence short-circuits the emitter. To re-run the funnel on a
machine, delete the `.chump/activation/` directory. A fresh clone never has it.

Event line format (minimal, anonymous):

```json
{"ts":"2026-04-24T22:15:03Z","session":"chump-wt-abc123","worktree":"activation-funnel","event":"activation","kind":"activation_install"}
```

No prompt text, no file paths, no user identity, no model name. Just a
timestamp, a session ID (worktree-scoped — never a user ID), and the kind.

## Reading the funnel

```bash
chump funnel
```

Prints the three-row table directly from `ambient.jsonl`, with `first_task` and
`return_d2` percentages computed against `install`:

```
Activation funnel  (.chump-locks/ambient.jsonl)
─────────────────────────────────────────────
install                         1  100.0%
first_task                      1  100.0%
return_d2                       0    0.0%
```

`chump funnel` is a pure reader — zero side effects, runs against whatever the
user has locally. No network call, no aggregator, no shared dashboard.

## Privacy posture

- **Local-only.** Events go to the same `ambient.jsonl` the coordination system
  already writes. No remote endpoint exists today (remote aggregator deferred).
- **Anonymous.** Only `session` (a worktree-scoped random ID) and `ts` land in
  the event; see `src/activation.rs::emit_event` for the exact payload.
- **Opt-out.** Set `CHUMP_ACTIVATION_DISABLED=1` in `.env` to silence all three
  emitters. `chump funnel` still runs (it just prints zeros).
- **Not shipped off-box.** Until a remote aggregator is designed and gated
  behind explicit opt-in, these events never leave the user's machine.

## The CPO gate

The activation threshold is the number below which research-credibility reviews
(docs/EXPERT_REVIEW_PANEL.md Tier 3) stay deferred. The threshold is a CPO
decision, not an engineering one, and is tracked alongside the current funnel
numbers in the next Red Letter synthesis. Until the threshold is set and met,
Tier 3 is on hold and PRODUCT-\* gaps take priority over RESEARCH-\*.

## Where the code lives

- `src/activation.rs` — the three emitters, the reader, the `print_funnel` CLI
  entry point.
- `src/chump_init.rs::run_init` — calls `emit_install` on first successful init.
- `src/task_db.rs::task_complete` — calls `emit_first_task_if_new` on the first
  task → `done` transition.
- `src/main.rs` — calls `emit_return_d2_if_due` on every non-`init` session
  start; registers the `chump funnel` subcommand.

## Clean-machine behavior

On a fresh clone with no `.chump/activation/` directory:

1. `chump init` → writes `.chump/activation/installed_at`, emits `activation_install`.
2. First `chump <task>` that completes → writes `first_task_at`, emits `activation_first_task`.
3. Next session > 24h later → writes `d2_return_at`, emits `activation_return_d2`.
4. `chump funnel` → prints `1 / 1 / 1` with `100.0% / 100.0%`.

The funnel is most meaningful aggregated across sessions and installs, which is
what a future opt-in remote aggregator would deliver. For now, the local
counters let the CPO sanity-check the gate on their own dogfood machine.
