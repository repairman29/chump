---
name: verify-existence
description: Before claiming feature/symbol/gap X is missing or broken, verify against runtime state via 4 independent signals
version: 1
platforms: []
metadata: {}
---

# verify-existence

## User story

**As a Filer agent**, when I observe something that looks broken or missing in the codebase,
**I want to verify against runtime state via multiple independent signals before filing a "missing-X" gap**,
**so that I don't waste 30+ minutes of picker time and erode operator trust by filing misdiagnoses**.

## When this skill applies

Trigger this skill whenever you are about to:
- File a gap claiming "feature X is missing / unwired / never implemented"
- Conclude a feature shipped under one gap ID but the gap "doesn't exist"
- Reference a function/route/command in AC that you haven't directly grep-confirmed
- Trust a `... | tail | grep | echo $?` chain as evidence of non-existence

## Procedure

1. **Gap-ID lookup** (only for `DOMAIN-NUMBER` patterns):
   ```bash
   gh search code <ID> --limit 5         # PR + commit subject search
   git log --all --oneline | grep <ID>   # local history search (catches reaped gaps)
   ```
   Reaped gaps will appear in `git log` even when `chump gap show` returns "not found".

2. **Symbol lookup** (functions, structs, traits):
   ```bash
   ast-grep --pattern 'fn $NAME(...)' src/   # AST-aware, ignores comments
   ast-grep --pattern 'struct $NAME' src/    # for types
   ```
   Prefer `ast-grep` over raw `grep` — raw grep matches comments and misses generics.

3. **Runtime surface**:
   - Endpoint? `grep -nE 'route\("/api/X"' src/web_server.rs`
   - Script? `test -x scripts/.../X.sh && echo present`
   - Event kind? `grep -rE '"kind":"<X>"' src/ scripts/` AND check `docs/observability/EVENT_REGISTRY.yaml`
   - Subcommand? `chump --help | grep <name>` (but verify binary is fresh — see Pitfalls)

4. **One-shot helper**:
   ```bash
   scripts/dev/verify-existence.sh <ID-or-symbol>   # runs all 4 checks, returns tri-state
   ```
   Returns `confirmed_shipped` | `confirmed_absent` | `ambiguous`. **Only file "missing" gaps on confirmed_absent.**

## Pitfalls

### Pitfall 1: `chump gap show` returns "not found" for shipped+reaped gaps
**Cautionary case**: [INFRA-1575](docs/gaps/INFRA-1575.yaml) (2026-05-16). An agent filed a P1 gap claiming 10 A2A implementation gaps were missing from the registry. All 10 had shipped (PRs #1900, #1960, #1967, #1969, #1972, #1991, #1992, #1994, #1997, #1998, #2004) and were reaped from the active state.db after closure. `chump gap show INFRA-1296` returns the same "not found" for typos AND for reaped gaps. **Always cross-check with `git log --all | grep <ID>`.** ([INFRA-1582](docs/gaps/INFRA-1582.yaml) will fix the CLI to distinguish.)

### Pitfall 2: Stale binary returns wrong feature surface
**Cautionary case**: same session, fleet doctor check. `chump fleet doctor --help` returned the parent usage page on a local install. I almost concluded the subcommand didn't exist. Reality: `/opt/homebrew/bin/chump` was built 2026-05-15, the feature merged 2026-05-17 via PR #2184. **Before claiming a CLI feature is missing, verify with `chump --version` against `git show origin/main --stat` for the implementing commit's date.**

### Pitfall 3: Pipe swallows exit code
```bash
chump health --slo-check | tail -5   # this is what tail returned, not chump
echo $?                              # → 0 (misleading)
```
**Always redirect to `/dev/null` before reading `$?` for exit-code claims:**
```bash
chump health --slo-check >/dev/null 2>&1; echo $?
```

### Pitfall 4: PR title ≠ what shipped
PR #2264 title was `feat(INFRA-1427): chump fleet doctor --strict`. Its commits were `ci: retrigger` only — the actual feature shipped earlier via PR #2184. **Check `gh pr view <N> --json files,commits`, don't trust the title.**

## Verification (how to know this skill worked)

- The gap you filed survives 24h without being closed as a misdiagnosis
- The picker agent that claims the gap doesn't immediately mark its AC criterion 1 as "file doesn't exist"
- Cross-checks the result of `verify-existence.sh`: a `confirmed_shipped` result blocked you from filing → success

## Outcome recording

```
skill_manage(action=record_outcome, name=verify-existence, success=true)
```

Call `success=true` when:
- You used this skill to BLOCK a false-positive filing (most valuable case)
- You filed a "missing X" gap that survived 24h

Call `success=false` when:
- You filed a misdiagnosis despite applying this skill (procedure was flawed for your case — file a patch)
- The 4 checks returned `confirmed_shipped` but you filed anyway (operator override case — record so future agents see the override pattern)

## Cross-references

- **Discipline rule**: [AGENTS.md "Filing meta-patterns" Behaviour 4](../../../AGENTS.md)
- **Helper script**: [scripts/dev/verify-existence.sh](../../../scripts/dev/verify-existence.sh)
- **Future tooling**: [INFRA-1583](docs/gaps/INFRA-1583.yaml) (chump-mcp-code) will replace these CLI calls with structured MCP tools
- **Same-class precedents**: INFRA-1575 (A2A), INFRA-1560 (fleet doctor), INFRA-238 (origin/main divergence)
