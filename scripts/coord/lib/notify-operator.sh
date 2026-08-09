#!/usr/bin/env bash
# notify-operator.sh — RESILIENT-263: reach the operator's PHONE when a
# production line stops.
#
# WHY THIS EXISTS. On 2026-08-08 pr-failure-auto-rescue closed PR #3510 after
# 23.2h on a single required check that was RED-but-false (a flake whose gate
# sat outside the retry wrapper). 23 hours of ready work was destroyed and
# nothing told the operator — he found out by asking, hours later. The daemon
# even had an outcome string named `operator_alert`, which wrote a log line and
# an ambient event and alerted nobody. A label, not an alert.
#
# WHY DISCORD AND NOT A NEW CHANNEL. The capability was already built,
# credentialed, addressed and in daily use — src/discord_dm.rs
# (send_dm_if_configured) has five live callers. DISCORD_TOKEN and
# CHUMP_READY_DM_USER_ID were already set. A Discord DM lands on the phone via
# the mobile app. Adding Pushover/iMessage/Telegram instead would have been the
# fleet's most-repeated mistake: building a second thing while the first sits
# uncalled. (TELEGRAM_BOT_TOKEN is also present but TELEGRAM_CHAT_ID is not, so
# that path is not addressable today — it is the documented fallback, not this.)
#
# CONTRACT — this is a bash mirror of src/discord_dm.rs's REST calls:
#   notify_operator "<message>"        → 0 on delivery, 1 on failure, 0 no-op
#                                        when unconfigured
#
# INVARIANTS, all load-bearing:
#   * NEVER prints the token, not even partially. Only lengths and HTTP codes.
#   * NEVER exits or kills its caller. A broken notifier must not break the
#     daemon it reports on — that would trade a silent failure for a louder one.
#   * Silent no-op when unconfigured, matching send_dm_if_configured's shape.
#   * SEVERITY-GATED BY THE CALLER, deliberately. Only "a line stopped" reaches
#     the phone. An escalation channel that cries wolf gets muted, and a muted
#     channel is the dead operator-recall handler all over again (RESILIENT-262:
#     that handler has been configured-but-not-running since 2026-05-08).
#
# shellcheck shell=bash

_notify_repo_root() {
    cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd
}

