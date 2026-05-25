# CP-007: Align Chump coord layer with Agent Client Protocol (ACP)

**Target:** Chump coord layer (`crates/chump-coord/`, INFRA-1118/1119/1120/1121 A2A
layers, INFRA-1758/1759/1761/1802/1803 in-flight foundation slices)
**Arsenal match:** `repairman29/registry` — a stale fork of
`agentclientprotocol/registry`, the Zed-led editor↔agent standard
**Recommended route:** **(c) Ignore — continue independent path, with one
narrow exception** (file a follow-up to add an ACP shim *as an inbound
adapter*, not as the coord layer's wire shape)
**Status:** proposed (2026-05-23, INFRA-1822)

---

## The Target

Chump is building an **agent-to-agent (A2A) coordination layer** in
`crates/chump-coord/`. Today the crate has 9 source modules and 11 integration
tests:

```
crates/chump-coord/src/
  lib.rs           — CoordClient (NATS connect, atomic gap claims, event emit)
  events.rs        — A2A Layer 1a pub/sub (INFRA-1758, foundation slice 1/4)
  rpc.rs           — A2A Layer 2b RPC (INFRA-1759, foundation slice 1/4)
  capability.rs    — A2A Layer 2c capability manifest (INFRA-1760, slice 1/4)
  scratchpad.rs    — A2A Layer 3d shared KV scratchpad (INFRA-1761, slice 1/4)
  assign.rs        — push-routing daemon (FLEET-034)
  work_board.rs    — FLEET-008 shared subtask queue
  help_request.rs  — FLEET-010 help-seeking protocol
```

The wire shape is **NATS-native** (JetStream subjects, KV buckets) with file
fallback (`.chump-locks/ambient.jsonl`) when NATS is unreachable. The problem
domain is *fleet-internal*: many Opus/Sonnet/Haiku worker sessions on one
operator's box (and eventually a Pi mesh) racing to claim gaps, posting help
requests, propagating lessons, sharing scratchpad state. There is no
"editor" in the picture.

In flight right now (5 active sibling leases): foundation slices 1/4 for
Layers 1a, 2b, 2c, and 3d (all type-only stubs) plus push-routing.

## The Arsenal Match (and the upstream ACP standard)

The Harvester catalog flagged `repairman29/registry`. Investigation reveals:

- **Fork status:** confirmed fork of `agentclientprotocol/registry` (parent
  in API response: `agentclientprotocol/registry`, id 1118231591).
- **Divergence direction (correction):** the catalog claim of *"276 commits
  ahead, 0 behind"* is inverted. `gh api repos/agentclientprotocol/registry/compare/agentclientprotocol:main...repairman29:main`
  returns `status: behind, ahead_by: 0, behind_by: 276, total_commits: 0`.
  Jeff's fork sits at commit `bcc37d4` (2026-04-16T01:46Z, "Update
  github-copilot-cli to 1.0.28") with **zero original commits**. Upstream
  marched 276 commits after the fork point — almost all hourly cron updates
  ("Update <agent> to <version>") plus a few release/CI tweaks (e.g.
  `55b484c` "Include registry-for-jetbrains.json in GitHub release").
- **Net:** there is no Jeff-authored divergence to harvest. The fork was
  taken once and never touched.

Upstream **ACP** itself (the protocol, repo `agentclientprotocol/agent-client-protocol`,
3.2k stars, 254 forks, Rust, last updated 2026-05-23) is well-described by its
own README banner from `zed.dev/img/acp/banner-dark.webp`:

> "The Agent Client Protocol (ACP) standardizes communication between
> *code editors* (interactive programs for viewing and editing source code)
> and *coding agents* (programs that use generative AI to autonomously
> modify code)."

The protocol is **JSON-RPC 2.0 over stdio**. The method surface from
`schema/meta.json` (v1):

```
agentMethods:   initialize, authenticate, logout,
                session/new, session/load, session/resume, session/list,
                session/prompt, session/cancel, session/close,
                session/set_config_option, session/set_mode
clientMethods:  fs/read_text_file, fs/write_text_file,
                session/request_permission, session/update,
                terminal/create, terminal/output, terminal/wait_for_exit,
                terminal/kill, terminal/release
```

The `registry` repo just lists agents that *implement* this protocol (current
membership: claude-acp, codex-acp, gemini, cursor, opencode, goose, github-copilot,
auggie, factory-droid, kimi, kilo, qwen-code, etc., each as a directory with
metadata). The registry distributes binaries (`darwin-aarch64`, `linux-x86_64`,
…), `npx` packages, or `uvx` packages — entries shaped by `agent.schema.json`:
`{id, name, version, description, distribution: {binary|npx|uvx}}`.

The two auth methods accepted by the registry (per `AUTHENTICATION.md`) are
**Agent Auth** (OAuth flow with local HTTP callback) and **Terminal Auth**
(interactive TUI handshake).

## Side-by-side comparison

| Concern | ACP (Zed standard) | Chump coord (in flight) | Overlap? |
|---|---|---|---|
| **Problem domain** | Editor ↔ coding agent (1:1 subprocess) | Worker ↔ worker (N:M fleet) | None |
| **Transport** | JSON-RPC 2.0 over stdio | NATS JetStream + KV + file fallback | None |
| **Connection lifecycle** | Editor spawns agent subprocess, holds it for the session | Workers are long-lived daemons; no spawner | None |
| **Auth model** | Agent Auth (OAuth browser flow) / Terminal Auth (TUI) | Operator-side: ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN (INFRA-622) | None — different actors |
| **Capability advertisement** | `agentCapabilities` returned from `initialize` (loadSession, promptCapabilities, mcpCapabilities) | `CapabilityManifest` in `chump_capabilities` KV bucket (skills, model_tier, gpu, machine, harness) | **Conceptual overlap** — both are "what can this agent do?" but the field sets are disjoint |
| **Session model** | One persistent conversation, `session/prompt` per user turn, `session/update` stream for progress | No sessions; gaps are the unit of work, claims are atomic, events are pub/sub broadcast | None |
| **Tool calls** | Permission-gated via `session/request_permission`, results streamed via `session/update` | No central tool gateway; each worker runs its own Claude-Code/opencode-bigpickle/etc. harness | None |
| **Filesystem** | `fs/read_text_file` / `fs/write_text_file` going *from agent back to client* | Direct fs access in each worker's process; no remote-fs RPC | None |
| **Registry** | `registry.json` listing agents with binary/npx/uvx distribution targets | `chump-binary` distribution is a single Cargo workspace; no agent registry needed | None |
| **A2A discovery** | Not modeled — ACP assumes 1 client + 1 agent | `subscribe_events` (Layer 1a) + capability KV (Layer 2c) for who's-online queries | **None** — ACP is silent on this |
| **RPC between peers** | Not modeled — ACP is client→agent only | `call_rpc` / `serve_rpc` (Layer 2b) for ask-eta/ask-overlap/ask-handoff/ask-progress/ask-capability | **None** — ACP doesn't have peer↔peer |
| **Shared state** | None | `chump_scratch` KV bucket with seed keys + CAS/LWW/MergeWithFn conflict policy (Layer 3d) | None |

**The overlap is one field: capability advertisement.** Even that overlap is
shallow — ACP's `agentCapabilities` describe what an agent can do *for an
editor* (load sessions, accept image prompts, speak MCP), while Chump's
`CapabilityManifest` describes what a worker can do *for the fleet* (which
skills, which model tier, which machine, which GPU). The two answer
different questions about different actors.

## The Verdict

**(c) Ignore — continue independent path.**

Rationale:

1. **No domain overlap.** ACP solves editor↔agent integration; Chump coord
   solves worker↔worker coordination. These are orthogonal problems with no
   shared primitives beyond the word "agent." Forcing ACP onto Chump's coord
   layer would be like making `kubectl` speak Language Server Protocol —
   plausible at the syntactic level, useless at the semantic level.

2. **The "276 commits ahead" framing was the misleading premise of this
   investigation.** With that corrected to "276 commits *behind* with zero
   original work," the apparent strategic urgency dissolves. There is no
   Chump-authored ACP IP to align around.

3. **Alignment cost would be high, benefit thin.** Wrapping the in-flight
   Layer 1a/2b/2c/3d work in ACP method names (`initialize`,
   `session/prompt`, …) would require either (a) reinterpreting fleet
   primitives as 1:1 editor↔agent sessions (a semantic mismatch — there is
   no editor) or (b) bolting NATS pub/sub onto a JSON-RPC stdio transport
   (a category mismatch). Either path delivers an "ACP-compatible" coord
   layer that no actual ACP client can use because the underlying problem
   has no client.

4. **Interop value is captured elsewhere.** ACP's real win is "any editor
   can drive any coding agent." Chump *participates* in that ecosystem by
   running ACP-speaking agents (claude-acp, opencode, codex-acp, goose) as
   workers — that integration sits in `chump-claude-impl` and
   `scripts/dispatch/worker.sh`, not in the coord layer.

### The narrow exception — file follow-ups, not alignment

Two follow-up gaps are warranted to capture the *real* opportunities the
investigation surfaced:

- **INFRA-NEW-ACP-INBOUND-SHIM (EFFECTIVE, P2, s).** Implement an inbound
  ACP adapter so Chump can be driven *as an ACP agent by an editor* (e.g.
  Zed user spawns `chump --acp` and asks it to ship gaps). Wire shape:
  small `crates/chump-acp/` that translates a subset of `session/prompt` →
  `chump --execute-gap`, with `session/update` notifications backed by
  ambient stream tail. **This is NOT alignment; it's a new ingress.**
  Scope: ~300 LOC, no impact on coord layer.

- **INFRA-NEW-CHUMP-IN-ACP-REGISTRY (EFFECTIVE, P3, xs).** If the inbound
  shim ships and is useful, submit a `chump` entry to `agentclientprotocol/registry`
  via the `CONTRIBUTING.md` flow (a `chump/` directory with `agent.schema.json`-shaped
  metadata). This is the only place Jeff's existing fork might come in
  handy — but submitting upstream via PR is cleaner than maintaining a
  long-lived divergent registry.

### What we do NOT need to do

- Do NOT rebase or supersede INFRA-1758, INFRA-1759, INFRA-1760, INFRA-1761,
  INFRA-1802, INFRA-1803. The in-flight foundation slices remain correct
  in shape (NATS-native A2A, file fallback, schema versioning).
- Do NOT introduce ACP method names into `crates/chump-coord/`. The
  `CoordEvent` / `RpcRequest` / `CapabilityManifest` / `SeedKey` types
  stay as designed.
- Do NOT take a dependency on the `agent-client-protocol` Rust crate from
  the coord workspace. (`chump-acp` ingress crate may take it; coord may
  not.)
- Do NOT spend further investigation cycles on the stale `repairman29/registry`
  fork — it has no Jeff-authored content and the upstream registry is
  hourly-bot-maintained.

## Bridge Strategy (if verdict had been (a) or (b))

Listed only for completeness so the verdict can be reconsidered if domain
assumptions change (e.g. if Chump pivots to *being* an editor-side host
for ACP agents, which would re-introduce ACP semantics natively).

For (a) full alignment: would require renaming `CoordEvent` → ACP
notifications, `RpcRequest` → ACP methods, `CapabilityManifest` →
`agentCapabilities`, and replacing NATS with stdio per-peer. Cost: full
rewrite of 5 in-flight crates; benefit: zero (no editor exists to drive it).

For (b) ACP shim atop existing coord: would mean two API surfaces (NATS-native
+ ACP-shaped) maintained in lockstep, with the ACP surface only ever
exercised by a hypothetical editor. Cost: ~2× coord-layer surface area;
benefit: theoretical interop with no concrete consumer.

Neither pencils out today. Revisit if/when an ACP client appears that wants
to drive a Chump fleet.

## Lineage / Risk

- **What could break this verdict:** Agentic AI Foundation extending ACP into
  agent↔agent semantics (e.g. a Layer 2c-equivalent `peer/capabilities`
  method). Monitor `agentclientprotocol/agent-client-protocol/issues` and
  `rfds/` quarterly. The schema currently has `version: 1` with stable
  wire format, so any extension would be additive within the same major.
- **What could change the calculus on the inbound shim:** demonstrated demand
  from a Zed user wanting `chump --acp`. Until that demand exists, INFRA-NEW-ACP-INBOUND-SHIM
  is P2 — file but don't pick.
- **Re-evaluate when:** (a) META-061 layers 1a/2b/2c/3d ship full impl and
  someone proposes adding "ACP compat" as a layer 4 — at that moment the
  empirical question becomes "is anyone asking for it?" If yes, build it
  as an inbound adapter (see exception above), not as a wire-shape rewrite.
- **Re-evaluate when:** (b) goose's coord layer adopts an A2A spec. Goose
  is in the ACP registry and an Anthropic-adjacent project; if they ship
  fleet-internal coord primitives, harvest *their* shape rather than the
  client↔agent ACP shape. File a parallel CP brief at that point.

## What this brief does *not* do

It does not commit. It does not modify `crates/chump-coord/`. It does not
file INFRA-NEW-ACP-INBOUND-SHIM or INFRA-NEW-CHUMP-IN-ACP-REGISTRY — those
filings are the PM's call on whether the exception is worth pursuing now.
It does not rebase or stop the 5 active sibling leases on `crates/chump-coord/*`.
It records a deliberate non-alignment decision for INFRA-1822's
acceptance criterion (c).
