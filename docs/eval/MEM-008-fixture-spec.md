# MEM-008 — Multi-hop QA Fixture Spec

**Gap:** MEM-008  
**Created:** 2026-04-20  
**Prerequisite for:** MEM-010 (entity resolution A/B), EVAL-034 (memory retrieval multi-hop QA sweep)  
**Status:** pilot spec — 15 questions across 3 categories

---

## Purpose

This document defines what "multi-hop memory retrieval" means for Chump's eval harness.
It is concrete enough that an automated harness can:

1. Load the required memory entries into the retrieval system under test.
2. Issue the question.
3. Evaluate the response against the expected answer and rubric.

Without a fixture spec, a negative result on a multi-hop eval is uninterpretable:
failure could mean the memory graph is broken, the embedding model can't link entries,
or the fixture only tests simple recall. The three categories below isolate *which
kind* of multi-hop failure is occurring.

---

## Category Definitions

### (a) Entity-chain — A → B → C linkage

**What is tested:** The system must resolve that two or more memory entries refer to
the same real-world entity under different surface forms, and then use the unified
entity to answer a question that no single entry answers alone.

**Hop structure:** Entry-1 names entity A by label X. Entry-2 names the same entity by
label Y and adds a fact. Entry-3 names the same entity by label Z and adds another
fact. The question requires combining facts from at least two entries, which is only
possible after resolving X = Y = Z.

**Typical failure mode:** Retrieval returns only the entry that surface-matches the
query term, missing the synonym entries.

---

### (b) Temporal-chain — event sequence reasoning

**What is tested:** The system must order two or more events from memory and reason
about the sequence (before/after, duration, overlap) to answer the question.

**Hop structure:** Entry-1 records event A at time T1. Entry-2 records event B at time
T2. The question asks which happened first, how much time elapsed, or what was the
state of some attribute between T1 and T2.

**Typical failure mode:** Retrieval returns both entries but the answer model ignores
the timestamps, producing a random ordering.

---

### (c) Causal-chain — cause → effect → consequence

**What is tested:** The system must follow a causal chain across entries: event A
caused condition B, condition B caused outcome C. The question asks about a
consequence that is only in Entry-3 and is only reachable by traversing the chain.

**Hop structure:** Entry-1 states cause A. Entry-2 states that A leads to effect B.
Entry-3 states that B produces consequence C. The question asks about C given only
knowledge of A.

**Typical failure mode:** Retrieval returns Entry-1 (matches query about A) but misses
Entry-2 and Entry-3 because they don't mention A explicitly.

---

## Pilot Question Set (15 questions — 5 per category)

### Format

Each question entry has the following fields:

| Field | Description |
|---|---|
| `id` | Stable identifier: `MEM008-<category>-<nn>` |
| `category` | One of: `entity-chain`, `temporal-chain`, `causal-chain` |
| `question` | The question posed to the retrieval system |
| `expected_answer` | The answer a correct system should produce (free-text or structured) |
| `hops` | Ordered list of hop steps the system must take |
| `required_memory_entries` | The minimal set of entries that must be present for a correct answer |

---

### Category A — Entity-chain

---

**MEM008-entity-001**

- **question:** What is the work email address of the person Jeff refers to as "my coworker Alice"?
- **expected_answer:** alice@work.example.com
- **hops:**
  1. Resolve "my coworker Alice" in Entry-1 → full name Alice Nguyen
  2. Resolve "Alice Nguyen" in Entry-2 → alias "alice@work.example.com"
  3. Return the email from Entry-2
- **required_memory_entries:**
  - Entry-1: `"my coworker Alice is Alice Nguyen; we worked together on the API redesign in Q3"`
  - Entry-2: `"Alice Nguyen's work email is alice@work.example.com; she prefers async Slack messages"`

---

**MEM008-entity-002**

- **question:** What programming language does the project codenamed "Firebolt" use?
- **expected_answer:** Rust
- **hops:**
  1. Resolve codename "Firebolt" in Entry-1 → project ID proj-4421
  2. Resolve proj-4421 in Entry-2 → canonical name "ChumpCore"
  3. Retrieve language fact from Entry-3 about "ChumpCore"
- **required_memory_entries:**
  - Entry-1: `"The project we call Firebolt internally maps to repo proj-4421"`
  - Entry-2: `"proj-4421 is the internal ID for ChumpCore, the Rust dispatcher"`
  - Entry-3: `"ChumpCore is written in Rust; primary crate is chump-core"`

---

**MEM008-entity-003**

- **question:** What is the home timezone of the vendor contact Jeff calls "the Berlin team"?
- **expected_answer:** Europe/Berlin (UTC+1 / UTC+2 DST)
- **hops:**
  1. Resolve "the Berlin team" in Entry-1 → company name Axon GmbH
  2. Resolve "Axon GmbH" in Entry-2 → primary contact Klaus Berger
  3. Retrieve timezone for Klaus Berger from Entry-3
