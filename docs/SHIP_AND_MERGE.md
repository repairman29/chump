# Ship, merge, and CI (operator playbook)

**Goal:** Every change that lands on **`main`** matches what CI enforces, stays reviewable, and keeps deployment paths predictable.

## Non-negotiables (match CI before you push)

From repo root (also in [CONTRIBUTING.md](../CONTRIBUTING.md)):

```bash
cargo fmt --all -- --check
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
```

CI additionally runs Node checks on `web/`, Playwright PWA, battle sim, golden path timing, and Tauri WebDriver on Ubuntu—see [.github/workflows/ci.yml](../.github/workflows/ci.yml).

## Pull requests

- **Base branch:** `main` (or `master` if that is the default in a fork).
- **Title:** Prefer a **single sentence** that states user-visible or system outcome. Optional prefix style: `feat:`, `fix:`, `docs:`, `chore:` — helps humans scan history; not enforced by tooling.
- **Body:** Use the [PR template](../.github/pull_request_template.md); link a roadmap line or issue when the change is tracked work.
- **Size:** Prefer smaller PRs. If a change is large, split by **mergeable slice** (tests green on each slice).

## Merge strategy (this repo)

- **Default:** **Squash merge** is recommended for agent-heavy or noisy histories so `main` stays a readable sequence of one-commit features.
- **Merge commit:** Acceptable for multi-author work that should preserve branch topology; avoid if it bundles unrelated changes.
- **Rebase + merge:** Fine when the PR branch is already linear and each commit is meaningful.

Pick one style per repo in GitHub **Settings → General → Pull Requests** and stick to it.

## GitHub branch protection (recommended)

Enable on `main`:

- Require PR before merging
- Require status checks to pass (**CI** workflow; add **Tauri desktop** / **mistralrs** if those gates matter for your org)
- Require branches to be up to date before merge (or use **merge queue** below)
- Block force pushes

## Merge queue (optional, “world class” at scale)

If the repo enables **GitHub Merge queue**, CI already listens for `merge_group` so queued entries run the same checks. Enable in repo settings when concurrent PR volume makes “update branch + race CI” painful.

## After merge

- **Operators:** follow [OPERATIONS.md](OPERATIONS.md) for heartbeats, roles, and health checks.
- **Desktop bundle:** path-filtered workflow [.github/workflows/tauri-desktop.yml](../.github/workflows/tauri-desktop.yml) builds on pushes that touch `desktop/`, `web/`, or agent `src/`.

## Retiring experiments

Do not leave dead remote branches as implied “active lines.” Document them in [archive/SUPERSEDED_BRANCHES.md](archive/SUPERSEDED_BRANCHES.md), then tag with [`scripts/archive-superseded-branch.sh`](../scripts/archive-superseded-branch.sh) before optional `git push origin --delete …`. Runtime tarball policy: [STORAGE_AND_ARCHIVE.md](STORAGE_AND_ARCHIVE.md).
