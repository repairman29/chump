# Code intelligence — verify before you claim something is missing

> INFRA-1583 (`chump-mcp-code`), INFRA-8080 (this doc + the regression test).
> Cautionary precedents: **INFRA-1575** (10 shipped A2A gaps declared "missing"),
> **INFRA-238** (a stale local tree misread as a revert on `origin/main`).

An empty lookup is not evidence of absence. Two failures have cost real time:

- `chump gap show <ID>` prints the same "not found" for a typo and for a gap whose
  registry row was **reaped** after it shipped. INFRA-1575 filed a P1 claiming ten
  A2A gaps were missing; all ten had merged.
- A stale local checkout looks like `origin/main` reverted your change (INFRA-238).

`chump-mcp-code` turns the existence checks into one structured call each, with
answers that cannot be mistaken for "nothing there".

## Tool surface

The server is `crates/mcp-servers/chump-mcp-code` (JSON-RPC 2.0 over stdio, same shape
as `chump-mcp-gaps`). Set `CHUMP_REPO`, build the index once with
`chump-mcp-code index --all`; a post-commit hook keeps it fresh incrementally.

| Tool | Question it answers | Response |
|---|---|---|
| `code.find_symbol { name, kind? }` | Does this function/struct/class exist, and where? | `{ symbol, exists, count, matches[{path,name,kind,line,language}] }` |
| `code.callers_of { symbol, limit? }` | Is it actually used? Who calls it? | `{ symbol, defined, count, truncated, callers[{path,line,text,in_symbol}] }` |
| `code.gap_history { gap_id }` | Did this gap exist, and did it ship? | `{ gap_id, status, title, shipped_pr, closed_date, reaped_date }` |
| `code.trait_impls { trait, limit? }` | Who implements this trait? | `{ trait, defined, count, truncated, impls[{path,line,type,kind,language}] }` |
| `code.symbol_history { symbol, limit? }` | When did this symbol appear / disappear? | `{ symbol, count, truncated, first_seen, last_changed, commits[{sha,date,subject}] }` |
| `code.dead_code_scan { reasons?, limit? }` | What looks dead? | `{ count, total, truncated, by_reason, findings[{symbol,file,line,location,reason,kind}] }` with `reason` one of `no_callers`, `no_emitters`, `registered_unused_route` (heuristic; verify before deleting) |
| `search_symbols`, `file_symbols`, `index_stats`, `reindex` | General index queries | see the crate README |

`code.gap_history.status` is one of:

| status | meaning |
|---|---|
| `open` | registry row exists, not closed |
| `done` | registry row exists and is closed; `shipped_pr` and `closed_date` are set |
| `reaped` | **no registry row, but git history mentions the id**: it existed. `reaped_date` is the latest such commit, `shipped_pr` comes from its trailing `(#N)` |
| `never_existed` | no registry row and no commit mentions it: safe to say it was never real |

`callers_of` is a textual call-pattern scan (tree-sitter indexes definitions, not
references), so treat `count: 0` on a `defined: true` symbol as "no call sites found in
indexed Rust/bash/Python", not as proof of dead code.

## The rule: verify before a missing-claim

Before you file a gap, an RCA, or a message that says **"X is missing / never shipped /
reverted / not implemented"**, you must have run the runtime check that would have
found it, and cite the result:

1. **A gap id** → `code.gap_history <ID>`. Only `never_existed` supports "never existed".
   `reaped` or `done` means it shipped: link `shipped_pr` instead of re-filing.
2. **A symbol or feature** → `code.find_symbol <name>`; if it exists, `code.callers_of`
   tells you whether it is wired in.
3. **A file/state divergence** → `git fetch origin main && git show origin/main:<path>`
   (AGENTS.md, "Diagnosing divergence").
4. If the tools are unavailable, `scripts/dev/verify-existence.sh <ID-or-symbol>` runs the
   equivalent shell checks.

A lookup that returns nothing, with no second check, is the failure this rule exists to stop.

## Worked example — the A2A scenario (INFRA-1575)

An agent audits the A2A chain and runs `chump gap show INFRA-1297`. Output: *not found*.
It files "INFRA-1297 is missing from the registry". The correct sequence:

```jsonc
// 1. Was the gap ever real, and did it ship?
{"jsonrpc":"2.0","method":"code.gap_history","params":{"gap_id":"INFRA-1297"},"id":1}
// -> {"gap_id":"INFRA-1297","status":"reaped","shipped_pr":1960,"reaped_date":"2026-05-14", ...}
//    reaped = row gone but git history proves it existed; it shipped in PR #1960.

// 2. Is the feature actually on main?
{"jsonrpc":"2.0","method":"code.find_symbol","params":{"name":"broadcast"},"id":2}
// -> {"exists":true,"matches":[{"path":"scripts/coord/broadcast.sh","kind":"fn", ...}]}

// 3. Is it wired in?
{"jsonrpc":"2.0","method":"code.callers_of","params":{"symbol":"broadcast"},"id":3}
// -> {"defined":true,"count":3,"callers":[...]}
```

(Values are illustrative.) Three calls, and the claim "missing" is refuted before any gap is filed. For a gap still in
the registry (INFRA-1296 here) step 1 returns `status: "done"` with `shipped_pr: 1900`.

`scripts/ci/test-misdiagnosis-prevention.sh` replays exactly this scenario against a
throwaway repo on every CI run, so the tooling stays load-bearing.

## Related

- AGENTS.md — "Runtime verification before a missing-claim" and "Diagnosing divergence".
- `skills-bundle/verify-existence/SKILL.md` — the same discipline as an agent skill.
- `crates/mcp-servers/chump-mcp-code/README.md` — response shapes and index details.
