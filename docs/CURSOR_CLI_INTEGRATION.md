# Cursor CLI integration

Chump can invoke the **Cursor CLI** (the `agent` command) to fix issues when you're online. Cursor's agent runs in non-interactive "auto" mode with full write access, so it can edit files and run commands without approval prompts.

## Prerequisites

- **Cursor CLI installed** and in `PATH`. Install: `curl https://cursor.com/install -fsS | bash`. The executable name is **agent** (not `cursor`).
- **Cursor CLI authenticated** — when Chump runs `agent -p "..." --force`, the CLI must be logged in. Do one of:
  - **Interactive:** Run `agent login` in your terminal once (browser or prompt); the CLI stores credentials for later use.
  - **Non-interactive (e.g. Chump):** Set `CURSOR_API_KEY` in your environment (e.g. in `.env`). Get the key from [Cursor account/settings](https://cursor.com/settings) or the CLI docs. Do not commit the key. If you use `run-local.sh`, it sources `.env`, so adding `CURSOR_API_KEY=...` there lets Chump's `run_cli` invoke `agent` successfully.
- **You're online** — Chump runs Cursor from your machine; Cursor uses your auth and workspace.
- **Chump can run it:** If you set `CHUMP_CLI_ALLOWLIST`, add `agent` to the list. If you don't use an allowlist, `agent` is already allowed.

## Enabling in Chump

Set in `.env`:

```bash
CHUMP_CURSOR_CLI=1
```

With that, Chump's system prompt tells him he may invoke Cursor CLI for complex fixes or when you ask. He will use:

- **Command:** `agent --model auto -p "<prompt>" --force` — use `--model auto` so Cursor picks the model; the task description goes in the `-p` argument (in quotes). There is no `--path`; put file paths or context in the prompt text. Example: `agent --model auto -p "fix the failing tests listed in logs/battle-qa-failures.txt" --force`.
- **Cwd:** Chump's `run_cli` already runs from `CHUMP_REPO` / `CHUMP_HOME`, so Cursor gets the correct workspace.
- **When:** For hard-to-fix issues, or when you say things like "use Cursor to fix this" or "let Cursor agent fix it."

Example (Chump would do this via run_cli):

```bash
agent --model auto -p "fix the failing tests listed in logs/battle-qa-failures.txt" --force
```

Or with an explicit workspace:

```bash
agent --model auto -p "fix the failing tests in logs/battle-qa-failures.txt" --force --workspace .
```

## Timeout

Cursor's agent can run a long time. Chump's `run_cli` uses `CHUMP_CLI_TIMEOUT_SECS` (default 120 in heartbeat). For Cursor invocations you may need a higher value (e.g. 300) or run from a context where timeout is larger.

## Improving the product and Chump–Cursor relationship

Chump is encouraged to **improve the product and how Chump and Cursor work together**. He may:

- **Write or update Cursor rules** (e.g. `.cursor/rules/*.mdc`) and **AGENTS.md** so Cursor follows repo conventions and handoff context.
- **Update docs** Cursor sees (e.g. `CURSOR_CLI_INTEGRATION.md`, `CHUMP_PROJECT_BRIEF.md`).
- **Use Cursor to implement** code, tests, and docs (not just research). Pass clear goals and context in the `-p` prompt.

The heartbeat **cursor_improve** round and the soul (when `CHUMP_CURSOR_CLI=1`) both direct Chump to do this. Use `write_file` / `edit_file` for rules and docs; use `run_cli agent -p "..." --force` for implementation.

## Safety

- Cursor CLI in `-p` (print) mode has **full write and shell access**; `--force` skips approval. Only enable `CHUMP_CURSOR_CLI=1` when you're okay with Chump delegating to Cursor on your machine.
- Chump will only call it when the soul says so (complex fix, you asked, or cursor_improve round). You can revoke by unsetting `CHUMP_CURSOR_CLI`.

## References

- [Cursor CLI overview](https://cursor.com/docs/cli/overview)
- [Cursor CLI parameters](https://cursor.com/docs/cli/reference/parameters) — `-p` / `--print`, `--force` / `--yolo`, `--workspace`
