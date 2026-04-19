# MCP Server Security Audit (COMP-013) — 2026-04-19

## Summary

All three first-party Chump MCP servers (`chump-mcp-adb`, `chump-mcp-github`,
`chump-mcp-tavily`) are **NOT VULNERABLE** to MCPwned / DNS-rebinding attacks.
The reason is structural, not defensive: every server speaks **JSON-RPC 2.0 over
stdio only** — there is no TCP/HTTP listener, no port binding, no Origin/Host
header to validate, and no browser-reachable surface. The MCPwned attack class
applies exclusively to MCP servers that expose an HTTP or SSE endpoint on
loopback; servers spawned as child processes by an MCP client and addressed via
their stdin/stdout pipes are out of scope. **COMP-009 (extending the MCP server
catalog from 3 to 6+) may proceed safely**, with one hard rule documented below:
new servers MUST also use stdio transport — adding any HTTP/SSE-based MCP server
re-opens the entire MCPwned threat model and triggers a re-audit.

## Per-server audit

### chump-mcp-adb
- **Transport / bind**: stdio only (`tokio::io::stdin()` line reader at
  `src/main.rs:285-289`). No `bind()`, no `TcpListener`, no HTTP server
  dependency in `Cargo.toml`.
- **Origin validation**: N/A — no HTTP requests reach this binary. The MCP
  client (Claude Desktop, Zed, chump) is the parent process; only that parent
  can write to the server's stdin.
- **Auth**: relies on process-level isolation (parent-child pipe). No token,
  no API key. Privileged actions are gated by a hardcoded shell-command
  blocklist (`ADB_SHELL_BLOCKLIST` at `src/main.rs:38-61`) that rejects
  `rm -rf /`, `factory_reset`, `flash`, `su `, `dd if=`, `chmod 777`, etc.
- **SDK version**: none. Hand-rolled JSON-RPC 2.0; deps are `serde`,
  `serde_json`, `tokio`, `anyhow` (`Cargo.toml`).
- **Verdict**: **SAFE** (re: DNS rebinding). One non-MCPwned hardening note
  in §"Recommended actions" below: the blocklist is substring-based and could
  be evaded by quoting / encoding tricks, but that is out of scope for this
  gap.

### chump-mcp-github
- **Transport / bind**: stdio only (`src/main.rs:373-377`). No HTTP server.
- **Origin validation**: N/A — stdio.
- **Auth**: relies on parent-process pipe + a repo allowlist
  (`CHUMP_GITHUB_REPOS`, enforced by `check_repo()` at `src/main.rs:68-81`).
  When the env var is unset, **all repos are allowed** — that is a defensive
  posture choice, not a DNS-rebinding bug. `gh` and `git` themselves
  authenticate via the user's existing credential store / `GITHUB_TOKEN`.
  Branch names are constrained to the `chump/` or `claude/` prefix at
  `src/main.rs:232-238` (coordination, not security).
- **SDK version**: none — same hand-rolled JSON-RPC stack.
- **Verdict**: **SAFE** (re: DNS rebinding).

### chump-mcp-tavily
- **Transport / bind**: stdio only (`src/main.rs:176-180`). The only network
  call is an *outbound* HTTPS POST to `https://api.tavily.com/search` using
  `reqwest` with `rustls-tls` — no listener.
- **Origin validation**: N/A — stdio.
- **Auth**: `TAVILY_API_KEY` env var, sent as a Bearer token to Tavily.
- **SDK version**: none.
- **Verdict**: **SAFE** (re: DNS rebinding).

## MCP SDK status

Chump does not depend on `rmcp`, the official `mcp-sdk`, or any other MCP
client/server SDK. Each server is a ~300-line hand-rolled JSON-RPC 2.0
read-line-then-respond loop over stdin/stdout. This is by design and is the
**explicitly recommended** transport in the MCP spec for local servers; it is
the only transport that is structurally immune to DNS rebinding because there
is no socket for a browser to address.

