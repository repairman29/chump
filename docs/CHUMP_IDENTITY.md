# Chump: soul, purpose, and heartbeat

Ways to make Chump smarter and expand its identity and behavior.

---

## Logs and memory

**Logs:** Chump appends to `logs/chump.log` (created in the bot’s cwd). Each line is timestamped and includes:

- `msg` – channel, user, and a short preview of the message
- `reply` – channel and reply length
- `cli` – command, args preview, exit code, output length

Use this to inspect activity and debug. The file is gitignored.

**Long-term memory:** Chump has a `memory` tool (store/recall). Storage prefers **SQLite** (`sessions/chump_memory.db`) with FTS5 keyword search and optional **hybrid recall** (RRF of keyword + semantic when the embed server or in-process embedding is used). Falls back to `sessions/chump_memory.json` when the DB path isn’t available. He’s prompted to store important facts and preferences and to recall them so conversations have depth and continuity across sessions. Recall can take an optional search phrase and a limit. See [CHUMP_SMART_MEMORY.md](CHUMP_SMART_MEMORY.md).

---

## Plans and execution with guidance

Chump is prompted to **make plans and execute them with your guidance**. For multi-step tasks he will: (1) propose a short plan, (2) ask for a go-ahead or changes before doing anything destructive or important, (3) use `run_cli` step by step and report back so you can say “next”, “skip that”, or “do X instead”. Override or sharpen this with `CHUMP_SYSTEM_PROMPT` if you want stricter confirmation or more autonomy.

---

## Soul (personality and voice)

**What it is:** The consistent “who” of the bot—tone, values, and how it responds.

**How it’s set:** The **system prompt** defines Chump’s soul. You can override it with env:

```bash
export CHUMP_SYSTEM_PROMPT="Your custom paragraph describing Chump's personality, limits, and voice."
```

**Default** (in code) is a friendly, sharp-witted assistant with a clear purpose (see below). Tweak that paragraph or replace it via `CHUMP_SYSTEM_PROMPT` to change voice, humor, formality, or boundaries.

**Ideas to expand:**

- Add a short backstory or role (“you’re a dev buddy who’s been in the trenches”).
- Specify what Chump won’t do (e.g. no medical/legal advice, no pretending to be someone else).
- Add a few example phrasings so the model mirrors the style.

---

## Purpose (mission and scope)

**What it is:** What Chump is _for_—its main job and priorities.

**How it’s set:** Purpose is part of the system prompt (default: help people think clearly, get unstuck, and ship). Include it in `CHUMP_SYSTEM_PROMPT`:

- One line: “Your purpose: …”
- Optional: “You prioritize X over Y” or “When in doubt, do Z.”

**Ideas to expand:**

- Narrow scope: “You focus on code, design, and shipping—not general knowledge.”
- Broaden: “You help with ideas, decisions, and follow-through in work and side projects.”
- Add constraints: “You don’t make commitments for the user; you suggest and they decide.”

---

## Memory (context across turns)

**What it is:** Chump remembering what was said in this channel/DM so replies stay on topic.

**How it works:** Each Discord channel (and each DM) has a **per-channel session** stored under `sessions/discord/<channel_id>/`. The agent loads that history for the channel before each reply and appends the new exchange, so it naturally has short-term memory in that conversation.

**Limits:** History is in-memory per request and persisted to disk; very long threads can hit context limits of the model. Future improvement: summarize or trim old turns and keep a “recent + summary” window.

---

## Heartbeat (proactive behavior)

**What it is:** The bot doing something on a schedule or trigger instead of only replying to messages (e.g. periodic check-ins, daily summary, or “here’s a nudge” in a channel).

**Current state:** Chump is **reactive only**—it replies when DMed or @mentioned. There is no background timer or “heartbeat” task yet.

**How you could add it:**

1. **Timer task:** In the Discord binary, spawn a `tokio::spawn` loop that runs every N minutes.
2. **What it does:** Decide the action (e.g. “should I post in channel X?”). Options:
   - Call the same agent with a system prompt like “You are Chump. It’s your heartbeat moment: optionally suggest one short nudge or tip for this server.” and post the reply to a configured channel.
   - Or run a lighter rule (e.g. “post a single line from a list”) without the full model.
3. **Config:** Store heartbeat channel ID and interval in env (e.g. `CHUMP_HEARTBEAT_CHANNEL_ID`, `CHUMP_HEARTBEAT_MINUTES`) or a small config file under `sessions/` (gitignored).

**Design choice:** Heartbeat can be “Chump’s voice” (same persona, optional proactive message) or a separate, minimal task. Keeping it optional and off by default avoids surprise messages until you want them.

---

## CLI / exec tool

Chump has full CLI access in Discord by default (private bot). He can run any command unless you restrict or block.

- **Default:** No allowlist = any executable. Commands run in the bot’s **cwd** (where you started `run-discord.sh`). Timeout 60s, output truncated to 2500 chars.
- **Optional restrict:** Set `CHUMP_CLI_ALLOWLIST=openclaw,git,cargo,...` to allow only those executables.
- **Optional block:** Set `CHUMP_CLI_BLOCKLIST=rm,sudo,...` to forbid specific executables.
- **`CHUMP_CLI_TIMEOUT_SECS`** – Override timeout (default 60).

He uses `run_cli` with `command` and `args`; one command per call, then he can run more in follow-up turns. For multi-step plans he runs them in sequence and reports back.

---

## Making Chump smarter (beyond identity)

- **Better model:** Use the 30B DWQ model (e.g. vLLM-MLX + `./serve-vllm-mlx.sh`) for harder reasoning and nuance.
- **Tools:** Calculator, `run_cli` (full CLI by default), `memory` (store/recall), when available `wasm_calc` (sandboxed WASI calculator), when `CHUMP_DELEGATE=1`: `delegate` (summarize), and when `TAVILY_API_KEY` is set: `web_search` (Tavily; use for research and self-improvement; store learnings in memory). See [WASM_TOOLS.md](WASM_TOOLS.md) and [ORCHESTRATOR_WORKER.md](ORCHESTRATOR_WORKER.md).
- **Richer prompt:** In `CHUMP_SYSTEM_PROMPT`, add 1–2 sentences of “when the user asks X, do Y” or “always include Z when answering about code.”
- **Session length:** If a channel thread gets very long, consider a separate “summary” step or trimming old messages so the model stays within context limits.

---

## Quick reference

| Levers           | Where                                          | Effect                                               |
| ---------------- | ---------------------------------------------- | ---------------------------------------------------- |
| Soul             | `CHUMP_SYSTEM_PROMPT` (env)                    | Personality, tone, boundaries                        |
| Purpose          | Inside system prompt                           | Mission and scope                                    |
| Memory           | `sessions/discord/` per channel                | Conversation context                                 |
| Heartbeat        | Not implemented yet                            | Optional proactive messages                          |
| CLI / exec       | Always on in Discord; optional allow/blocklist | Run any CLI; plans + guidance                        |
| Long-term memory | `memory` tool, SQLite/JSON + optional embed    | Store/recall across sessions; see CHUMP_SMART_MEMORY |
| Logs             | `logs/chump.log`                               | Messages, replies, CLI runs                          |
| Smarter model    | vLLM-MLX 30B, better prompt                    | Reasoning and consistency                            |

---

## Future direction

For prioritized next steps (hybrid memory, speculative decoding, structured tool output, WASM sandbox, multi-agent), see [ROADMAP.md](ROADMAP.md).