- **required_memory_entries:**
  - Entry-1: `"The Berlin team = Axon GmbH; Jeff's main vendor for the infra contract"`
  - Entry-2: `"Axon GmbH primary contact: Klaus Berger, engineering lead"`
  - Entry-3: `"Klaus Berger is based in Berlin, timezone Europe/Berlin"`

---

**MEM008-entity-004**

- **question:** Which Slack channel should be used for urgent alerts related to the service Jeff calls "the watcher"?
- **expected_answer:** #ops-alerts-critical
- **hops:**
  1. Resolve "the watcher" in Entry-1 → service name chump-heartbeat
  2. Resolve "chump-heartbeat" in Entry-2 → on-call rotation "infra-oncall"
  3. Retrieve Slack channel for "infra-oncall" urgent alerts from Entry-3
- **required_memory_entries:**
  - Entry-1: `"Jeff calls chump-heartbeat 'the watcher' — the liveness probe daemon"`
  - Entry-2: `"chump-heartbeat is owned by the infra-oncall rotation"`
  - Entry-3: `"infra-oncall urgent escalation channel: #ops-alerts-critical"`

---

**MEM008-entity-005**

- **question:** What database engine backs the storage layer Jeff refers to as "the ledger"?
- **expected_answer:** SQLite (via rusqlite)
- **hops:**
  1. Resolve "the ledger" in Entry-1 → module name `memory_db`
  2. Resolve `memory_db` in Entry-2 → crate `chump-memory`
  3. Retrieve storage backend for `chump-memory` from Entry-3
- **required_memory_entries:**
  - Entry-1: `"Jeff calls the memory_db module 'the ledger' — it's the persistent store"`
  - Entry-2: `"memory_db is the main module inside the chump-memory crate"`
  - Entry-3: `"chump-memory uses SQLite via rusqlite for all persistent storage"`

---

### Category B — Temporal-chain

---

**MEM008-temporal-001**

- **question:** Did Jeff adopt the MEM-006 lessons-at-spawn feature before or after the INFRA-MERGE-QUEUE merge queue went live?
- **expected_answer:** MEM-006 (lessons-at-spawn) shipped first; INFRA-MERGE-QUEUE went live the same day but in a later PR.
- **hops:**
  1. Retrieve merge date/PR for MEM-006 from Entry-1
  2. Retrieve merge date/PR for INFRA-MERGE-QUEUE from Entry-2
  3. Compare the two timestamps
- **required_memory_entries:**
  - Entry-1: `"MEM-006 (lessons-loaded-at-spawn) merged as PR #153 on 2026-04-19T14:22Z"`
  - Entry-2: `"INFRA-MERGE-QUEUE (GitHub merge queue setup) merged as PR #155 on 2026-04-19T17:05Z"`

---

**MEM008-temporal-002**

- **question:** How many days elapsed between the first chump dogfood run and the first successful E2E smoke test?
- **expected_answer:** 3 days
- **hops:**
  1. Retrieve date of first dogfood run from Entry-1
  2. Retrieve date of first successful E2E smoke test from Entry-2
  3. Compute the difference
- **required_memory_entries:**
  - Entry-1: `"First chump dogfood run: 2026-04-16 — ran claude -p on itself, output was noisy but non-empty"`
  - Entry-2: `"First successful E2E smoke test (AUTO-013 step 5): 2026-04-19 — chump self-orchestrated without errors"`

---

**MEM008-temporal-003**

- **question:** Was the worktree reaper bug (INFRA-WORKTREE-REAPER-FIX) fixed before or after the PR #52 data loss incident?
- **expected_answer:** The PR #52 data loss happened on 2026-04-18; INFRA-WORKTREE-REAPER-FIX was merged later on 2026-04-19. The reaper fix came after.
- **hops:**
  1. Retrieve date of PR #52 data loss from Entry-1
  2. Retrieve merge date of INFRA-WORKTREE-REAPER-FIX from Entry-2
  3. Order the two events
- **required_memory_entries:**
  - Entry-1: `"PR #52 data loss incident: 2026-04-18 — agent kept pushing after auto-merge was armed; 11 commits lost"`
  - Entry-2: `"INFRA-WORKTREE-REAPER-FIX merged as PR #156 on 2026-04-19 — process-aware reap check"`

---

**MEM008-temporal-004**

- **question:** What was the state of the chump-memory crate between the commit that added the SQLite schema and the commit that added full-text search?
- **expected_answer:** The crate had a working key-value store but no FTS index; queries were exact-match only.
- **hops:**
  1. Retrieve schema-add commit timestamp and description from Entry-1
  2. Retrieve FTS-add commit timestamp and description from Entry-2
  3. Infer the intermediate state from the gap between the two entries
