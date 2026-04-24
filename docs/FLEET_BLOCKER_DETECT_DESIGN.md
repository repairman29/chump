# Blocker detection (FLEET-012)

**Status:** shipped 2026-04-24. FLEET-010 (help-request system) is the next
gap; until it lands, blockers surface as `event=blocker_alert` lines on
`.chump-locks/ambient.jsonl`.

## What "stuck" means

Four orthogonal signals, any one of which is enough to declare the agent
blocked:

| Signal | Default trigger | Why this number |
|---|---|---|
| `ExecutionTimeout` | 60 min with no `mark_progress()` | matches CLAUDE.md "execution timeout > 60min" guidance |
| `CompileFailureLoop` | 3 consecutive `cargo check` failures | empirically the point where the model is fix-flailing instead of fixing |
| `ResourceExhaustion` | available RAM < 1024 MB (caller-supplied) | smaller models start swapping; agent loop becomes hostile to siblings |
| `CapabilityGap` | required `model_family` not in `read_all_local()` | hard-fail — no point retrying without the model |

## Pure detection + side-effect emit

`blocker_detect.rs` keeps detection (`ExecutionTimer`, `CompileFailureCounter`,
`check_resource_exhaustion`, `check_capability_gap`) **pure** — no I/O, no
clock except where `Instant::now()` is the obvious default. Each helper
exposes a test seam (`check_against(now, …)`) so unit tests don't sleep.

The single side-effecting function is `emit_blocker_alert(&Blocker)`, which
appends one JSON line to `.chump-locks/ambient.jsonl` mirroring the format
that `adversary::emit_ambient_alert` already uses. That keeps war-room /
musher consumers source-agnostic.

## Why pure RAM check (caller measures)

`sysinfo` is not in the dep tree, and adding it to detect "free RAM" pulls in
a cross-platform crate that does much more than we need. The pure helper
takes `available_mb` as an argument; the *caller* (orchestrator, agent loop)
decides how to measure — `sysctl`, `/proc/meminfo`, or hard-coded for tests.
This matches the same discipline the rest of `fleet_capability` uses
(numbers in, decisions out, no platform calls).

## Wiring (deferred)

The orchestrator hookup — calling `mark_progress()` from inside the agent
loop, sampling RAM each iteration, treating `cargo check` exit codes — is
**not** in this PR. That is a 1–3 line change at each call site and lives
naturally with FLEET-010 (which decides what to *do* with the alert: post
help-request, escalate to human, switch model). Shipping the detection
primitives first means FLEET-010 can wire them in mechanically.

## Acceptance criteria mapping

| Criterion | Status |
|---|---|
| Agent monitors execution time; flags if > 60min with no progress | ✅ `ExecutionTimer` (`DEFAULT_TIMEOUT_SECS = 3600`) |
| Detects compile failure loops (> 3 consecutive) | ✅ `CompileFailureCounter` (`DEFAULT_COMPILE_FAILURE_THRESHOLD = 3`) |
| Detects resource exhaustion (available_ram < threshold) | ✅ `check_resource_exhaustion` |
| Detects capability gap (required model family not available) | ✅ `check_capability_gap` against `fleet_capability` |
| Posts help request (FLEET-010) when blocker detected | ⚠️ deferred — emits `event=blocker_alert` to ambient.jsonl as the FLEET-010 stand-in |
| Test: timeout → help request appears in ambient stream | ✅ `timeout_emits_ambient_alert_line` |
