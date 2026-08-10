# almanac-audit.py — depth ledger (CREDIBLE-209)

Shop rule #8: **green ≠ covered.** This ledger names the depth tier AND the
gaps of `scripts/dev/almanac-audit.py`, the textual half of the bullshit boss
(sibling: `scripts/dev/capability-drift-scan.py` for the code-tree half).
Updated in the same commit as the tool it describes.

Tiers: D1 smoke · D2 happy path (verdict asserted, not just "didn't crash") ·
D3 edges · D4 adversarial.

## What it does

`python3 scripts/dev/almanac-audit.py <repo> [--json] [--llm]` extracts
checkable claims from a repo's README (backtick code-spans → `symbol`
claims, capability-verb sentences → `capability` claims) and grounds each
against that repo's own Almanac index (`~/.almanac/indexes/<repo>.db`):
`symbol` claims are exact/substring lookups against `files`/`symbols`;
`capability` claims look for a matching implementation symbol AND a matching
test symbol, verdicting `grounded` (both), `unverifiable` (impl only, no
test evidence), or `ungrounded` (neither). Zero network calls in the default
path — index lookups are local sqlite; `--llm` is the only path that talks
to anything off-disk, and that's `127.0.0.1:11434` (local Ollama), never a
remote host, and fails open to the regex-only claim set on any error.

## Depth

| Surface | Depth | What it actually proves | Gaps (named, not vibes) |
|---|---|---|---|
| `scripts/ci/test-almanac-audit.sh` (6 assertions, synthetic fixture repo + hand-built sqlite index, no network/Ollama dependency) | D2–D3 | exact symbol claim → grounded with a real `path:line` citation; capability claim with impl+test symbols → grounded; capability claim with impl but NO test symbol → unverifiable; capability claim with NO matching symbol at all (the "enterprise platform" shape from AC2 — a claim naming a capability the codebase doesn't implement) → ungrounded; an unindexed repo name reports a clean `error` field instead of crashing (MISSION-045: signal, not a gate, exit 0 always) | `--llm` augmentation path is entirely untested in CI (by design — it needs a live Ollama, so it's opt-in and best-effort, but that also means a broken JSON-parse branch could regress silently); the test is not yet wired into `.github/workflows/ci.yml` (matches the precedent of `test-capability-drift-scan.sh`, also unwired) — a real gap, filed as a follow-up rather than papered over here |
| Manual run against the `almanac` repo's own live index (`~/.almanac/indexes/almanac.db`, 79 files) | D2 (real-world smoke) | tool runs clean against a real, densely-cross-referenced README: 75 claims extracted, 44 grounded with real citations (e.g. `--min <pct>` → `crates/almanac-core/src/coverage.rs:80`), 0 crashes | 31/75 ungrounded on this run are a **mix** of true negatives (nothing in the codebase implements `fallback_reason` as a named symbol) and heuristic false negatives (env-var names like `ALMANAC_DB`, MCP tool names like `almanac_search` that exist as string literals/JSON-RPC names rather than indexed Rust symbols) — the `symbols` table only carries function/struct/etc. definitions, not arbitrary string literals, so anything grounded only by string match is invisible to this tool. This is a known, documented precision ceiling, not a bug: it means "ungrounded" is a **prompt to investigate**, not a proof of falsehood (mirrors `capability-drift-scan.py`'s exit-0-always design) |
| AC2 (run against BEAST-MODE, flag "enterprise-platform"-class claims ungrounded) | **not run** — no `repairman29/BEAST-MODE` Almanac index exists in this dev environment | the synthetic fixture test above proves the exact mechanism AC2 exercises (an unimplemented capability claim → `ungrounded`) using a deliberately BEAST-MODE-shaped claim ("enterprise platform for orchestrating everything") | this is a real gap: nobody has run `almanac-audit.py BEAST-MODE --json` against a live BEAST-MODE index and eyeballed the output. Follow-up: once `chump onboard`/harvester indexes BEAST-MODE locally, run it for real and fold the actual output into this ledger — do not treat the synthetic-fixture proof as a substitute forever |

## Honest state

The mechanism (extract → ground against the repo's OWN index → grounded /
ungrounded / unverifiable with citations) is real and CI-proven on synthetic
fixtures — all three verdicts asserted, including the BEAST-MODE-shaped
ungrounded case — plus manually verified against a live 79-file index.
What's **not** proven yet: (a) AC2's literal BEAST-MODE run (no local index
for that repo exists in this environment), (b) `--llm` augmentation is fully
best-effort/manual, (c) the CI test isn't wired into `ci.yml` yet. Raising
the floor means running the real BEAST-MODE pass once that index exists and
wiring the test into CI — not adding more grounding heuristics on top of an
unverified base.
