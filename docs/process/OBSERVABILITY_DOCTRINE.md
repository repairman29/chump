# Observability Doctrine

> **One-line rule:** before scaling any new component, ship its observability.

## Why this is a doctrine, not a suggestion

Chump is a multi-agent dispatcher whose load-bearing substrate is
`.chump-locks/ambient.jsonl` — a JSON-Lines event stream every fleet
worker, reaper, and operator-side script reads to maintain peripheral
vision.

When a new component lands without emitting structured events:
- The operator (or sibling agents) cannot tell whether it ran, succeeded,
  failed, or is silently wedged.
- Consumers (`fleet-brief`, `kpi-report`, `waste-tally`, watchdogs) have
  no signal to fold into their summaries.
- Failures only become visible after they cascade into something more
  expensive (a stalled queue, a wedged binary, a budget overrun).

We have observed this failure mode at every scale — from a single hung
`bot-merge.sh` zombie (no heartbeat, discovered 4 days late) to entire
fleet workers wedged on `claude -p` stdin (silent for hours). Every time,
the fix was "emit a `kind=...` event so a watchdog can grade it." Every
time, that emit was easier to add at component-build time than to retrofit.

So we make it **mechanically enforceable**.

## The mechanics

Three artifacts collaborate:

1. **`docs/observability/EVENT_REGISTRY.yaml`** — canonical, append-only
   list of every `kind=...` value the system can emit. Each entry names
   its emitter, trigger, downstream consumers, and required fields.
2. **`scripts/git-hooks/pre-commit-event-registry.sh`** — pre-commit
   guard that scans staged additions for new `"kind":"X"` literals and
   refuses commits where `X` is not registered.
3. **`scripts/ci/test-event-registry-guard.sh`** — unit test for the
   guard (six fixtures: clean commit, registered kind, unregistered
   kind, bypass env, missing registry, joint emit+register).

The guard runs as step 10 of `scripts/git-hooks/pre-commit`. It's
bypassable (`CHUMP_EVENT_REGISTRY_CHECK=0`) but the operator audits the
ambient stream for `Event-Registry-Bypass:` trailers.

## What this guard does NOT do

- It does **not** verify that the emitter actually emits the event.
  That's a separate concern (INFRA-757 owns CI coverage of event paths).
- It does **not** enforce a fields contract. If you register
  `fields_required: [ts, agent_id]` and emit only `ts`, the guard does
  not catch it. We considered a field-shape lint but rejected it as
  premature: too many emitters use serde structs, jq filters, or python
  dicts where static parsing is unreliable.
- It does **not** stop you from removing a registered kind. Removing
  emitters never breaks the consumer contract this guard protects.
  Mark obsolete kinds `status: deprecated` so the registry remains a
  searchable history of what the system used to do.

## Adding a new kind — the workflow

1. **Decide whether you need a new kind.** Most new emit sites can reuse
   an existing kind. Skim the registry first; reuse beats invention.
2. **Register it.** Add an entry to `EVENT_REGISTRY.yaml` with `kind`,
   `emitter`, `trigger`, and (recommended) `consumers` + `fields_required`.
3. **Add the emit.** Stage the registry change AND the emit in the same
   commit. The guard accepts both together.
4. **Wire a consumer.** If the registry says nothing reads the event,
   the operator will ask why you bothered — do the integration in the
   same PR or open a follow-up gap.

## Bypass discipline

`CHUMP_EVENT_REGISTRY_CHECK=0` exists for cases like:
- Mass-import of legacy code where the registry isn't ready.
- Test fixtures that emit synthetic kinds for assertion purposes.
- Investigative spike branches that aren't shipping to main.

Every bypass should carry an `Event-Registry-Bypass: <reason>` trailer
in the commit body. The reason should be one sentence; reviewers
should treat unexplained bypasses the same way they treat `git commit
--no-verify` — sparingly.

## Companion gaps

- **INFRA-754** (this gap) — the registry + guard + test + doctrine.
- **INFRA-755** — observability budget hook: refuse commits to `src/`
  that add new functions/methods without at least one structured log
  emit (or explicit `// no-observability` waiver).
- **INFRA-757** — CI test that runs every emit path under a fixture and
  asserts an event hits `ambient.jsonl`. This closes the gap between
  "registered" and "actually emits."

Together they make "observability before scale" the path of least
resistance instead of the path nobody walks.
