# Fleet Node Architecture — the node contract

> **Status:** DRAFT, 2026-08-09. Written from the closetjunky recovery the same night it
> happened, while the evidence was still on the floor.
>
> **Thesis:** the fleet has excellent *work* coordination (gaps, leases, NATS routing,
> consensus) and no *node* coordination. A node is currently a machine somebody set up
> once and remembers. This doc makes a node a **declared contract** the fleet can read,
> verify, and act on.

---

## 0. Why this doc exists — the receipts

closetjunky was moved to a new physical location. Recovering it took an evening of
console typing. Every step below was a real failure, not a hypothetical:

| What happened | What it reveals |
|---|---|
| Box off-network 5 days; nothing paged | No node liveness distinct from fleet ship-rate |
| `ADD_A_FLEET_NODE.md` covers Ethernet only | Runbook assumes a link class that wasn't true |
| Operator hand-typed netplan with 5 defects | No declarative network config per node |
| `ufw` inactive, `fail2ban` absent, SSH password auth ON, since 2026-07-23 | No security baseline, no drift check |
| Box had a **public IPv6** + password SSH + no firewall | Posture is location-dependent; nothing re-evaluates on move |
| `chumpd` `disabled`, binary absent | No boot-persistence verification |
| Nobody could say what CJ has mounted | No storage/attachment inventory |
| `50-cloud-init.conf` silently overrode `99-hardening.conf` | Config *presence* checked, never *effective* value |

The last row is the whole doc in miniature. Every one of these was invisible because
**the fleet models work, not substrate.**

---

## 1. The core idea

> A node is not a box. A node is a **contract**: a declaration of what it is, what it is
> attached to, what posture it holds, and what it promises to run — plus a continuously
> verified claim that reality still matches the declaration.

Two consequences:

1. **Declared, not discovered.** Provisioning writes the contract. Drift is
   contract-vs-reality, which is checkable. Today "what is this box" lives only in
   operator memory, so drift is undetectable by construction.
2. **Verified, not asserted.** Every field carries `last_verified_at` and the probe
   that produced it. Presence is not validity — this is the same lesson as
   RESILIENT-086 (auth presence vs validity) and CREDIBLE-090 (signal vs outcome),
   applied to substrate.

---

## 2. Node lifecycle — the nine phases

Each phase names its artifact, today's state, and the gap.

### P0 — Provision
Bare box to toolchain. **Exists:** `scripts/setup/provision-chumpd-host.sh`,
`ADD_A_FLEET_NODE.md`. **Gap:** assumes Ethernet; no link-class branch.

### P1 — Identity
A node must have a stable name independent of hostname and tailnet IP.
**Artifact:** `~/.chump/node-id.txt` + a record in the fleet node registry.
**Today:** referenced in `DISK_AWARE_FLEET_2026-05-29.md` and INFRA-2193.
**Verified absent on both nodes** (checked 2026-08-09). Nothing generates it.

### P2 — Network
Declared link class (`ethernet` | `wifi` | `cellular`), declared uplinks, and a
**location-change procedure**. **Today:** none. A move means console recovery.
**Artifact:** per-node network stanza + `chump node network apply`.

### P3 — Security baseline
The posture every node must hold, verified by *effective* config, never by file
presence:

| Control | Probe (effective, not file) |
|---|---|
| Firewall default-deny inbound | `ufw status verbose` |
| Fleet path reachable | allow on `tailscale0` |
| SSH keys only | `sshd -T \| grep passwordauthentication` |
| Brute-force protection | `systemctl is-active fail2ban` |
| No service on a public interface | `ss -tlnp` minus loopback minus tailnet |
| Public-address exposure | probe **from another node**, not locally |

**Today:** Helsinki holds all six. closetjunky held **none** for 17 days. Nothing
compares them. The `sshd_config.d` first-value-wins trap means a naive grep check
would have reported PASS while the box was exposed.

### P4 — Runtime
What the node promises to run, and that it survives reboot.
**Probe:** `systemctl is-enabled` + linger + binary present + a post-reboot proof.
**Today:** `chumpd` was `disabled` with a missing binary and nothing noticed.

### P5 — Inventory
What the node *has*: disks, mounts, removable media, RAM, cores, accelerators.
**Today:** `chump disk status|plan|budget` **shipped** (`src/disk_cmd.rs`), but
`crates/chump-disk-inventory` is **absent** and no `~/.chump/disk-inventory.json`
exists on any node. **The consumer shipped without the producer.** This is
META-128 Wave 1 / C2, specced and dormant — fold it in here, do not re-file it.

### P6 — Observability
Node-level heartbeat distinct from fleet ship-rate. A node can be dead while the
fleet ships fine from another node — exactly what happened for 5 days.
**Artifact:** `kind=node_heartbeat` with contract-verification results attached.

### P7 — Recovery
The documented path back when a node is unreachable, **including the case where
the node has no network at all**. Tonight's working answer: USB phone tether as a
temporary uplink, then remote repair over SSH. That belongs in the runbook.

### P8 — Decommission
Lease release, registry removal, tailnet key revocation, credential rotation.
**Today:** undefined. Stale tailnet entries persist (several dead phones listed).

---

## 3. The node record

One file per node, generated at provision, verified continuously.

