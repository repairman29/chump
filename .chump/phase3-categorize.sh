#!/usr/bin/env bash
# Phase 3 scripts/ categorization plan — INFRA-135.
# Produces a (path → subdir) mapping. bash 3.2 compatible (macOS default).
#
# Usage:
#   bash .chump/phase3-categorize.sh                  # print mapping (file<TAB>subdir)
#   bash .chump/phase3-categorize.sh --counts         # per-subdir counts
#   bash .chump/phase3-categorize.sh --uncategorized  # files not yet mapped
#   bash .chump/phase3-categorize.sh --sed-pairs      # rewrite patterns
#   bash .chump/phase3-categorize.sh --execute        # git mv all files
#
# Categories per .chump/PHASE_2_3_5_PLAN.md.
# Existing subdirs (audit, lib, git-hooks, plists, qa, soak, overnight, test-fixtures,
# ab-harness, eval-human-label, eval-reflection-ab) are left as-is — files only move
# *into* them via the mapping below.
set -eo pipefail
cd "$(git rev-parse --show-toplevel)"

# Mapping table: "<basename> <subdir>" per line. Wins over pattern matching.
MAPPING=$(cat <<'EOF'
bot-merge.sh coord
bot-merge-run-timed.py coord
bot-shipped-audit.sh coord
broadcast.sh coord
chump-commit.sh coord
gap-architect.py coord
gap-claim.sh coord
gap-gardener.py coord
gap-preflight.sh coord
gap-reserve.sh coord
gap-store-prototype.sh coord
check-gap-status-flip.sh coord
check-gaps-integrity.py coord
resolve-gaps-conflict.py coord
queue-driver.sh coord
musher.py coord
musher.sh coord
ensure-chump-repo.sh coord
archive-superseded-branch.sh coord
worktree-prune.sh coord
demo-pr-worktree.sh coord
code-reviewer-agent.sh coord
ci-failure-digest.sh coord
log-chump-cli.sh coord
claude-retry.sh coord
harvest-synthesis-lessons.sh coord
check.sh ci
check-discord-preflight.sh ci
check-heartbeat-health.sh ci
check-heartbeat-preflight.sh ci
check-inference-mesh.sh ci
check-mistralrs-infer-build.sh ci
check-network-after-swap.sh ci
check-product-floor.sh ci
check-providers.sh ci
chump-preflight.sh ci
ci-setup-ollama-e2e.sh ci
coord-surfaces-smoke.sh ci
coord-serve.sh ci
daily-driver-preflight.sh ci
golden-path-timing.sh ci
mistralrs-inference-ab-smoke.sh ci
mistralrs-structured-smoke.sh ci
mdbook-linkcheck.py ci
roadmap-mdbook-links.py ci
doc-keeper-check-links.py ci
verify-external-golden-path.sh ci
verify-mutual-supervision.sh ci
verify-ollama-respawn.sh ci
verify-toolkit.sh ci
verify-web-index-inline-scripts.cjs ci
run-web-ui-selftests.cjs ci
battle-api-sim.sh ci
battle-cli-no-llm.sh ci
battle-pwa-live.sh ci
battle-qa.sh ci
run-battle-qa-full.sh ci
run-battle-sim-suite.sh ci
run-stories.sh ci
run-tests-with-config.sh ci
run-tauri-e2e.sh ci
run-ui-e2e.sh ci
test-acp-smoke.sh ci
test-ambient-glance.sh ci
test-bot-merge-liveness.sh ci
test-bot-merge-pending-gap.sh ci
test-bot-merge-syntax.sh ci
test-claude-retry.sh ci
test-code-reviewer-agent.sh ci
test-cursor-cli-integration.sh ci
test-duplicate-id-guard.sh ci
test-file-lease.sh ci
test-gap-preflight-unregistered.sh ci
test-gap-reserve-concurrency.sh ci
test-gap-reserve-preflight.sh ci
test-heartbeat-learn.sh ci
test-mcp-coord-smoke.sh ci
test-multi-agent-stress.sh ci
test-preregistration-guard.sh ci
test-recycled-id-guard.sh ci
test-research-026-preflight.sh ci
test-research-cursor-round.sh ci
test-ship-chassis-round.sh ci
test-stale-worktree-reaper.sh ci
test-status.sh ci
test-tier5-self-improve.sh ci
test-together-routing.sh ci
test-vector6-schema.sh ci
test-vector7-swarm.sh ci
test-yaml-lint-guard.sh ci
analyze-ab-results.sh eval
analyze-neuromod-telemetry.py eval
bench-mistralrs-chump.sh eval
bench-mistralrs-tune.sh eval
bench_mistralrs_chump.py eval
chump-bench.sh eval
consciousness-ab-mini.sh eval
consciousness-baseline.sh eval
consciousness-exercise.sh eval
consciousness-report.sh eval
dogfood-matrix.sh eval
dogfood-matrix-scheduled.sh eval
dogfood-run.sh eval
dogfood-t1-1-probe.sh eval
eval-reflection-ab.sh eval
export-pilot-summary.sh eval
extract-best-practices.sh eval
generate-cos-weekly-snapshot.sh eval
generate-research-draft.sh eval
generate-sprint-synthesis.sh eval
latency-envelope-measure.sh eval
measure-ftue.sh eval
memory-graph-benchmark.sh eval
recall-benchmark.sh eval
replay-trajectory.sh eval
rescore-jsonl.py eval
research-cursor-only.sh eval
research-lane-a-smoke.sh eval
run-ablation-study.sh eval
run-autonomy-tests.sh eval
run-consciousness-study.sh eval
run-longitudinal-study.sh eval
run-multi-model-study.sh eval
run-neuromod-study.sh eval
run-overnight-research.sh eval
run-study1.sh eval
run-study2.sh eval
run-study3.sh eval
run-study4.sh eval
run-study5.sh eval
soak-checkpoint.sh eval
tail-model-dogfood.sh eval
wedge-h1-smoke.sh eval
print-repo-metrics.sh eval
doc-inventory.py eval
doc-phase0-classify.py eval
quarterly-cos-memo.sh eval
morning-briefing-dm.sh eval
github-triage-snapshot.sh eval
doc-hygiene-round-prompt.bash eval
sprint-synthesis-round-prompt.bash eval
adb-connect.sh setup
adb-pair.sh setup
apply-mabel-badass-env.sh setup
apply-mlx-8001-env.py setup
bootstrap-toolkit.sh setup
build-android.sh setup
build-chump-menu.sh setup
build-white-papers.py setup
build-white-papers.sh setup
deploy-all-to-pixel.sh setup
deploy-android-adb.sh setup
deploy-fleet.sh setup
deploy-mabel-to-pixel.sh setup
deploy-mac.sh setup
download-mlx-models.sh setup
ensure-mabel-bot-up.sh setup
ensure-ship-heartbeat.sh setup
enter-chump-mode.sh setup
install-active-target-reaper-launchd.sh setup
install-hooks.sh setup
install-overnight-research-launchd.sh setup
install-roles-launchd.sh setup
install-stale-auditor-finding-reaper-launchd.sh setup
install-stale-worktree-reaper-launchd.sh setup
ollama-restart.sh setup
ollama-serve-fast.sh setup
ollama-serve-m4-air-24g.sh setup
ollama-unload-models.sh setup
ollama-watchdog.sh setup
openai-base-local-mlx-port.sh setup
populate-paper-section33.sh setup
populate-paper-section4.sh setup
print-chump-web-base.sh setup
restart-chump-heartbeat.sh setup
restart-mabel-bot-on-pixel.sh setup
restart-mabel-heartbeat.sh setup
restart-mabel.sh setup
restart-ship-heartbeat.sh setup
restart-vllm-8001-if-down.sh setup
restart-vllm-if-down.sh setup
retire-mac-hourly-fleet-report.sh setup
run-setup-via-ssh.sh setup
scaffold-side-repo.sh setup
self-reboot.sh setup
serve-multi-mlx.sh setup
serve-vllm-mlx-8001.sh setup
serve-vllm-mlx-supervised.sh setup
setup-and-run-termux.sh setup
setup-llama-on-termux.sh setup
setup-local.sh setup
setup-termux-once.sh setup
start-companion.sh setup
start-embed-server.sh setup
stop-chump-discord.sh setup
stop-ollama-if-running.sh setup
switch-mabel-to-qwen3-4b.sh setup
tauri-desktop-mlx-fleet.sh setup
unload-roles-launchd.sh setup
wait-for-vllm.sh setup
warm-the-ovens.sh setup
mlx-warmup-chat.sh setup
inference-primary-mistralrs.sh setup
macos-cowork-dock-app.sh setup
screen-ocr.sh setup
requirements-embed.txt setup
embed_server.py setup
agent-loop.sh dev
ambient-emit.sh dev
ambient-query.sh dev
ambient-rotate.sh dev
ambient-watch.sh dev
start-ambient-watch.sh dev
chump-ambient-glance.sh dev
autonomous-mlx-smoke.sh dev
autonomy-cron.sh dev
autopilot-remote.sh dev
bring-up-stack.sh dev
capture-mabel-timing.sh dev
capture-oom-context.sh dev
chump-explain.sh dev
chump-focus-mode.sh dev
chump-macos-process-list.sh dev
chump-mode.conf dev
chump-operational-sanity.sh dev
cleanup-repo.sh dev
cursor-cli-status-and-test.sh dev
demo-golden-path.sh dev
diagnose-mabel-model.sh dev
doc-keeper.sh dev
env-default.sh dev
env-max_m4.sh dev
env-mistralrs-power.sh dev
env-mlx-8001-7b.sh dev
env-self-improve-logging.sh dev
farmer-brown.sh dev
fleet-health.sh dev
fleet-status.sh dev
fleet-ws-spike.sh dev
heartbeat-cloud-only.sh dev
heartbeat-cursor-improve-loop.sh dev
heartbeat-doc-hygiene-loop.sh dev
heartbeat-learn.sh dev
heartbeat-lock.sh dev
heartbeat-mabel.sh dev
heartbeat-self-improve.sh dev
heartbeat-shepherd.sh dev
heartbeat-ship.sh dev
heartbeat-watcher.sh dev
hourly-update-to-discord.sh dev
keep-chump-online.sh dev
list-heavy-processes.sh dev
mabel-explain.sh dev
mabel-farmer.sh dev
mabel-status.sh dev
memory-keeper.sh dev
oven-tender.sh dev
parse-timing-log.sh dev
probe-mac-health.sh dev
record-demo.sh dev
repo-health-sweep.sh dev
run-web-mistralrs-infer.sh dev
sentinel.sh dev
start-daily-driver.sh dev
start-self-improve-cycles.sh dev
sync-book-from-docs.sh dev
synthesis-pass.sh dev
war-room.sh dev
active-target-reaper.sh ops
stale-auditor-finding-reaper.sh ops
stale-branch-reaper.sh ops
stale-pr-reaper.sh ops
stale-worktree-reaper.sh ops
publish-crates.sh release
README-BATTLE-QA-BACKGROUND.md qa
com.chump.autonomy-cron.plist.example plists
com.chump.battle-qa.plist plists
cos-weekly-snapshot.plist.example plists
doc-keeper.plist.example plists
farmer-brown.plist.example plists
heartbeat-health-check.plist.example plists
heartbeat-self-improve.plist.example plists
heartbeat-shepherd.plist.example plists
hourly-update-to-discord.plist.example plists
memory-keeper.plist.example plists
oven-tender.plist.example plists
research-cursor-only.plist.example plists
restart-vllm-if-down.plist.example plists
sentinel.plist.example plists
shed-load.plist.example plists
EOF
)

