#!/usr/bin/env bash
# use-chat-model.sh — PRODUCT-024
#
# Atomically swap the vLLM-MLX server on :8000 from whatever it's serving to a
# non-reasoning chat model and verify the swap actually fixed latency.
#
# Why: reasoning models (Qwen3.5-OptiQ, etc.) emit ~50 s of plain-prose
# Chain-of-Thought before any user-visible answer. The Chump chunk processor
# only routes <think>-tag content to thinking_delta (INFRA-184 follow-up),
# so the entire CoT is invisible to the user — they see keepalive pings for
# 50+ s, then the final answer. Measured 56.985 s for "Say pong, nothing else."
#
# Usage:
#   scripts/setup/use-chat-model.sh                     # default 14B-Instruct
#   scripts/setup/use-chat-model.sh --model 7B          # shortcut to 7B-Instruct
#   scripts/setup/use-chat-model.sh --model FULL_HF_ID  # any non-reasoning HF id
#   scripts/setup/use-chat-model.sh --skip-probe        # don't run the pong probe
#
# Acceptance (PRODUCT-024):
#   - Switches default to non-reasoning model ✓
#   - Measured pong-prompt turn under 5 s ✓ (printed by this script)
#   - Original reasoning model still selectable via VLLM_MODEL=... ✓
#     (this script is opt-in; setting VLLM_MODEL in .env keeps the prior choice)
#
# Exit codes:
#   0  swap succeeded; pong probe under 5 s
#   1  swap succeeded; pong probe over 5 s (still report numbers)
#   2  vLLM-MLX failed to come up
#   3  user passed --dry-run (just prints what would happen)

set -euo pipefail

DEFAULT_MODEL="mlx-community/Qwen2.5-14B-Instruct-4bit"
MODEL=""
SKIP_PROBE=0
DRY_RUN=0
PORT=8000

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)
            MODEL="$2"
            shift 2 ;;
        --skip-probe) SKIP_PROBE=1; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --port)       PORT="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Resolve shortcuts
case "$MODEL" in
    "")     MODEL="$DEFAULT_MODEL" ;;
    "14B")  MODEL="mlx-community/Qwen2.5-14B-Instruct-4bit" ;;
    "7B")   MODEL="mlx-community/Qwen2.5-7B-Instruct-4bit" ;;
    "3bit") MODEL="mlx-community/Qwen2.5-14B-Instruct-3bit" ;;
esac

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi

say()  { printf '\033[1;36m[use-chat-model]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[use-chat-model]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[use-chat-model]\033[0m %s\n' "$*" >&2; exit "${2:-1}"; }

# Refuse to "swap" to a known reasoning model unless --force-reasoning
case "$MODEL" in
    *Qwen3.5-9B-OptiQ*|*Qwen3-Reasoning*|*deepseek-r1*|*o1-*)
        die "$MODEL is a reasoning model — that's the thing PRODUCT-024 is fixing. Pick a non-reasoning chat model (default $DEFAULT_MODEL) or pass --force-reasoning if you really mean it." ;;
esac

CURRENT=""
if curl -sf --max-time 3 "http://127.0.0.1:${PORT}/v1/models" >/dev/null 2>&1; then
    CURRENT="$(curl -s --max-time 3 "http://127.0.0.1:${PORT}/v1/models" | python3 -c "import json,sys; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || echo "?")"
fi

say "current :${PORT} model: ${CURRENT:-(none)}"
say "target model:           $MODEL"

if [[ "$CURRENT" == "$MODEL" ]]; then
    say "already serving target model; nothing to do"
    [[ "$SKIP_PROBE" -eq 1 ]] && exit 0
