#!/usr/bin/env bash
# Verify Ollama comes back quickly after a hard kill (expects Homebrew `brew services start ollama`).
# Usage: ./scripts/verify-ollama-respawn.sh
# PASS: prints recovered_in_sec=N with N <= 10 (typical ~3–8s).

set -euo pipefail
if ! curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:11434/api/tags | grep -q 200; then
  echo "FAIL: Ollama not up before test. Run: brew services start ollama" >&2
  exit 1
fi
killall ollama 2>/dev/null || true
START=$(date +%s)
for i in $(seq 1 15); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 http://127.0.0.1:11434/api/tags 2>/dev/null || echo 000)
  if [[ "$code" == "200" ]]; then
    END=$(date +%s)
    echo "PASS recovered_in_sec=$((END - START))"
    exit 0
  fi
  sleep 1
done
echo "FAIL: no 200 from /api/tags within 15s after killall" >&2
exit 1
