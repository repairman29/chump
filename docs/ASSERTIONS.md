# Assertion Framework for Gap Execution (CREDIBLE-065)

Runtime assertion framework to catch data invariant violations early. When a gap claim or ship operation encounters invalid state (corrupted lease, missing required field, etc.), assertions fail-fast with clear error messages rather than silently proceeding or panicking.

## Overview

The assertion framework provides three core validation functions designed for fail-fast, observable error detection:

1. **`assert_json_shape()`** — Verify JSON object has required fields with correct types
2. **`assert_gap_valid()`** — Validate gap record has all required fields and valid content
3. **`assert_lease_held()`** — Verify lease JSON has required structure and valid data

## Assertions Catalog

### assert_json_shape

Ensures a JSON object contains all required fields with the correct types.

```rust
let gap_json = json!({ "id": "INFRA-1", "status": "open" });
assert_json_shape(&gap_json, &[("id", "string"), ("status", "string")])?;
```

**Supported types:** `null`, `boolean`, `number`, `string`, `array`, `object`

**Error on:**
- Non-object input
- Missing required field
- Field type mismatch

**Error message format:**
```
json_shape: field 'fieldname' expected 'expectedtype' but got 'actualtype' (context)
```

### assert_gap_valid

Validates that a gap record has all required fields and valid values. Returns an error immediately if the gap structure is invalid.

```rust
let gap = json!({
    "id": "INFRA-1",
    "domain": "INFRA",
    "title": "Test gap",
    "status": "open",
    "priority": "P1"
});
assert_gap_valid(&gap)?;
```

**Required fields:**
- `id` (string) — Gap identifier
- `domain` (string) — Domain (INFRA, CREDIBLE, EFFECTIVE, RESILIENT, ZERO-WASTE)
- `title` (string) — Human-readable title
- `status` (string) — One of: `open`, `claimed`, `done`, `wontfix`
- `priority` (string) — One of: `P0`, `P1`, `P2`, `P3`

**Error on:**
- Missing required field
- Invalid status value (not one of the valid statuses)
- Invalid priority value (not P0-P3)

**Error message format:**
```
gap_valid: field 'fieldname' expected 'expected_values' but got 'actual_value'
```

### assert_lease_held

Verifies that a gap claim lease has the required structure and valid timestamps.

```rust
let lease = json!({
    "gap_id": "INFRA-1",
    "session_id": "sess-abc123",
    "claimed_at": 1700000000i64,
    "worktree_path": "/tmp/chump-infra-1"
});
assert_lease_held(&lease)?;
```

**Required fields:**
- `gap_id` (string) — Gap being claimed
- `session_id` (string) — Session identifier
- `claimed_at` (number) — Unix timestamp when lease was acquired
- `worktree_path` (string) — Path to the linked worktree

**Validation:**
- `claimed_at` must be a timestamp after 2020 (unix timestamp > 1577836800)

**Error on:**
- Missing required field
- Invalid timestamp (before 2020)

**Error message format:**
```
lease_held: field 'fieldname' expected 'expected' but got 'actual' (context)
```

## Error Handling

All assertion functions return `AssertionResult<()>`, which is `Result<(), AssertionError>`.

### AssertionError Structure

Each error contains:

- **assertion_type** — The kind of check that failed (e.g., "json_shape", "gap_valid")
- **field_name** — Which field/key triggered the failure
- **expected** — What value(s) were expected
- **actual** — What was actually found
- **context** — Optional additional context for debugging

### Display Format

Errors implement `Display` and `Error` traits for ergonomic logging:

```
assertion_type: field 'fieldname' expected 'expected' but got 'actual' (context)
```

## Integration Points

### chump claim (atomic_claim.rs)

**When to use:** After reading gap from state.db, before creating worktree

```rust
// Step 1: Read gap from state.db
let gap = read_gap_from_db(gap_id)?;

// Step 2: Validate with assertion — fail-fast if invalid
assertion::assert_gap_valid(&gap)
    .map_err(|e| emit_assertion_failure_event(&e))?;

// Step 3: Proceed to worktree creation if valid
create_worktree()?;
```

### chump gap ship (bot-merge.sh, ship path)

**When to use:** Before merging PR, verify lease is still held and gap is claimed

```rust
// Step 1: Read lease from .chump-locks/<session>.json
let lease = read_lease()?;

// Step 2: Validate lease — fail-fast if corrupted or expired
assertion::assert_lease_held(&lease)
    .map_err(|e| emit_assertion_failure_event(&e))?;

// Step 3: Verify gap is still in claimed state
let gap = read_gap_from_db(gap_id)?;
assertion::assert_gap_valid(&gap)?;

if gap.status != "claimed" {
    return Err("gap transitioned away from claimed state");
}

// Step 4: Proceed to PR merge
```

## Event Emission (ambient.jsonl)

When an assertion fails, emit an event with `kind=assertion_failure`:

```json
{
  "ts": "2026-05-15T14:30:00Z",
  "kind": "assertion_failure",
  "assertion_type": "gap_valid",
  "gap_id": "INFRA-1",
  "field_name": "status",
  "expected": "open|claimed|done|wontfix",
  "actual": "corrupted",
  "context": "gap transitioned to invalid state during claim",
  "severity": "error"
}
```

**Fields:**
- `ts` — ISO 8601 timestamp
- `kind` — Always `"assertion_failure"`
- `assertion_type` — Which assertion failed (json_shape, gap_valid, lease_held)
- `gap_id` — Gap identifier (if applicable)
- `field_name` — Field that failed validation
- `expected` — Expected value(s)
- `actual` — Actual value found
- `context` — Additional context for debugging
- `severity` — `"error"` for assertion failures

## Failure Recovery Guide

### "gap_valid: field 'status' expected '...' but got 'corrupted'"

**Cause:** Gap record in state.db has invalid status

**Recovery:**
1. Run `chump gap show <GAP-ID>` to inspect current state
2. If status is genuinely invalid, manually update via:
   ```bash
   sqlite3 ~/.chump/state.db "UPDATE gaps SET status='open' WHERE id='<GAP-ID>';"
   ```
3. Re-run `chump claim`

### "lease_held: field 'claimed_at' expected '> 1577836800' but got '1000'"

**Cause:** Corrupted or manually-created lease with invalid timestamp

**Recovery:**
1. Remove the corrupted lease:
   ```bash
   rm .chump-locks/<session>.json
   ```
2. Re-run `chump claim` to create a fresh lease

### "json_shape: field 'gap_id' expected 'string' but got 'missing'"

**Cause:** Lease or gap JSON is malformed (missing required field)

**Recovery:**
1. Inspect the actual JSON:
   ```bash
   cat .chump-locks/<session>.json | jq .
   ```
2. If manually created, fix the JSON structure
3. If from state.db, run `chump gap import` to re-seed from YAML
4. Remove the corrupted file and retry the operation

## Testing

Unit tests verify assertion behavior:

```bash
cargo test --bin chump assertion
```

Integration tests verify readiness for claim/ship paths:

```bash
cargo test --test assertion_test
```

All tests check:
- Valid data passes assertions
- Invalid data is rejected with clear error messages
- Error messages include field name, expected, and actual values

## Future Enhancements

- Metrics tracking: count assertions per operation type (claim vs ship)
- Assertion composition: combine multiple validations into reusable guards
- Custom validators: allow gaps to define domain-specific assertions
- Retry logic: some failures (transient timestamp drift) could be retryable
