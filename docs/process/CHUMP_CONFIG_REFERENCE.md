# `chump config` reference

**Status:** shipped — INFRA-2371 (2026-06-01).

`chump config` is a pure-read diagnostic surface that prints a structured
snapshot of the current chump runtime: cascade slots, privacy filters,
MCP server registry, config-file presence, and auth-token presence.

It **never invokes an LLM**, so it is safe to run when the cascade is
wedged or when a single malformed slot would otherwise 400 the whole
call. This is the surface to paste into a bug report when a colleague
asks "what's chump doing on your machine?".

## Usage

```bash
chump config                # same as `chump config show`
chump config show           # human-readable snapshot (default)
chump config --json         # one-line JSON object for machine consumers
chump config --help         # this reference
```

## Output sections (human mode)

```
chump config snapshot
=====================

CONFIG FILE
  /Users/<you>/.chump/config.toml (present)
                                              # — or (MISSING — run `chump init`)

PRIVACY
  CHUMP_ROUND_PRIVACY = safe (active)
  filtered: 2 of 5 cascade slots blocked by round privacy
    skip mistral_free (privacy=trains)
    skip gemini_free  (privacy=trains)

AUTH
  ANTHROPIC_API_KEY     present (length 108)
  CLAUDE_CODE_OAUTH_TOKEN not set
  OPENAI_API_KEY        present (length 51)

PROVIDER CASCADE (5 slots)
  -  local            tier=local privacy=safe rpm=0  rpd=0    today=0 key=present(len=51)
       base_url: http://127.0.0.1:11434/v1
  -  groq             tier=cloud privacy=caution rpm=30 rpd=14400 today=12 key=present(len=56)
       base_url: https://api.groq.com/openai/v1
  ...

MCP SERVERS (12 tools registered)
  chump-mcp-github: 7 tools registered
  chump-mcp-sqlite: 5 tools registered

(no LLM call was made to produce this snapshot)
```

The `chump init` nudge appears at the top whenever `~/.chump/config.toml`
does not exist (INFRA-2373 — same hint is added to `chump --help`).

## JSON mode (`--json`)

Single-line JSON for shell pipelines and PWA dashboards:

```json
{"config_toml":{"present":true,"home_set":true,"path":"/Users/me/.chump/config.toml"},
 "round_privacy":"safe",
 "auth":{"anthropic_api_key_len":108,"claude_code_oauth_token_len":null,"openai_api_key_len":51},
 "slots":[{"name":"local","base_url":"http://127.0.0.1:11434/v1","privacy_tier":"safe",
            "tier":"local","rpd_limit":0,"calls_today":0,"rpm_limit":0,"api_key_len":51,
            "filtered_by_round_privacy":false}, ...],
 "mcp":{"tools_registered":12,"by_binary":{"chump-mcp-github":7,"chump-mcp-sqlite":5}}}
```

The JSON schema is intentionally minimal — keys are stable, but additive
changes (new fields) can land without a major version bump. Consumers
should ignore unknown keys.

## What this does NOT show

By design:

- **Raw API key values.** Only lengths. If you need to verify a specific
  key, read it from `~/.chump/config.toml` directly.
- **Live network probes.** Use `chump fleet doctor` for the network-level
  health check (latency, 200 OK from each cloud endpoint).
- **Per-call cost tracking.** Use `chump cost-watch` or
  `chump cost record-pr`.
- **PR/gap state.** Use `chump gap list`, `chump health`, or
  `chump session-summary`.

## Related

- `chump init` — first-run setup (writes `~/.chump/config.toml`).
- `chump fleet doctor` — network-level health probe.
- `chump cost-watch` — real-time inference spend.
- `chump cascade stats` — per-slot hit/miss/error counts.

## Why this exists

Before INFRA-2371, bare `chump config` fell through to the LLM
gen path and 400'd from Gemini ("Function calling config is set
without function_declarations"). This was the most common "what's
broken on my machine" question during onboarding. The subcommand
is now a one-shot, always-works diagnostic that produces output a
new user can paste into a bug report immediately.

Paired with:

- **INFRA-2372** — cascade now treats the Gemini malformed-tool-config
  400 as cascade-able (skip slot, try next), so even a misconfigured
  cascade slot no longer aborts bare `chump`.
- **INFRA-2373** — `chump --help` and `chump config` both prepend a
  one-line `chump init` hint when `~/.chump/config.toml` is absent,
  so new users know what to run next.
