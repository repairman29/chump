# Sprint A1 — Encrypted-at-Rest SQLite (Defense Trinity)

**Status:** scaffold shipped (feature flag + PRAGMA key wiring). Full sqlcipher activation and migration tooling is documented below but requires maintainer sign-off before enabling.

## Why

Per [docs/NEXT_GEN_COMPETITIVE_INTEL.md](NEXT_GEN_COMPETITIVE_INTEL.md), "Encrypted + Auditable + Typed" is a defense story no Python agent can tell. IronClaw and OpenCoordex both ship sqlcipher; adopting it is table stakes for federal, enterprise, and privacy-conscious deployment.

A previous sprint switched the `r2d2_sqlite` / `rusqlite` features from `bundled` to `bundled-sqlcipher` without designing the migration story. The change broke tests and production state (existing plain DBs couldn't be opened by sqlcipher-linked binaries). We reverted to `bundled` and deferred the proper fix — this document.

## Design

### Build-time opt-in via Cargo feature

```toml
[features]
encrypted-db = []
```

Default builds remain plain SQLite. To build with encryption:

```bash
cargo build --release --features encrypted-db
```

**Note:** Rust's feature system doesn't let us conditionally pick between `rusqlite`'s `bundled` and `bundled-sqlcipher` features (they're declared at the top level). The proper activation requires editing `Cargo.toml` to swap the feature manually OR structuring the `rusqlite`/`r2d2_sqlite` dependencies as optional with feature-gated re-exports. V1 ships the feature flag + passphrase wiring; V2 activates the dependency swap via an opt-in installation path.

### Runtime behavior

When the `encrypted-db` feature is compiled in, `db_pool::build_connection_init_pragmas` runs `PRAGMA key` before any other SQL on every connection. The key comes from the `CHUMP_DB_PASSPHRASE` environment variable.

```rust
#[cfg(feature = "encrypted-db")]
{
    let key = std::env::var("CHUMP_DB_PASSPHRASE")
        .map_err(|_| /* auth error */)?;
    c.execute_batch(&format!("PRAGMA key = '{}';", escape(key)))?;
}
```

If `CHUMP_DB_PASSPHRASE` is unset or empty, pool initialization fails fast with an auth error rather than silently writing unencrypted data.

### Passphrase sources (priority order)

1. `CHUMP_DB_PASSPHRASE` env var (explicit, documented)
2. (future V2) macOS Keychain entry `ai.chump.db.passphrase`
3. (future V2) Linux secret-service integration
4. (future V2) Interactive prompt on first run in TTY mode

### Migration: plain → encrypted

An existing plain DB can be converted to an encrypted DB using SQLite's `ATTACH` + `sqlcipher_export` combo:

```sql
ATTACH DATABASE 'chump_memory_encrypted.db' AS encrypted KEY 'your-passphrase';
SELECT sqlcipher_export('encrypted');
DETACH DATABASE encrypted;
```

Then swap the files atomically. V2 will ship `chump --migrate-db-encrypt` as a CLI subcommand that:

1. Verifies the plain DB is readable and not corrupt
2. Creates a new encrypted DB with `CHUMP_DB_PASSPHRASE`
3. Exports all data via `sqlcipher_export`
4. Atomically swaps: original → `.backup`, new → original path
5. Prints the backup location and the rotate/delete instructions

### Rotation

`PRAGMA rekey` re-encrypts the database with a new passphrase without needing a full export/import:

```sql
PRAGMA rekey = 'new-passphrase';
```

V2 will expose `chump --rotate-db-passphrase` that takes old and new passphrases, runs rekey, and confirms.

### Key management in CI / multi-user deployments

For CI environments or shared fleet deployments, `CHUMP_DB_PASSPHRASE` should come from:

- GitHub Actions Secrets (for CI)
- AWS Secrets Manager / HashiCorp Vault (for production fleet)
- macOS Keychain (for local developer workstations)

A passphrase file path (`CHUMP_DB_PASSPHRASE_FILE`) will be supported in V2 for systems where env vars are inspectable.

## Threat model

### What encryption protects against

- **Laptop theft / cold-boot attacks:** attacker cannot read stored conversations, memories, skill history, or task queue without the passphrase.
- **Filesystem access by other users on shared machines:** SQLite file is encrypted; opening without the key returns garbage.
- **Backup leaks:** Time Machine / rsync backups contain only encrypted bytes.
- **Compliance (FedRAMP, HIPAA, SOC 2):** encryption-at-rest is a standard control.

### What it does NOT protect against

- **Running process memory:** while Chump is running, the DB is decrypted in-process. A memory dump or debugger attached to a live `chump` process can read plaintext data.
- **Keyloggers / compromised env vars:** if the attacker has code execution on your machine, they can read `CHUMP_DB_PASSPHRASE` directly.
- **Weak passphrases:** sqlcipher uses PBKDF2-SHA512 with 256k iterations by default (good), but a weak passphrase still enables brute-force. Use a password manager; 20+ random characters recommended.
- **Side-channel attacks:** SQL query timing, log files, `dtrace` output. Not in scope.

## Implementation status

### V1 (shipped)

- [x] `encrypted-db` Cargo feature declared
- [x] `build_connection_init_pragmas()` honors `CHUMP_DB_PASSPHRASE` when feature is on
- [x] Fail-fast on missing/empty passphrase when feature is on
- [x] Docs describe the full design and migration plan

### V2 (future work)

- [ ] Feature-gated swap of `rusqlite`/`r2d2_sqlite` to `bundled-sqlcipher` variants
- [ ] `chump --migrate-db-encrypt` CLI subcommand
- [ ] `chump --rotate-db-passphrase` CLI subcommand
- [ ] macOS Keychain integration for passphrase storage
- [ ] `CHUMP_DB_PASSPHRASE_FILE` env var support
- [ ] Integration tests against a real sqlcipher build

### V3 (research)

- [ ] Per-table encryption (different passphrases for `chump_memory` vs `chump_tool_calls`)
- [ ] Hardware-backed key storage (Secure Enclave on macOS, TPM on Linux)

## Related docs

- [docs/NEXT_GEN_COMPETITIVE_INTEL.md](NEXT_GEN_COMPETITIVE_INTEL.md) — the 20-project review that identified this pattern
- [docs/HERMES_COMPETITIVE_ROADMAP.md](HERMES_COMPETITIVE_ROADMAP.md) — positioning context
- [sqlcipher documentation](https://www.zetetic.net/sqlcipher/sqlcipher-api/) — PRAGMAs and API reference
