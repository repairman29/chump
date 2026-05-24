# Cross-Agent Lesson Propagation Format

> META-079 (META-073 child slice, Track 3 of 3). Defines the on-wire message
> format for one agent sharing a *lesson* (a generalizable finding) with the
> rest of the fleet. Pairs with META-075 (collision schema) and META-077
> (skill-routing schema) — those route *work*; this routes *knowledge*.

## Why a lesson-propagation layer

Today, lessons are captured ad-hoc:
- `docs/process/CURATOR_OPUS_LESSONS_2026-05-23.md` (the 7-lesson doc from
  the overnight session) is a hand-curated artifact, distributed by inbox
  ping.
- `docs/process/CLAUDE_GOTCHAS.md` is a long-form running list that agents
  read at session start.
- Recovery-mode tricks (union-resolve regex, `--force-overlap` patterns)
  live in commit messages, not in a discoverable place.

The result: a lesson learned at 14:00 by curator A is rediscovered
painfully at 22:00 by curator B because B never saw A's commit body.

A propagation layer captures lessons in a structured, queryable, time-stamped
form. Agents emit lessons as a first-class action; consumers read them at
relevant junctures (claim time, pre-push time, rebase-conflict time).

## Wire format (v1)

```json
{
  "ts": "<ISO-8601 UTC>",
  "kind": "lesson_published",
  "schema_version": "lesson-propagation-v1",
  "agent": "<emitter session id>",
  "lesson_id": "<short slug, kebab-case>",
  "lesson_type": "recovery_pattern | failure_class | tool_quirk | scope_calibration | discipline | architectural_insight",
  "headline": "<one-sentence summary, < 80 chars>",
  "context_tags": ["<tag1>", "<tag2>"],
  "applies_when": "<one-sentence trigger condition>",
  "do_this": "<one-paragraph or 3-step prescription>",
  "dont_do_this": "<one-paragraph or 3-step anti-pattern>",
  "evidence": {
    "observed_at_pr": <int|null>,
    "observed_at_gap": "<gap-id|null>",
    "elapsed_to_recover_min": <int|null>,
    "would_have_been_caught_by": "<existing-gate-name|null>"
  },
  "success_metric": {
    "kind": "wall_clock_min | bypass_count | ci_failure_rate | other",
    "before_value": <number>,
    "after_value": <number>,
    "delta": <number>
  },
  "payload_encryption": "none | aes256gcm",
  "session": "<emitter session id (duplicates agent for envelope consistency)>"
}
```

### Required fields

| Field                | Type             | Meaning                                       |
|----------------------|------------------|-----------------------------------------------|
| `ts`                 | ISO-8601 UTC     | When the lesson was published                 |
| `kind`               | `lesson_published` | Constant; registered in EVENT_REGISTRY.yaml |
| `schema_version`     | `lesson-propagation-v1` | Schema version                         |
| `agent`              | session id       | Who published                                 |
| `lesson_id`          | kebab-case slug  | Stable identifier (e.g. `union-resolve-reserved-txt`) |
| `lesson_type`        | enum (6 values)  | See taxonomy below                            |
| `headline`           | string ≤80 chars | One-sentence summary                          |
| `context_tags`       | array of strings | Free-form (e.g. `rebase`, `pre-push`)         |
| `applies_when`       | string           | Trigger condition for consumers to filter     |
| `do_this`            | string           | The prescription                              |
| `dont_do_this`       | string           | The anti-pattern                              |
| `evidence`           | object           | What concretely happened (4 sub-fields)       |
| `success_metric`     | object           | Quantified delta (4 sub-fields)               |

### Optional fields

| Field                | Type              | Meaning                                       |
|----------------------|-------------------|-----------------------------------------------|
| `payload_encryption` | enum              | `none` (default) or `aes256gcm` for sensitive |
| `supersedes`         | lesson_id         | This lesson replaces an older one             |

## Lesson-type taxonomy

| Type                       | Meaning                                          | Example                                          |
|----------------------------|--------------------------------------------------|--------------------------------------------------|
| `recovery_pattern`         | How to dig out of a failure mode                 | union-resolve regex for reserved.txt rebase conflict |
| `failure_class`            | A new failure class with classification          | "operator's regex take-both produces broken src/preflight.rs after rebase" |
| `tool_quirk`               | A surprising behavior of a fleet tool            | "chump-commit.sh _staged_paths unbound variable is non-fatal" |
| `scope_calibration`        | A lesson about gap-effort estimation             | "xs gap touching ~16 envvars is actually s effort" |
| `discipline`               | A discipline reminder w/ teeth                   | "--no-verify on push wrapper only; bypass any pre-existing CI gate requires Test-Gate-Bypass trailer" |
| `architectural_insight`    | A structural finding that reshapes design        | "fn main() should short-circuit --version BEFORE tokio runtime init" |

