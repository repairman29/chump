# Bypass Trailer Schema

**Gap**: INFRA-2407
**Layer**: Wave-1 of `docs/strategy/AGENT_GATE_LOCKDOWN_2026-06-02.md` §3 (Layer 1+2)
**Status**: enforced by `scripts/git-hooks/commit-msg-bypass-trailers.sh` and `scripts/git-hooks/pre-push-bypass-trailers.sh`

---

## Purpose

Every bypass of a Chump gate must be declared in the commit body with four structured trailers. This converts invisible/audit-invisible bypass usage into auditable, classifiable, time-bounded events.

Rule: **every commit whose body contains any `*Bypass*` or `*Bypass-*` token (case-insensitive) MUST include all four trailers below.** The commit-msg hook enforces this.

---

## The 4 Required Trailers

### `Bypass-Tier:` — how bad is this bypass?

Enum: one of `T0`, `T1`, `T2`, `T3`, `T4`

| Tier | Name | Meaning | Acceptable use | Anti-pattern signal |
|---|---|---|---|---|
| **T0** | Always-OK | Operator-broadcast explicitly authorized this class in ambient.jsonl within 24h | Trunk-red rescue, operator-directed recovery | Used more than once per outage without fresh broadcast |
| **T1** | Audit-OK | Stale state or clock drift forced a one-time workaround; semantically valid | `CHUMP_BYPASS_PROOF_OF_MERGE=1` on stale merge-state, clock drift bypass | Used without any trailer; used routinely |
| **T2** | Suspect | Pre-existing trunk-red rescue; legitimate but needs follow-up | `CHUMP_PREFLIGHT_SKIP=1` when main was already red before your branch | Used with no follow-up gap; used after trunk is green |
| **T3** | Bad | Tooling bug workaround; never acceptable as default practice | `--no-verify` forced by a broken hook; emergency CI infra failure | Any regular use; used without operator awareness |
| **T4** | Banned | Admin-merge / `--no-verify` without operator authorization; operator-only | `gh pr merge --admin` authorized by operator in ambient.jsonl | Anyone using this without explicit operator broadcast |

### `Bypass-Class:` — which gate was bypassed?

Free-form string. Canonical examples:

| Class | What it bypasses |
|---|---|
| `preflight-skip` | `chump preflight` / `CHUMP_PREFLIGHT_SKIP=1` |
| `proof-of-merge` | `CHUMP_BYPASS_PROOF_OF_MERGE=1` (merge-state check) |
| `obs-budget` | `CHUMP_OBS_BUDGET_BYPASS=1` (observability budget gate) |
| `test-gate` | `CHUMP_TEST_GATE=0` / `Test-Gate-Bypass:` trailer path |
| `install-manifest-bypass` | `CHUMP_INSTALL_MANIFEST_SKIP=1` |
| `bot-merge-bypass` | `Bot-Merge-Bypass:` (existing legacy class) |
| `docs-delta` | `CHUMP_DOCS_DELTA_CHECK=0` |
| `no-verify` | `git commit --no-verify` |
| `admin-merge` | `gh pr merge --admin` |

New classes: add an entry to this table and update the CI threshold table in `docs/strategy/AGENT_GATE_LOCKDOWN_2026-06-02.md` §3 Layer 1.

### `Bypass-Reason:` — why was the bypass necessary?

**Minimum 10 words.** Must describe the specific technical reason the bypass was needed right now, not a generic "tooling issue." The 10-word minimum is enforced by the commit-msg hook.

Good: `Bypass-Reason: main was red before branch cut; preflight gate would have blocked a legitimate rescue`
Bad: `Bypass-Reason: tooling issue`
Bad: `Bypass-Reason: CI broken`

### `Bypass-Followup:` — what gap tracks the root cause?

**Format**: `INFRA-NNNN` (must match regex `^INFRA-[0-9]+$`)

Every bypass implies a gap was filed to address the root cause that forced the bypass. If no gap exists yet, `chump gap reserve` one before committing. The gap does not have to be picked before you ship — but it must be filed and tracked.

The follow-up SLA (from `docs/strategy/AGENT_GATE_LOCKDOWN_2026-06-02.md` §3 Layer 2):
- 24h: warning emitted to ambient if follow-up gap not `in_progress`
- 72h: new bypass-class uses blocked until follow-up ships
- 7d: auto-filed P0 escalation gap with operator broadcast

---

## Complete Example

```
fix(INFRA-2350): rescue pre-push hook after fmt drift

Applied `cargo fmt --all` to resolve rustfmt regression on pre-commit hook
that was blocking every push fleet-wide.

Bypass-Tier: T2
Bypass-Class: preflight-skip
Bypass-Reason: main was red before branch cut due to upstream rustfmt regression; preflight would have blocked a trunk-rescue commit that had no Rust changes
Bypass-Followup: INFRA-2351
```

---

## Enforcement

- **commit-msg hook** (`scripts/git-hooks/commit-msg-bypass-trailers.sh`): runs at `git commit` time; reads `$1` (commit message file); if any `*Bypass*` token found in body → validates all 4 trailers; rejects with clear diagnostic if any missing or invalid.
- **pre-push hook** (`scripts/git-hooks/pre-push-bypass-trailers.sh`): scans every commit being pushed; applies same validation to any bypass-containing commit; prevents non-compliant commits from reaching the remote.
- **Legacy grandfather list** (`scripts/ci/legacy-bypass-trailer-allowlist.txt`): contains SHA1 hashes of the 139 pre-existing `Bot-Merge-Bypass` commits that existed before this schema was enforced. Allowlisted commits skip validation.

---

## Hook Bypass

To bypass the bypass-trailer validator itself (T3/T4 territory — use sparingly):

```bash
CHUMP_BYPASS_TRAILER_CHECK=0 git commit ...
```

This bypass is itself audited: the hook emits a warning to stderr. Use only when the hook is broken and a tracker gap (filed immediately) documents the reason.

---

## Related

- Strategy: `docs/strategy/AGENT_GATE_LOCKDOWN_2026-06-02.md`
- Threat model + per-class thresholds: same doc §3 Layer 1
- SLA enforcement daemon: same doc §3 Layer 2
- Gap: INFRA-2407
