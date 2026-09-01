# RESILIENT-274 design doc — incident-commander duty-officer

> **Gap:** RESILIENT-441 (this doc) is the AC-mandated design slice of RESILIENT-274
> ("wire the incident-commander as a STANDING duty-officer + playbook registry").
> **Prior art this doc formalizes:** [`docs/design/DUTY_OFFICER.md`](design/DUTY_OFFICER.md)
> (the problem statement + narrative design), [`docs/process/PLAYBOOK_REGISTRY.yaml`](process/PLAYBOOK_REGISTRY.yaml)
> (the shipped registry, slice 1), [`scripts/coord/duty-officer-loop.sh`](../scripts/coord/duty-officer-loop.sh)
> (the shipped loop skeleton, slice 2). This doc exists because RESILIENT-441's AC asks
> for four specific artifacts — tier definitions, a registry **JSON schema**, a
> **trait contract**, and a **step-by-step business-instantiation example** — none of
> which existed as standalone, reviewable sections before this gap.
> **Status:** Design v1, submitted for RESILIENT-lead review (AC #3).

## 1. Tier definitions

The duty officer routes every firing health signal through exactly one of three
tiers, chosen by how deterministic the fix is — not everything is code, and not
everything needs a human.

| Tier | Name | Who acts | Latency | Coverage | Precondition to fire |
|---|---|---|---|---|---|
| **T1** | Executable auto-heal | code / a daemon — no agent, no operator | seconds | narrow (only anticipated failures) | the fix is deterministic and already exists as a script |
| **T2** | Agent-run runbook | a duty-officer agent, running the matching playbook doc | minutes | medium (known-shape incidents) | the signal has passed its reality-check gate (§1.1) |
| **T3** | Escalate to operator | human, paged over Discord | human-speed | the long tail (novel / halt-class) | the signal is genuinely novel, or matches one of the 4 halt-class triggers (T1–T4 in `AGENTS.md` § No-operator-escalation discipline) |

Routing is strictly ordered T1 → T2 → T3: a signal only reaches T2 if no T1
action is registered for it, and only reaches T3 if no T2 runbook resolves it
(or the runbook agent itself determines the incident is novel/halt-class).
**Paging the operator is the tier-3 fallback, never the default response.**

### 1.1 The reality-check gate (applies to every tier)

Every signal declares a `false_positive_class`. A signal known to cry wolf
(e.g. `farmer_auth_dead`, mis-called 4× per CREDIBLE-090) is never acted on
raw — it runs its `reality_check` command first (ground truth: is the fleet
still shipping? is trunk green?) and is dropped (`refuted`) if the check
contradicts the alarm. This is the same discipline as the `reality-check`
skill and `scripts/dev/reality-check.sh`; the duty officer is a scheduled
caller of that gate, not a reimplementation of it.

### 1.2 The verify obligation (T1/T2 only)

Every T1/T2 registry entry declares a `verify` clause: the **outcome** to
confirm, never `exit 0 == fixed`. An action that ran but didn't fix the
underlying condition is a `healed` verdict with a false verify, not a
success — see Durable-fix doctrine in `AGENTS.md`.

## 2. Registry JSON schema

`docs/process/PLAYBOOK_REGISTRY.yaml` is the shipped registry (YAML for
human authorship; loaded by `duty-officer-loop.sh`). This section is its
canonical **schema**, expressed as JSON Schema (draft 2020-12) so it can be
validated mechanically (`ajv`, `jsonschema`, or a Rust `schemars`-derived
check) regardless of the on-disk YAML/JSON serialization.

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://chump.internal/schemas/playbook_registry.json",
  "title": "PlaybookRegistry",
  "type": "object",
  "required": ["signals"],
  "properties": {
    "signals": {
      "type": "array",
      "items": { "$ref": "#/$defs/SignalEntry" }
    }
  },
  "$defs": {
    "SignalEntry": {
      "type": "object",
      "required": ["signal", "tier", "detect", "action", "verify", "false_positive_class"],
      "properties": {
        "signal": {
          "type": "string",
          "description": "Ambient event kind OR a derived-metric name. Must be unique across the registry.",
          "pattern": "^[a-z][a-z0-9_]*$"
        },
        "tier": {
          "type": "integer",
          "enum": [1, 2, 3],
          "description": "1=executable auto-heal, 2=agent-run runbook, 3=escalate."
        },
        "detect": {
          "type": "string",
          "description": "Human-readable trigger condition. Documented intent — the loop's actual detection logic lives in duty-officer-loop.sh."
        },
        "action": {
          "type": "string",
          "description": "Tier 1: path to an executable script. Tier 2: path to a runbook doc the agent executes. Tier 3: omitted or 'page' (routes through the quiet gate)."
        },
        "verify": {
          "type": "string",
          "description": "The OUTCOME to confirm after the action runs — never the fact that it exited 0."
        },
        "false_positive_class": {
          "type": "string",
          "description": "'none' if the signal is never a false alarm, else a short class name (e.g. 'brief-window false-alarm')."
        },
        "reality_check": {
          "type": "string",
          "description": "Required when false_positive_class != 'none'. The ground-truth command run BEFORE any action fires."
        },
        "page": {
          "type": "boolean",
          "default": true,
          "description": "Tier 3 only. false = log-and-suppress instead of paging (a known non-actionable signal that still needs a paper trail)."
        }
      },
      "allOf": [
        {
          "if": { "properties": { "false_positive_class": { "const": "none" } } },
          "then": { "not": { "required": ["reality_check"] } },
          "else": { "required": ["reality_check"] }
        }
      ]
    }
  }
}
```

Validation rules encoded above, matching the discipline already documented
in the YAML file's header comment:

1. `signal` is unique — the loop looks entries up by exact match.
2. `false_positive_class != "none"` **requires** `reality_check` — a signal
   that can cry wolf must declare how to check it, or the schema rejects it.
3. `tier: 3` entries may set `page: false` to record a suppressed-but-logged
   signal (mirrors `scripts/coord/operator-escalation-registry.txt`'s
   page/suppress binary) without inventing a second escalation path.

A CI gate (`scripts/ci/test-duty-officer-loop.sh` is the natural home) can
validate `PLAYBOOK_REGISTRY.yaml` against this schema on every touch —
tracked as a build-slice follow-up, not part of this design doc's AC.

## 3. Duty-Officer trait contract

The shipped implementation (`scripts/coord/duty-officer-loop.sh`) is
deliberately bash (Rust-First-Bypass logged in its header: glue over
existing ambient/registry/notify primitives, no state mutation beyond
ambient emit). This section specifies the **contract** that implementation
satisfies today and that any future Rust port (or a second harness's
implementation) must satisfy to be a conformant duty officer. It is written
as a Rust trait because that's the fleet's primary implementation language
(`crates/chump-coord`), but the contract is the interface, not the
language — a bash, Python, or TS implementation is conformant if it honors
the same pre/postconditions.

```rust
/// A single row of the playbook registry (see §2 schema).
pub struct SignalEntry {
    pub signal: String,
    pub tier: Tier,
    pub detect: String,
    pub action: String,
    pub verify: String,
    pub false_positive_class: Option<String>,
    pub reality_check: Option<String>,
    pub page: bool,
}

