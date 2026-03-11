#!/usr/bin/env bash
# Verify Chump's toolkit: check which tools are installed and report.
# Usage: ./scripts/verify-toolkit.sh
#        ./scripts/verify-toolkit.sh --json   # output as JSON for Chump to parse

set -e
JSON_MODE=""
[[ "${1:-}" == "--json" ]] && JSON_MODE=1

# Categories and tools: "binary:display_name:category"
TOOLS=(
  # Code search & navigation
  "rg:ripgrep:search"
  "fd:fd:search"
  "tree:tree:search"
  "tokei:tokei:search"
  "ast-grep:ast-grep:search"
  # Code quality
  "cargo-nextest:cargo-nextest:quality"
  "cargo-audit:cargo-audit:quality"
  "cargo-outdated:cargo-outdated:quality"
  "cargo-deny:cargo-deny:quality"
  "cargo-tarpaulin:cargo-tarpaulin:quality"
  "cargo-expand:cargo-expand:quality"
  "cargo-watch:cargo-watch:quality"
  "flamegraph:flamegraph:quality"
  # Data processing
  "jq:jq:data"
  "yq:yq:data"
  "xsv:xsv:data"
  "sd:sd:data"
  "htmlq:htmlq:data"
  # System monitoring
  "btm:bottom:system"
  "dust:dust:system"
  "procs:procs:system"
  "bandwhich:bandwhich:system"
  # Network
  "xh:xh:network"
  "dog:dog:network"
  # Git
  "gh:gh-cli:git"
  "delta:git-delta:git"
  "git-absorb:git-absorb:git"
  "gitleaks:gitleaks:git"
  # Docs
  "pandoc:pandoc:docs"
  "mdbook:mdbook:docs"
  # Automation
  "just:just:automation"
  "watchexec:watchexec:automation"
  "hyperfine:hyperfine:automation"
  "nu:nushell:automation"
  # AI / LLM
  "ollama:ollama:ai"
  "llm:llm:ai"
  # Core (should always be present)
  "cargo:cargo:core"
  "rustc:rustc:core"
  "git:git:core"
  "curl:curl:core"
  "wasmtime:wasmtime:core"
)

ok=0; missing=0; total=0
json_items=""

for entry in "${TOOLS[@]}"; do
  bin="${entry%%:*}"
  rest="${entry#*:}"
  name="${rest%%:*}"
  cat="${rest##*:}"
  total=$((total + 1))

  if command -v "$bin" &>/dev/null; then
    ok=$((ok + 1))
    if [[ -z "$JSON_MODE" ]]; then
      ver=$(command "$bin" --version 2>/dev/null | head -1 | cut -c1-60 || echo "?")
      echo "  ✅ $name ($ver)"
    else
      json_items="${json_items}{\"name\":\"$name\",\"bin\":\"$bin\",\"cat\":\"$cat\",\"installed\":true},"
    fi
  else
    missing=$((missing + 1))
    if [[ -z "$JSON_MODE" ]]; then
      echo "  ❌ $name"
    else
      json_items="${json_items}{\"name\":\"$name\",\"bin\":\"$bin\",\"cat\":\"$cat\",\"installed\":false},"
    fi
  fi
done

if [[ -n "$JSON_MODE" ]]; then
  json_items="${json_items%,}"
  echo "{\"total\":$total,\"installed\":$ok,\"missing\":$missing,\"tools\":[$json_items]}"
else
  echo ""
  echo "=== Summary: $ok/$total installed, $missing missing ==="
  echo ""
  echo "By category (ok/missing per category):"
  for cat in core search quality data system network git docs automation ai; do
    c_ok=0; c_miss=0
    for entry in "${TOOLS[@]}"; do
      [[ "${entry##*:}" != "$cat" ]] && continue
      bin="${entry%%:*}"
      if command -v "$bin" &>/dev/null; then c_ok=$((c_ok + 1)); else c_miss=$((c_miss + 1)); fi
    done
    c_total=$((c_ok + c_miss))
    if [[ $c_total -gt 0 ]]; then
      if [[ $c_miss -eq 0 ]]; then
        echo "  $cat: $c_ok/$c_total ✅"
      else
        echo "  $cat: $c_ok/$c_total ($c_miss missing)"
      fi
    fi
  done
fi
