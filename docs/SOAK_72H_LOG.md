# 72-Hour Soak Test Log

Running log of extended stability runs (72+ hours). Each entry captures configuration, anomalies, and recovery actions. Use this as a pre-release checklist and regression record.

## Format

```
## Run N — YYYY-MM-DD to YYYY-MM-DD

**Config:** model, backend, surface (Discord/web/CLI), VRAM, fleet
**Duration:** actual vs planned
**Summary:** pass / degraded / failed

### Anomalies

| Time offset | Event | Recovery | Recurrence |
|-------------|-------|----------|------------|
| +Xh | description | action taken | once / flapping |

### Notes

Observations, perf numbers, log excerpts.
```

---

## Run 1 — 2026-04-17 to 2026-04-19 (autonomous loop session)

**Config:** claude-sonnet-4-7 1M (cloud), web PWA + Discord, M4 24GB, vLLM-MLX 14B on 8000
**Duration:** ~36 hours (autonomous loop: ~2h × ~18 sessions)
**Summary:** Sustained; 24 PRs landed. No full crash. Several partial anomalies.

### Anomalies

| Time offset | Event | Recovery | Recurrence |
|-------------|-------|----------|------------|
| +0h | config/config.yaml committed with live Together.ai key | Rotate key immediately | Once (single actor) |
| +2h | Cargo.lock conflicts — multi-agent parallel edits | `CHUMP_GAP_CHECK=0 git push` | 3× across session |
| +4h | vLLM-MLX Metal OOM during 14B reload | Restarted via `restart-vllm-if-down.sh`; reduced `VLLM_CACHE_PERCENT` to 0.12 | Twice |
| +8h | Duplicate gap work: two agents claimed EVAL-011 | Coordination audit; lease file system implemented | Once |
| +12h | `chump-commit.sh` stomp — memory_db.rs overwritten | Recovery PR #65 (cherry-pick) | Once |
| +18h | "Your Name" actor pushed 13 commits to main outside coordination | Identified; hooks not enforced for that identity | Ongoing risk |
| +24h | COG-016 lessons block confirmed amplifying fake tool calls on haiku | EVAL-025 result; COG-016 directive gated | Structural (unpatched) |

### Notes

- **Throughput:** 24 PRs, ~1620 A/B trials, ~$14 total cloud spend
- **Inference:** vLLM-MLX stable at max_num_seqs=1; two Metal OOMs during model reloads (not during inference)
- **Key finding:** n=100 A/B sweep is the right unit of work — smaller cells are noise-dominated
- **Coordination:** lease file system introduced after duplicate-work incident; effective for subsequent sessions

---

## Run 0 — pre-log (early dogfood runs)

No structured log. Observations from RED_LETTER.md and git history:
- Ollama restart needed ~daily when keep-alive expired and model was evicted
- `CHUMP_PAUSED=1` kill switch used twice during vLLM instability
- Battle QA (`battle-qa.sh`) run weekly; typical pass rate 87–92%
- Memory DB growth: ~1MB/week at moderate use

---

## Soak acceptance criteria

For a production-ready soak to count as passing:

- [ ] 72+ continuous hours
- [ ] Zero process crashes (vLLM OOM restarts by Oven Tender allowed)
- [ ] Battle QA pass rate ≥ 85% at end of run
- [ ] No API key leaks in git
- [ ] chump_tool_health ring buffer shows no circuit-breaker trips > 5% of calls
- [ ] Memory DB size growth < 5MB/day
- [ ] At least one autonomy task completes end-to-end (task → PR → CI pass)

## See Also

- [Inference Stability](INFERENCE_STABILITY.md) — OOM runbook, Metal crash recovery
- [Operations](OPERATIONS.md) — Farmer Brown, Oven Tender, monitoring
- [RED_LETTER.md](RED_LETTER.md) — adversarial review of soak findings
- [BENCHMARKS.md](BENCHMARKS.md) — structured pass/fail benchmark suite
