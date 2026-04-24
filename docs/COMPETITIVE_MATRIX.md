# Competitive Matrix — Chump vs Cursor / Cline / Aider / Devin / Claude Code

> **Wedge (one sentence):** Chump is the only AI coding agent built as a
> **local-first multi-agent dispatcher with merge-queue-disciplined
> coordination** — N concurrent agents sharing one repo via lease-based file
> ownership, an ambient event stream, and a SQLite gap ledger — whereas every
> competitor is a single-agent, IDE-resident or cloud-hosted assistant.
>
> **Tradeoff accepted:** higher setup complexity (worktrees, lease files,
> pre-commit guards, gap registry) in exchange for concurrency that does not
> corrupt shared state. Users who want a single chat pane in an IDE should pick
> Cursor or Cline; Chump is for operators running a fleet.

This matrix is maintained by the Chump team and is **biased by construction**.
See *Honesty clause* at the bottom.

---

## Feature-diff matrix

| Capability | **Chump** | **Cursor** | **Cline** | **Aider** | **Devin** | **Claude Code** |
|---|---|---|---|---|---|---|
| **Local-first** (runs fully offline with local LLM) | Yes — Ollama / vLLM / mistral.rs first-class; cloud is optional cascade | No — cloud inference required | Partial — can point at Ollama / LM Studio, but UX is cloud-default | Yes — "can connect to almost any LLM, including local models" | No — fully hosted SaaS | No — requires Anthropic API |
| **Multi-agent coordination** (N concurrent agents, conflict-free shared state) | **Yes** — lease files, ambient.jsonl stream, merge queue, five pre-commit guards, gap registry | No — single agent per session | No — single agent per IDE window | No — single REPL session | Partial — "Teams" plan runs multiple Devins but no shared-repo lease protocol disclosed | No — single agent per session |
| **Mobile / edge inference** (ARM / Android / Pi) | Aspirational — Apple Silicon works today; Pi mesh in `FLEET-*` roadmap, not shipped | No | No | Indirect — works if the local LLM runs there | No | No |
| **Structured long-term memory subsystem** | Yes — SQLite FTS5 + embeddings + HippoRAG-inspired graph + per-gap briefings; cognitive-architecture research program (see RESEARCH_INTEGRITY.md) | No — session / project context only | No — session context only | No — chat-history + repo map | Proprietary "DeepWiki" + long-running tasks; internals not public | No — session context only |
| **OSS license** | **MIT** | Proprietary (closed source) | **Apache-2.0** | **Apache-2.0** | Proprietary (closed source) | Proprietary (closed source CLI; API terms) |
| **Pricing tier (lowest paid)** | **$0** — self-host; bring your own inference | $20 / mo (Pro) | $0 — pay the upstream API provider only | $0 — pay the upstream API provider only | $20 / mo (Pro) | Included with Anthropic subscription / API credits |
| **Install complexity** | Multi-step — clone, `cargo build`, install hooks, configure worktrees + leases | One-liner — download installer | One-liner — VS Code marketplace, JetBrains plugin, or `npm i -g cline` | One-liner — `python -m pip install aider-install` | Zero install — web app / Slack | One-liner — `npm i -g @anthropic-ai/claude-code` |

Legend: **Yes** = shipping and documented; **Partial** = supported but not the default path; **No** = not supported; **Aspirational** = on the roadmap but not yet landed; **unverified** = public specs unclear at retrieval time.

---

## Pricing — retrieved 2026-04-24

| Product | Free tier | Lowest paid | Team | Enterprise | Source |
|---|---|---|---|---|---|
| Chump | Self-host, $0 | n/a (self-host) | n/a | n/a | This repo, `LICENSE` (MIT) |
| Cursor | Hobby (free) | Pro — $20/mo | Teams — $40/user/mo | Custom | https://cursor.com/pricing (retrieved 2026-04-24) |
| Cline | Free (BYO API key) | n/a (pay upstream LLM provider) | n/a | n/a | https://cline.bot/ + https://github.com/cline/cline (retrieved 2026-04-24) |
| Aider | Free (BYO API key) | n/a (pay upstream LLM provider) | n/a | n/a | https://aider.chat/ + https://github.com/Aider-AI/aider (retrieved 2026-04-24) |
| Devin | Free — limited usage, DeepWiki + Devin Review | Pro — $20/mo | Teams — $80/mo (unlimited members, central billing) | Custom — SAML/OIDC SSO, dedicated team | https://devin.ai/pricing (retrieved 2026-04-24) |
| Claude Code | Included with Anthropic API credits / Claude subscription | Usage-based against API | Anthropic Teams plan (usage-based) | Anthropic Enterprise | https://www.anthropic.com/pricing (unverified at retrieval — plan names evolve; check before citing) |

Notes:
- "Free" for Aider / Cline is **tool-cost-free**; the user still pays the upstream LLM provider (OpenAI, Anthropic, OpenRouter, or $0 for fully-local models).
- Devin's $20 "Pro" tier was added after the original launch at $500/mo in 2024 and now includes Windsurf IDE access.
- Cursor "Ultra" ($200/mo) and Devin "Max" ($200/mo) land in the same price band but bundle different quotas.

---

## Where Chump loses

Honesty requires naming the axes where competitors beat Chump today:

- **First-run UX.** Cursor, Cline, and Claude Code are one-liner installs. Chump requires `cargo build`, hook install, worktree setup, and reading `CLAUDE.md` before the first commit. This is the single biggest adoption tax.
- **Single-developer ergonomics.** If you are one person writing one feature at a time, Cursor's in-editor inline-diff loop is faster than Chump's worktree + lease + merge-queue ceremony.
- **Hosted convenience.** Devin runs in the browser with zero local setup. That is genuinely valuable for users who do not want to touch a terminal.
- **Ecosystem reach.** Cursor / Cline have IDE plugins with millions of installs; Chump ships with a PWA, CLI, Discord bot, and ACP server but no VS Code plugin yet.

Chump's bet is that **the concurrency problem becomes dominant at N > 1 agents** and that no competitor is solving it at the coordination-primitive level.

---

## Update cadence

**Revisit on the first of each quarter** (next review: 2026-07-01). Re-verify every pricing cell and every "Yes / No / Partial" cell against public sources, and update the retrieval date. If a competitor ships multi-agent coordination, the wedge sentence at the top must be rewritten the same day.

---

## Honesty clause

This matrix is written by the Chump team and has obvious in-house bias. We have tried to cite public sources and mark unverified cells honestly, but we are not neutral. **Competitors and users are welcome to submit corrections via GitHub issue** — specifically, we want to hear about (a) pricing changes, (b) feature capabilities we marked "No" or "Partial" that are in fact shipping, and (c) any wedge claim we make that no longer holds. We will update the doc and the retrieval date on merge.
