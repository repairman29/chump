# No-passwordless-sudo nodes — maintain via root organs only (INFRA-8058)

**Applies to:** closetjunky (CJ, role=gpu-embed, user=jeff) and any node without passwordless sudo.
Verified 2026-10-02: `sudo -n systemctl disable --now chump-armed-rebaser.timer` →
`sudo: interactive authentication is required`.

## The rule

1. A no-sudo node is maintained **only** through its root-privileged organs —
   `chump-organ-reconcile`, `chump-organ-deploy`, `chump-node-converge` (all run as root via
   systemd) — applying a **declarative desired state** (role roster / manifest) committed to the repo.
2. **No runbook, script, or ATC/first-mate step may assume interactive sudo** over a jeff-user SSH
   session. A fix that reconfigures a system unit (enable/disable/mask/install/edit
   `/etc/systemd/system`) ships as a desired-state change that reconcile applies as root.
3. If a one-off root action is unavoidable it must be an explicitly **operator-gated one-liner**,
   labelled as such, with the exact commands printed (never a silent self-elevation attempt) and a
   follow-up gap to convert it into reconcile-applied desired state.

Why: a step that needs manual sudo stalls on the operator and never self-heals; the same
change via reconcile is idempotent, auditable, and re-applied on drift. (INFRA-8057 is the model.)

## Audit of existing CJ-touching paths (2026-11-11)

| Path | Assumes sudo? | Disposition |
|---|---|---|
| `scripts/ops/fix-cj-dnsmasq.sh` + `docs/process/PROCEDURES/fix-cj-dnsmasq.md` | Yes (system unit disable/mask) | Operator-gated one-liner (already prints exact commands, never silently elevates). Durable form: declare dnsmasq masked in the CJ role roster applied by `chump-organ-reconcile`. |
| `chump-armed-rebaser.timer` / shipping-cruft disable | Yes (immediate step) | Durable fix routed through reconcile (INFRA-8057); immediate step is operator-gated. |
| `chump-organ-deploy` failed-unit note | n/a | Root organ itself — leave alone. |
| `docs/process/ADD_A_FLEET_NODE.md`, `LINUX_NODE_ONBOARDING.md` | Bootstrap only | Sudo is required once at first install; after the organs are installed, maintenance follows this rule. |

New CJ-touching scripts/runbooks must be added to this table or follow rule 2.

## Optional: scoped sudoers entry (OPERATOR DECISION — security tradeoff, NOT installed)

Grants the fleet user passwordless control of `chump-*` units only, for faster manual recovery.
It lets that user start/stop/disable any unit named `chump-*` as root (keep
`/etc/systemd/system` root-owned so the user cannot rewrite those units). Install only on
explicit operator approval:

```
# /etc/sudoers.d/chump-fleet   (mode 0440; validate with: visudo -cf /etc/sudoers.d/chump-fleet)
jeff ALL=(root) NOPASSWD: /usr/bin/systemctl enable chump-*, /usr/bin/systemctl disable chump-*, \
  /usr/bin/systemctl start chump-*, /usr/bin/systemctl stop chump-*, /usr/bin/systemctl restart chump-*
```

Note `--now` is a separate argument: `disable --now chump-x` will not match the lines above;
add explicit `enable --now chump-*` / `disable --now chump-*` entries if wanted. Default
posture remains: reconcile-applied desired state, no sudoers grant.
