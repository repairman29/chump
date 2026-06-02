# Trunk-Red Prevention — Author-Time Procedure

**Filed under:** `docs/process/PROCEDURES/` — INFRA-2399  
**Related:** INFRA-2397 (main-preflight-watchdog daemon), INFRA-2398 (claim gate),
INFRA-2396 (47-condition paydown that motivated this doc)

---

## Why this exists

Every trunk-red condition paid down in INFRA-2396 followed the same pattern:

1. Author adds a new feature (env var / event kind / install script / path-filtered
   dir / raw gh call)
2. Author forgets to update the corresponding registry or allowlist
3. CI gate fires on the **next** PR (an innocent bystander)
4. Debt accumulates over weeks, paid all at once by whoever pushes next

This document gives the author the 30-second fix at point-of-change instead of
a 15-minute CI round-trip for someone else later.

**Enforcement layer:** INFRA-2397 catches main-red within 10 min and dispatches
remediation. INFRA-2398 blocks a claim if the gap's target paths would overlap an
active lease. These helpers prevent the debt from landing in the first place.

---

## Gate classes and author-time commands

### 1. `install-manifest` — new install script not in bootstrap manifest

**Trigger:** You add `scripts/setup/install-<foo>.sh`. CI checks that every
installer is either in `REQUIRED_DAEMONS` (chump-fleet-bootstrap.sh), the
optional allowlist, or the deprecated allowlist. An unlisted script fails the
`install-manifest` gate.

**Author-time fix:**

```bash
# Required daemon (fleet-incomplete without it):
chump install-daemon <foo> --kind required --gap-id <YOUR-GAP-ID>

# Situational / opt-in:
chump install-daemon <foo> --kind optional --gap-id <YOUR-GAP-ID>

# Scheduled for removal:
chump install-daemon <foo> --kind deprecated --gap-id <YOUR-GAP-ID>
```

Where `<foo>` is the stem: `install-<foo>.sh` minus the `install-` prefix and
`.sh` suffix.

**Verify:** `bash scripts/setup/chump-fleet-bootstrap.sh --check`

**Escape hatch:** If you genuinely cannot classify the installer yet, add a
comment entry to the allowlist file manually with a `# reason:` note. Emit
`kind=install_manifest_bypass` to ambient.jsonl for the audit trail.

---

### 2. `pipefail-race` — new shell script missing `set -euo pipefail`

**Trigger:** You add a `.sh` file without `set -euo pipefail` at the top. The
CI pipefail-lint gate flags it.

**Author-time fix:** Add to your script's preamble:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

No `chump` helper needed — this is a one-line edit. If a script genuinely
cannot use `pipefail` (e.g. it sources interactive user configs), add:

```bash
# pipefail-exempt: <reason>
```

as a comment in the first 10 lines. The lint gate reads this marker.

**Escape hatch:** `# pipefail-exempt: <reason>` inline comment. No bypass
trailer needed; the comment IS the audit trail.

---

### 3. `env-vars-internal` — new env var not in registry

**Trigger:** You add a new `CHUMP_*` (or other fleet env var) that isn't in
`.env.example` or `scripts/ci/env-vars-internal.txt`. The env-var-coverage
gate fails.

**Author-time fix:**

```bash
# Tier 1: operator sets this in their .env (visible to new users)
chump add-env-var MY_VAR --tier 1 --gap-id <YOUR-GAP-ID>

# Tier 2: debug/advanced (not for new operators)
chump add-env-var MY_VAR --tier 2 --gap-id <YOUR-GAP-ID>

# Tier 3: system/runtime state set by OS, Cargo, or fleet runtime
chump add-env-var MY_VAR --tier 3 --gap-id <YOUR-GAP-ID>
```

**CRITICAL:** The audit parses `env-vars-internal.txt` treating **the whole
line** as the variable name. Never add an inline comment on the var line —
doing so registers `MY_VAR # some comment` as the var name, which will never
match. Comments belong on a **separate line above**, which `--gap-id` does
automatically.

**Verify:** `bash scripts/ci/test-env-var-coverage.sh`

**Escape hatch:** If a var is deliberately undocumented (security-sensitive
credential name), add it to `scripts/ci/env-vars-coverage-exceptions.txt`
with a `# reason:` comment. Emit `kind=env_var_coverage_bypass` to
ambient.jsonl.

---

### 4. `raw-gh-allowlist` — new script calls `gh` directly without cache

**Trigger:** You add a script that calls `gh pr view`, `gh api`, or similar
without going through the cache layer (`lib/github_cache.sh`). The raw-gh
lint gate (INFRA-1274) flags it.

**Author-time fix:**

```bash
chump add-raw-gh-allowlist scripts/coord/my-script.sh --migration-gap INFRA-NNNN
```

`--migration-gap` is **required** — it records which gap will eventually
migrate this script to use the cache layer.

**Verify:** `grep my-script.sh scripts/ci/raw-gh-allowlist.txt`

**Escape hatch:** The allowlist itself is the escape hatch, but it must have a
migration gap on record. Scripts that call GitHub Admin API operations (branch
protection CRUD, `gh pr merge --admin`) are permanently exempt — add them
with `# migration gap: N/A (admin API, no cache abstraction)`.

