# UUID Gap-ID Compatibility Audit (INFRA-630)

**Date:** 2026-05-12  
**Author:** chump/infra-630-claim  
**Ticket:** INFRA-630  
**Scope:** Identify all sites in the Chump stack that assume `[A-Z]+-\d+` gap ID format and report their UUID-compatibility status.

## Background

`chump-mcp-coord`'s `valid_gap_token()` already accepts UUID-format gap IDs
(`[0-9a-f-]{36}`), but the rest of the stack was unverified. chump-proprietary
uses UUID-format IDs (`8d3f2c0e-9f5b-4e1a-b2c3-d4e5f6a7b8c9`) displayed as
8-char short prefixes (e.g., `8d3f2c0e`). Branch filenames follow the
`<prefix>--<slug>.yaml` convention.

## Audit Results

| Site | UUID Compatible? | Fix Applied | Notes |
|------|:--------------:|:-----------:|-------|
| `scripts/coord/gap-preflight.sh` | ✅ Yes | — | Passes ID to `chump gap preflight` exact-match; no format gate |
| `scripts/coord/gap-claim.sh` | ✅ Yes | — | `GAP_ID="$1"` passes through; branch name lowercased then prefixed `chump/<id>-*` |
| Pre-commit `recycled-id` guard | ✅ Yes | — | `re.match(r'^- id:\s*(\S+)', line)` captures any non-whitespace |
| Pre-commit `duplicate-id-insert` guard | ✅ Yes | — | `re.findall(r'^\s*-\s*id:\s*(\S+)', text)` — same |
| `chump-mcp-coord` `valid_gap_token` | ✅ Yes | — | Per gap description; already accepts UUIDs |
| `src/gap_store.rs` `get()` — exact match | ✅ Yes | — | `WHERE id=?1` accepts any string |
| `src/gap_store.rs` `get()` — 8-char prefix | ✅ Fixed (INFRA-630) | ✅ Added prefix-match | `LIKE '<prefix>%' LIMIT 2` fallback; returns unique match only |
| `src/gap_store.rs` `preflight()` — 8-char prefix | ✅ Fixed (INFRA-630) | ✅ Added prefix-resolve | Resolves short-prefix to full ID before status/lease checks |
| `scripts/coord/bot-merge.sh` auto-derive | ✅ Fixed (INFRA-630) | ✅ Added UUID branch regex | Extracts RFC-4122 UUID and `<8hex>--slug` from branch before `tr '-' ' '` |
| `src/intent_parser.rs` `extract_gap_id()` | ⚠️ Partial | Advisory (no fix) | Only matches `UPPER-digits`; natural-language UUID input unrecognized. Low-priority: operators type IDs explicitly. |
| `src/gap_store.rs` `reserve()` ID generation | ✅ N/A | — | Generates `{domain}-{NNN}` for Chump gaps; UUID IDs come via import, not generation |
| `scripts/ci/test-recycled-id-guard.sh` | ✅ Yes | — | Fixture-based; creates YAML with arbitrary IDs |
| `scripts/ci/test-duplicate-id-guard.sh` | ✅ Yes | — | Same |

## Fixes Applied

### 1. `scripts/coord/bot-merge.sh` — UUID branch auto-derive (line ~234)

Before this fix, `--gap` auto-derive used:
```bash
_branch_tail="$(echo "$_branch_name" | sed ... | tr '-' ' ' | tr 'a-z' 'A-Z')"
_derived_gaps="$(echo "$_branch_tail" | grep -oE '[A-Z]+ [0-9]+' | sed 's/ /-/')"
```

The `tr '-' ' '` step destroyed UUID hyphens, making `grep -oE '[A-Z]+ [0-9]+'`
unable to match hex-only strings like `8D3F2C0E`.

**Fix:** Extract UUID-format patterns _before_ the `tr` transformation:
```bash
# Full RFC-4122 UUID from branch tail
_uuid_full=$(printf '%s' "$_branch_raw" \
    | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' ...)
# Short-prefix (chump-proprietary: 8d3f2c0e--slug)
_uuid_short=$(printf '%s' "$_branch_raw" \
    | sed -n 's/^\([0-9a-f]\{8\}\)--.*$/\1/p' ...)
```

### 2. `src/gap_store.rs` `get()` — UUID short-prefix fallback

Added: if `gap_id` is exactly 8 ASCII hex chars and the exact-match returns
`None`, fall through to `LOWER(id) LIKE '<prefix>%' LIMIT 2`. If exactly one
row matches, return it. If zero or two, return `None` (caller reports "not
found" or "ambiguous prefix").

### 3. `src/gap_store.rs` `preflight()` — UUID short-prefix resolve

Same 8-char hex detection; resolves to full ID via `SELECT id FROM gaps WHERE
LOWER(id) LIKE ?1 LIMIT 1` before running the status + lease checks so those
queries always see the canonical full ID.

## Advisory: `intent_parser.rs`

`extract_gap_id()` uses:
```rust
parts.len() == 2
&& parts[0].chars().all(|c| c.is_ascii_uppercase())
&& parts[1].chars().all(|c| c.is_ascii_digit())
```

UUID-format IDs typed in natural language (e.g., "show gap 8d3f2c0e-9f5b-...")
would not be recognized by the intent parser. This is low-priority because:
1. Operators pass IDs explicitly via `chump gap show <ID>` on the CLI, not
   through the natural-language intent parser in practice.
2. Fixing it requires adding a UUID regex branch to `extract_gap_id()` — a
   straightforward change tracked for a future INFRA gap.

## Test Coverage

`scripts/ci/test-uuid-gap-id-compat.sh` (INFRA-630) exercises:
- `chump gap preflight <full-UUID>` → Available
- `chump gap preflight <8-char-prefix>` → Available (prefix-match)
- `chump gap show <full-UUID>` → prints gap
- `chump gap show <8-char-prefix>` → prints gap (prefix-match)
- `bot-merge.sh` UUID auto-derive from full-UUID branch name
- `bot-merge.sh` UUID auto-derive from `<8hex>--slug` branch name
- Pre-commit duplicate-id guard accepts UUID-format IDs in YAML
