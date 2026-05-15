# Chump Runtime Assertion Framework (CREDIBLE-065)

Runtime assertions catch data invariant violations at key execution boundaries
(gap claim, gap ship) rather than letting bad state propagate silently. When an
assertion fires it emits `kind=assertion_failure` to `ambient.jsonl` **and**
returns an error so the caller can surface a clear, actionable message.

## Assertion catalog

### `assert_json_shape(value, required_keys)`

**Location:** `src/assertion.rs`  
**Purpose:** Verify a JSON object has all expected top-level keys.  
**Used in:** HTTP handler response shape validation, fixture validation in tests.

```rust
use chump::assertion::assert_json_shape;
assert_json_shape(&response, &["pillars", "kpis", "slo", "ts"])?;
```

**Failure message:** `"assertion failed (assert_json_shape): missing keys ["x", "y"]"`

---

### `assert_gap_valid(gap)`

**Location:** `src/assertion.rs`  
**Purpose:** Verify a `GapRow` has a non-empty `id`, non-empty `title`, and at
least one non-vague acceptance criterion (not all TODO/TBD placeholders).  
**Used in:** `chump gap claim` — fires before the atomic claim write.

**Failure message:** `"assertion failed (assert_gap_valid): gap INFRA-N has no concrete acceptance_criteria"`

**Recovery:** Add concrete ACs via `chump gap set acceptance_criteria` or by editing
`docs/gaps/<ID>.yaml` and running `chump gap sync`.

---

### `assert_lease_held(gap_id, repo_root)`

**Location:** `src/assertion.rs`  
**Purpose:** Verify that an active lease file exists in `.chump-locks/` for the
given gap. Detects ships without prior claims (e.g. manual `chump gap ship` without
`chump claim`).  
**Used in:** `chump gap ship` — fires before the status flip write (soft warning, not hard exit).

**Failure message:** `"assertion failed (assert_lease_held): no active lease for INFRA-N in .chump-locks/"`

**Recovery:** If the lease expired (normal bot-merge delay), set `CHUMP_ASSERT_SKIP=1`.
If the gap was never claimed, run `chump claim <ID>` first.

---

## Ambient event: `assertion_failure`

All assertion failures emit one `assertion_failure` event to `ambient.jsonl`:

```json
{
  "ts": "2026-05-15T20:00:00Z",
  "kind": "assertion_failure",
  "session": "...",
  "assertion": "assert_gap_valid",
  "expected": "at least 1 concrete acceptance criterion",
  "actual": "vague/empty ACs for gap INFRA-999"
}
```

Fields:

| Field | Meaning |
|-------|---------|
| `assertion` | Function name that fired (`assert_json_shape`, `assert_gap_valid`, `assert_lease_held`) |
| `expected` | What the assertion expected to find |
| `actual` | What it actually found |

Consumers: `fleet-brief`, `ops-audit`, `watchdog`.

---

## Bypass and escape hatches

| Mechanism | When to use |
|-----------|-------------|
| `CHUMP_ASSERT_SKIP=1` | Silence `assert_lease_held` warning during ship (lease expired post-CI) |
| `--force` on `chump gap claim` | Skip ambient glance only; does **not** skip `assert_gap_valid` |

Never bypass `assert_gap_valid` — claiming a gap with vague ACs is the root cause
of wasted work (agent spends 30 min guessing what to build). Fix the ACs instead.

---

## Adding new assertions

1. Add the function to `src/assertion.rs` following the existing pattern.
2. Call `emit_assertion_failure(name, expected, actual)` on the failure path.
3. Register the new function name as a `fields_required` value in
   `docs/observability/EVENT_REGISTRY.yaml` under `kind: assertion_failure`.
4. Add a unit test in `src/assertion.rs #[cfg(test)] mod tests`.
5. Update this file with the new catalog entry.