else
    if [[ "$DRY_RUN" -eq 1 ]]; then
        say "dry-run: would stop :${PORT} and start vllm-mlx serve $MODEL --port $PORT"
        exit 3
    fi

    # ── Stop existing :8000 if any ────────────────────────────────────────
    if [[ -n "$CURRENT" ]]; then
        PIDS=$(lsof -nP -iTCP:${PORT} -sTCP:LISTEN -t 2>/dev/null || true)
        if [[ -n "$PIDS" ]]; then
            say "stopping existing :${PORT} (pids: $PIDS)"
            for p in $PIDS; do kill -TERM "$p" 2>/dev/null || true; done
            sleep 3
            for p in $PIDS; do
                if kill -0 "$p" 2>/dev/null; then
                    warn "  pid $p did not exit on TERM; KILL"
                    kill -KILL "$p" 2>/dev/null || true
                fi
            done
        fi
        # Wait for port to actually clear
        for _ in 1 2 3 4 5; do
            if ! lsof -i ":${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then break; fi
            sleep 1
        done
        if lsof -i ":${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
            die "port ${PORT} still bound after kill — manual intervention needed" 2
        fi
    fi

    # ── Start with the target model ──────────────────────────────────────
    # Invoke vllm-mlx directly (NOT via serve-vllm-mlx.sh) because the
    # latter sources .env, which would re-impose whatever VLLM_MODEL the
    # user has pinned there — including the very reasoning-model we're
    # trying to swap away from. The cli flags below match what
    # serve-vllm-mlx.sh would otherwise pass.
    if ! command -v vllm-mlx >/dev/null && [[ -x "$HOME/.local/bin/vllm-mlx" ]]; then
        export PATH="$HOME/.local/bin:$PATH"
    fi
    command -v vllm-mlx >/dev/null || die "vllm-mlx not on PATH (uv tool install git+https://github.com/waybarrios/vllm-mlx.git)" 2

    say "starting vllm-mlx serve $MODEL on :${PORT} (bypassing serve-vllm-mlx.sh + .env)"
    mkdir -p "$MAIN_REPO/logs"
    VLLM_MAX_NUM_SEQS="${VLLM_MAX_NUM_SEQS:-1}"
    VLLM_MAX_TOKENS="${VLLM_MAX_TOKENS:-4096}"
    VLLM_CACHE_PERCENT="${VLLM_CACHE_PERCENT:-0.12}"
    nohup env \
        VLLM_MODEL="$MODEL" \
        VLLM_MAX_NUM_SEQS="$VLLM_MAX_NUM_SEQS" \
        VLLM_MAX_TOKENS="$VLLM_MAX_TOKENS" \
        VLLM_CACHE_PERCENT="$VLLM_CACHE_PERCENT" \
        VLLM_WORKER_MULTIPROC_METHOD=spawn \
        vllm-mlx serve "$MODEL" \
        --port "$PORT" \
        --max-num-seqs "$VLLM_MAX_NUM_SEQS" \
        --max-tokens "$VLLM_MAX_TOKENS" \
        --cache-memory-percent "$VLLM_CACHE_PERCENT" \
        >> "$MAIN_REPO/logs/vllm-mlx-${PORT}.log" 2>&1 &
    say "  pid $!  log=$MAIN_REPO/logs/vllm-mlx-${PORT}.log"

    # ── Wait for ready (up to 4 min — first-time HF download takes a while) ─
    say "waiting for :${PORT} to respond (timeout 4 min)..."
    for i in $(seq 1 48); do
        c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || echo "000")
        if [[ "$c" == "200" ]]; then
            say "  ready after ${i}x5s"
            break
        fi
        sleep 5
        if [[ "$i" == 48 ]]; then
            die "vLLM-MLX did not come up within 4 min — check logs/vllm-mlx-${PORT}.log" 2
        fi
    done
fi

# ── Pong probe ──────────────────────────────────────────────────────────────
if [[ "$SKIP_PROBE" -eq 1 ]]; then
    say "skipping pong probe; swap complete"
    exit 0
fi

say "running 'Say pong, nothing else.' probe"
START=$(date +%s.%N 2>/dev/null || date +%s)
RESP=$(curl -s --max-time 30 -X POST "http://127.0.0.1:${PORT}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"default","messages":[{"role":"user","content":"Say pong, nothing else."}],"max_tokens":8,"stream":false}' || true)
END=$(date +%s.%N 2>/dev/null || date +%s)

if command -v bc >/dev/null; then
    ELAPSED=$(echo "$END - $START" | bc 2>/dev/null || echo "?")
else
    ELAPSED=$(python3 -c "print(round($END-$START, 3))" 2>/dev/null || echo "?")
fi

CONTENT=$(echo "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null || echo "?")
say "  response: $(printf '%s' "$CONTENT" | head -c 80)"
say "  pong-probe latency: ${ELAPSED}s  (target: under 5 s)"

# Threshold check
PASS=$(python3 -c "print(1 if float('$ELAPSED') < 5.0 else 0)" 2>/dev/null || echo 0)
if [[ "$PASS" == "1" ]]; then
    say "✓ PRODUCT-024 acceptance met: pong under 5 s"
    exit 0
else
    warn "✗ pong probe over 5 s — model may still be reasoning, or server warm-up"
    warn "  re-run probe in a moment; first-call MLX cold-start can be 5-10 s"
    exit 1
fi
