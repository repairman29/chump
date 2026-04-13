# shellcheck shell=bash
# Resolve the Chump PWA base URL for automation (Playwright, curl helpers).
# Priority:
#   1. CHUMP_E2E_BASE_URL (full URL, if already set in environment)
#   2. CHUMP_E2E_PORT (path-only override for E2E)
#   3. logs/chump-web-bound-port under CHUMP_HOME / CHUMP_REPO / cwd — when Chump bound to a different port
#   4. Scan CHUMP_WEB_PORT (from .env when sourced), then 3847, 3000, 3848 for GET /api/health with chump-web
#   5. Fallback http://${CHUMP_WEB_HOST:-127.0.0.1}:${CHUMP_WEB_PORT:-3847} (nothing listening yet — caller may start server)
#
# Caller should export CHUMP_REPO or CHUMP_HOME to the repo root so the bound-port marker is found.
#
# Usage (from repo root):
#   export CHUMP_REPO="$(pwd)"
#   source scripts/lib/chump-web-base.sh
#   url="$(chump_resolve_e2e_base_url)"

chump_web_health_ok() {
  local base="$1"
  curl -sf "${base}/api/health" 2>/dev/null | grep -q '"service"[[:space:]]*:[[:space:]]*"chump-web"'
}

chump_resolve_e2e_base_url() {
  local host="${CHUMP_WEB_HOST:-127.0.0.1}"
  if [[ -n "${CHUMP_E2E_BASE_URL:-}" ]]; then
    printf '%s' "${CHUMP_E2E_BASE_URL}"
    return
  fi
  if [[ -n "${CHUMP_E2E_PORT:-}" ]]; then
    printf 'http://%s:%s' "$host" "${CHUMP_E2E_PORT}"
    return
  fi

  local root="${CHUMP_HOME:-${CHUMP_REPO:-}}"
  [[ -z "$root" ]] && root="$(pwd)"
  local marker="${root}/logs/chump-web-bound-port"
  if [[ -f "$marker" ]]; then
    local mp=""
    IFS= read -r mp <"$marker" || true
    mp="${mp//$'\r'/}"
    mp="${mp//$'\n'/}"
    if [[ "$mp" =~ ^[0-9]+$ ]]; then
      local mb="http://${host}:${mp}"
      if chump_web_health_ok "$mb"; then
        printf '%s' "$mb"
        return
      fi
    fi
  fi

  local -a ports=()
  [[ -n "${CHUMP_WEB_PORT:-}" ]] && ports+=("${CHUMP_WEB_PORT}")
  ports+=(3847 3000 3848)

  local seen="|"
  local p
  for p in "${ports[@]}"; do
    [[ -z "$p" ]] && continue
    [[ "$seen" == *"|${p}|"* ]] && continue
    seen="${seen}${p}|"
    local base="http://${host}:${p}"
    if chump_web_health_ok "$base"; then
      printf '%s' "$base"
      return
    fi
  done

  # Prefer .env web port when nothing is listening yet (matches ./run-web.sh defaulting).
  local fallback_port="${CHUMP_WEB_PORT:-3847}"
  printf 'http://%s:%s' "$host" "$fallback_port"
}

# Port number from a base URL like http://127.0.0.1:3847
chump_port_from_base_url() {
  local url="$1"
  if [[ "$url" =~ http://[^/:]+:([0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return
  fi
  printf '%s' "${CHUMP_E2E_PORT:-3847}"
}