pub enum Tier { T1, T2, T3 }

/// Verdict returned by routing one signal. Mirrors the verdict strings
/// already emitted by duty-officer-loop.sh as kind=duty_officer_action.
pub enum Verdict {
    Healed { detail: String },        // T1 action ran; verify is the caller's job to confirm
    Refuted { detail: String },       // T2 reality-check contradicted the alarm; dropped
    RunbookNeeded { detail: String }, // T2 confirmed real; an agent must run the runbook
    Suppressed { detail: String },    // T3 signal has page=false; logged, not paged
    Paged { detail: String },         // T3 signal paged the operator
    Unregistered,                    // no registry entry — treated as novel, routes to T3
}

pub trait DutyOfficer {
    /// Load (or reload) the registry. Must reject a registry that fails
    /// the §2 JSON Schema — a duty officer never routes against an
    /// unvalidated registry.
    fn load_registry(&mut self, path: &Path) -> Result<(), RegistryError>;

    /// Scan the last `window_n` ambient lines (or equivalent signal source)
    /// for firing signals. Pure read — must not mutate ambient or registry.
    fn scan(&self, window_n: usize) -> Vec<FiredSignal>;

    /// Route ONE named signal through T1 -> T2 -> T3, per §1's ordering.
    ///
    /// Contract:
    ///   - MUST look up `signal` in the loaded registry before acting.
    ///   - If `false_positive_class.is_some()`, MUST run `reality_check`
    ///     and return `Verdict::Refuted` if it contradicts the alarm,
    ///     BEFORE taking any T1/T2/T3 action (§1.1 — never optional).
    ///   - T1: MUST execute `action` only when `execute == true` (a
    ///     conformant implementation defaults to log-only, mirroring
    ///     CHUMP_DUTY_OFFICER_EXECUTE=0); MUST emit the `verify` clause
    ///     as part of the outcome record, not just that the action ran.
    ///   - T3: MUST route escalation through the ONE existing quiet-gate
    ///     notify path (never a second/bespoke escalation channel) and
    ///     MUST honor `page == false` as suppress-not-page.
    ///   - MUST emit an auditable action record (ambient kind=
    ///     duty_officer_action or equivalent) for every routed signal,
    ///     including `Unregistered` — an un-owned signal is itself a
    ///     finding, not a silent no-op.
    fn route(&self, signal: &str, execute: bool) -> Verdict;