**Important:** This allowlist should shrink over time. Every new entry is
technical debt.

---

### 5. `path-filter` — new top-level directory not in CI paths-filter

**Trigger:** You add a new top-level directory (e.g. `newfeature/`) that could
be the **sole diff** of a future PR. If it's not in the `code:` block of
`.github/workflows/ci.yml`, CI marks required checks as "skipped" and branch
protection blocks the merge forever (INFRA-272 / INFRA-682).

**Author-time fix:**

```bash
chump add-path-filter newfeature
```

Inserts `- 'newfeature/**'` alphabetically into the `code:` block.

**Verify:** `grep newfeature .github/workflows/ci.yml`

**Escape hatch:** If the directory is intentionally CI-excluded (e.g. a
`scratch/` dir that should never gate CI), add a comment in ci.yml explaining
why and leave it out of the `code:` block. Document the decision in the PR
description.

---

### 6. `event-registry-emit` — new `kind=` literal emitted without registry entry

**Trigger:** You add code that emits `kind=my_new_event` to ambient.jsonl but
don't add an entry to `docs/observability/EVENT_REGISTRY.yaml`. The CI
event-registry-coverage gate (INFRA-1237) blocks the PR.

**Author-time fix:**

```bash
chump emit-event my_new_event --gap-id <YOUR-GAP-ID> --description "Emitted when X happens"
```

This appends a `status: pending` entry to EVENT_REGISTRY.yaml. Flesh out
`trigger`, `consumers`, and `fields_required` before the PR merges.

**Verify:** `grep "kind: my_new_event" docs/observability/EVENT_REGISTRY.yaml`

**Escape hatch:** Add the kind to `scripts/ci/event-registry-reserved.txt`
with a `# reason:` comment (e.g. for test-fixture kinds that are emitted but
never registered). The reserved list is audited — don't abuse it.

---

### 7. `event-registry-register` — registry entry with no matching emitter

**Trigger:** You add an entry to EVENT_REGISTRY.yaml but never emit it.
With `CHUMP_REGISTRY_GATE_MODE=strict`, this fails CI (register-without-emit
direction). Default mode (strict-emit) only fails on emit-without-register.

**Author-time fix:** Either implement the emitter before merging, or mark the
entry `status: pending` and add it to the reserved list until the emitter lands.

**Escape hatch:** `status: pending` in the registry entry suppresses the
strict-register check for that kind.

---

### 8. `preflight-ci-parity` — new CI gate not mirrored in `chump preflight`

**Trigger:** You add a `run:` step to `.github/workflows/ci.yml` but don't
mirror it in `src/preflight.rs`. The parity-smoke CI step (INFRA-1867) and
the pre-commit hook (block 18) both fail.

**Author-time fix:** One of three paths (per INFRA-2120):

1. **Mirror in preflight** — add the equivalent `scripts/ci/test-foo.sh` or
   cargo invocation to `src/preflight.rs`. Preferred.
2. **Tier-D (cannot mirror)** — add the step name to the `## Tier D` section
   of `docs/process/CI_GATES_INVENTORY.md` with a reason.
3. **Allowlist exception** — append to
   `scripts/ci/preflight-ci-parity-exceptions.txt`:
   ```
   <step-name-or-script-basename>    # reason: <why this can't mirror>
   ```

No `chump` helper for this class — the three-path decision is intentionally
manual because it requires human judgment about whether the gate can run
locally.

**Escape hatch:** `CHUMP_PREFLIGHT_PARITY_CHECK=0 git commit ...` — emits
`kind=preflight_parity_bypassed` to ambient.jsonl. File a follow-up gap.

---

## Quick reference

| Gate class | Helper | Registry file |
|---|---|---|
| install-manifest | `chump install-daemon <stem> --kind required\|optional\|deprecated` | `scripts/setup/chump-fleet-bootstrap.sh` or allowlist |
| pipefail-race | one-line preamble edit | n/a |
| env-vars-internal | `chump add-env-var <NAME> --tier 1\|2\|3` | `.env.example` / `scripts/ci/env-vars-internal.txt` |
| raw-gh-allowlist | `chump add-raw-gh-allowlist <path> --migration-gap <ID>` | `scripts/ci/raw-gh-allowlist.txt` |
| path-filter | `chump add-path-filter <dir>` | `.github/workflows/ci.yml` |
| event-registry-emit | `chump emit-event <kind>` | `docs/observability/EVENT_REGISTRY.yaml` |
| event-registry-register | mark `status: pending` or add emitter | `docs/observability/EVENT_REGISTRY.yaml` |
| preflight-ci-parity | mirror / Tier-D / allowlist (manual) | `src/preflight.rs` / `docs/process/CI_GATES_INVENTORY.md` |

---

## Audit trail discipline

Every bypass must leave a trace:

- All `chump` helpers print the verification command to run after.
- Escape-hatch bypasses should emit an ambient event (`kind=<gate>_bypass`)
  so `fleet-brief` surfaces them.
- The `--gap-id` flag on each helper adds a comment line above the registry
  entry, keeping the reason visible without polluting the parseable field.
