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

# RESILIENT-274 escalation discipline. Operator decision (Jeff, 2026-08-10):
# "don't hear from the fleet unless it's way out of line or we don't have a
# playbook for it." Quiet by default. A page reaches the phone ONLY when the
# signal is halt-class OR novel (no playbook). Known signals that have an
# auto-heal / runbook are SUPPRESSED here — logged to ambient, not DM'd — so the
# escalation channel never cries wolf (a muted channel is the RESILIENT-262 dead
# operator-recall handler all over again).
#
# Classification input (both optional, set by the caller):
#   CHUMP_NOTIFY_KIND      the ambient/signal kind (e.g. discord_gateway_down)
#   CHUMP_NOTIFY_SEVERITY  set to "halt" to force a page regardless of registry
# Registry: scripts/coord/operator-escalation-registry.txt — "<kind><TAB>suppress|page|direct".
# Rules: halt severity → PAGE. kind in registry → its verdict. Unknown kind or
# no kind → PAGE (fail loud: "no playbook → tell me").
#   suppress → log operator_notify_suppressed, DO NOT DM.
#   page     → emit operator_paged (counts against page-rate) AND DM the phone.
#   direct   → INFRA-3835: emit operator_direct_message and DM, but it is NOT an
#              escalation (no operator_paged). For normal messages the fleet owes
#              the operator, e.g. the Advisor's answer — the DM IS the payload,
#              a parallel "you were paged" event would be pure noise.
_notify_ambient_log() {
    local root; root="$(_notify_repo_root)"
    printf '%s\n' "${CHUMP_AMBIENT_LOG:-${root}/.chump-locks/ambient.jsonl}"
}

_notify_emit() {  # kind, extra_json_fragment
    local log; log="$(_notify_ambient_log)"
    mkdir -p "$(dirname "$log")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"%s"%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:-}" >> "$log" 2>/dev/null || true
}

# Returns "page", "suppress", or "direct" on stdout. Default is PAGE
# (novel/no-playbook). Whitespace-split (space OR tab); anything after the
# verdict is an inline comment. "direct" (INFRA-3835) means a normal DM the
# fleet owes the operator — deliver it, but it is NOT an escalation.
_notify_escalation_verdict() {
    local kind="$1" root reg k verdict _rest
    [[ -n "$kind" ]] || { echo "page"; return; }   # unclassified caller → page
    root="$(_notify_repo_root)"
    reg="${root}/scripts/coord/operator-escalation-registry.txt"
    [[ -f "$reg" ]] || { echo "page"; return; }    # no registry → fail loud
    while read -r k verdict _rest; do
        [[ -z "$k" || "$k" == \#* ]] && continue
        if [[ "$kind" == "$k" ]]; then
            case "$verdict" in
                suppress) echo "suppress" ;;
                direct)   echo "direct" ;;
                *)        echo "page" ;;            # page or any typo → fail loud
            esac
            return
        fi
    done < "$reg"
    echo "page"                                    # unknown kind = novel = page
}