    /// Emit a liveness heartbeat. A duty officer that cannot prove it is
    /// alive is indistinguishable from the pre-RESILIENT-274 state (nobody
    /// on duty) — this is not optional instrumentation.
    fn heartbeat(&self) -> HeartbeatRecord;

    /// Report registry coverage: how many known ambient kinds have a
    /// registry entry vs. are un-owned. Surfaces the "un-owned tail" as a
    /// queryable list per DUTY_OFFICER.md §3 rule 3.
    fn status(&self) -> CoverageReport;
}
```

**Conformance mapping to the shipped bash implementation:**

| Trait member | `duty-officer-loop.sh` equivalent |
|---|---|
| `load_registry` | reads `$CHUMP_DUTY_OFFICER_REGISTRY`, no separate validate step yet (§2's CI gate closes this) |
| `scan` | `tick` subcommand, `$CHUMP_DUTY_OFFICER_WINDOW_N` |
| `route` | `route <signal>` subcommand; `$CHUMP_DUTY_OFFICER_EXECUTE` gates T1 execution |
| `heartbeat` | `heartbeat` subcommand, emits `kind=duty_officer_heartbeat` |
| `status` | `status` subcommand |

A future Rust port is a drop-in replacement only if it satisfies every MUST
above — the trait is written so the existing bash loop already conforms,
and so a second-harness (non-Claude) implementation has an unambiguous spec
to implement against, per `AGENTS.md`'s harness-neutral contract pattern.

## 4. Step-by-step business instantiation example

Per DUTY_OFFICER.md §7, the duty officer is not ChumpOS-specific: it is a
role, parameterized by a registry, that any business (a COTG customer) gets
as its always-on operations owner. Worked example — standing up a duty
officer for a hypothetical customer running a small e-commerce fulfillment
business ("Acme Fulfillment") on ChumpOS-managed infrastructure:

1. **Identify the business's health signals.** Acme's operator (a human at
   Acme, not a ChumpOS operator) and their onboarding ChumpOS instance
   enumerate what "on fire" looks like for *this* business — analogous to
   the fleet's `ambient.jsonl` kinds. Example signals: `order_queue_stalled`
   (no orders processed in 30 min during business hours), `shipping_api_5xx`
   (carrier API returning errors), `inventory_sync_drift` (warehouse count
   vs. DB count mismatch > 2%).

2. **Write `acme/PLAYBOOK_REGISTRY.yaml`** conforming to the §2 schema, one
   entry per signal, e.g.:
   ```yaml
   signals:
     - signal: order_queue_stalled
       tier: 1
       detect: "no order-status transitions in 30 min during 09:00-21:00 local"
       action: scripts/order-queue-kick.sh   # Acme-specific: restart the worker pool
       verify: "order queue depth decreasing within 5 min of kick"
       false_positive_class: none

     - signal: shipping_api_5xx
       tier: 2
       detect: "carrier API error rate > 10% over 10 min"
       reality_check: "curl the carrier status page — is this OUR integration or THEIR outage?"
       action: playbooks/SHIPPING_FAILOVER.md   # Acme-specific runbook: switch to backup carrier
       verify: "order fulfillment rate returns to baseline"
       false_positive_class: "carrier-side outage — not ours to fix, only to route around"

     - signal: inventory_sync_drift
       tier: 3
       detect: "warehouse count vs DB count mismatch > 2%"
       action: page
       verify: "n/a — human reconciliation required"
       false_positive_class: none
       page: true
   ```
   T1/T2 actions and runbooks are Acme-specific scripts/docs; the **registry
   format and the routing engine are shared**, not reimplemented per
   business (DUTY_OFFICER.md §6: build to share code, not to compete).

3. **Point the standing loop at the business registry.**
   ```bash
   CHUMP_DUTY_OFFICER_REGISTRY=acme/PLAYBOOK_REGISTRY.yaml \
   CHUMP_DUTY_OFFICER_NOTIFY_CMD=acme/notify-acme-operator.sh \
   CHUMP_DUTY_OFFICER_EXECUTE=1 \
     scripts/coord/duty-officer-loop.sh tick
   ```
   `CHUMP_DUTY_OFFICER_NOTIFY_CMD` is Acme's own delivery channel — per §5 of
   DUTY_OFFICER.md, this rides the same Discord-DM substrate a ChumpOS
   operator gets (`send_dm_if_configured` + `notify-operator.sh`), keyed to
   Acme's own `DISCORD_TOKEN` / recipient, not ChumpOS's. Same wiring,
   different keys — "what serves customer-0 must be what serves user-1."

4. **Schedule the loop as a standing daemon** (not a session-bound job — see
   `docs/process/SCHEDULING_LAYERS.md`): a launchd/cron entry running `tick`
   on an interval plus a periodic `heartbeat`, exactly as ChumpOS runs its
   own `com.chump.*` duty-officer plist.

5. **Verify the T1 loop end-to-end** before trusting it unattended: force a
   synthetic `order_queue_stalled` ambient event, confirm `route` fires
   `scripts/order-queue-kick.sh`, confirm the `verify` clause's condition is
   met, and confirm a `kind=duty_officer_action` record lands in Acme's
   ambient log. This is the acceptance test pattern already used by
   `scripts/ci/test-duty-officer-loop.sh` for the ChumpOS instance.

6. **Onboard escalation.** Acme's T3 (`inventory_sync_drift`) pages Acme's
   own operator — never ChumpOS's. The quiet-gate discipline (page only on
   T1-T4-class triggers, never routine) applies per-business exactly as it
   applies to the fleet: an Acme duty officer that pages its operator for
   every T1-resolvable blip has the same "cried wolf" failure mode CREDIBLE-090
   documented for ChumpOS.

7. **Grow the registry over time.** As Acme hits new incident classes, each
   one starts as a T3 (escalate, human diagnoses) and is demoted to T2 (once
   a runbook exists) and eventually T1 (once the runbook is automatable) —
   the same "progressively executable-ize the top recurring incidents"
   discipline from RESILIENT-274's acceptance criteria, applied per-business
   instead of per-fleet.

**What is shared vs. per-business:**

| Shared (built once, in ChumpOS core) | Per-business (Acme-specific) |
|---|---|
| Registry JSON schema (§2) | The actual `PLAYBOOK_REGISTRY.yaml` contents |
| `DutyOfficer` trait / `duty-officer-loop.sh` engine (§3) | T1 action scripts, T2 runbook docs |
| Reality-check gate mechanism | The specific `reality_check` commands per signal |
| Discord DM delivery substrate | The recipient's token/user-id |
| Tier semantics (§1) | Which signals map to which tier for this business |

## 5. Open items for the RESILIENT-lead review (AC #3)

- Confirm the §2 schema matches intended future validation tooling (ajv vs.
  a `schemars`-derived Rust check) — either is conformant, pick one before
  wiring CI.
- Confirm the §3 trait is the right home (`crates/chump-coord`) if/when a
  Rust port is scheduled, or whether the bash implementation remains
  canonical indefinitely (Rust-first criteria in `CLAUDE.md` would trigger
  a port once the loop crosses ~200 LOC or starts mutating `state.db`
  directly — today it doesn't).
- Confirm §4's business-instantiation shape matches the COTG productization
  plan once that has its own design doc (this doc's §4 is illustrative, not
  a COTG spec).