# Look up category for one base name. Returns "UNCATEGORIZED" if missing.
lookup() {
  local base="$1"
  local hit
  hit=$(printf '%s\n' "$MAPPING" | awk -v k="$base" '$1 == k {print $2; exit}')
  if [[ -n "$hit" ]]; then
    printf '%s\n' "$hit"
  else
    printf 'UNCATEGORIZED\n'
  fi
}

mapping_full() {
  local f base cat
  while IFS= read -r f; do
    base="${f#scripts/}"
    cat="$(lookup "$base")"
    printf '%s\t%s\n' "$base" "$cat"
  done < <(find scripts -maxdepth 1 -type f | sort)
}

case "${1:-}" in
  --counts)
    mapping_full | awk -F'\t' '{print $2}' | sort | uniq -c | sort -rn
    ;;
  --uncategorized)
    mapping_full | awk -F'\t' '$2 == "UNCATEGORIZED" {print $1}'
    ;;
  --sed-pairs)
    # Read directly from the MAPPING table so this works after --execute too.
    printf '%s\n' "$MAPPING" | awk 'NF==2 {printf "s|scripts/%s|scripts/%s/%s|g\n", $1, $2, $1}'
    ;;
  --execute)
    mkdir -p scripts/coord scripts/ci scripts/eval scripts/setup scripts/dev scripts/ops scripts/release
    count=0
    while IFS=$'\t' read -r f cat; do
      if [[ "$cat" == "UNCATEGORIZED" ]]; then
        echo "WARN: skipping uncategorized: $f" >&2
        continue
      fi
      git mv "scripts/$f" "scripts/$cat/$f"
      count=$((count+1))
    done < <(mapping_full)
    echo "moved $count files"
    ;;
  *)
    mapping_full
    ;;
esac
