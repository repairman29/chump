#!/usr/bin/env python3
"""discord-gateway.py — RESILIENT-266 serenity-free Discord receive gateway.

Opens an OUTBOUND WebSocket to Discord's gateway (no inbound endpoint, no domain,
no TLS to terminate, no serenity → sidesteps SECURITY-004's vulnerable rustls-webpki).
Receives operator DMs + button-click interactions and acts on them, replying via the
Discord REST API (the same path notify-operator.sh already uses).

This is the RECEIVE half of Chump<->operator Discord. The SEND half is
scripts/coord/lib/notify-operator.sh (bash+curl). Together = two-way.

Env:
  DISCORD_TOKEN            bot token (required)
  CHUMP_READY_DM_USER_ID   the ONLY user whose DMs/buttons are honored (required)
  CHUMP_REPO               repo root for status/exec commands (default cwd)
  CHUMP_DISCORD_GW_INTENTS override the intents bitfield (default DIRECT_MESSAGES)

Command surface (DM the bot):
  status | brief   → fleet ship-rate + recent merges
  ping             → pong (liveness)
  help             → this list
Button interactions (custom_id "approve:<id>" / "deny:<id>") are acknowledged and
logged to ambient; wiring them to the approval resolver is the next slice.

Run: DISCORD_TOKEN=... CHUMP_READY_DM_USER_ID=... python3 discord-gateway.py
Needs: pip install websockets
"""
from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
import time
from pathlib import Path

try:
    import websockets
except ImportError:
    sys.stderr.write("discord-gateway: needs `pip install websockets`\n")
    sys.exit(3)

GATEWAY = "wss://gateway.discord.gg/?v=10&encoding=json"
API = "https://discord.com/api/v10"
TOKEN = os.environ.get("DISCORD_TOKEN", "").strip()
OPERATOR = os.environ.get("CHUMP_READY_DM_USER_ID", "").strip()
REPO = os.environ.get("CHUMP_REPO", os.getcwd())
AMBIENT = Path(REPO) / ".chump-locks" / "ambient.jsonl"
# DIRECT_MESSAGES (1<<12). Interactions are delivered regardless of intents.
# MESSAGE_CONTENT (1<<15) is privileged; enable it in the dev portal to read DM text.
INTENTS = int(os.environ.get("CHUMP_DISCORD_GW_INTENTS", str(1 << 12)))

# Opcodes
OP_DISPATCH, OP_HEARTBEAT, OP_IDENTIFY = 0, 1, 2
OP_RECONNECT, OP_INVALID_SESSION, OP_HELLO, OP_HEARTBEAT_ACK = 7, 9, 10, 11


def now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def emit(kind: str, **extra) -> None:
    """Best-effort ambient event — mirrors the fleet's observability."""
    try:
        AMBIENT.parent.mkdir(parents=True, exist_ok=True)
        rec = {"ts": now(), "kind": kind, **extra}
        with AMBIENT.open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec, separators=(",", ":")) + "\n")
    except Exception:
        pass


def _curl_post(url: str, payload: dict) -> int:
    """POST JSON with the bot auth. Returns HTTP code (0 on transport error)."""
    try:
        out = subprocess.run(
            ["curl", "-sS", "--max-time", "10", "-o", "/dev/null",
             "-w", "%{http_code}", "-X", "POST", url,
             "-H", f"Authorization: Bot {TOKEN}",
             "-H", "Content-Type: application/json",
             "-d", json.dumps(payload)],
            capture_output=True, text=True, timeout=15,
        )
        return int(out.stdout.strip() or 0)
    except Exception:
        return 0


def send_dm(content: str) -> None:
    """Open the operator DM channel and post a message (REST, no serenity)."""
    try:
        ch = subprocess.run(
            ["curl", "-sS", "--max-time", "10", "-X", "POST",
             f"{API}/users/@me/channels",
             "-H", f"Authorization: Bot {TOKEN}",
             "-H", "Content-Type: application/json",
             "-d", json.dumps({"recipient_id": OPERATOR})],
            capture_output=True, text=True, timeout=15,
        )
        ch_id = json.loads(ch.stdout).get("id")
        if ch_id:
            _curl_post(f"{API}/channels/{ch_id}/messages", {"content": content[:1990]})
    except Exception:
        pass


def run_status() -> str:
    """Cheap ground-truth status the operator can ask for from their phone."""
    try:
        merges = subprocess.run(
            ["git", "-C", REPO, "log", "origin/main", "--since=1 hour ago", "--oneline"],
            capture_output=True, text=True, timeout=15,
        ).stdout.strip().splitlines()
        head = subprocess.run(
            ["git", "-C", REPO, "log", "origin/main", "--oneline", "-1"],
            capture_output=True, text=True, timeout=10,
        ).stdout.strip()
        n = len(merges)
        lines = "\n".join(f"• {m}" for m in merges[:6]) or "• (none in last hour)"
        return f"**Fleet status** — {n} merge(s) in the last hour.\nHEAD: {head}\n{lines}"
    except Exception as e:
        return f"status error: {e}"


