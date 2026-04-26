# INFRA-022 — Gap-Store Architecture Decision Memo

> Author: automated gap agent, 2026-04-21.
> Deliverable: architecture pick + migration plan. Migration itself is INFRA-023+.

---

## Problem Statement

`docs/gaps.yaml` has outgrown its origin:

| Symptom | Root cause |
|---|---|
| 8,000+ lines in one file | No domain partitioning |
| Merge conflicts on every PR | All agents write the same file |
| Non-atomic ID assignment | No reservation primitive → 7 collision pairs (Red Letter #2) |
| Poor search and query | YAML is not a query engine |
| Stale metadata accumulates | No comment / label / milestone support |

**Constraints that rule out GitHub Issues as source of truth:**
1. Bots must work fully offline — no network dependency for gap scaffolding
2. Bots scaffold and ship without waiting on a network
3. No vendor lock-in — GitHub is an acceptable *mirror*, not the authority

---

## Evaluation Matrix: 4 Candidate Designs

Scored 1–5 on five dimensions. Higher is better.

| Dimension | (1) SQLite-in-repo | (2) Per-gap files | (3) Per-domain YAML | (4) JSON-lines + index |
|---|:---:|:---:|:---:|:---:|
| **Offline fidelity** | 5 | 5 | 5 | 5 |
| **Bot scaffolding ergonomics** | 3 | 5 | 3 | 4 |
| **Merge-conflict surface** | 4 | 5 | 3 | 4 |
| **Migration cost from today** | 2 | 3 | 5 | 3 |
| **GH-mirror compatibility** | 2 | 5 | 3 | 3 |
| **Rich query support** | 5 | 2 | 2 | 3 |
| **Human diff review** | 2 | 5 | 4 | 3 |
| **TOTAL** | **22** | **30** | **25** | **25** |

### (1) SQLite-in-repo

`.chump/gaps.db` checked in. Periodic `.sql` dump committed alongside for human review.

**Pros:** Atomic writes at the DB level. Rich SQL queries. Scales to 100k rows. Every LLM knows SQL.

**Cons:** Binary format in git (mitigated by sql dump, not eliminated). `git diff` on the db file is meaningless. CI must install sqlite3 on every runner. Concurrent writers still need external locking (WAL mode helps but doesn't eliminate contention across worktrees sharing the same file).

**Verdict:** Best for queries, worst for human review and git hygiene. Overkill for a gap registry that peaks at ~1000 entries.

---

### (2) Per-gap directory — **PICK**

```
docs/gaps/
  INFRA/
    INFRA-022.md    ← YAML frontmatter + Markdown body
    INFRA-023.md
  EVAL/
    EVAL-069.md
  PRODUCT/
    PRODUCT-012.md
  ...
```

Each gap is its own file. Frontmatter carries structured fields (id, title, status, priority, effort, closed_date). Body carries description, acceptance_criteria, notes in Markdown.

**Pros:**
- **Zero merge conflicts by design.** Each agent writes exactly one file for its gap. No file ever has two agents writing concurrently (unlike a shared YAML list).
- **Trivial bot scaffolding.** `scripts/gap-scaffold.sh INFRA "My title"` → reserve ID, write file, done. No YAML parser needed.
- **1:1 with GitHub Issues.** One file = one Issue if you ever want a mirror. Every field maps cleanly.
- **Human-readable diffs.** `git diff docs/gaps/INFRA/INFRA-023.md` is a clean, narrow diff.
- **Greppable.** `rg "status: open" docs/gaps/` works perfectly.
- **Editor-friendly.** `vim docs/gaps/INFRA/INFRA-022.md` is a natural unit of work.

**Cons:**
- ~500 files at current scale. Not a real problem — ripgrep handles 500k files.
- No built-in atomic ID assignment (still needs `scripts/coord/gap-reserve.sh` to coordinate). Solvable with a monotonic counter file per domain (`.chump/id-counters/INFRA` stores the next integer — single-file write is atomic enough at our write rates, guarded by Python `fcntl.flock`).
- Migration from monolithic YAML requires a one-time split script.

---

### (3) Per-domain YAML

`docs/gaps/eval.yaml`, `docs/gaps/infra.yaml`, etc.

**Pros:** Smallest migration delta from today. Same tool support.

**Cons:** EVAL has 60+ gaps already — `eval.yaml` will hit the 8000-line problem again within a year. Does not solve ID assignment or merge conflicts within a domain. Kicks the can.

**Verdict:** Not worth the migration cost for such limited gain.

---

### (4) JSON-lines + index

Append-only `docs/gaps.jsonl`. ID from line-number monotonic counter.

**Pros:** Append is nearly atomic. Any language reads JSONL trivially. IDs are implicitly ordered.

**Cons:** Closing a gap requires rewriting the file (or appending a tombstone event — awkward for humans). `git diff` on JSONL is line-noisy. Tools that parse JSONL are less universal than Markdown. No natural GitHub Issues mirror.

**Verdict:** Would work, but per-gap files are strictly better for human ergonomics and git review.

---

## Pick: Option 2 — Per-gap files

**Rationale:** Highest total score. Solves the two root causes (merge conflicts + ID collision) without sacrificing offline fidelity, grep-ability, or human review quality. Maps cleanly to GitHub Issues for future mirror work.

---

## Migration Plan

### Phase 1 — Tooling (INFRA-022, this PR)

- `scripts/coord/gap-store-prototype.sh` CRUD wrapper (init, scaffold, list, get, done, search)
- Prototype converts INFRA domain from `docs/gaps.yaml` into `docs/gaps/INFRA/` files
- Runs alongside `docs/gaps.yaml` — fully additive, no deletion

### Phase 2 — Migration (INFRA-023)

- One-time `scripts/gap-migrate.sh` splits `docs/gaps.yaml` into `docs/gaps/<domain>/<ID>.md` files
- All scripts (gap-preflight.sh, gap-claim.sh, bot-merge.sh, etc.) updated to read from `docs/gaps/`
- `docs/gaps.yaml` kept as a read-only archive with a deprecation header
- CI check: gap-preflight now reads from `docs/gaps/` exclusively

### Phase 3 — Cleanup (INFRA-024)

- Remove `docs/gaps.yaml` archive
- Remove YAML-reader code paths from all scripts
- Optional: `scripts/gap-sync.sh` for ad-hoc GitHub Issues mirror

---

## Conflict Resolution Rules (Phase 2+)

When a sync layer is introduced (Phase 3 optional), the following rules apply:

| Conflict scenario | Winner | Rationale |
|---|---|---|
| Local edit vs remote (GH Issues) edit to same field | **Local** | Repo is source of truth; GH mirror is read-only |
| Two local branches edit same gap file | **Later merge** wins on conflicting fields | Standard git merge; per-file structure means conflicts are rare and narrow |
| Gap closed locally, re-opened remotely | **Local closed** state wins | Bots land the ground truth; human re-open goes through the repo |
| New gap in GH Issues with no local file | Ignored until `gap-sync.sh --pull` is run explicitly | Offline-first: GH issues never modify local repo autonomously |

---

## Scaffolding Requirement

The non-negotiable gate (from gap spec): **a bot must be able to call `scripts/gap-scaffold.sh <domain> <title>` and get back (a) a reserved ID, (b) a ready-to-edit file, (c) no collision with concurrent bots.**

Implementation in `scripts/coord/gap-store-prototype.sh scaffold`:

```bash
# ID reservation: per-domain monotonic counter in .chump/id-counters/<DOMAIN>
# Concurrency: Python fcntl.flock (cross-platform, works on macOS + Linux)
# Output: docs/gaps/<DOMAIN>/<DOMAIN>-NNN.md with YAML frontmatter template
```

The counter file is a single integer. `fcntl.flock(LOCK_EX | LOCK_NB)` with retry gates concurrent reservation. Since bots in different worktrees share the same `.chump/` directory (in the main repo root), the lock is cross-process safe.

---

*Prepared by: Chump autonomous gap agent (INFRA-022, 2026-04-21).*
