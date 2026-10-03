# Rust-first vs. shell-OK (META-064)

Moved out of `AGENTS.md` / `CLAUDE.md` by ZERO-WASTE-125 (rulebook line-budget cut).

When you reach for `nano scripts/coord/foo.sh`, check the criteria first.
The codebase has shipped 16k+ LOC of "this was shell, now we port it to
Rust" gaps in the last quarter. Most could have been Rust from day 1.

**Rust-first IF *any* of these hold:**
- Mutates canonical state: `state.db`, `.chump-locks/*.json`, `ambient.jsonl`, `docs/gaps/*.yaml`
- Called from a hot path: `worker.sh` per-cycle, `bot-merge.sh` per-ship, every claim
- Shares a process boundary with a Rust caller (subprocess-race candidate)
- Will outlive 3 months (durable tooling)
- > 200 LOC at first commit

**Shell is OK IF *all* of these hold:**
- Glue between existing CLI tools (`gh` + `git` + `jq`)
- One-shot or exploratory
- < 200 LOC, no state mutation
- No regression-test maintenance burden

**Bypass:** for legitimate shell that meets Rust-first criteria (e.g. a
30-line glue shim), add to the commit body trailer:
```
Rust-First-Bypass: <one-sentence reason>
```
Enforced by `scripts/git-hooks/pre-commit-rust-first.sh`; bypass goes
into the audit log.

Sibling rules: [`REDUNDANCY_PREVENTION.md`](./REDUNDANCY_PREVENTION.md) (META-063).