- **required_memory_entries:**
  - Entry-1: `"commit a1b2c3 (2026-04-10): added SQLite schema to chump-memory — key/value table, no FTS yet"`
  - Entry-2: `"commit d4e5f6 (2026-04-17): added FTS5 virtual table to chump-memory — enables substring search"`

---

**MEM008-temporal-005**

- **question:** Was the COG-024 safe-by-default lessons flag introduced before or after the EVAL-030 task-class-aware lessons gating?
- **expected_answer:** COG-024 came first (it is the mechanism); EVAL-030 builds on top of it by adding task-class awareness.
- **hops:**
  1. Retrieve when COG-024 was closed/shipped from Entry-1
  2. Retrieve when EVAL-030 was shipped from Entry-2
  3. Compare the ordering and explain the dependency
- **required_memory_entries:**
  - Entry-1: `"COG-024 (safe-by-default lessons flag) shipped 2026-04-17 — OFF by default, opt-in via env var"`
  - Entry-2: `"EVAL-030 (task-class-aware lessons gating) shipped 2026-04-19 — extends COG-024 with prompt-length check"`

---

### Category C — Causal-chain

---

**MEM008-causal-001**

- **question:** Why does Chump disable lessons injection by default, and what problem would happen if it were enabled by default?
- **expected_answer:** Lessons injection is OFF by default (COG-024) to avoid polluting every agent session with potentially stale or irrelevant lessons. If ON by default, short/trivial prompts would receive a large lessons block that increases token cost and can cause the model to over-apply past learnings to unrelated tasks.
- **hops:**
  1. Retrieve the reason for the COG-024 safe-by-default decision from Entry-1
  2. Retrieve the EVAL-030 observation about trivial prompts from Entry-2
  3. Chain the consequence: default-ON → trivial prompts get lessons → overcost + confusion
- **required_memory_entries:**
  - Entry-1: `"COG-024 rationale: lessons can be stale or context-mismatched; safe default is OFF to preserve signal quality"`
  - Entry-2: `"EVAL-030 found: prompts < 30 chars trimmed are almost always trivial chat — lessons block adds noise, no benefit"`

---

**MEM008-causal-002**

- **question:** What sequence of failures led to the introduction of the wrong-worktree commit check in chump-commit.sh?
- **expected_answer:** A Python script wrote to the main repo root while the user thought they were in a worktree; the staged changes leaked into an unrelated commit, wasting ~30 minutes on 2026-04-18. This caused the wrong-worktree guard to be added to chump-commit.sh on 2026-04-18.
- **hops:**
  1. Retrieve the root cause incident from Entry-1 (Python script / wrong path)
  2. Retrieve the time wasted and date from Entry-2
  3. Retrieve the guard added as a consequence from Entry-3
- **required_memory_entries:**
  - Entry-1: `"2026-04-18: Python script wrote files to main repo root; user thought active worktree was target"`
  - Entry-2: `"Incident cost ~30 min of debugging; staged diff leaked into sibling agent's commit"`
  - Entry-3: `"chump-commit.sh gained wrong-worktree check 2026-04-18: blocks if named files have no changes in current worktree but do in a sibling"`

---

**MEM008-causal-003**

- **question:** Why does Chump use a merge queue, and what specific data loss event motivated it?
- **expected_answer:** PR #52 (2026-04-18) lost 11 commits because an agent kept pushing after auto-merge was armed; GitHub captured the branch at first-CI-green and dropped later pushes. The merge queue (INFRA-MERGE-QUEUE) was introduced to prevent this by serializing merges — each PR is rebased onto current main and re-runs CI atomically.
- **hops:**
  1. Retrieve the PR #52 data loss from Entry-1
  2. Retrieve the mechanism of loss (GitHub branch capture) from Entry-2
  3. Retrieve the merge queue solution and how it prevents the failure from Entry-3
- **required_memory_entries:**
  - Entry-1: `"PR #52 (2026-04-18): agent pushed 11 commits after auto-merge was armed; only first-CI-green snapshot was merged"`
  - Entry-2: `"GitHub merge queue captures the branch HEAD at first CI pass; pushes after that point are silently dropped"`
  - Entry-3: `"INFRA-MERGE-QUEUE: each PR rebased onto main + CI re-run before atomic squash — prevents stale-base merges and post-arm push loss"`

---

**MEM008-causal-004**

- **question:** What would happen to the eval harness if MEM-008 were skipped and EVAL-034 ran without a fixture spec?
- **expected_answer:** A negative result on EVAL-034 would be uninterpretable. It would be unclear whether failure was due to the memory graph being broken, the embedding model failing to link entries, or the fixture only testing simple recall. Any remediation effort would be misdirected.
- **hops:**
  1. Retrieve the dependency statement from Entry-1 (MEM-008 precedes EVAL-034)
  2. Retrieve the failure modes that become confounded without category separation from Entry-2
  3. Chain the consequence: confounded failure → misdirected remediation
