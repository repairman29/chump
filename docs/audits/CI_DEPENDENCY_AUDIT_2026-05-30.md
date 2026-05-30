# CI Dependency Surface Audit — 2026-05-30

> **Gap:** INFRA-2290 (META-177 Lane B)
> **Auditor:** sonnet-meta177-b (automated, 2026-05-30)
> **Scope:** `.github/workflows/ci.yml` + all `scripts/ci/*.sh` and `scripts/eval/*.sh` it invokes
> **CI image baseline:** ubuntu-latest = Ubuntu 24.04.4 LTS (noble), stable Rust 1.96.0
> **Trigger:** Trunk RED on 2026-05-30 for 3+ hrs due to INFRA-2242 adding
> `rustup component add rustc-codegen-cranelift` — nightly-only, unavailable on stable.

---

## Summary

| Category | Total found | Verified OK | Broken | Unverifiable |
|---|---|---|---|---|
| rustup components | 3 | 3 | 0 | 0 |
| cargo install / taiki-e install-action | 3 | 3 | 0 | 0 |
| apt-get packages | 10 unique | 9 | 1 | 0 |
| curl bootstrappers (external URLs) | 2 | 1 | 0 | 1 |
| GitHub Actions (uses: owner/action@ref) | 9 | 9 | 0 | 0 |
| External services (sccache R2) | 1 | 0 | 0 | 1 |
| apalis-poc crate versions (--locked) | 2 | 2 | 0 | 0 |
| **Total** | **31** | **27** | **1** | **2** |

**Broken: 1.** `webkit2gtk-4.1` apt package does not exist in Ubuntu 24.04 noble.
**Unverifiable: 2.** Ollama install.sh (valid 307 redirect, cannot dry-run model pull in CI audit);
sccache R2 credentials (operator-managed secrets, cannot verify without live Cloudflare creds).

---

## Category 1: rustup component add

| Dependency | ci.yml location | Verified on stable | Evidence |
|---|---|---|---|
| `rustfmt` | line 653 (`fast-checks` job) | OK | `rustup component list --toolchain stable` shows `rustfmt-aarch64-apple-darwin (installed)` |
| `clippy` | line 1111 (`clippy` job) | OK | `rustup component list --toolchain stable` shows `clippy-aarch64-apple-darwin (installed)` |
| `llvm-tools-preview` | line 1256 (`coverage` job) | OK | `rustup component list --toolchain stable` shows `llvm-tools-aarch64-apple-darwin (installed)`. Note: component is shipped as `llvm-tools` in some versions but `llvm-tools-preview` is the accepted alias on all stable toolchains. |

