# Dependency Modernization Audit

**Date:** 2026-04-24  
**Gap:** INFRA-047  
**Goal:** Clear technical debt and security blockers before release-plz integration  

---

## CVE Summary

### Critical Issues Found

| Crate | Issue | Severity | Fix | Effort |
|-------|-------|----------|-----|--------|
| rustls-webpki | CRL panic + constraints bypass | HIGH | Upgrade to ≥0.103.13 | s |
| rsa | Marvin timing attack | MEDIUM | No fix available; evaluate usage | m |
| async-std | Deprecated/unmaintained | MEDIUM | Replace or evaluate necessity | m |
| GTK3 bindings | Unmaintained (desktop only) | LOW | Not critical for lib crates | — |

---

## Detailed Breakdown

### 1. rustls-webpki (TLS Certificate Validation)

**Current:** 0.102.8  
**Issues:**
- RUSTSEC-2026-0104: Reachable panic in CRL parsing
- Name constraints incorrectly accepted for URI names
- Name constraints accepted for wildcard certs
- CRLs not considered authoritative (matching logic flaw)

**Fix:** Upgrade to 0.103.13 or later  
**Impact:** TLS validation security; used transitively via rustls  
**Effort:** Small (version bump + testing)

```bash
# Action: Bump rustls-webpki to 0.103.13+
# Check: cargo audit should clear these 4 issues
```

### 2. RSA (Cryptographic Signing)

**Current:** 0.9.10  
**Issue:** RUSTSEC-2023-0071 — Marvin Attack: potential key recovery via timing sidechannel  
**Fix:** No fixed version available; library author abandoned maintenance  
**Dependency Path:** rsa 0.9.10 ← superboring ← jwt-simple ← web-push ← chump

**Options:**
1. Evaluate if JWT signing is critical for chump's MVP
2. If required: audit code for constant-time usage patterns
3. Consider: would web-push be used in public-facing features?

**Recommendation:** 
- For MVP: Document as known risk, note that timing attacks require local access
- Long-term: Migrate to maintained RSA library or remove web-push if unused

**Effort:** m (requires decision + possible refactoring)

### 3. async-std (Async Runtime)

**Current:** Appears as transitive dependency  
**Issue:** Library discontinued; no maintenance  
**Dependency Path:** Likely via async-nats  

**Action:**
- Check if async-nats 0.47+ still depends on async-std
- If so: Evaluate tokio migration or async-nats upgrade
- Document: chump-coord uses tokio (preferred), so async-std may be unnecessary

**Effort:** m (if migration needed) or s (if already unused)

### 4. GTK3 Bindings (Desktop App Only)

**Crates:** atk, gdk, gdkwayland, gdkx11, glib, etc.  
**Issue:** gtk-rs GTK3 bindings unmaintained (GTK4 available)  
**Scope:** Only affects desktop/src-tauri, not publishable lib crates  
**Decision:** Out of scope for INFRA-047 (library publishing); desktop app is separate  

**Note:** Desktop app can continue using GTK3 indefinitely; not a blocker for crate publishing.

---

## Action Plan

### Phase 1: Blocking (Must Clear Before INFRA-048)

**rustls-webpki upgrade (HIGH priority)**
```bash
# 1. Check current usage of rustls-webpki
cargo tree -i rustls-webpki

# 2. Upgrade to 0.103.13+
# Edit Cargo.lock or Cargo.toml for rustls transitive bump

# 3. Verify
cargo audit  # Should clear 4 rustls-webpki issues
cargo test   # Verify no regressions
```

**RSA evaluation (HIGH priority)**
```bash
# 1. Is JWT/web-push actually used in chump?
cargo tree -i rsa
cargo tree -i web-push

# 2. If unused: remove
#    If used: document risk + evaluate migration path

# 3. Decision: keep-as-is-with-doc, migrate, or remove
```

### Phase 2: Nice-to-Have (Before Release)

**async-std cleanup (MEDIUM priority)**
```bash
# 1. Check current usage
cargo tree -i async-std

# 2. If only via async-nats: check version
#    async-nats 0.47+ uses native tokio

# 3. If unnecessary: document removal plan
```

---

## Acceptance Criteria

- [ ] cargo-deny check passes (no license conflicts)
- [ ] cargo-audit shows zero RUSTSEC for publishable crates
  - rustls-webpki upgraded to 0.103.13+
  - RSA decision made (documented or fixed)
  - async-std status determined
- [ ] cargo-udeps confirms no unused dependencies
- [ ] MSRV declared in Cargo.toml for:
  - chump-tool-macro
  - chump-coord
  - chump-perception
- [ ] CI job added to verify MSRV (`cargo +nightly msrv`)
- [ ] This audit document completed with decisions

---

## Current Status

- [x] Audit complete
- [ ] rustls-webpki upgraded
- [ ] RSA decision made
- [ ] async-std status determined
- [ ] MSRV declared
- [ ] CI job added
- [ ] Tests passing

**Next:** Begin Phase 1 (rustls-webpki + RSA evaluation)