QUICK_COMMANDS = ("status", "brief", "fleet", "ping", "help", "?", "commands")

DISPATCH_SCRIPT = Path(REPO) / "scripts" / "dispatch" / "discord-command-agent.sh"
# INFRA-3596: cap concurrent fresh-agent dispatches so a burst of DMs can't
# fan out unbounded `claude -p` processes (cost + resource guard alongside
# the per-invocation --max-budget-usd inside the script itself).
MAX_CONCURRENT_DISPATCHES = int(os.environ.get("CHUMP_DISCORD_AGENT_MAX_CONCURRENT", "1"))
_dispatch_semaphore: "asyncio.Semaphore | None" = None

# INFRA-3597: The Advisor — DISTINCT from the ops command agent above. The
# ops agent ACTS on a DM (may file gaps); the Advisor only reads + replies,
# never mutates anything. Reached with an explicit "advisor"/"advise" prefix
# so Jeff can choose "act on this" (default free text -> ops agent) vs. "just
# tell me" (advisor prefix) from the same DM thread.
ADVISOR_SCRIPT = Path(REPO) / "scripts" / "dispatch" / "discord-advisor-agent.sh"
ADVISOR_TRIGGERS = ("advisor", "advise")
MAX_CONCURRENT_ADVISOR_DISPATCHES = int(os.environ.get("CHUMP_DISCORD_ADVISOR_MAX_CONCURRENT", "1"))
_advisor_semaphore: "asyncio.Semaphore | None" = None


def handle_command(text: str) -> str:
    cmd = text.strip().lower().split()[0] if text.strip() else ""
    if cmd in ("status", "brief", "fleet"):
        return run_status()
    if cmd == "ping":
        return "pong ✅ (gateway online, receiving)"
    if cmd in ("help", "?", "commands"):
        return ("Chump gateway — try: `status` (ship-rate + recent merges), "
                "`ping` (liveness), `help`, `advisor <question>` (read-only "
                "Advisor — knows the fleet, never acts), or any other "
                "free-text command/question — a fresh Chump agent will read "
                "board state, act, and reply.")
    return ""


def extract_advisor_question(text: str) -> "str | None":
    """Returns the question text if `text` opens with an Advisor trigger
    word ("advisor"/"advise"), else None. Case-insensitive; the trigger word
    itself is stripped from what's handed to the Advisor agent."""
    stripped = text.strip()
    if not stripped:
        return None
    parts = stripped.split(None, 1)
    if parts[0].lower() not in ADVISOR_TRIGGERS:
        return None
    return parts[1].strip() if len(parts) > 1 else ""