notify_operator() {
    local content="${1:-}"
    [[ -n "${content//[[:space:]]/}" ]] || return 0

    # Escalation gate — suppress known-playbook'd routine before touching Discord.
    local _kind="${CHUMP_NOTIFY_KIND:-}" _sev="${CHUMP_NOTIFY_SEVERITY:-}"
    if [[ "$_sev" != "halt" ]]; then
        local _verdict; _verdict="$(_notify_escalation_verdict "$_kind")"
        if [[ "$_verdict" == "suppress" ]]; then
            _notify_emit "operator_notify_suppressed" ",\"signal\":\"${_kind}\",\"reason\":\"has-playbook\""
            echo "[notify-operator] SUPPRESSED (playbook exists, quiet-by-default): kind=${_kind}" >&2
            return 0
        fi
        if [[ "$_verdict" == "direct" ]]; then
            # INFRA-3835: a normal DM the fleet owes the operator (e.g. the
            # Advisor's answer). DELIVER it (fall through to the Discord send),
            # but emit operator_direct_message rather than operator_paged — it is
            # not an escalation, so it must not inflate the page-rate vital sign.
            _notify_emit "operator_direct_message" ",\"signal\":\"${_kind}\""
            echo "[notify-operator] DIRECT (owed-message, delivered without paging): kind=${_kind}" >&2
        else
            # Page-worthy: record whether it was classified or fell through as novel.
            [[ -n "$_kind" ]] && _notify_emit "operator_paged" ",\"signal\":\"${_kind}\",\"class\":\"registry-page\"" \
                              || _notify_emit "operator_paged" ",\"class\":\"unclassified-caller\""
        fi
    fi

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

# notify_operator_buttons — RESILIENT-265 "approve-from-phone". Send ONE operator
# DM that carries an interactive button row (Discord message components), so a
# decision the operator would otherwise make on GitHub is one phone tap instead.
#
#   notify_operator_buttons "<content>" "<components-json-array>"
#     → 0 on delivery, 1 on failure, 0 no-op when unconfigured
#
# The caller builds the components array (Discord "action row" of type-2 buttons
# with the custom_ids the gateway's INTERACTION_CREATE handler parses, e.g.
# `mergepr:owner/repo/number`). This deliberately BYPASSES the escalation
# suppress-registry: an approval prompt is operator-requested action, never
# cry-wolf routine — it must always reach the phone. It also does NOT chunk:
# an approval message is short and components must ride the single message that
# owns the buttons. Reuses notify_operator's env/token resolution + curl shape.
notify_operator_buttons() {
    local content="${1:-}" components="${2:-[]}"
    [[ -n "${content//[[:space:]]/}" ]] || return 0

    local token uid
    token="$(_notify_env DISCORD_TOKEN)"
    uid="$(_notify_env CHUMP_READY_DM_USER_ID)"
    if [[ -z "$token" || -z "$uid" ]]; then
        echo "[notify-operator] SKIP (buttons): DISCORD_TOKEN or CHUMP_READY_DM_USER_ID unset" >&2
        return 0
    fi

    local api="https://discord.com/api/v10"
    local ch_json ch_id
    ch_json="$(curl -sS --max-time 10 -X POST "${api}/users/@me/channels" \
        -H "Authorization: Bot ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"recipient_id\":\"${uid}\"}" 2>/dev/null)" || {
        echo "[notify-operator] FAIL (buttons): could not open DM channel" >&2; return 1; }
    ch_id="$(printf '%s' "$ch_json" | python3 -c \
        'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null)"
    if [[ -z "$ch_id" ]]; then
        echo "[notify-operator] FAIL (buttons): open DM channel: $(printf '%s' "$ch_json" \
            | python3 -c 'import sys,json;print(json.load(sys.stdin).get("message","?"))' 2>/dev/null)" >&2
        return 1
    fi

    # Build the message payload (content + components) with python so the JSON is
    # always valid regardless of what's in content/components.
    local payload code
    payload="$(CONTENT="$content" COMPONENTS="$components" python3 -c '
import os,json
print(json.dumps({
    "content": os.environ["CONTENT"][:1990],
    "components": json.loads(os.environ["COMPONENTS"] or "[]"),
}))' 2>/dev/null)"
    if [[ -z "$payload" ]]; then
        echo "[notify-operator] FAIL (buttons): could not build payload (bad components JSON?)" >&2; return 1; fi

    code="$(printf '%s' "$payload" | curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
        -X POST "${api}/channels/${ch_id}/messages" \
        -H "Authorization: Bot ${token}" \
        -H "Content-Type: application/json" \
        --data @- 2>/dev/null)" || true
    if [[ "$code" == "200" || "$code" == "201" ]]; then
        echo "[notify-operator] delivered (buttons)" >&2; return 0
    fi
    echo "[notify-operator] FAIL (buttons): HTTP ${code:-000}" >&2
    return 1
}

# Direct-execution entry point — INFRA-3602. Restrictive Bash allowlists
# (e.g. `claude --permission-mode dontAsk`) deny `source X && fn args` as a
# compound command regardless of how precisely the allowlist pattern matches
# the literal string: a permission engine can't statically verify what a
# dynamically-sourced function does, so it refuses the whole chain. Running
# this file directly — `CHUMP_NOTIFY_KIND=x notify-operator.sh "<msg>"` — is
# a single non-compound invocation of one known executable and is allowed.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    notify_operator "$@"
fi