```yaml
node_id: closetjunky
hostname: closetjunky
role: worker                 # worker | broker | hub | runner
hardware:
  cores: 4
  ram_gb: 7
  disk_gb: 115
  arch: x86_64
network:
  link_class: wifi           # declared, drives the runbook branch
  tailnet_ip: 100.90.52.126
  known_aps: [CBCI-D2FB-2.4, Bits]
  public_v6: true            # posture-relevant, changes with location
security_baseline:
  firewall: {state: active, default_in: deny, verified_at: ...}
  ssh_password_auth: {value: false, probe: "sshd -T", verified_at: ...}
  fail2ban: {state: active, verified_at: ...}
  external_exposure: {probe_from: helsinki, result: blocked, verified_at: ...}
runtime:
  supervisor: chumpd
  enabled_at_boot: true
  linger: true
  mode: grind
  workers_desired: 2
storage:
  - {mount: /, fs: ext4, size_gb: 115, free_gb: 25}
  - {mount: /mnt/cjdata1, fs: ext4, label: CJDATA1, removable: true}
contract_verified_at: ...
```

**Registry:** `docs/fleet/nodes/<node-id>.yaml` in-repo (reviewable, diffable), with
the live verification results published to `chump.node.contract.<node-id>` over NATS
for the runtime view.

---

## 4. Claimed vs verified — honest current state

| Layer | Claimed | Verified 2026-08-09 |
|---|---|---|
| Work coordination | Strong | **True** — gaps, leases, NATS, consensus all live |
| Disk cost model + CLI | Shipped | **True** — `chump disk` works |
| Disk inventory daemon | Wave 1 | **Absent** — no crate, no snapshot on any node |
| Node identity | Referenced | **Absent** — no `node-id.txt` anywhere |
| Security baseline | Implied by Helsinki | **Not enforced** — CJ unhardened 17 days |
| Node liveness | Assumed via fleet health | **Absent** — 5-day outage unnoticed |
| Node registry | — | **Does not exist** |
| Wi-Fi provisioning | — | **Not in runbook** |

`infra-watcher` is the closest existing role, but its lane is *this Mac's* substrate
(launchd plists, self-hosted runner, `/tmp` pressure, claude proc bloat). It is
single-node by construction. Extending it is the natural Wave-1 host.

---

## 5. Wave plan

**Wave 1 — Declare (unblocks everything, no dependencies)**
- Node identity generator + `docs/fleet/nodes/*.yaml` registry
- `chump node contract show|verify` reading the record, probing reality
- Disk/mount inventory (META-128 C2) as the first inventory producer

**Wave 2 — Enforce**
- Security baseline probe set, effective-value based
- Cross-node external exposure probe (node A probes node B's public addresses)
- Boot-persistence verification, including a real reboot in the provision flow

**Wave 3 — Observe**
- `kind=node_contract_drift` + `kind=node_heartbeat`
- Node health surfaced in `chump fleet brief` alongside ship-rate
- infra-watcher generalized from single-Mac to per-node

**Wave 4 — Recover**
- Runbook branches by link class, Wi-Fi path included
- Off-network recovery procedure (tether)
- Decommission checklist

---

## 6. Success criteria

- Any node's full contract answerable in one command, no SSH archaeology
- A node that drifts from baseline is flagged **within one cycle**, not 17 days
- A node offline > 1h pages, independent of whether other nodes are shipping
- A new node reaches verified-contract state from bare metal via the runbook, on
  Wi-Fi or Ethernet, with no undocumented steps
- `chump disk plan` reads a real inventory snapshot rather than degrading silently

---

## 7. Operator decisions of record — 2026-08-09

These were open questions in the draft. The operator answered all four the same
night; they are now binding on the wave plan above, not up for re-litigation.

1. **Registry location — in-repo.** `docs/fleet/nodes/<node-id>.yaml`, reviewable and
   diffable. **Posture facts only; never credentials.** A node record may say
   "password auth is off"; it may never contain a key, token, or PSK.
2. **Enforcement posture — REFUSE WORK.** A node failing the security baseline is
   not merely flagged; the picker refuses to route work to it. This is the stronger
   and riskier option and was chosen deliberately. Corollary: the baseline probe is
   now on the critical path, so a false positive strands a healthy node — it must
   follow CREDIBLE-090 discipline (verify the outcome, not just the signal) before
   it can refuse.
3. **Scope — every node, including the Mac.** The Mac is a node and holds the same
   contract. It is currently the least-inspected machine in the fleet and the only
   one with no baseline at all.
4. **Cadence — aggressive.** Operator: "as aggressive as needed to keep things
   running." Read as: verify on every change event, plus a short periodic floor
   (minutes, not days). Bias toward noisy-and-correct over quiet-and-stale; tune
   down only with evidence of real false-positive cost.

### Consequences worth stating plainly

Decision 2 makes this doctrine, not tooling. A picker that refuses work based on a
substrate probe can halt the fleet if the probe is wrong. That is an acceptable
trade **only** with the CREDIBLE-090 gate in front of it, and it is why Wave 2
cannot ship before Wave 1's verification surface is trustworthy.

Decision 4 inverts the usual detector-tuning instinct. Tonight's failure mode was
*silence for 17 days*, not noise — so the default error direction is to over-report.
