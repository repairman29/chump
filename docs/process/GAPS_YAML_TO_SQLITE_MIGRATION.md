---
doc_tag: archive-candidate
owner_gap:
last_audited: 2026-04-25
---

# Gap System Migration: YAML → SQLite-Authoritative

**Date:** 2026-04-24  
**Current State:** YAML-authoritative + SQLite shadow (INFRA-023 bolted on)  
**Question:** Can we flip to SQLite as source of truth and retire YAML?  
**TL;DR:** **YES, with minimal breakage.** Claims are already in JSON. Status/metadata can move to SQLite. Costs: enforce CLI-only mutations, auto-export for git diffs, fix 3 shell scripts.

---

## Current State (Audit)

### Layer 1: Claims (ALREADY decoupled from YAML) ✅

**How:** `.chump-locks/<session>.json` lease files  
**Operations:** `gap-claim.sh` writes, `gap-preflight.sh` reads  
**Status:** ROBUST — zero merge conflicts, auto-expire, session-scoped  
**Breaking gap-claim.sh:** This layer will NOT break on any migration (it doesn't touch YAML)

```
gap-claim.sh GAP-001 --paths src/foo.rs
→ writes .chump-locks/<session>.json {"gap_id":"GAP-001","paths":"...","claimed_at":"..."}
→ YAML untouched
```

### Layer 2: Status + Metadata (currently YAML, proposed move to SQLite)

**Current home:** `docs/gaps.yaml`  
**Operations:**
- `gap-preflight.sh` reads (`status: done` check)
- `gap-reserve.sh` appends new gaps (`status: open`)
- `bot-merge.sh` writes (`status: done`, `closed_date`, `closed_commit`)
- Manual edits during PRs (user fills `description`, `acceptance_criteria`, etc.)
- Pre-commit guard validates (gaps.yaml discipline check)

**Current flow:**
```bash
gap-reserve.sh INFRA "title"
→ Appends new entry to docs/gaps.yaml
→ User edits YAML manually to add description, effort, etc.
→ git commit (pre-commit guard validates)
→ `chump gap import` syncs YAML → SQLite (one-way)
```

### Layer 3: Runtime DB (SQLite, optional)

**Current home:** `.chump/state.db`  
**How:** Hand-synced from YAML via `chump gap import`  
**Operations:** `chump gap list`, `chump gap reserve` (new SQL path)  
**Status:** INCOMPLETE — `chump gap` CLI exists but shell scripts still use YAML

---

## Breakage Analysis: YAML → SQLite Flip

### ❌ WILL BREAK

#### 1. `gap-preflight.sh` reads YAML, ignores SQLite
**Impact:** Medium (coordination gate doesn't work)  
**Fix:** Change line 64 from:
```bash
GAPS_YAML_REMOTE="$(git show "$REMOTE/$BASE:docs/gaps.yaml" 2>/dev/null || echo "")"
```
To:
```bash
# Query SQLite via: chump gap list --json --remote=$REMOTE --base=$BASE
# (requires new flag support in chump binary)
```
**Alternative (simpler):** Keep reading YAML, but YAML is now an export of SQLite (read-only view).

#### 2. `gap-reserve.sh` appends to YAML, not to SQLite
**Impact:** High (new gaps don't sync)  
**Fix:** Remove shell script, teach `chump gap reserve` to handle the same logic.
**Current `gap-reserve.sh`:** appends to YAML + writes pending_new_gap to lease file  
**Proposed:** `chump gap reserve --domain INFRA --title "..."` does both atomically

#### 3. Manual YAML edits during gap creation
**Impact:** Medium (workflow friction)  
**Current:** User runs `gap-reserve.sh`, then manually edits YAML to fill `description`, `effort`, etc.  
**Fix:** Either:
  - Option A: `chump gap update <GAP-ID> --description "..." --effort s` (more CLI, less friction)
  - Option B: Keep YAML as human-editable view, auto-export to SQL before each commit

#### 4. Pre-commit guard validates YAML, not SQLite
**Impact:** Low (guard logic can adapt)  
**Fix:** Pre-commit hook runs `chump gap preflight <staged-gap-ids>` instead of parsing YAML  
**Risk:** Performance (CLI invocation per commit) — but acceptable if memoized

#### 5. Git diffs show YAML, but source of truth is binary .db
**Impact:** High (PR review blind spot)  
**Current state:** Users see gap changes in `git diff docs/gaps.yaml`  
**With SQLite:** Users see nothing unless we export  
**Fix:** Auto-run `chump gap dump --out .chump/state.sql` in pre-commit, commit both `.db` and `.sql`  
**Cost:** Every gap change creates 2 commits (or 1 commit + 2 files). Humans review `.sql`, ignore `.db`.

#### 6. Offline workflows (no network)
**Impact:** Low (edge case)  
**Current:** `gap-preflight.sh` falls back to local YAML if fetch fails  
**With SQLite:** `.chump/state.db` is local, no fallback needed  
**Fix:** Zero breakage — SQLite is faster offline

---

### ✅ WILL NOT BREAK

#### 1. Lease files (claims in `.chump-locks/`) — unchanged
No change to lease mechanism. Claims stay in JSON.

#### 2. Session ID resolution (CHUMP_SESSION_ID env vars)
Unaffected. Lease files still work the same.

#### 3. Lease collision checks (pre-commit guard #1)
Unaffected. Still reads `.chump-locks/*.json`.

#### 4. Worktree hygiene
Unaffected. Stale worktree reaper reads lease files.

#### 5. Merge queue discipline (atomic PRs)
Unaffected. Still enforces one gap per PR via application logic (not YAML).

#### 6. Dual-gap protection (blocking done gaps from being re-used)
Current: `gap-preflight.sh` checks if gap is `status: done` in YAML  
Migrated: Same check runs against SQLite  
Breakage: None — just a data-source change

---

## Migration Cost Estimate

| Item | Effort | Risk | Notes |
|------|--------|------|-------|
| Teach `chump gap reserve` to write SQLite | s | low | Already partially done (INFRA-023) |
| Update `gap-preflight.sh` to read SQLite | s | low | Simple query swap |
| Retire `gap-reserve.sh` shell script | xs | low | Delete 80 lines |
| Update `bot-merge.sh` to call `chump gap ship` | s | medium | Must handle atomicity correctly |
| Auto-export `.sql` in pre-commit | s | low | One extra `chump gap dump` call |
| Add `--paths` support to `chump gap claim` | xs | low | Already in shell version |
| Update CLAUDE.md docs | xs | low | Update 3–4 sections |
| Update `.github/workflows` (if any YAML refs) | xs | low | Remove YAML path triggers if any |

**Total:** ~1.5–2 weeks for a single engineer. Can be parallelized (CLI + migration + docs in parallel).

---

## Migration Path: Phased Approach

### Phase 1: Tooling Completeness (Week 1)

**Goal:** `chump gap` CLI fully handles all operations.

**Work:**
- ✅ `chump gap import` — YAML → SQLite (done, INFRA-023)
- ❓ `chump gap reserve` — creates new gap with pending_new_gap in lease (partially done?)
- ❓ `chump gap claim` — alias for gap-claim.sh logic (verify exists)
- ❓ `chump gap ship` — set status: done + closed_date + closed_commit (partially done?)
- ❓ `chump gap list --json --remote origin --base main` — supports remote check (new?)

**Validation:**
```bash
# Can I do everything via chump gap CLI?
chump gap reserve --domain INFRA --title "test"   # → gap ID returned
chump gap claim INFRA-999 --paths src/foo.rs      # → lease created
chump gap ship INFRA-999                           # → status: done
chump gap list --json --status open               # → all open gaps
```

### Phase 2: Tool Migration (Week 1.5)

**Goal:** Shell scripts read from SQLite, not YAML.

**Work:**
1. Update `gap-preflight.sh` — swap YAML read for `chump gap list --json`
2. Delete `gap-reserve.sh` — all logic moves to `chump gap reserve`
3. Update `bot-merge.sh` — call `chump gap ship` instead of YAML mutation
4. Update pre-commit guard — call `chump gap preflight` instead of parsing YAML

**Validation:**
```bash
# gap-preflight still works?
scripts/coord/gap-preflight.sh INFRA-999
# exit 0 if available, 1 if done/claimed

# gap-claim still works?
scripts/coord/gap-claim.sh INFRA-999 --paths src/foo.rs
# .chump-locks/<session>.json created

# New gaps created via CLI?
chump gap reserve --domain INFRA --title "..." 
# → new gap in SQLite (no YAML edit)
```

### Phase 3: Git Diff Story (Week 2)

**Goal:** PR reviewers see gap changes via `.sql` export.

**Work:**
1. Add `chump gap dump --out .chump/state.sql` to pre-commit hook
2. Update `.gitignore` to **ignore** `.chump/state.db` (binary, untrackable)
3. Track `.chump/state.sql` in git (readable SQL)
4. Update CLAUDE.md: "Commit both when gap changes — humans review `.sql`, ignore `.db`"

**Validation:**
```bash
# Does pre-commit auto-export?
echo "gap change..." && git add docs/gaps.yaml
git commit -m "test"
# → .chump/state.sql auto-updated and staged

# Can we revert a PR with SQL diffs?
git revert <PR> && git push
# → .chump/state.sql reverted, .db rebuilt on next import
```

### Phase 4: Documentation + Cleanup (Week 2)

**Work:**
1. Update CLAUDE.md: remove YAML edit workflow, document `chump gap` CLI workflow
2. Update docs/gaps.yaml header comment (mark as export-only)
3. Delete `scripts/coord/gap-reserve.sh` (superseded by `chump gap reserve`)
4. Add recovery playbook: "SQLite .db corrupted? Run `chump gap import` from .sql"

**Result:** CLAUDE.md gap-creation flow is now:
```bash
# NEW workflow
chump gap reserve --domain INFRA --title "Fix X"      # → INFRA-999 created
chump gap update INFRA-999 --description "..." --effort s
git add docs/.chump/state.sql && git commit ...

# OLD workflow (retired)
gap-reserve.sh INFRA "Fix X"                           # → deleted
# [manual YAML edit]                                    # → deleted
git add docs/gaps.yaml && git commit ...
```

---

## Rollback Plan

If Phase 1–2 break something, rollback is simple:

1. Revert commits that change shell scripts
2. Set `CHUMP_GAPS_LOCK=0 chump gap import` to re-sync YAML from SQL (or vice versa)
3. Re-enable YAML as source of truth by reverting pre-commit logic

**Lowest risk:** Keep both paths for 1 release (dual-read from YAML and SQL, writes go to both). Then retire YAML in the next release.

---

## Success Criteria

After migration:

- ✅ `chump gap reserve` creates new gaps (no YAML edits)
- ✅ `chump gap claim/ship` update SQLite atomically
- ✅ `gap-preflight.sh` reads from SQLite
- ✅ Pre-commit guards pass on SQL changes (no YAML required)
- ✅ `.chump/state.sql` exports are readable diffs, tracked in git
- ✅ `.chump/state.db` is in `.gitignore` (binary, not tracked)
- ✅ CLAUDE.md updated — all gap ops via `chump gap` CLI
- ✅ Zero merge conflicts in gap metadata (app-level dedup, not YAML)
- ✅ Offline workflows still work (SQLite is local)
- ✅ 5–10 migration test runs (reserve, claim, ship, preflight all green)

---

## Decision Point: Keep or Migrate?

| Scenario | Recommendation |
|----------|-----------------|
| "YAML is stable and not causing pain" | DEFER migration 6 months. Run Phase 1 (tooling) in background. Migrate when pain hits. |
| "Manual YAML edits are creating merge conflicts" | MIGRATE NOW. Gap system is a blocker. |
| "bot-merge.sh is fragile with YAML writes" | MIGRATE ASAP. Phase 2 (tool migration) fixes the fragility. |
| "We're hiring new engineers and YAML workflow is a bottleneck" | MIGRATE SOON (1–2 sprints). CLI is friendlier. |
| "SQLite bloat / corruption concerns" | KEEP YAML. Stick with readable ledger. Rebuild SQLite from YAML on corruption. |

**Current status:** YAML isn't causing pain (claims moved to JSON, no edit thrashing). Can defer 1–2 sprints without penalty. But Phase 1 (tooling validation) should run now so the path is clear when you decide to move.

---

## Next Steps

1. **Decide scope:** Just Phase 1 (tooling validation) or full migration?
2. **If Phase 1:** File gap `INFRA-044: Validate chump gap CLI completeness` (effort: s, P2)
3. **If full migration:** File `INFRA-045: YAML → SQLite migration` (effort: m, P2)
4. **Assign owner:** Who drives this? (ops/infra focused engineer recommended)
5. **Estimate budget:** 1.5–2 weeks of focused work + review cycle
