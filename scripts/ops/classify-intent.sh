#!/usr/bin/env bash
# classify-intent.sh — the org router's brain on FREE inference (Groq 70B).
# Reads a business INTENT, returns the department class. Uses curl (proven path).
source /root/.chump/providers.env 2>/dev/null
intent="$*"
menu="build (write/fix code, a bug or crash) | publication (already BUILT but nobody was TOLD — announce/launch) | sales (pay/pricing/buy/upgrade) | support (an existing user is stuck/confused) | growth (marketing, create demand) | analytics (measure usage/KPIs/revenue numbers) | finance (billing/get paid) | operations (keep the factory itself alive)"
prompt="You route incoming business needs to the department that owns them. Classes: ${menu}. Careful: 'we shipped X but nobody knows' is publication (the thing already exists), NOT build. Need: \"${intent}\". Reply with ONLY the one class word."
payload=$(python3 -c 'import json,sys; print(json.dumps({"model":"llama-3.3-70b-versatile","temperature":0,"max_tokens":6,"messages":[{"role":"user","content":sys.argv[1]}]}))' "$prompt")
resp=$(curl -s --max-time 30 https://api.groq.com/openai/v1/chat/completions \
  -H "Authorization: Bearer ${GROQ_API_KEY}" -H "Content-Type: application/json" -d "$payload")
cls=$(printf '%s' "$resp" | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["choices"][0]["message"]["content"].strip().lower().split()[0].strip(".,"))
except Exception as e: print("ERR")' 2>/dev/null)
printf 'intent: "%s"  ->  class=%s\n' "$intent" "$cls"
