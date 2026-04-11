# Capability checklist: how to test Chump and judge real results

Use this as a **layered** validation ladder. No single check proves “full capability”; combine the layers that match your goal. Deeper detail: [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md), [ROAD_TEST_VALIDATION.md](ROAD_TEST_VALIDATION.md), [BATTLE_QA.md](BATTLE_QA.md), [OPERATIONS.md](OPERATIONS.md).

## 1. CI-style gates (code health)

From repo root:

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
bash scripts/verify-external-golden-path.sh
```

These match [.github/workflows/ci.yml](../.github/workflows/ci.yml). They prove compile/test invariants, not live model quality.

## 2. Golden path (first real inference)

1. Ollama on `11434`, model pulled (e.g. `qwen2.5:7b`).
2. Web: `./run-web.sh` → open `http://127.0.0.1:3000` → `curl -s http://127.0.0.1:3000/api/health`. On Mac, **ChumpMenu → Chat** uses the same `POST /api/chat` API (no Discord).
3. CLI: `OPENAI_API_BASE=http://127.0.0.1:11434/v1 OPENAI_API_KEY=ollama OPENAI_MODEL=qwen2.5:7b ./target/release/chump --chump "Reply in one word: what is 2+2?"` (or `cargo run -- …`).

See [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md).

## 3. Battle QA (breadth / regression)

- **Smoke:** `BATTLE_QA_MAX=25 ./scripts/battle-qa.sh` (or `50`).
- **Full suite:** `./scripts/battle-qa.sh` (500 queries; long).
- **Until green:** `BATTLE_QA_ITERATIONS=5 ./scripts/battle-qa.sh`.

**Inference env:** The script sources `.env`. If you **export `OPENAI_API_BASE`, `OPENAI_API_KEY`, or `OPENAI_MODEL` in the shell before** running the script, those values **override** `.env` for that run (explicit one-off / CI).

**Triage failures:** Read `logs/battle-qa-failures.txt` and `logs/battle-qa.log`. Categories and fixes: [BATTLE_QA_FAILURES.md](BATTLE_QA_FAILURES.md).

**Alternate stack:** `./scripts/run-tests-with-config.sh default battle-qa.sh` or `max_m4 battle-qa.sh` — [BATTLE_QA.md](BATTLE_QA.md).

## 4. Consciousness stack (metrics + exercise battery)

- **Snapshot:** `./scripts/consciousness-baseline.sh` → `logs/consciousness-baseline.json`.
- **Report:** `./scripts/consciousness-report.sh` and `./scripts/consciousness-report.sh --json`.
- **28-prompt battery:** `./scripts/consciousness-exercise.sh` (optional `CHUMP_EXERCISE_MODEL`, `CHUMP_EXERCISE_TIMEOUT`). Compare before/after baselines per [ROAD_TEST_VALIDATION.md](ROAD_TEST_VALIDATION.md).
- **Mini A/B:** `./scripts/consciousness-ab-mini.sh`.

If many steps show `TIMEOUT`, raise `CHUMP_EXERCISE_TIMEOUT` or use a faster local model; heavy parallel load on the host can starve Ollama.

## 5. Manual scenarios (what *your* Chump can do)

Run these on **web PWA** or **Discord** with real `.env` (tokens, `CHUMP_REPO`, brain path as you use them). Check success by eye: correct tool use, sensible answer, no silent errors.

| # | Scenario | What to verify |
|---|----------|----------------|
| 1 | “Use calculator: what is 17 × 23?” | Tool path + numeric answer. |
| 2 | “Remember: [unique phrase]. Confirm you stored it.” then later “Recall [phrase].” | `memory` store + recall. |
| 3 | “Read `README.md` (or `src/main.rs`) and summarize the first section in two sentences.” | `read_file`, path sane. |
| 4 | “List files in `src/` and name three modules.” | `list_dir` + accuracy. |
| 5 | “Create a task: title=… notes=… then list my open tasks.” | `task` create + list. |
| 6 | “Log an episode: summary=… sentiment=win tags=test” then “Show recent episodes.” | `episode` + DB. |
| 7 | “What is `git rev-parse --short HEAD` in this repo?” (with `CHUMP_REPO` set) | `run_cli` or git tool, safe command. |
| 8 | If `GITHUB_TOKEN` is set: “List open issues on [your repo] (limit 3).” | GitHub tools + rate limits. |
| 9 | If delegate/Cursor configured: “Use Cursor to …” (narrow prompt) | [CURSOR_CLI_INTEGRATION.md](CURSOR_CLI_INTEGRATION.md) path. |
|10 | Multi-turn: reference something from turn 1 in turn 3 without repeating the full text. | Session + context assembly. |

Discord-specific: set `CHUMP_HEALTH_PORT` and poll `GET /health` while testing — [ROAD_TEST_VALIDATION.md](ROAD_TEST_VALIDATION.md).

## 6. Discovery factory (Wave 3 scripts)

Read-only helpers (no model): [PRODUCT_ROADMAP_CHIEF_OF_STAFF.md](PRODUCT_ROADMAP_CHIEF_OF_STAFF.md) wave 3.

```bash
./scripts/golden-path-timing.sh
./scripts/repo-health-sweep.sh
CHUMP_TRIAGE_REPO=owner/name ./scripts/github-triage-snapshot.sh
./scripts/ci-failure-digest.sh logs/some-ci-log.txt
```

Details: [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) (timing), triage script header comments for env vars.

**Dedupe / autofix:** `CI_FAILURE_DEDUPE_FILE` (default `logs/ci-failure-dedupe.tsv`), `CI_FAILURE_DEDUPE=0` to disable, `--no-dedupe` on digest. `REPO_HEALTH_AUTOFIX=1` on repo-health (chmod `scripts/*.sh` only).

## 7. Adjacent products (Wave 4)

- **Validate:** [PROBLEM_VALIDATION_CHECKLIST.md](PROBLEM_VALIDATION_CHECKLIST.md)
- **Scaffold:** `./scripts/scaffold-side-repo.sh /path/to/new-repo "Name" [--git]`
- **Portfolio:** copy [templates/cos-portfolio.md](templates/cos-portfolio.md) → `cos/portfolio.md` in brain
- **Quarterly memo:** `./scripts/quarterly-cos-memo.sh` → `logs/cos-quarterly-YYYY-Qn.md`

## What “good” looks like

- **Shipping health:** CI gates + golden path + small Battle QA smoke green.
- **Model + tools at scale:** High pass rate on full Battle QA with the same model/profile you run in production; investigate failures by category.
- **Your workflow:** Manual table above passes for the integrations you actually enable.