async def dispatch_command_agent(text: str) -> None:
    """INFRA-3596 DISPATCH: hand a free-text operator command to a fresh,
    bounded `claude -p` agent (scripts/dispatch/discord-command-agent.sh) that
    reads board state and replies via notify_operator itself. Fire-and-forget
    from the gateway's perspective — awaiting the subprocess here would block
    the single-threaded gateway loop (heartbeats, other DMs) for the agent's
    full runtime, so this runs as a background task instead."""
    global _dispatch_semaphore
    if _dispatch_semaphore is None:
        _dispatch_semaphore = asyncio.Semaphore(MAX_CONCURRENT_DISPATCHES)
    # scanner-anchor: "kind":"discord_command_agent_dispatch_failed"
    async with _dispatch_semaphore:
        if not DISPATCH_SCRIPT.exists():
            emit("discord_command_agent_dispatch_failed", reason="script_missing")
            send_dm("(command agent dispatch script is missing — cannot act on that yet.)")
            return
        try:
            proc = await asyncio.create_subprocess_exec(
                "bash", str(DISPATCH_SCRIPT), text,
                cwd=REPO,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            await proc.wait()
        except Exception as e:
            emit("discord_command_agent_dispatch_failed", reason=str(e)[:160])
            send_dm(f"(couldn't start the command agent: {e})")


async def dispatch_advisor_agent(question: str) -> None:
    """INFRA-3597 DISPATCH: hand an "advisor"-prefixed DM to a fresh, bounded,
    READ-ONLY `claude -p` agent (scripts/dispatch/discord-advisor-agent.sh)
    that knows the fleet (almanac + live state) and replies via
    notify_operator itself — it never acts. Fire-and-forget from the
    gateway's perspective, same shape as dispatch_command_agent above."""
    global _advisor_semaphore
    if _advisor_semaphore is None:
        _advisor_semaphore = asyncio.Semaphore(MAX_CONCURRENT_ADVISOR_DISPATCHES)
    # scanner-anchor: "kind":"discord_advisor_agent_dispatch_failed"
    async with _advisor_semaphore:
        if not question:
            send_dm("(ask me something — e.g. `advisor what's blocking PR 2780`.)")
            return
        if not ADVISOR_SCRIPT.exists():
            emit("discord_advisor_agent_dispatch_failed", reason="script_missing")
            send_dm("(advisor dispatch script is missing — cannot answer that yet.)")
            return
        try:
            proc = await asyncio.create_subprocess_exec(
                "bash", str(ADVISOR_SCRIPT), question,
                cwd=REPO,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            await proc.wait()
        except Exception as e:
            emit("discord_advisor_agent_dispatch_failed", reason=str(e)[:160])
            send_dm(f"(couldn't start the advisor agent: {e})")


async def gateway_loop() -> None:
    seq = None
    async with websockets.connect(GATEWAY, max_size=2**20) as ws:
        hello = json.loads(await ws.recv())
        interval = hello["d"]["heartbeat_interval"] / 1000.0

        async def heartbeat():
            while True:
                await asyncio.sleep(interval)
                try:
                    await ws.send(json.dumps({"op": OP_HEARTBEAT, "d": seq}))
                except Exception:
                    return

        await ws.send(json.dumps({
            "op": OP_IDENTIFY,
            "d": {"token": TOKEN, "intents": INTENTS,
                  "properties": {"os": "linux", "browser": "chump", "device": "chump"}},
        }))
        hb = asyncio.create_task(heartbeat())
        emit("discord_gateway_connected", intents=INTENTS)
        print(f"[discord-gateway] connected, intents={INTENTS}", flush=True)

        try:
            async for raw in ws:
                msg = json.loads(raw)
                if msg.get("s") is not None:
                    seq = msg["s"]
                op = msg.get("op")
                if op in (OP_RECONNECT, OP_INVALID_SESSION):
                    print("[discord-gateway] reconnect requested", flush=True)
                    return
                if op != OP_DISPATCH:
                    continue
                t, d = msg.get("t"), msg.get("d", {})

                if t == "READY":
                    u = d.get("user", {})
                    print(f"[discord-gateway] READY as {u.get('username')}#{u.get('discriminator')}", flush=True)
                    continue

                if t == "MESSAGE_CREATE":
                    # DMs only (guild_id absent), from the operator only, ignore our own.
                    if d.get("guild_id") or str(d.get("author", {}).get("id")) != OPERATOR:
                        continue
                    content = d.get("content", "")
                    if not content:  # MESSAGE_CONTENT intent off → empty; nudge once
                        send_dm("(I received your DM but can't read its text — enable the "
                                "MESSAGE CONTENT intent in the Discord dev portal. Buttons "
                                "and `status` still work.)")
                        continue
                    emit("discord_operator_command", command=content[:120])
                    print(f"[discord-gateway] operator: {content[:80]}", flush=True)
                    advisor_question = extract_advisor_question(content)
                    if advisor_question is not None:
                        # INFRA-3597: explicit "advisor"/"advise" prefix routes
                        # to the read-only Advisor instead of the ops command
                        # agent — checked first so it wins even over quick
                        # built-ins (e.g. "advisor status" asks the Advisor
                        # to explain status, not run the built-in).
                        # scanner-anchor: "kind":"discord_advisor_command"
                        emit("discord_advisor_command", question=advisor_question[:120])
                        asyncio.create_task(dispatch_advisor_agent(advisor_question))
                        continue
                    reply = handle_command(content)
                    if reply:
                        send_dm(reply)
                    else:
                        # Not a quick built-in — hand off to a fresh helsinki
                        # Sonnet agent (INFRA-3596) that reads board state,
                        # may act (file a gap), and replies itself via
                        # notify_operator. Backgrounded so the gateway loop
                        # (heartbeats, future messages) stays responsive.
                        asyncio.create_task(dispatch_command_agent(content))
                    continue

                if t == "INTERACTION_CREATE":
                    inter_id, tok = d.get("id"), d.get("token")
                    custom_id = d.get("data", {}).get("custom_id", "")
                    uid = str(d.get("member", {}).get("user", {}).get("id")
                              or d.get("user", {}).get("id"))
                    if uid != OPERATOR:
                        # ACK so the client doesn't error, but do nothing.
                        _curl_post(f"{API}/interactions/{inter_id}/{tok}/callback",
                                   {"type": 4, "data": {"content": "not authorized", "flags": 64}})
                        continue
                    emit("discord_operator_interaction", custom_id=custom_id)
                    print(f"[discord-gateway] button: {custom_id}", flush=True)
                    # Phase 1: acknowledge with an ephemeral confirmation. Wiring
                    # custom_id -> approval_resolver / dispatch is the next slice.
                    _curl_post(f"{API}/interactions/{inter_id}/{tok}/callback",
                               {"type": 4, "data": {
                                   "content": f"received `{custom_id}` ✅ (action wiring lands next slice)",
                                   "flags": 64}})
                    continue
        finally:
            hb.cancel()


async def main() -> None:
    if not TOKEN or not OPERATOR:
        sys.stderr.write("discord-gateway: DISCORD_TOKEN and CHUMP_READY_DM_USER_ID required\n")
        sys.exit(2)
    backoff = 2
    while True:
        try:
            await gateway_loop()
            backoff = 2
        except Exception as e:
            emit("discord_gateway_disconnected", error=str(e)[:160])
            print(f"[discord-gateway] disconnected: {e}; retry in {backoff}s", flush=True)
        await asyncio.sleep(backoff)
        backoff = min(backoff * 2, 60)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
