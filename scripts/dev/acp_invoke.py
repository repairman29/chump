#!/usr/bin/env python3
"""acp_invoke.py (INFRA-3452) — the receipt-as-a-test primitive.

Drive a chump `--acp` agent through ONE real turn and report whether a specific
tool was actually INVOKED (with what outcome), by reading the chump_tool_calls
audit log before/after. This tests at the altitude of real use: it catches the
class where a tool is registered / in a profile / present in the binary but the
agent still cannot reach it (the 2026-07-28 comprehend_repo profile gap, which
every structural check missed).

Usage:
  acp_invoke.py --bin <chump> --repo <cwd> --tool <name> --target <path> [--timeout N]

Exit 0 iff <tool> was invoked and its latest outcome is 'ok'. Prints a one-line
JSON result to stdout regardless, so a wrapper can aggregate.
"""
import argparse, json, os, sqlite3, subprocess, sys, threading, time


def audit_db(repo):
    # chump writes tool calls to <cwd>/sessions/chump_memory.db
    return os.path.join(repo, "sessions", "chump_memory.db")


def count_calls(db, tool):
    try:
        c = sqlite3.connect(db)
        n = c.execute("SELECT count(*) FROM chump_tool_calls WHERE tool=?", (tool,)).fetchone()[0]
        c.close()
        return n
    except Exception:
        return 0


def latest_outcome(db, tool):
    try:
        c = sqlite3.connect(db)
        row = c.execute(
            "SELECT outcome FROM chump_tool_calls WHERE tool=? ORDER BY rowid DESC LIMIT 1",
            (tool,),
        ).fetchone()
        c.close()
        return (row[0] if row else "")[:40]
    except Exception:
        return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default="/opt/homebrew/bin/chump")
    ap.add_argument("--repo", required=True)
    ap.add_argument("--tool", required=True)
    ap.add_argument("--target", default="")
    ap.add_argument("--prompt", default="")
    ap.add_argument("--timeout", type=int, default=140)
    args = ap.parse_args()

    db = audit_db(args.repo)
    before = count_calls(db, args.tool)

    prompt = args.prompt or (
        f"Invoke the {args.tool} tool now"
        + (f' with arguments {{"repo": "{args.target}"}}' if args.target else "")
        + ". Use the tool itself as a tool call — do NOT use run_cli, bash, or a "
        "shell command. Then reply with one short sentence about what it returned."
    )

    env = dict(os.environ)
    env["CHUMP_REPO"] = args.repo
    env["PATH"] = "/Users/jeffadkins/.cargo/bin:/usr/bin:/bin:" + env.get("PATH", "")

    p = subprocess.Popen([args.bin, "--acp"], cwd=args.repo, env=env,
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True, bufsize=1)
    responses, done = {}, threading.Event()

    def reader():
        for line in p.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                m = json.loads(line)
            except Exception:
                continue
            if m.get("id") is not None and "method" not in m:
                responses[m["id"]] = m
                if m["id"] == 9:
                    done.set()

    threading.Thread(target=reader, daemon=True).start()

    def send(o):
        p.stdin.write(json.dumps(o) + "\n")
        p.stdin.flush()

    send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
          "params": {"protocolVersion": "2026-04", "clientInfo": {"name": "smoke", "version": "0.1"},
                     "clientCapabilities": {"fs": {"read": True}}}})
    time.sleep(1.5)
    send({"jsonrpc": "2.0", "id": 3, "method": "session/new",
          "params": {"cwd": args.repo, "mcpServers": []}})
    time.sleep(2.0)
    sid = responses.get(3, {}).get("result", {}).get("sessionId")
    if not sid:
        print(json.dumps({"tool": args.tool, "invoked": False, "outcome": "", "error": "no session"}))
        p.kill()
        sys.exit(1)
    send({"jsonrpc": "2.0", "id": 9, "method": "session/prompt",
          "params": {"sessionId": sid, "prompt": [{"type": "text", "text": prompt}]}})
    done.wait(timeout=args.timeout)
    p.kill()

    after = count_calls(db, args.tool)
    invoked = after > before
    outcome = latest_outcome(db, args.tool) if invoked else ""
    print(json.dumps({"tool": args.tool, "invoked": invoked, "outcome": outcome,
                      "calls_before": before, "calls_after": after}))
    sys.exit(0 if (invoked and outcome == "ok") else 1)


if __name__ == "__main__":
    main()
