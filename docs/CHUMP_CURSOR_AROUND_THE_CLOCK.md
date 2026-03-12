# Chump + Cursor: best setup for around-the-clock runs

What to configure so Chump and Cursor work together reliably when you run unattended (e.g. overnight or 24/7 on a machine that stays on). The goal is **real product improvement and a better Chump–Cursor relationship**: Chump can write Cursor rules, update docs Cursor sees, and use Cursor to implement code, tests, and docs—not just research.

## 1. Env and auth (required)

- **`.env`** (do not commit):
  - `TAVILY_API_KEY=...` — so Chump can use web_search in research and research_cursor rounds.
  - `CHUMP_CURSOR_CLI=1` — so Chump is allowed to invoke Cursor CLI.
  - `CURSOR_API_KEY=...` — so `agent` works non-interactively (no `agent login` prompt). Get from [Cursor settings](https://cursor.com/settings).
- **PATH** for the process that runs heartbeat (launchd, tmux, nohup) must include where `agent` lives, e.g. `$HOME/.local/bin` and optionally `$HOME/.cursor/bin`.

## 2. Cursor timeout in heartbeat

Cursor agent runs can take several minutes. In the same `.env` or in the launchd plist env:

```bash
CHUMP_CLI_TIMEOUT_SECS=600
```

So research_cursor rounds don’t kill the Cursor run at 120s. The test script already uses 600; heartbeat defaults to 120 unless you set this.

## 3. What to run “around the clock”

| Option | What it does | When to use |
|--------|----------------|-------------|
| **Self-improve heartbeat (launchd)** | Full cycle: work, opportunity, research, **cursor_improve**, discovery, battle_qa over 8h (or your duration). cursor_improve = improve product + Chump–Cursor (write rules, docs; use Cursor to implement). | Best default: one 8h session every 8h (or daily). |
| **Cursor-improve–only loop** | Only cursor_improve rounds via **research-cursor-only.sh**: improve product and relationship; write rules; use Cursor to implement. | When you want more rounds focused on product + Cursor without full work/opportunity/discovery. |
| **Heartbeat in tmux/nohup** | Same as above but in a terminal session; stops when you close the session unless you use nohup. | Quick “run for a while” without launchd. |

Recommendation: run **heartbeat-self-improve.sh via launchd** so it runs on a schedule (e.g. every 8h). That already includes one **cursor_improve** round per cycle (improve product and Chump–Cursor; write rules; use Cursor to implement). If you want more Cursor-focused runs, add a second schedule that runs **research-cursor-only.sh** (e.g. every 4h).

## 4. launchd plist for self-improve (Chump + Cursor)

Use the existing `scripts/heartbeat-self-improve.plist.example`. Important for Cursor:

- **WorkingDirectory** — your Chump repo (e.g. `/Users/you/Projects/Chump`).
- **EnvironmentVariables** — include:
  - `PATH`: `/usr/local/bin:/opt/homebrew/bin:/Users/YOU/.local/bin` (so `agent` is found).
  - Optionally: `CHUMP_CLI_TIMEOUT_SECS=600`, `CURSOR_API_KEY=...` (if you don’t load .env; the script sources `.env` from WorkingDirectory, so usually .env is enough).
- **StartInterval** — 28800 (8h) or 14400 (4h). Each run is one full heartbeat session (many rounds over the duration).

The script sources `.env` from the repo, so `TAVILY_API_KEY`, `CHUMP_CURSOR_CLI`, and `CURSOR_API_KEY` in `.env` are enough for Cursor + Tavily.

## 5. Optional: cursor-improve–only loop

If you want more rounds focused on product improvement and Chump–Cursor (rules, docs, Cursor to implement) without full work/opportunity/discovery:

- **Script:** `scripts/research-cursor-only.sh` — runs one cursor_improve round per invocation (same prompt as heartbeat cursor_improve). Logs to `logs/research-cursor-only.log`. Schedule it (cron or a second launchd job) every 2–4h.
- **launchd:** Copy `scripts/research-cursor-only.plist.example` to `~/Library/LaunchAgents/ai.chump.research-cursor-only.plist`, replace `/path/to/Chump` and `/Users/you`, then `launchctl load ~/Library/LaunchAgents/ai.chump.research-cursor-only.plist`. Default StartInterval is 14400 (4h).
- **Use case:** “Improve the product and make Cursor better here” more often (write rules, docs; use Cursor to implement).

## 6. Safety and guardrails

- **DRY_RUN:** Heartbeat respects `HEARTBEAT_DRY_RUN=1` / `DRY_RUN=1` (no push/PR). Use this if you want Cursor to edit code but not push.
- **Kill switch:** `touch logs/pause` or `CHUMP_PAUSED=1` — heartbeat skips rounds.
- **Notify:** Set `CHUMP_READY_DM_USER_ID` and `DISCORD_TOKEN` so Chump can DM you (blocked, PR ready, summary). You don’t need the Discord bot running for notify if the heartbeat process can reach Discord.

## 7. Monitoring

- **Heartbeat log:** `logs/heartbeat-self-improve.log` — round type, ok/exit non-zero.
- **launchd:** `launchctl list | grep chump` — job loaded; check StandardOutPath/StandardErrorPath for crashes.
- **Cursor runs:** Look for “run_cli” and “Round … (cursor_improve)” in the heartbeat log; increase `CHUMP_CLI_TIMEOUT_SECS` if you see timeouts on cursor_improve.

## Summary

1. Set **TAVILY_API_KEY**, **CHUMP_CURSOR_CLI=1**, **CURSOR_API_KEY** in `.env`; ensure **PATH** includes `~/.local/bin` for launchd.
2. Set **CHUMP_CLI_TIMEOUT_SECS=600** (in .env or plist) so Cursor isn’t killed mid-run.
3. Run **heartbeat-self-improve.sh** on a schedule (launchd every 8h recommended); that already runs **cursor_improve** once per cycle (improve product + Chump–Cursor; write rules; use Cursor to implement).
4. Optionally add **research-cursor-only.sh** on a separate schedule for more cursor_improve rounds.
5. Use **DRY_RUN** and **logs/pause** when you want to throttle or pause.
