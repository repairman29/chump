# Session findings — 2026-08-09

Everything below was verified by running it. Where something is unverified it
says so. Written for the operator and whichever agent picks this up.

## Shipped and merged

| Gap | What | PR |
|---|---|---|
| DOC-089 | Vision anchor + all 70 strategy docs classified | #3524 |
| EFFECTIVE-396 | mold linker actually wired (was installed, never used) | #3509 |
| RESILIENT-248 | Zero-CI-runs detector + GitHub App token | #3525 |
| RESILIENT-263 | Chump reaches the operator's phone; chunking | #3544 |
| RESILIENT-266 | Discord gateway daemon; SECURITY-005 closed by design | #3551 |
| CREDIBLE-273 | First-pass-yield measurement | #3556 |

**Working now:** outbound Discord alerts; the gateway runs and answers DMs.
**Not working:** approve/deny from the phone (RESILIENT-277).

---

## The three that matter most

### 1. CREDIBLE-268 (P0) — merging a PR closes every gap it mentions

**Mechanism, verified on main.** `scripts/ops/github-webhook-receiver.py`:

- `_extract_gap_ids` (:161) — regex `\b([A-Z][A-Z-]+-\d+)\b` over **title AND body**
- `_auto_flip_gaps_done` (:243, CREDIBLE-092) — on any merged PR, runs
  `chump gap set <ID> --status done --closed-pr <N>` for **every** match

The receiver is **running**.

It calls `gap set`, not `gap ship` — so **INFRA-1392 PROOF-OF-MERGE never fires**
(that guard is on the ship path). And `gap set --status done` writes no
`closed_date`, which is why every falsely-closed gap has `closed_pr` set and
`closed_date` empty.

**Damage, from the emitter's own ambient trail: 30 flips across 8 PRs**
(#3551→7, #3544→5, #3556→5, #3554→3, #3549→3, #3553→3, #3548→2, #3550→2).
~8 legitimate, **~22 collateral**. It hits fleet PRs, not just one session.

**The illustration:** PR #3556 changed two files — the factory-yield decision
record and its script — and closed **five** gaps, including CREDIBLE-251 and
RESILIENT-250, *the two gaps that document identified as the causes of destroyed
PRs*. It closed them by citing them.

CREDIBLE-092's intent was sound (CI can't reach `state.db`, so merged gaps
stayed open and got re-claimed). The **extraction** is what's wrong.

### 2. INFRA-3580 (P1) — the repair path is broken, and it's a live risk

Reopened gaps keep a stale `closed_pr`, which is exactly the
`stale_post_merge_gap` shape `test-gap-closure-consistency.sh` detects. Right
now: RESILIENT-262, RESILIENT-265, CREDIBLE-265.

Nothing consumes that event today, so the repair holds. **Wiring a consumer
(CREDIBLE-275) before fixing this could re-close the work just recovered.**
Sequence matters.

There is no supported way to clear `closed_pr` — `--closed-pr` rejects empty,
no `--clear` flag exists, direct SQL is correctly refused.

### 3. CREDIBLE-275 (P1) — the telemetry contract is half-enforced

`EVENT_REGISTRY.yaml` declares `consumers:` per event. The coverage gate
enforces the **emit** side rigorously (emit-without-register AND
register-without-emit both fail CI) and mentions the word "consumer"
**zero times**.

`gap_flipped_done_on_merge` declares consumers `[fleet-brief, ops-audit,
waste-tally]`. Those tools exist (39/6/49 files). **None reads that event.**
30 destructive events accumulated in a stream three named consumers claimed to
watch. `stale_post_merge_gap` is the same — two for two.

Also: the registry's `trigger` says the receiver reads **"title/branch."** The
code reads **title/body**. That one word *is* CREDIBLE-268. A true doc would
have made this visible on inspection instead of an hour of forensics.

---

## Also filed

| Gap | P | What |
|---|---|---|
| RESILIENT-275 | P0 | A build in any worktree **deletes the fleet binary mid-build** (shared target dir, ZERO-WASTE-029) |
| RESILIENT-277 | P1 | Duplicate approval cards orphan `request_id`s — taps do nothing, turn hangs |
| RESILIENT-276 | P1 | No provider timeout; one slot hung **4m45s**, failover never fired |
| CREDIBLE-266 | P1 | 15-slot cascade logs `provider_ms` but never **which slot** |
| CREDIBLE-274 | P1 | No detector for instruments that **stopped reporting** (4 found by accident) |
| CREDIBLE-251 | P1 | The flake that **killed** PR #3510, and the gate that made it undiagnosable |
| RESILIENT-250 | P1 | Deadlock making #3499 structurally unmergeable |
| CREDIBLE-237/239 | P2 | Detectors whose scope stopped following the code |
| RESILIENT-262/265/270 | P1/P2 | Triage, approval loop, default transport |
| INFRA-3540/3541 | P2 | Audit docs-only lane + 31% sccache; fail-open pre-push guard |
| DOC-093/094/096 | P2/P3 | Port policy; four opt-in gates; parity obligation |
| CREDIBLE-276 | P3 | Loose ends (below) |

---

## Loose ends — CREDIBLE-276

1. **`pr-title-drift-detector.sh` never examined** — reads title+body+files+diff,
   may already overlap CREDIBLE-268.
2. **A dead flag shipped to main by this session** — `first-pass-yield.sh`
   parses `--json` and never uses it. Written hours after filing gaps about
   exactly this class.
3. **Main CI failure at 22:16:30 uninvestigated** — probably the
   `proof_of_merge` flake, **unverified**.
4. **Three fleet worktrees unexamined** — including **DOC-093**, a gap this
   session filed, now worked by someone else. Check it doesn't contradict the
   openclaw port policy.
5. **Stale artifacts** — `DISCORD_HANDOFF.md` says RESILIENT-266 is "in
   progress"; almanac's chump index is behind head.
6. **Yield sample half-classified** — 14 PRs measured, 7 classified. The
   "under 5% real defects" figure rests on those 7.
7. **The Discord gateway is still running and still broken** — it will keep
   producing dead approval cards. Land RESILIENT-277 or
   `launchctl bootout gui/$(id -u)/ai.chump.discord-gateway`.

---

## Where I was wrong, so nobody inherits it

- Filed **two P1s against designed behaviour** (markdown summary drop; the
  remote-cached repos-cache) before reading the tool's own docs. Both retracted.
- Called RESILIENT-263 a "false-done" — it wasn't; I checked in the seconds
  between the flip and the merge.
- Claimed **"6 gaps falsely closed, none worked on."** Actual: 4 genuinely
  false, 1 misattributed, 1 premature.
- Proposed **empty `closed_date` as a detector** — it flags 555 of 1783 done
  gaps (31%). Useless.
- Wrote a preflight mirror and **didn't push it before #3544 merged**, turning
  main red for ~1h.
- Filed CREDIBLE-268 **without checking for prior art** —
  `test-gap-closure-consistency.sh` already existed.

## The through-line

Almost nothing here was a broken feature. It was **instruments that quietly
stopped telling the truth**: a notifier dead since May with `enabled = true`, a
gate asserting a file path instead of a behaviour, a negative assertion passing
vacuously, a cascade logging duration but not identity, an `operator_alert` that
alerted nobody, and a registry describing its own emitter incorrectly in exactly
the way that hid a P0.

CREDIBLE-273's yield metric can see none of them — nothing fails. That's why
CREDIBLE-274 and CREDIBLE-275 exist as its counterpart.
