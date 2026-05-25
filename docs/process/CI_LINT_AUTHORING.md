# CI Lint Gate Authoring Guide

> **Companion to** [`CI_GATES_INVENTORY.md`](./CI_GATES_INVENTORY.md).
> Applies to any `scripts/ci/test-*-lint.sh` or `test-*-banlist.sh` gate.
> Tracked by [CREDIBLE-075](../gaps/CREDIBLE-075.yaml) (2026-05-24).

## Why this guide exists

The INFRA-1728 voice-banlist gate (#2509) was stuck 49 minutes because
`test-voice-banlist.sh` scanned its own documentation file
(`docs/process/VOICE_GUARDRAIL.md`), which necessarily contains banned words
as definitional table examples. This produced a false-positive CI failure on
the very PR that added the lint gate.

Two root causes were found and fixed:

1. **Self-scan**: the lint script did not exclude its own guardrail doc from
   the changed-file scan.
2. **Base-ref double-prefix**: `--base=origin/main` caused
   `BASE_REF=origin/origin/main` which fell back to `HEAD~1` (too narrow).

This guide encodes those lessons as a mandatory authoring checklist.

---

## CI Gate Author Checklist (CREDIBLE-075)

`scripts/ci/test-lint-gate-checklist.sh` enforces items marked **[mandatory]**
on every PR that adds a new lint gate. Items marked **[recommended]** produce
warnings only.

### (a) Self-fixture test **[mandatory]**

Ship `scripts/ci/test-NAME-self-fixture.sh` alongside every new lint gate.
The self-fixture must:

1. Confirm the lint's own documentation file (e.g. `docs/process/VOICE_GUARDRAIL.md`)
   exits 0 when scanned — i.e. the lint does NOT self-flag its examples.
2. Confirm the documentation file actually contains the banned/flagged patterns
   (so the test has diagnostic value if the doc is later sanitised).
3. Confirm any structural guards (exclusion regex, bypass trailer) are present
   in the lint script.

If a lint gate genuinely has no documentation file to self-test against, add
this comment in the script header instead of a fixture file:

```bash
# Self-fixture-skip: <one-sentence reason why a self-fixture is not applicable>
```

**Reference implementation**: `scripts/ci/test-voice-banlist-self-fixture.sh`

### (b) Skip-context filter **[mandatory for doc-scanning lints]**

Lint patterns that run against Markdown files must skip content inside:

| Context | Reason to skip |
|---|---|
| Fenced code blocks (` ``` ` / `~~~`) | Code examples legitimately use banned terms |
| Inline backtick spans (`` `word` ``) | Table cells list banned terms by name |
| Indented code blocks (4-space, `.md`) | Same as fenced |

**Reference implementation**: `strip_code_spans()` + `is_in_code_fence()` in
`scripts/ci/test-voice-banlist.sh`.

### (c) Bypass trailer documented **[mandatory]**

Every lint gate must support a per-PR escape hatch via a commit-body trailer,
e.g.:

```
Voice-Lint-Bypass: <one-sentence reason>
```

The script must:
- Check for the trailer across all commits in the PR range (not just HEAD)
- Emit `kind=<name>_lint_bypassed` to `ambient.jsonl` with the reason
- Print `BYPASS:` confirmation to stdout

**Reference implementation**: `_has_bypass()` + `_bypass_reason()` in
`scripts/ci/test-voice-banlist.sh`.

### (d) Tier classification **[recommended]**

State the gate's Tier (A/B/C/D per `CI_GATES_INVENTORY.md`) in the script's
header comment:

```bash
# Tier: B — runs in CI, not yet mirrored into chump preflight
```

### (e) Base-ref construction **[mandatory for scripts accepting --base=]**

When parsing a `--base=` argument that may arrive as `origin/main` (full ref)
or `main` (bare branch name), guard against the double-prefix bug:

```bash
# CORRECT: handles both --base=main and --base=origin/main
[[ "$BASE_BRANCH" == */* ]] && BASE_REF="$BASE_BRANCH" || BASE_REF="origin/$BASE_BRANCH"
if ! git -C "$REPO_ROOT" rev-parse "$BASE_REF" &>/dev/null; then
    BASE_REF="HEAD~1"
fi
```

---

## Retroactive status (2026-05-24)

Run `bash scripts/ci/test-lint-gate-checklist.sh --retroactive` to see
which existing lint gates lack self-fixture tests.

Known gaps as of 2026-05-24 (no self-fixture present):

| Script | Gap |
|---|---|
| `test-cascade-bandit-extended.sh` | filed as follow-up in CREDIBLE-076 |
| `test-lint-handoff-comment.sh` | filed as follow-up in CREDIBLE-076 |
| `test-offline-check-linter.sh` | filed as follow-up in CREDIBLE-076 |
| `test-pre-push-lint-gate.sh` | filed as follow-up in CREDIBLE-076 |
| `test-yaml-lint-guard.sh` | filed as follow-up in CREDIBLE-076 |
| `test-voice-banlist.sh` | fixed in INFRA-1728 + self-fixture added here |

CREDIBLE-076 is an umbrella follow-up to add self-fixtures for the above.

---

## Enforcement

`scripts/ci/test-lint-gate-checklist.sh` runs in the `fast-checks` matrix on
every PR. It only activates when a new `test-*-lint.sh` or `test-*-banlist.sh`
is added — no overhead for PRs that don't touch lint gates.

To add new lint scripts to enforcement scope, they are auto-discovered by
filename pattern — no registration step needed.