- **Current SDK version we depend on**: none (n/a)
- **Latest version available**: n/a
- **Known CVEs / advisories**: none applicable. The MCPwned class of
  vulnerabilities (publicly discussed in 2025 around HTTP-mode MCP servers
  binding to `0.0.0.0` or accepting any `Host` header) only affects
  HTTP/SSE-mode servers. Stdio-mode servers have no exposure.

## Recommended actions

- **Patches needed in `chump-mcp-*` code re: COMP-013**: NONE. No DNS
  rebinding mitigation is required because no server exposes an HTTP surface.
- **SDK upgrades needed**: NONE.
- **New conventions to add to the build process**:
  - Add a hard rule (now codified here): **new MCP servers MUST use stdio
    transport.** Any future server that introduces a TCP listener,
    `axum`/`hyper`/`actix` HTTP dependency, or an SSE/StreamableHTTP MCP
    transport REQUIRES a follow-up audit covering: (a) explicit `127.0.0.1`
    bind (never `0.0.0.0`, never unspecified), (b) Origin/Host header
    allowlist matching `localhost`, `127.0.0.1`, `[::1]` exactly, (c)
    per-server bearer token in addition to loopback binding (defense in
    depth — DNS rebinding can't bypass a token), (d) `cargo audit` clean for
    the chosen MCP SDK.
  - Optional follow-up gap (NOT this PR): grep guard in CI or
    `scripts/install-hooks.sh` that fails if `crates/mcp-servers/**/*.rs`
    introduces `bind(`, `TcpListener`, `0.0.0.0`, or an HTTP-server crate
    without a paired `docs/SECURITY_MCP_AUDIT-<server>.md` review.
- **Whether COMP-009 (extending MCP servers) can proceed safely**: **YES**,
  provided new servers continue to use stdio transport. If COMP-009 wants to
  add an HTTP/SSE-mode server, file a fresh security gap and re-audit before
  shipping.

## Non-MCPwned observations (out of scope, noted for follow-up)

These are NOT DNS-rebinding issues and are NOT being patched in this PR. They
are listed only so they aren't lost:

1. `chump-mcp-adb` shell blocklist is substring-based and case-insensitive,
   but does not normalize quoting / `$IFS` / hex escapes. A determined
   adversary with stdin access (which is already the trust boundary) could
   evade `rm -rf /` with e.g. `r""m -rf /`. Acceptable given the trust model
   (parent process == user's MCP client), worth a follow-up gap if we ever
   relax that model.
2. `chump-mcp-github` defaults to "all repos allowed" when
   `CHUMP_GITHUB_REPOS` is unset. Consider flipping the default to deny-all
   in a future hardening pass.
3. `chump-mcp-tavily` does not redact the `TAVILY_API_KEY` from any error
   path; current code does not log the key, but a future refactor that
   stringifies the request could leak it. Worth a follow-up linting gap.

## References

- MCP spec — transports overview:
  https://modelcontextprotocol.io/docs/concepts/transports
  (stdio is the recommended default for local servers)
- MCP spec — Streamable HTTP transport (the surface MCPwned targets):
  https://modelcontextprotocol.io/specification/2025-03-26/basic/transports
- Public MCPwned-class discussions (2025): HTTP-mode MCP servers binding
  unspecified addresses + accepting any `Host` header → browser-driven
  DNS-rebinding RCE. Mitigations: explicit `127.0.0.1` bind + Origin/Host
  allowlist + per-server bearer token.
- Local code audited:
  - `crates/mcp-servers/chump-mcp-adb/src/main.rs`
  - `crates/mcp-servers/chump-mcp-github/src/main.rs`
  - `crates/mcp-servers/chump-mcp-tavily/src/main.rs`
  - Each crate's `Cargo.toml` (no HTTP-server / MCP-SDK deps present).
