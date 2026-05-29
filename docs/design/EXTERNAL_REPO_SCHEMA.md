# External Repo Schema

**Gap:** INFRA-2116 (META-123 C8)
**Status:** Canonical — Wave 2 children build against this.

This document defines the persistent on-disk layout under
`~/.chump/external/<owner>/<repo>/`. It is the shared memory, scan-result, and
signal layer written by Scout, curated by Context-Keeper, and read by
Decompose and the Target picker.

---

## Directory layout

```
~/.chump/external/<owner>/<repo>/
├── clone/                          # shallow git clone (chump onboard populates)
├── memory/
│   ├── snapshot-<YYYY-MM-DD>.json  # periodic health snapshot (see §Memory)
│   ├── delta-<from>-to-<to>.md     # diff summary between two snapshots
│   └── notes.md                    # hand-maintained operator notes
├── scans/
│   └── onboard-scan-<iso-ts>.json  # Scout output: proposed-gap list (see §Scans)
└── signals/
    ├── issues.jsonl    # streaming-append: issue events (see §Signals)
    ├── prs.jsonl       # streaming-append: PR events
    └── commits.jsonl   # streaming-append: commit events
```

`<iso-ts>` in scan filenames uses compact UTC form: `YYYYMMDDTHHMMSSZ`
(colons removed for filesystem safety). `<YYYY-MM-DD>` in snapshot filenames is
the UTC date. Readers take the lexicographically last file within each
directory to find the most recent record.

---

## Canonical tag format

External-repo gaps use this `skills_required` tag:

```
external_repo:<owner>/<repo>
```

Rules:
- All-lowercase
- Single colon between `external_repo` and the path
- Single slash separator between owner and repo
- No trailing slash
- No spaces

Valid examples:
```
external_repo:anthropics/anthropic-sdk-rust
external_repo:tokio-rs/tokio
external_repo:rust-lang/rust
```

Invalid examples (all rejected by `validate_external_repo_tag`):
```
external:foo/bar           # missing _repo
external_repo:foo          # missing slash / repo portion
external_repo:Owner/repo   # uppercase
external_repo:foo/         # empty repo
```

**INFRA-2113 (picker filter) and INFRA-2112 (decompose `--external-repo`) rely
on this exact shape. Do not deviate.**

---

## Scans — `scans/onboard-scan-<iso-ts>.json`

Produced by Scout after an onboarding pass over the external repo clone.

```json
{
  "scan_timestamp": "2026-05-28T12:00:00Z",
  "external_repo": "owner/repo",
  "tool_version": "0.1.0",
  "inputs_read": [
    {
      "path": "README.md",
      "sha256": "<hex>",
      "summary": "Main project overview"
    }
  ],
  "proposed_gaps": [
    {
      "title": "EFFECTIVE: add streaming support to SDK",
      "domain": "EFFECTIVE",
      "priority": "P1",
      "effort": "m",
      "confidence": "high",
      "source_of_evidence": {
        "input_path": "README.md",
        "section": "## Roadmap",
        "excerpt": "streaming SSE support planned"
      },
      "acceptance_criteria_draft": [
        "SSE stream iterator returns typed chunks",
        "README updated with streaming example"
      ]
    }
  ]
}
```

Field notes:
- `priority`: one of `P0`, `P1`, `P2`, `P3`
- `effort`: one of `xs`, `s`, `m`, `l` (lowercase)
- `confidence`: one of `high`, `med`, `low` (lowercase)
- `proposed_gaps` is ranked confidence-descending by Scout

---

## Memory — `memory/snapshot-<YYYY-MM-DD>.json`

Periodic health snapshot written by Context-Keeper.

```json
{
  "snapshot_timestamp": "2026-05-28T12:00:00Z",
  "external_repo": "owner/repo",
  "git_head_sha": "abc123def456abc123def456abc123def456abc1",
  "open_issues_count": 7,
  "open_prs_count": 2,
  "last_commit_iso": "2026-05-27T18:30:00Z",
  "last_30d_commit_count": 15,
  "intent_files_present": ["AGENTS.md", "CONTRIBUTING.md"]
}
```

`intent_files_present` lists relative paths of "intent" files found in the
repo root: `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `ROADMAP.md`,
`ARCHITECTURE.md`, etc. An empty list means the repo has no machine-readable
intent.

`delta-<from>-to-<to>.md` is a freeform Markdown diff summary comparing two
snapshot dates (e.g. `delta-2026-05-21-to-2026-05-28.md`). `notes.md` is
hand-edited by the operator; tools never overwrite it.

---

## Signals — `signals/{issues,prs,commits}.jsonl`

Streaming-append JSONL files. One JSON object per line, no blank separators.
Context-Keeper appends events as they arrive (webhook or polling).

### `signals/issues.jsonl`

```json
{"ts":"2026-05-28T12:00:00Z","number":42,"action":"opened","title":"Fix the thing"}
```

`action`: `opened`, `closed`, `reopened`, `commented`, `labeled`

### `signals/prs.jsonl`

```json
{"ts":"2026-05-28T12:00:00Z","number":7,"action":"merged","title":"Add feature X","head_repo":"owner/repo"}
```

`action`: `opened`, `merged`, `closed`, `reviewed`

`head_repo`: `owner/repo` of the fork head (identical to `external_repo` for
same-repo PRs).

### `signals/commits.jsonl`

```json
{"ts":"2026-05-28T12:00:00Z","sha":"abc123","author":"alice","summary":"fix: resolve overflow"}
```

`summary` is the first line of the commit message.

---

## Rust module

`crates/chump-handoff/src/external_repo_schema.rs` provides serde-derived
structs for each schema above plus these helpers:

| Function | Description |
|---|---|
| `save_snapshot(repo_dir, &snap)` | Write snapshot to canonical path |
| `load_snapshot(repo_dir)` | Read most-recent snapshot; `None` if absent |
| `save_scan(repo_dir, &scan)` | Write scan to canonical path |
| `read_latest_scan(repo_dir)` | Read most-recent scan; `None` if absent |
| `append_signal(repo_dir, kind, &event)` | Append one event to the JSONL stream |
| `read_signals(repo_dir, kind)` | Read all events; tolerant of partial lines |
| `read_signals_strict(repo_dir, kind)` | Read all events; error on malformed lines |
| `validate_external_repo_tag(tag)` | Validate `external_repo:<owner>/<repo>` tag |

`SignalKind` enum selects the JSONL file: `Issues`, `Prs`, `Commits`.

---

## Wave 2 dependencies

| Gap | Dependency on this schema |
|---|---|
| INFRA-2112 | `decompose --external-repo` reads `scans/` and uses `ProposedGap` shape |
| INFRA-2113 | Target picker filters `skills_required` against `validate_external_repo_tag` |
| INFRA-2110 | Scout writes `OnboardScan` to `scans/` |
| INFRA-2115 | Context-Keeper appends to `signals/` and writes `RepoSnapshot` |