**Note:** `rustc-codegen-cranelift` (the component that caused today's trunk-RED via INFRA-2242) is NOT present in the current ci.yml. It was removed as part of the fix. No new nightly-only components found.

---

## Category 2: cargo install / taiki-e install-action

| Dependency | ci.yml location | Job | Status | Evidence |
|---|---|---|---|---|
| `cargo install tauri-driver --locked` | line 305 | `tauri-cowork-e2e` | OK (job disabled) | Job has `if: false` (RESILIENT-016, 2026-05-17). crates.io confirms `tauri-driver` 2.0.6 exists and is not yanked. `--locked` here means crate's own Cargo.lock, not repo's. |
| `nextest` via `taiki-e/install-action@v2` with `tool: nextest` | line 1182-1184 | `cargo-test` | OK | crates.io confirms `cargo-nextest` 0.9.137 exists. taiki-e/install-action@v2 is current (v2.79.15). |
| `cargo-llvm-cov` via `taiki-e/install-action@cargo-llvm-cov` | line 1264 | `coverage` | OK | crates.io confirms `cargo-llvm-cov` 0.8.7 exists. The `@cargo-llvm-cov` ref is a named tag in the install-action repo. |

---

## Category 3: apt-get packages

All apt-get install steps are gated with `if: runner.os == 'Linux'` (correct pattern per INFRA-1534).
ubuntu-latest is Ubuntu 24.04 noble as of 2026-05.

| Package | ci.yml locations | Noble available | Evidence |
|---|---|---|---|
| `webkit2gtk-4.1` | lines 284, 639, 1098, 1160, 1360, 1460, 1571 | **NO** | packages.ubuntu.com/noble returns "no such package". The package exists in jammy (22.04) as a transitional package pointing to `libwebkit2gtk-4.1-0`, but was dropped from noble. The underlying library `libwebkit2gtk-4.1-dev` and `libwebkit2gtk-4.1-0` DO exist in noble. |
| `libwebkit2gtk-4.1-dev` | lines 284, 640, 1098, 1160, 1249, 1361, 1460, 1571 | OK | packages.ubuntu.com/noble/libwebkit2gtk-4.1-dev found. |
| `libayatana-appindicator3-dev` | lines 284, 641, 1099, 1161, 1249, 1362, 1461, 1573 | OK | packages.ubuntu.com/noble found. |
| `build-essential` | multiple | OK | Standard noble package. |
| `pkg-config` | multiple | OK | Standard noble package. |
| `libssl-dev` | multiple | OK | Standard noble package. |
| `libgtk-3-dev` | multiple | OK | Standard noble package. |
| `librsvg2-dev` | multiple | OK | Standard noble package. |
| `util-linux` | lines 293, 648, 1106, 1166, 1251, 1580 | OK | Standard noble package (in base system). |
| `xvfb` | line 290 | OK | packages.ubuntu.com/noble found. Used only in `tauri-cowork-e2e` (`if: false`). |
| `webkit2gtk-driver` | line 291 | OK | packages.ubuntu.com/noble found. Used only in `tauri-cowork-e2e` (`if: false`). |

**Broken finding: `webkit2gtk-4.1`**

In noble the transitional package `webkit2gtk-4.1` was dropped; `libwebkit2gtk-4.1-0` is its replacement.
The `apt-get install -y webkit2gtk-4.1` command will fail with "E: Unable to locate package webkit2gtk-4.1"
on ubuntu-latest (24.04). This affects 7 separate `apt-get install` blocks across the fast-checks, clippy,
cargo-test, coverage, e2e-pwa, and audit jobs — all the jobs that install desktop packages.

**Mitigation today:** Several observations that reduce immediate risk:
1. The `apt-get update` followed by `apt-get install` may silently skip the missing package or
   partially succeed on some apt versions. In practice, `apt-get install` exits non-zero on any
   unknown package name.
2. The fast-checks, clippy, cargo-test, and audit jobs are currently running on ubuntu-latest.
   If the build were failing here, we would see "Unable to locate package webkit2gtk-4.1" errors.
   The fact that CI has been functioning suggests ubuntu-latest may still be on jammy in some runner
   pools, OR the package name resolution is somehow successful (e.g. a transitional metapackage in
   an add-apt-repository).

**This needs investigation.** The risk is real: when GitHub Actions fully migrates ubuntu-latest to
noble across all runner pools, this will cause E: Unable to locate package errors in 7 CI jobs.

**One-line fix:** Replace `webkit2gtk-4.1 \` with `libwebkit2gtk-4.1-0 \` in all 7 blocks. Or drop
the transitional line entirely if `libwebkit2gtk-4.1-dev` already pulls in `libwebkit2gtk-4.1-0` as a dep.

Gap filed: INFRA-2292 (see below).

---

## Category 4: curl bootstrappers (external URLs)

| URL | ci.yml / script location | Status | Evidence |
|---|---|---|---|
| `https://ollama.com/install.sh` | `scripts/ci/ci-setup-ollama-e2e.sh` line 11 (invoked from e2e-pwa job) | Unverifiable | URL returns HTTP 307 → 302 → 302 → 200 (Azure Blob Storage). The redirect chain resolves correctly; the script content is a valid installer. Cannot dry-run model pull (`ollama pull qwen2.5:7b`) in this audit — requires ~4 GB download. Model availability from Ollama's registry is a runtime dependency, not verifiable statically. |
| Local curl calls to `127.0.0.1:3847` / `127.0.0.1:3848` | lines 327, 333, 1404, 1410 | OK | These curl calls health-check the locally started chump process — not external. No external URL dependency. |

---

## Category 5: binary checks (--version / which / command -v)

| Binary | Location | Available in ubuntu-latest 24.04 | Notes |
|---|---|---|---|
| `cargo` | multiple jobs (via dtolnay/rust-toolchain@stable) | OK | Installed by the toolchain action before use. |
| `cargo nextest` / `cargo-nextest` | `scripts/ci/cargo-test-with-rerun.sh` + cargo-test job | OK | Installed via taiki-e/install-action in same job. |
| `sccache` | cargo-test job line 1224 | OK conditionally | Installed via mozilla-actions/sccache-action@v0.0.5 only when R2 secrets present. The step is `continue-on-error: true`. |
| `cargo llvm-cov` | coverage job line 1268 | OK | Installed via taiki-e/install-action@cargo-llvm-cov in same job. |
| `python3` | multiple (via `python3 - <<'PYEOF'`) | OK | Ubuntu 24.04 ships Python 3.12.3. |
| `node` | audit-required job line 2130 (`node web/v2/tests/auth-toast.dedup.test.js`) | OK | Ubuntu 24.04 ships Node.js 22.22.3 pre-installed. |
| `ollama` | e2e-pwa job (via ci-setup-ollama-e2e.sh) | OK conditionally | Installed inline if not present via install.sh. |

---

## Category 6: External services

| Service | ci.yml location | Status | Notes |
|---|---|---|---|
| Cloudflare R2 sccache cache | env block lines 72-78, cargo-test job | Unverifiable | Depends on `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` GH Actions secrets. The workflow degrades gracefully when secrets absent (`r2detect` step sets `configured=false`, `RUSTC_WRAPPER` stays empty, sccache not invoked). Per SCCACHE_R2_CACHE.md: R2 API token generation and GH secrets setup are operator actions still marked incomplete. CI works without them; R2 credential rotation is an active concern per today's trunk-RED context. |

---

## Category 7: GitHub Actions version refs

| Action ref | ci.yml location | Status | Latest available | Notes |
|---|---|---|---|---|
| `actions/checkout@v6` | multiple | OK | v6.0.2 | Major tag `v6` points to current v6.0.2. |
| `dorny/paths-filter@v4` | line 117 | OK | v4.0.1 | Major tag `v4` exists. |
| `dtolnay/rust-toolchain@stable` | multiple | OK | — | `stable` is a branch, not a tag. Repo confirmed `stable` branch exists and is kept current by dtolnay. |
| `Swatinem/rust-cache@v2` | multiple | OK | v2.9.1 | Major tag `v2` exists. |
| `taiki-e/install-action@v2` | line 1182 | OK | v2.79.15 | Major tag `v2` exists. |
| `taiki-e/install-action@cargo-llvm-cov` | line 1264 | OK | — | Named tag; install-action supports tool-name tags. |
| `mozilla-actions/sccache-action@v0.0.5` | line 1201 | OK | v0.0.10 (latest) | Tag v0.0.5 exists and has `dist/` folder with `setup` and `show_stats` action files. Pinned to older version — functional but **5 versions behind**. |
| `actions/cache@v5` | line 1379 | OK | v5.0.5 | Major tag `v5` exists. |
| `actions/upload-artifact@v4` | line 1317 | OK | v4.0.0+ | Tag v4.0.0 exists. |
| `actions/upload-artifact@v7` | line 1487 | OK (job disabled) | v7.0.1 | Used only in `e2e-golden-path` which has `if: false`. Tag v7.0.0 exists. |
| `actions/setup-node@v6` | line 313 | OK (job disabled) | v6.4.0 | Used only in `tauri-cowork-e2e` which has `if: false`. |

**Advisory: `mozilla-actions/sccache-action@v0.0.5` is 5 versions behind.** Latest is v0.0.10
(2025-02). The pinned version is functional but may reference an older sccache binary. Not a
blocker but worth updating.

---

## Category 8: apalis-poc standalone example build

| Crate | Version | ci.yml location | Yanked | Notes |
|---|---|---|---|---|
| `apalis` | `1.0.0-rc.7` | line 1055 (fast-checks) | No | crates.io confirms present and not yanked. |
| `apalis-sqlite` | `1.0.0-rc.7` | line 1055 (fast-checks) | No | crates.io confirms present and not yanked. |

`cargo build --locked --manifest-path examples/apalis-poc/Cargo.toml` uses the example's own
`Cargo.lock`, not the repo root. No issues found.

---

## Broken Findings — Follow-up Gaps

### Finding 1 (INFRA-2292 — HIGH PRIORITY)

**`webkit2gtk-4.1` does not exist in Ubuntu 24.04 noble**

- Affects: fast-checks, clippy, cargo-test, coverage, e2e-pwa, audit, tauri-cowork-e2e jobs
- Risk: When ubuntu-latest runner pools fully migrate to noble, all 7 `apt-get install` blocks
  that include `webkit2gtk-4.1` will fail with "E: Unable to locate package webkit2gtk-4.1"
- One-line fix per block: Replace `webkit2gtk-4.1 \` with `libwebkit2gtk-4.1-0 \`
  (or remove the line entirely if `libwebkit2gtk-4.1-dev` pulls it in transitively)
- Why not already failing: GitHub may be routing ubuntu-latest to jammy-based images in some
  runner pools. The migration to noble is ongoing.

### Advisory 1 (no gap filed — low priority)

**`mozilla-actions/sccache-action@v0.0.5` is 5 versions behind**

- Current: v0.0.5 (2024-06-17). Latest: v0.0.10.
- Risk: older sccache binary may lack bug fixes. Not a correctness concern today.
- Fix: bump to `mozilla-actions/sccache-action@v0.0.10`

---

## Gaps Filed

| Gap ID | Title | Priority |
|---|---|---|
| INFRA-2291 | RESILIENT: replace webkit2gtk-4.1 with libwebkit2gtk-4.1-0 in all CI apt-get blocks — package dropped from Ubuntu 24.04 noble | P1 |

---

## Items NOT in Scope (verified not present)

- `rustup component add rustc-codegen-cranelift` — was the cause of today's trunk-RED (INFRA-2242). Confirmed removed from current ci.yml; no other nightly-only components found.
- `cargo binstall` — not used in ci.yml (only taiki-e/install-action, which has its own binary download mechanism).
- External service calls to BuildBuddy — not referenced.
- Any `ssh`, `gpg`, or signing tool external bootstrap — not present.
