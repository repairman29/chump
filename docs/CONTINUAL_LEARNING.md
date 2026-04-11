# Continual learning (Cursor): transcript mining and `AGENTS.md`

How **high-signal** preferences and workspace facts from past Cursor chats are merged into this repo’s **[AGENTS.md](../AGENTS.md)** using the **continual-learning** skill and **`agents-memory-updater`** subagent.

---

## What it does

- **Mines** parent chat transcripts under the Cursor project’s **`agent-transcripts/`** tree (JSONL).
- **Incrementally** skips work already reflected in a local **mtime index** (see below).
- **Updates** [AGENTS.md](../AGENTS.md) only with **durable** items: recurring user preferences, stable workspace facts.
- **Never** stores secrets, tokens, passwords, or transient one-off instructions.
- **Avoids** unnecessary PII (e.g. full street addresses) unless truly required as a workspace fact.

---

## Components

| Piece | Role |
|-------|------|
| **Skill: `continual-learning`** | **Orchestration only:** delegates to `agents-memory-updater`; parent does not mine transcripts or edit files. Shipped with the Cursor **continual-learning** plugin (see plugin `skills/continual-learning/SKILL.md` in the plugin install). |
| **Subagent: `agents-memory-updater`** | **Full flow:** read `AGENTS.md`, load index, scan eligible transcripts, merge bullets, refresh index, remove stale index keys for deleted files. |

---

## Incremental index (local)

**Path (repo root):** `.cursor/hooks/state/continual-learning-index.json`

**Note:** The repo **`.gitignore`** ignores **`.cursor/`**, so this file is **machine-local** and **not committed**. Each clone creates its own index; first run processes all transcripts, then only **new or changed** files.

**Schema (informal):**

- `version` — integer (currently `1`).
- `updatedAt` — ISO-8601 UTC when the index was last refreshed.
- `transcripts` — map of **absolute path** → `{ "mtimeMs": number }` (filesystem `mtime` in milliseconds).

**Eligibility rule for a transcript file:**

- Path **not** in the map → **process**.
- Path in map but **current `mtimeMs` > indexed `mtimeMs`** → **process**.
- Otherwise → **skip** content mining (still refresh index entry to current mtime after a full directory scan).

After a run, the updater should:

1. Set **`mtimeMs`** for every `*.jsonl` found under this project’s `agent-transcripts` directory (including nested `subagents/` files if present).
2. **Delete** index entries whose files no longer exist.

---

## Transcript location

Cursor stores parent transcripts per workspace, typically:

`~/.cursor/projects/<project-slug>/agent-transcripts/`

The `<project-slug>` matches how Cursor names the project (e.g. path-based). **Subagent** transcripts may appear under `…/agent-transcripts/<uuid>/subagents/<id>.jsonl`.

The exact root for **this** repo on your machine is under **`~/.cursor/projects/`**; the continual-learning run uses that tree for the **Chump** workspace.

---

## What changes in `AGENTS.md`

The subagent maintains **plain bullets** in these sections **only** (create them if missing):

- **`## Learned User Preferences`**
- **`## Learned Workspace Facts`**

Rules:

- **At most 12 bullets** per section.
- **Deduplicate** semantically similar bullets; **update in place** when matching an existing idea.
- No evidence tags, no process metadata blocks in those sections.

**Coexistence with §6:** [AGENTS.md](../AGENTS.md) also has **`## 6. Learned conventions`** (Chump–Cursor technical conventions). That section stays as-is for **repo-specific engineering** notes. The **Learned User Preferences / Facts** blocks at the top capture **user and workspace** durable context from transcripts; avoid duplicating the same fact in three places—prefer **one** canonical bullet.

---

## How to run it

Ask the agent in Cursor, for example:

```text
Run the continual-learning skill. Use the agents-memory-updater subagent for the full memory update flow.
Use incremental transcript processing with index file `<repo>/.cursor/hooks/state/continual-learning-index.json`:
only consider transcripts not in the index or transcripts whose mtime is newer than indexed mtime.
Have the subagent refresh index mtimes, remove entries for deleted transcripts, and update AGENTS.md only
for high-signal recurring user corrections and durable workspace facts. Exclude one-off/transient details and secrets.
If no meaningful updates exist, respond exactly: No high-signal memory updates.
```

Replace `<repo>` with your clone path. Ensure **`.cursor/hooks/state/`** exists (the updater or you can `mkdir -p`).

---

## Expected responses

- **Updates applied:** short summary of `AGENTS.md` edits and index refresh.
- **Nothing durable:** parent should return **exactly** (single line):

  `No high-signal memory updates.`

  The index may still be refreshed so mtimes stay current.

---

## Related docs

| Doc | Purpose |
|-----|---------|
| [AGENTS.md](../AGENTS.md) | Target file for learned sections + Chump–Cursor protocol |
| [CURSOR_CLI_INTEGRATION.md](CURSOR_CLI_INTEGRATION.md) | How Chump invokes Cursor (separate from this memory loop) |
| [DEFENSE_MARKET_RESEARCH.md](DEFENSE_MARKET_RESEARCH.md) / [DEFENSE_PILOT_EXECUTION.md](DEFENSE_PILOT_EXECUTION.md) / [FEDERAL_OPPORTUNITIES_PIPELINE.md](FEDERAL_OPPORTUNITIES_PIPELINE.md) | Example topics that may surface as **Learned Workspace Facts** |

---

## Revision

Plugin skill text may evolve; the **authoritative** workflow for edits is still: **orchestrate with `continual-learning`**, **execute with `agents-memory-updater`**, **do not bypass** the subagent for this flow.
