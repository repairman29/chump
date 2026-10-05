# Design Gaps — make it run itself, then serve someone

**Status:** scoped (2026-09-10), gap tree filed to the fleet. Design foundation, not a rewrite.

These are five architectural gaps that keep ChumpOS from running itself and from
proving it serves anyone. Each is grounded in a live receipt from tonight's operator
session — not a vibe. The order is diagnostic; the build order is the two ranked
tracks at the bottom (Track A and Track B), because without those two every other
fix silently decays.

The through-line: **the machine is optimized to produce, trusts proxies for "done,"
and ends every control loop at a human. To run itself and serve someone it needs a
ratchet (solved stays solved), outcome-verification (did it actually do its job),
a served-gauge that closes the loop, and one honest mirror of its own state.**

---

## The five gaps

### Gap 1 — "Done" = merged, not running-and-verified

The architecture trusts proxies (`enabled`, `is-active`, `merged`) and never asks
the only question that matters: *did this actually do its job on the target node?*

**Receipt:** a `WorkingDirectory` pointing at a non-existent
`/home/ubuntu/Projects/chump` killed every organ at CHDIR and hid indefinitely —
`systemctl is-active` stayed green while every single run failed. Green never meant
working; it meant scheduled.

This is the root class behind "merged ≠ running" and the CHDIR incident. A proxy
for success is not success.

### Gap 2 — Every control loop ends in a human at the top

The final catch is always a person.

**Receipt:** tonight's stall detector was the operator ("fleet's down tho"). The
path bug was found by the operator's assistant. The apex watchdog that "runs from
the board" *is* a human. A system whose last line of defense is a person cannot,
by definition, run itself — it runs on the person.

Every automated loop bottoms out in a human backstop. That backstop is the thing
we are trying to remove, and it is load-bearing.

### Gap 3 — No ratchet: solved silently un-solves

Nothing enforces that a fix stays fixed, and nothing pages when it regresses.

**Receipt:** autonomy went 12.5% → 0% unnoticed. The self-heal for it was *built
and then switched off*. The worker filter froze in untracked config. Three
independent regressions, zero alarms — because there is no mechanism that says "this
was true, it must stay true, page me the moment it isn't."

This is the Anti-Memento disease: we re-solve the same failures because fixes decay
without enforcement-and-watching. (See Track A — this is the #1 build.)

### Gap 4 — Open loop: produces into a void

The system optimizes internal production because no real outcome closes the loop.

**Receipt:** 253 ships in 30 days, and the persons-served gauge has *never recorded
a single reading* — Mission Grade History reads "No mission-grade snapshots recorded
yet." Motion is measured to four decimal places; value has never been measured once.
With nothing on the far end of the loop, the optimizer maximizes ships, not served.

### Gap 5 — No faithful self-model

The machine cannot show its own true state, so a human hand-builds the mirror.

**Receipt:** the operator had to hand-build a "Prime Operating State" page on
claude.ai because no surface in the system tells the truth about itself — 35 organs,
57 timers, 4 cockpit surfaces, and not one single honest reflection of what is
actually running-and-working. Four dashboards and none of them is a mirror.

Without a faithful self-model, the operator has to reconstruct ground truth by hand
every session, and Gaps 2 and 4 can never close — you cannot remove the human catch
or measure served if the machine can't see itself.

---

## The two priority tracks

These are ranked **#1 and #2 to build.** Without them, every other fix decays: a
fix that isn't ratcheted un-solves (Track A), and a fix whose success is measured by
a proxy was never verified in the first place (Track B). Build these two and the
other three gaps become closeable rather than perpetual.

### Track A — THE RATCHET (solved stays solved)

**Gap:** ratcheting is ad-hoc and partial. Guards exist for *roster* (via
`organ-reconcile`), for *organ-death* (via the watchdog), and for *CI* — but **not**
for config values, capability toggles, or metric floors. So a self-heal can be
switched off, a metric can crater, and a load-bearing config can drift, all silently.

**Mine-before-build (these already exist — extend, don't rebuild):**
- `fleet-doctor-strict.sh` — 7 invariants, exits non-zero on any breach. The
  registry backbone.
- `vital-signs.sh` — the collector shape to reuse for metric readings.
- `autonomous-ship-rate.sh` — already computes a baseline and emits a
  `*_regression` signal on a >10pp drop. The regression-guard pattern to generalize.
- `CAPABILITY_DECISIONS.md` — the ledger of risky toggles that must be watched.
- PR #4593 — config-as-code, the hook for pulling load-bearing config into git.

**Build:**
1. **Invariant registry + one guard-organ** extending `fleet-doctor-strict`, so
   that adding a ratchet = registering an invariant (not writing a new bespoke
   check).
2. **Metric floors + regression-guards** on zero-touch %, hours-unattended, and
   served — generalizing the `autonomous-ship-rate` pattern beyond ship rate.
3. **Config-drift guard** for any load-bearing config living outside git.
4. **Meta-rule:** no fix ships for a recurring failure class without its
   invariant-check registered alongside it.

**Acceptance:** inject a regression — disable a self-heal, drop a metric below its
floor, or drift a load-bearing config — and be alerted **within one cycle,
autonomously** (no human noticing first).

### Track B — OUTCOME-VERIFICATION (verify it works, not that it's scheduled)

**Gap:** the fleet measures *scheduling* (`is-active`), not *success*. That is
exactly why the CHDIR bug hid — every organ was "active" while every run failed.

**Mine-before-build (these already exist — the first one is literally this job):**
- `chump-outcome-verify-heal-consumer` — **EXISTS, currently dark.** Its literal
  job is this track. Mine it hard before writing anything new.
- `systemctl show -p Result/ExecMainStatus` — a per-organ success signal that is
  present today and **unwatched fleet-wide**.
- `systemctl --failed` — the failed-unit list, likewise unwatched.
- durability-gauge (#4589) — top-level outcome-verify precedent.
- `organ-reconcile` — enforces *enabled-and-up*, but **not** *succeeded*.

**Build:**
1. **Organ-success verifier** — each cycle, check every manifest-enabled organ's
   last-run `Result` / `ExecMainStatus`; page/heal on **FAILED**, not just on
   inactive. *This alone catches the entire CHDIR class in minutes.*
2. **Effect-verification** for key organs — catch exit-0-but-no-op (e.g. the farmer
   ticking against an empty queue and reporting success).
3. **Redefine "done"** = verified running-and-effective *on the target node* — kill
   the proxy definition of done at its root (this is Gap 1's fix).
4. **Surface "verified-working N/M"** on the cockpit — a real number, not a green
   dot.

**Acceptance:** break an organ — exit-fail **or** silent no-op — and have it
**caught and paged within one cycle.**

---

## Gap tree filed to the fleet

- **RESILIENT umbrella — Ratchet track (solved stays solved)** + 4 sub-gaps
  (invariant registry / metric floors / config-drift guard / meta-rule).
- **RESILIENT umbrella — Outcome-verification (verify organs work not just
  scheduled)** + 4 sub-gaps (organ-success verifier / effect-verification /
  redefine done / cockpit surface).
- **Three tracked design gaps** for Gaps 2, 4, 5 (apex-human backstop /
  open-loop-no-served-gauge / no-faithful-self-model).

Every gap references this doc (`docs/design/DESIGN_GAPS_SELF_RUNNING.md`).
