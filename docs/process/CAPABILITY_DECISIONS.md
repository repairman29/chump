# Capability decisions — tracked toggles

Some capabilities are gated behind an environment-variable flag rather than
shipped unconditionally: the code lands, but flipping the behavior on for
the whole fleet is a deliberate, logged decision rather than an implicit
side effect of a merge. This doc is the audit trail for those toggles —
when one is flipped, who flipped it, and why.

| Toggle | Default | Flipped by | Date | Reason |
|---|---|---|---|---|
| `CHUMP_STORE_SHADOW` | `0` (off) | — | — | INFRA-3618 Substrate S1: write-only shadow dual-write from `chump-gap-store` mutations (reserve/set/claim/ship/close) to the self-hosted `shared_gaps` table (see `crates/chump-gap-store/src/shadow.rs`). Reads stay on `state.db` this stage — zero read-path risk. Best-effort: any shadow-write failure is logged as `kind=shadow_write_failed` to `ambient.jsonl` and swallowed; it can never block or slow the canonical `state.db` write. Requires `CHUMP_TEAM_URL` + `CHUMP_TEAM_API_KEY` pointed at the self-hosted PostgREST instance (`:3000` on CJ). Reversible: set back to `0` (or unset) for zero residue — no threads spawn, no network calls, no further ambient lines. Gate for S2 (parity validator, `scripts/coord/substrate-parity.sh`) is >= 99.x% parity over K days before S3 (flip reads) is considered. |

## How to add an entry

When you gate new fleet-wide behavior behind an env var flip (rather than a
per-invocation CLI flag), add a row here at flip time — not at code-ship
time. The code landing and the toggle being turned on for the live fleet
are two different events; this table tracks the second one.
