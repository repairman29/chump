# Fix CJ's failed dnsmasq.service — Operator Procedure

**Filed under:** `docs/process/PROCEDURES/` — INFRA-8034
**Source script:** `scripts/ops/fix-cj-dnsmasq.sh`

---

## Background

`dnsmasq.service` has been in `failed` state on closetjunky (CJ) since at
least 2026-09-26 (surfaced during a CJ health check). The fleet does not use
dnsmasq — it's a leftover, likely conflicting with `systemd-resolved` — so
the fix is disable+mask, not a config debug.

**CJ's other two failed units are expected and NOT part of this gap:**
`chump-backlog-sync-writer` (intentionally disabled, must not publish) and
`chump-organ-deploy` (root-privileged; CJ has no passwordless sudo). Leave
both alone.

## Why this needs an operator, not a session

`dnsmasq.service` is a system unit (not `--user`), so disabling/masking it
needs root — and CJ has no passwordless sudo (same constraint noted above for
`chump-organ-deploy`). Separately, no Claude Code session has been able to
reach CJ over SSH from off-box (see the confirmed access gap recorded in
`docs/process/PROCEDURES/verify-process-organ-heal-live.md`, INFRA-3650) —
unless the session's worktree happens to physically be running on CJ itself
(check `hostname` first).

## Steps (run ON closetjunky, by the operator or a session physically on CJ)

**1. Diagnose:**
```bash
systemctl --failed
systemctl status dnsmasq.service
```

**2. Run the fix script (prompts for sudo password interactively if needed):**
```bash
bash scripts/ops/fix-cj-dnsmasq.sh
```
Idempotent — safe to re-run. No-ops cleanly if dnsmasq.service isn't
installed on this node, or isn't currently failed. Preview without changing
anything: `bash scripts/ops/fix-cj-dnsmasq.sh --dry-run`.

If sudo can't self-elevate (no passwordless sudo, no interactive terminal),
the script prints the exact manual commands instead of failing silently:
```bash
sudo systemctl disable --now dnsmasq.service
sudo systemctl mask dnsmasq.service
sudo systemctl reset-failed dnsmasq.service
```

**3. Verify (AC1 + AC2):**
```bash
systemctl --failed
```
Expect only `chump-backlog-sync-writer` and `chump-organ-deploy` to remain —
`dnsmasq.service` must no longer appear.
