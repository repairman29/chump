# Merge Drivers (INFRA-310 / INFRA-1389)

Chump uses custom git merge drivers so concurrent PRs that make independent
additive changes to the same file don't produce conflict markers.

## Why this matters

During active fleet sprints, 3-8 agents work simultaneously. Many file edits
are purely additive — each agent adds a new entry to a list-structured file.
Git's default 3-way merge sees two adjacent-line insertions as a conflict even
though they don't logically overlap. The drivers below resolve this
automatically, keeping PRs green without human intervention.

## Covered files (hot-file registry)

| File | Driver | Strategy |
|---|---|---|
| `.github/workflows/ci.yml` | `ci-yml-add-row` | Pure-append check + step-body validation |
| `docs/observability/EVENT_REGISTRY.yaml` | `union` (git built-in) | Unique-line union |
| `scripts/ci/env-vars-internal.txt` | `union` (git built-in) | Unique-line union |
| `web/v2/index.html` | `union` (git built-in) | Unique-line union |
| `scripts/git-hooks/pre-commit` | `pre-commit-add-guard` | Append guard blocks |
| `docs/gaps/*.yaml` | `gap-yaml-add-line` | Take ours (newest state) |
| `.chump/state.sql` | `chump-state-sql-regen` | Regenerate from canonical SQLite |
| `Cargo.toml` | `cargo-toml-append` (→ `merge-driver-append-only.sh`) | Pure-append + dedup |
| `web/v2/app.js` | `js-append` (→ `merge-driver-append-only.sh`) | Pure-append + dedup |
| `src/main.rs` | `rust-main-append` (→ `merge-driver-append-only.sh`) | Pure-append + dedup |

## How the append-only driver works

`scripts/git/merge-driver-append-only.sh` handles all three INFRA-1389 files:

1. **Pure-append check**: verifies both branches start with the ancestor verbatim
   (no edits to the shared prefix). If either branch edited existing lines → exits 1
   (falls back to git's standard 3-way merge, which produces conflict markers).

2. **Tail extraction**: takes the lines theirs appended beyond the ancestor length.

3. **Deduplication**: filters out any theirs-tail lines already present in ours,
   preserving original append order. Prevents double-registration when two PRs
   independently add the same dependency (`serde = "1"`).

4. **Append**: writes the unique new lines to the end of ours.

**When it doesn't help (and shouldn't):** if two PRs both _edit_ the same line
(e.g., changing a dependency version), the driver correctly declines and lets
git mark the conflict for human resolution.

## What qualifies as append-only

A file is append-only with respect to a merge driver when:

- Each PR adds **new structural units** at the end (new dep line, new component
  class, new route arm, new event kind).
- No PR **removes or rewrites** existing entries in the shared section.
- The file has a clear structural delimiter that makes "new unit" detectable.

If a file stops being append-only (e.g., a PR that renames a dependency),
the driver exits 1 and git falls through to standard conflict resolution.

## Adding a new append-only file

1. Verify the file genuinely follows the append-only pattern.
2. Add a `.gitattributes` entry:
   ```
   path/to/file merge=my-driver-name
   ```
3. Add registration to `scripts/setup/install-merge-drivers.sh`:
   ```bash
   git config "merge.my-driver-name.name" "Description (INFRA-XXXX)"
   git config "merge.my-driver-name.driver" "scripts/git/merge-driver-append-only.sh %O %A %B %L"
   ```
4. Add a synthetic conflict simulation to `scripts/ci/test-merge-driver-coverage.sh`.
5. Document it in this file (the table above).

## Installation

Drivers are registered per-checkout in `.git/config` (not committed, per git
convention). They are auto-installed via:

```bash
bash scripts/setup/install-merge-drivers.sh
```

This is called automatically by `scripts/setup/install-hooks.sh` (which runs
on `post-checkout` and as part of `chump claim`). Manual verification:

```bash
git config --get-regexp '^merge\.' | grep -E 'driver|name'
```

## CI gate

`scripts/ci/test-merge-driver-coverage.sh` runs as part of the CI `test` job.
It asserts every hot file has a driver registered and simulates synthetic
append-only conflicts on each file to verify auto-resolution.