# Candidate .env locations, most-specific first.
#
# The worktree case is load-bearing, not defensive: .env is GITIGNORED, so it
# exists only in the main checkout. `chump claim` creates a worktree for every
# gap, so anything invoked from one would silently find no credentials and skip
# the alert — the precise fail-silently mode this file exists to prevent.
# `git rev-parse --git-common-dir` resolves a worktree back to the main .git,
# whose parent is the checkout that actually holds .env.
_notify_env_files() {
    local root common
    root="$(_notify_repo_root)"
    [[ -n "$root" ]] && printf '%s\n' "$root/.env"
    [[ -n "${CHUMP_HOME:-}" ]] && printf '%s\n' "${CHUMP_HOME}/.env"
    common="$(git -C "${root:-.}" rev-parse --git-common-dir 2>/dev/null)" || true
    if [[ -n "$common" ]]; then
        [[ "$common" != /* ]] && common="${root}/${common}"
        printf '%s\n' "$(dirname "$common")/.env"
    fi
}

# Read a var from the process environment first, else from the first .env that
# has it. Never echoes the value.
_notify_env() {
    local key="$1" val f
    # Indirect expansion; this file is bash-only (see shebang) by design.
    val="${!key:-}"
    if [[ -n "$val" ]]; then printf '%s' "$val"; return 0; fi
    while read -r f; do
        [[ -f "$f" ]] || continue
        val="$(grep -m1 "^${key}=" "$f" 2>/dev/null \
            | cut -d= -f2- \
            | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//" -e 's/[[:space:]]*$//')"
        if [[ -n "$val" ]]; then printf '%s' "$val"; return 0; fi
    done < <(_notify_env_files)
}

notify_operator() {
    local content="${1:-}"
    [[ -n "${content//[[:space:]]/}" ]] || return 0

    local token uid
    token="$(_notify_env DISCORD_TOKEN)"
    uid="$(_notify_env CHUMP_READY_DM_USER_ID)"
    if [[ -z "$token" || -z "$uid" ]]; then
        # Unconfigured is not an error — same shape as send_dm_if_configured.
        echo "[notify-operator] SKIP: DISCORD_TOKEN or CHUMP_READY_DM_USER_ID unset" >&2
        return 0
    fi

    local api="https://discord.com/api/v10"
    local ch_json ch_id
    ch_json="$(curl -sS --max-time 10 -X POST "${api}/users/@me/channels" \
        -H "Authorization: Bot ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"recipient_id\":\"${uid}\"}" 2>/dev/null)" || {
        echo "[notify-operator] FAIL: could not open DM channel (curl error)" >&2
        return 1
    }
    ch_id="$(printf '%s' "$ch_json" | python3 -c \
        'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null)"
    if [[ -z "$ch_id" ]]; then
        # Print Discord's error message, which never contains the token.
        echo "[notify-operator] FAIL: open DM channel: $(printf '%s' "$ch_json" \
            | python3 -c 'import sys,json;print(json.load(sys.stdin).get("message","?"))' 2>/dev/null)" >&2
        return 1
    fi

    # CHUNK RATHER THAN TRUNCATE. Discord hard-caps message content at 2000
    # chars. The first cut of this file truncated at 1900 and appended "…",
    # which silently drops the tail — and on an escalation the tail is the link
    # and the ask, i.e. the part that lets the operator act. Split on paragraph
    # then line then word boundaries, and number the parts so a message arriving
    # out of order is still readable.
    #
    # Approach borrowed from openclaw's src/discord/chunk.ts (MIT). Rewritten
    # here, not copied — see DOC-093 for the port policy.
    local -a parts=()
    while IFS= read -r part; do
        [[ -n "$part" ]] && parts+=("$(printf '%b' "$part")")
    done < <(printf '%s' "$content" | python3 -c '
import sys
LIMIT = 1900
text = sys.stdin.read()
out, buf = [], ""
def flush():
    global buf
    if buf.strip():
        out.append(buf.rstrip("\n"))
    buf = ""
for para in text.split("\n"):
    # A single line longer than LIMIT still has to be broken; do it on words.
    while len(para) > LIMIT:
        cut = para.rfind(" ", 0, LIMIT)
        if cut <= 0:
            cut = LIMIT
        if len(buf) + len(para[:cut]) + 1 > LIMIT:
            flush()
        buf += para[:cut] + "\n"
        para = para[cut:].lstrip()
    if len(buf) + len(para) + 1 > LIMIT:
        flush()
    buf += para + "\n"
flush()
for i, chunk in enumerate(out, 1):
    if len(out) > 1:
        chunk = f"({i}/{len(out)}) " + chunk
    # One line per part; escape newlines so bash read can take it whole.
    print(chunk.replace("\\", "\\\\").replace("\n", "\\n"))
' 2>/dev/null)

    if (( ${#parts[@]} == 0 )); then parts=("$content"); fi

    local code sent=0 failed=0
    for part in "${parts[@]}"; do
        code="$(printf '%s' "$part" \
            | python3 -c 'import json,sys;print(json.dumps({"content":sys.stdin.read()}))' \
            | curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
                -X POST "${api}/channels/${ch_id}/messages" \
                -H "Authorization: Bot ${token}" \
                -H "Content-Type: application/json" \
                --data @- 2>/dev/null)" || true
        if [[ "$code" == "200" || "$code" == "201" ]]; then
            sent=$((sent + 1))
        else
            failed=$((failed + 1))
            echo "[notify-operator] FAIL: part returned HTTP ${code:-000}" >&2
        fi
    done

    if (( failed == 0 && sent > 0 )); then
        echo "[notify-operator] delivered (${sent} part(s))" >&2
        return 0
    fi
    echo "[notify-operator] FAIL: ${failed} of $((sent + failed)) part(s) failed" >&2
    return 1
}