- **required_memory_entries:**
  - Entry-1: `"MEM-008 must complete before EVAL-034 — the fixture spec is the ground truth for scoring"`
  - Entry-2: `"Without category separation, a low EVAL-034 score could be entity resolution failure, temporal reasoning failure, or causal chain failure — indistinguishable"`

---

**MEM008-causal-005**

- **question:** Why did the memory_db.rs file get accidentally overwritten on 2026-04-17, and what coordination mechanism was introduced as a direct result?
- **expected_answer:** Two concurrent agent sessions staged changes to the same file without awareness of each other; `git commit` picked up both sets of staged changes and created a cross-agent stomp. The lease-collision pre-commit hook was introduced as a direct result to block commits when a file is claimed by a different live session.
- **hops:**
  1. Retrieve the memory_db.rs stomp event and root cause from Entry-1
  2. Retrieve the specific commit that captured both agents' changes from Entry-2
  3. Retrieve the lease-collision pre-commit hook that was added in response from Entry-3
- **required_memory_entries:**
  - Entry-1: `"2026-04-17: memory_db.rs stomp in cf79287 — two concurrent sessions staged conflicting changes; neither session saw the other's edits"`
  - Entry-2: `"cf79287 merged both agents' staged diffs; one agent's work was silently overwritten"`
  - Entry-3: `"lease-collision pre-commit hook added 2026-04-17: blocks commit if staged file is claimed by a different live session in .chump-locks/"`

---

## What Counts as a Correct Answer

### Scoring rubric

A response is scored on three dimensions. Each dimension is binary (pass / fail).
The overall question result is **pass** only if all three dimensions pass.

#### Dimension 1 — Factual accuracy

The answer states the correct fact(s) as defined in `expected_answer`.

- **Pass:** The core fact is present and not contradicted. Paraphrasing is fine.
- **Fail:** The core fact is wrong, inverted, or missing entirely.
- **Partial credit rule (for automated scoring):** If the answer contains the correct
  fact alongside an incorrect fact about the same entity, score as **fail** — a
  hedged-wrong answer is worse than a useful "I don't know."

#### Dimension 2 — Chain traversal evidence

The answer demonstrates (explicitly or implicitly) that it followed the required hops.

- **Pass:** The answer references at least two distinct pieces of information that came
  from different memory entries. Explicit citation is not required; traceability is
  inferred from whether the answer would be impossible from any single entry alone.
- **Fail:** The answer could have been produced from a single entry (simple recall),
  meaning the multi-hop capability was not exercised.

#### Dimension 3 — Confidence calibration

The answer's expressed confidence matches the evidence in the memory entries.

- **Pass:** Confident answer when entries are definitive; hedged answer when entries
  are approximate or conflicting; "I don't know" when required entries are absent.
- **Fail:** Confidently wrong (states a fact not supported by entries), or refuses to
  answer when sufficient entries are present.

### Scoring table

| D1 accuracy | D2 chain traversal | D3 calibration | Overall |
|---|---|---|---|
| pass | pass | pass | **PASS** |
| pass | pass | fail | fail |
| pass | fail | pass | fail |
| fail | any | any | fail |

### Grade thresholds (for category-level reporting)

| Category accuracy | Interpretation | Next action |
|---|---|---|
| ≥ 80% | Category is viable for EVAL-034 | Include in full sweep |
| 50–79% | Category needs investigation | Open sub-gap before EVAL-034 |
| < 50% | Category is broken | Open sub-gap; exclude from EVAL-034 until fixed |

### Automated harness contract

The harness must:

1. Load exactly the entries listed in `required_memory_entries` for each question
   into the retrieval index — no other entries that could short-circuit the hops.
2. Issue the `question` verbatim.
3. Score D1 using an LLM judge with the `expected_answer` as the reference.
4. Score D2 by checking whether the retrieval log shows at least two distinct entry
   sources were fetched before the answer was generated.
5. Score D3 using the LLM judge against a calibration rubric (overconfident /
   calibrated / underconfident).
6. Emit one JSON result row per question:
   `{"id": "MEM008-entity-001", "d1": true, "d2": true, "d3": false, "pass": false}`

### What does NOT count as a correct answer

- A verbatim quote of a single memory entry that happens to contain the right words —
  this fails D2 (no chain traversal).
- A correct fact with no traceability to memory (model guessing from training data) —
  this fails D2.
- A correct fact expressed with wrong confidence level ("I'm not sure, but maybe X"
  when entries are definitive) — this fails D3.
- A refusal to answer when the required entries are present — this fails D3.