## Encryption (payload_encryption=aes256gcm)

For lessons that include sensitive strategies (e.g. specific operator
credentials patterns, customer-specific quirks, partial-secret leaks):

- Encrypt `do_this`, `dont_do_this`, and `evidence` fields with AES-256-GCM
  using a fleet-shared key derived from `~/.chump/lesson-key` (operator-managed)
- Set `payload_encryption: "aes256gcm"`
- All other fields stay cleartext so the lesson is discoverable / filterable
  without decryption

Consumer code: `chump scratch lesson get <lesson-id> --decrypt`.

The default is `none` — agents publish in cleartext unless they explicitly
opt into encryption. Avoid encryption for routine lessons; it raises the
friction for future consumers.

## Success-metric semantics

Every lesson MUST claim a measurable improvement so we can prune stale
or false ones:

| `kind`                  | What it measures                                          |
|-------------------------|-----------------------------------------------------------|
| `wall_clock_min`        | Time-to-recover delta (lower-is-better)                   |
| `bypass_count`          | How many bypasses-per-day this lesson eliminates          |
| `ci_failure_rate`       | % of CI failures of this class that this lesson prevents  |
| `other`                 | Free-form, with explanation in `do_this`                  |

`before_value` and `after_value` are concrete numbers; `delta` is signed
(positive = improvement for "lower-is-better" metrics).

## Lifecycle

1. **Publish** — agent emits `kind=lesson_published` to ambient AND
   writes the cleartext (or encrypted) blob to `.chump-locks/lessons/<lesson_id>.json`.
2. **Discovery** — consumers query via `chump fleet lessons list --tag <tag>` (filed as follow-up)
   OR auto-surface at relevant junctures (claim time, rebase-conflict time, pre-push time).
3. **Application** — agent reads relevant lesson before acting; emits
   `kind=lesson_applied {lesson_id, gap_id, decision}` to record influence.
4. **Audit** — operator can run `chump fleet lessons audit` to find:
   - Lessons never applied (stale)
   - Lessons with negative success_metric.delta (false positives)
   - Top-K most-applied lessons (high-leverage)

## Companion event: `lesson_applied`

```json
{
  "ts": "<ISO-8601 UTC>",
  "kind": "lesson_applied",
  "lesson_id": "<the published lesson's slug>",
  "applied_at_gap": "<gap-id|null>",
  "applied_at_pr": <int|null>,
  "decision": "followed | considered_and_skipped | superseded_by:<other-lesson-id>",
  "session": "<applying session id>"
}
```

Applied count + decision distribution feed the `chump fleet lessons audit`
follow-up gap.

## Registry note

Both kinds (`lesson_published`, `lesson_applied`) MUST be registered in
`docs/observability/EVENT_REGISTRY.yaml` before the first emitter ships.
Registration is the responsibility of META-080 (the first implementation,
in-memory store) — this doc is schema spec only.

## Storage layout

```
.chump-locks/lessons/
├── <lesson_id_A>.json
├── <lesson_id_B>.json
└── <lesson_id_C>.json.enc        # encrypted variant
```

Each file is one lesson; the directory IS the catalog. `chump fleet
lessons list` walks it. NATS-backed v2 (filed as INFRA-NEW post-META-080)
will replace the file store with a `chump_lessons` KV bucket while
preserving the JSON schema.

## Cross-references

- META-073 — parent epic (forward-looking coordination)
- META-075 — collision schema (Track 1)
- META-077 — skill-routing schema (Track 2)
- META-080 — first implementation (in-memory store)
- META-083 — failure-class taxonomy (lesson_type=failure_class uses it)
- `docs/process/CURATOR_OPUS_LESSONS_2026-05-23.md` — example of today's hand-curated lesson set; v1 of this layer should ingest it as 7 separate `lesson_published` records on first run
- `docs/process/CLAUDE_GOTCHAS.md` — running long-form gotcha list; complementary, not replaced
