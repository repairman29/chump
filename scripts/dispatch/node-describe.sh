#!/usr/bin/env bash
# node-describe.sh — RESILIENT-291 / Node Fabric component #1.
#
# Introspect THIS node into a capability + services profile: what it IS
# (hardware), what it can DO (roles it fits), and — the guardrail that would
# have stopped an ATC agent killing helsinki's ollama blind — what load-bearing
# services it is RUNNING. Emits JSON for the node registry (docs/fleet/nodes/).
#
# Portable across Linux (nvidia-smi) and macOS (Apple Silicon / no CUDA).
# Bootstrap for the eventual `chump node describe` Rust subcommand that populates
# fleet_capability::AgentCapability directly (see docs/design/NODE_FABRIC.md).
#
# Usage: bash node-describe.sh   # prints JSON profile to stdout
set -uo pipefail

os="$(uname -s)"; host="$(hostname -s 2>/dev/null || hostname)"
tailnet="$(tailscale ip -4 2>/dev/null | head -1)"; tailnet="${tailnet:-unknown}"

# --- hardware ---
if [[ "$os" == "Darwin" ]]; then
  cores="$(sysctl -n hw.ncpu 2>/dev/null || echo 0)"
  ram_gb="$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))"
  disk_free_gb="$(df -g / 2>/dev/null | awk 'NR==2{print $4}')"
  disk_total_gb="$(df -g / 2>/dev/null | awk 'NR==2{print $2}')"
  gpu_name="$(sysctl -n machdep.cpu.brand_string 2>/dev/null | grep -qi apple && echo "Apple Silicon (Metal, no CUDA)" || echo none)"
  gpu_vram_mb=0            # unified memory; not a CUDA VRAM floor
  always_on=false          # laptop — sleeps
else
  cores="$(nproc 2>/dev/null || echo 0)"
  ram_gb="$(free -g 2>/dev/null | awk '/Mem:/{print $2}')"
  disk_free_gb="$(df -BG / 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4);print $4}')"
  disk_total_gb="$(df -BG / 2>/dev/null | awk 'NR==2{gsub(/G/,"",$2);print $2}')"
  if command -v nvidia-smi >/dev/null 2>&1; then
    gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
    gpu_vram_mb="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)"
  else
    gpu_name="none"; gpu_vram_mb=0
  fi
  # always-on heuristic: a non-laptop Linux box with multi-hour uptime
  up_h="$(awk '{print int($1/3600)}' /proc/uptime 2>/dev/null || echo 0)"
  [[ "$up_h" -ge 2 ]] && always_on=true || always_on=false
fi
gpu_name="${gpu_name:-none}"; gpu_vram_mb="${gpu_vram_mb:-0}"
[[ "$gpu_name" == "none" ]] && gpu_present=false || gpu_present=true

# --- roles this node FITS (derived from hardware) ---
roles=()
(( gpu_vram_mb >= 2000 )) && roles+=("gpu-embed" "gpu-inference-small")
(( disk_free_gb >= 20 && cores >= 4 )) && roles+=("build-worker" "ci-runner")
[[ "$always_on" == true ]] && roles+=("atc-heartbeat" "broker")
[[ "$always_on" == false ]] && roles+=("atc-interactive")
(( ${#roles[@]} == 0 )) && roles+=("light-worker")

# --- services RUNNING (the dependency guardrail) ---
svc=()
pgrep -x ollama            >/dev/null 2>&1 && svc+=("ollama:embed/inference")
pgrep -f 'worker.sh'       >/dev/null 2>&1 && svc+=("chump-worker")
pgrep -x nats-server       >/dev/null 2>&1 && svc+=("nats:broker")
pgrep -f 'actions.runner|Runner.Listener' >/dev/null 2>&1 && svc+=("github-actions-runner")
pgrep -f 'discord-gateway' >/dev/null 2>&1 && svc+=("discord-gateway")
pgrep -f 'embed-fleet\|summarize-worker' >/dev/null 2>&1 && svc+=("almanac-embed-fleet")
systemctl is-active chump-pr-lander.timer >/dev/null 2>&1 && svc+=("chump-pr-lander")

j_arr(){ local out=""; for x in "$@"; do out+="\"$x\","; done; echo "[${out%,}]"; }

cat <<EOF
{
  "node_id": "$host",
  "tailnet_ip": "$tailnet",
  "os": "$os",
  "hardware": {
    "cpu_cores": ${cores:-0},
    "ram_gb": ${ram_gb:-0},
    "disk_free_gb": ${disk_free_gb:-0},
    "disk_total_gb": ${disk_total_gb:-0},
    "gpu_present": $gpu_present,
    "gpu_name": "$gpu_name",
    "gpu_vram_mb": ${gpu_vram_mb:-0},
    "always_on": $always_on
  },
  "roles_fit": $(j_arr "${roles[@]}"),
  "services_running": $(j_arr "${svc[@]:-}"),
  "capability": {
    "vram_gb": $(( ${gpu_vram_mb:-0} / 1024 )),
    "supported_task_classes": $( (( gpu_vram_mb >= 2000 )) && echo '["embed","small-inference"]' || echo '["build","ship","coord"]' )
  }
}
EOF
