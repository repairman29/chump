# FTUE & User Profile System

> Spec for PRODUCT-003 (user profile data layer) and PRODUCT-004 (first-run conversation).
> North Star: "I'm happy to help — let's set you up for success."

---

## The Problem

Right now Chump starts every session knowing nothing. There's no memory of who the user is, what they care about, or how they want to work. Every interaction starts from zero. The cognitive architecture (neuromodulation, belief state, precision controller) runs blind — it has no user model to calibrate against.

This is the most important missing piece in the product.

---

## Three-Layer User Model

### Layer 1 — Identity & Relationship
*Persistent. Low-volatility. Set during onboarding, updated explicitly.*

Who the user is and how the relationship works. Changes rarely — maybe a few times a year.

```
name            TEXT        "Jeff"
role            TEXT        "founder, software developer"
domains         JSON        ["Rust", "AI agents", "product strategy"]
timezone        TEXT        "America/Denver"
created_at      DATETIME
last_seen_at    DATETIME
```

### Layer 2 — Current Context
*Volatile. Session-aware. Stale-flagged after 7 days without a touch.*

What the user is working on right now. Chump updates this based on what the user says. Items expire; Chump asks to refresh stale context.

```
key             TEXT UNIQUE     e.g. "project:chump", "goal:ftue-this-week"
value           TEXT            e.g. "Building the first-run experience spec"
context_type    TEXT            "project" | "goal" | "priority" | "blocker"
expires_at      DATETIME        now + 7 days on write
updated_at      DATETIME
```

### Layer 3 — Learned Preferences
*Chump-authored, user-confirmable. The relationship memory.*

Observations Chump made and the user confirmed. The difference between a tool and a working relationship.

```
key             TEXT UNIQUE     e.g. "prefers_async_checkins"
value           TEXT            e.g. "true"
source          TEXT            "user_explicit" | "chump_observed"
confirmed        BOOLEAN        false until user approves
note            TEXT            human-readable explanation
created_at      DATETIME
```

### Behavioral Regime
*Compiles into the precision controller at session start.*

```
checkin_frequency   TEXT    "frequent" | "async" | "autonomous"
risk_tolerance      TEXT    "low" | "medium" | "high"
communication_style TEXT    "concise" | "detailed" | "technical"
never_do            JSON    array of prohibited behaviors/topics
```

---

## Security Model

**Rule: the full profile never appears in any prompt, log, tool response, or error output.**

### Storage
- Separate SQLite file: `sessions/user_profile.db`
- File permissions: `600` (owner read/write only)
- Sensitive string fields (name, role, context values) encrypted with AES-256-GCM
- Encryption key stored in OS keychain via the `keyring` crate
- `sessions/` is already in `.gitignore` — profile never lands in git

### Injection
- `user_context()` returns a `UserContext` struct — a curated, sanitized summary
- **No raw field values** in the returned struct — behavioral summaries only
- The full profile is never in a single prompt
- Context injection is task-type aware: a coding task gets project context; a planning task gets goal context

### Rust interface
```rust
pub struct UserContext {
    pub display_name: Option<String>,       // first name only
    pub role_summary: String,               // "software developer and founder"
    pub current_focus: Vec<String>,         // max 3 active items, summarized
    pub behavioral_regime: BehaviorRegime,  // compiles into precision controller
    pub never_do: Vec<String>,              // hard constraints
}

pub fn user_context() -> Option<UserContext>;
pub fn update_context(key: &str, value: &str, ctx_type: ContextType) -> Result<()>;
pub fn record_preference(key: &str, value: &str, note: &str) -> Result<()>;
pub fn confirm_preference(key: &str) -> Result<()>;
pub fn profile_complete() -> bool;  // false on first run → triggers FTUE
```

### Never do
- Include raw profile fields in tool call results
- Write profile data to `ambient.jsonl` or any log file
- Return profile contents in error messages
- Commit any file under `sessions/` to git

---

## The `user_context()` Injection Model

Behavioral preferences (checkin_frequency, risk_tolerance) feed the `PrecisionController` at session start — they shape *how* Chump acts before the first message, not what it says.

Current context (active projects, goals) injects as a light summary in the system prompt. Rotated out as the session gets long. The model sees: "Jeff is currently focused on: [1-3 items]" — not the raw DB rows.

Identity (name, role) only surfaces in greeting/personalization. Never included in task-execution prompts.

---

## FTUE — The Onboarding Conversation

### Trigger
`profile_complete()` returns `false`. Runs exactly once per installation.

### The Five Questions

Chump opens with: *"I'm happy to help — let's set you up for success."*

Then asks in order, one at a time, waiting for real answers:

**Q1 — Name**
> "First — what should I call you?"

Writes to: `user_identity.name`

**Q2 — Role & Context**
> "What kind of work do you do? Give me the short version."

Writes to: `user_identity.role`, `user_identity.domains` (extracted)

**Q3 — Active Projects**
> "What are you working on right now? Walk me through your active projects."

Writes to: `user_context` (type: `project`, one row per project mentioned)

**Q4 — This Week**
> "What do you most want to accomplish this week?"

Writes to: `user_context` (type: `goal`)

**Q5 — Working Style**
> "Last one: how do you want me to work with you — check in often, update you async, or mostly just grind and tell you when something's done?"

Writes to: `user_behavior.checkin_frequency`

### After Q5
Chump summarizes what it heard, confirms, and says: *"Got it. Let's get to work."*

From this point, the first real task is whatever the user mentioned in Q3/Q4. Chump doesn't wait — it starts.

### The "Skip" Path
If the user says anything like "just get started" or "skip this" — Chump sets sensible defaults (`async`, `medium` risk, no context) and asks *one* question: "What do you want to work on?" Profile fills in over time.

---

## PWA Profile View

A dedicated **Profile** tab in the PWA. Three sections matching the three layers:

**About You** (Layer 1)
- Name, role, domains — editable inline
- "Last updated X days ago"

**Right Now** (Layer 2)
- List of active context items with types (project / goal / priority)
- Each item shows age and an expiry warning if >5 days old
- Add / edit / delete inline
- "Refresh" button Chump can suggest when context is stale

**What I've Learned** (Layer 3)
- List of Chump-observed preferences, each with source and explanation
- Pending confirmations highlighted — "Chump thinks: [X]. Is that right?"
- Delete any preference at any time

**Danger Zone**
- "Reset profile" — wipes all three layers, triggers FTUE again

---

## What This Enables

Once the profile exists:

- **Neuromodulation** calibrates dopamine/noradrenaline parameters from risk tolerance and checkin frequency at session start
- **Precision controller** sets the opening regime (exploit / balanced / explore) from the user's risk tolerance
- **Counterfactual module** can write back to Layer 3 when it learns something ("user always prefers small PRs")
- **Cold Water** can grade whether the heartbeat is actually matching user intent by comparing stated goals (Layer 2) against what actually shipped that week

The profile is the foundation that makes the heartbeat real.
