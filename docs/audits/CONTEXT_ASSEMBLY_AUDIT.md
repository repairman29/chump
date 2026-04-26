---
doc_tag: archive-candidate
owner_gap:
last_audited: 2026-04-25
---

# Context Assembly Audit

Documents how Chump assembles the context window (system prompt + memory + tool hints + blackboard) and known inefficiencies. Key entry point: `src/local_openai.rs` `apply_sliding_window_to_messages_async`.

See [MISTRALRS.md](MISTRALRS.md) §Chat sliding window for the cross-backend comparison.

## Context assembly pipeline

```
1. System prompt (CHUMP_SYSTEM_PROMPT or default)
2. Blackboard injection (belief state, entity keys, neuromod signals)
3. Lessons block injection (COG-016 gated by model tier)
4. Memory retrieval (recall_for_context, CHUMP_CONTEXT_HYBRID_MEMORY)
5. Sliding window (truncate oldest messages to fit context limit)
6. Tool hints (EFE-biased tool ranking)
```

## Sliding window (`apply_sliding_window_to_messages_async`)

Located in `src/local_openai.rs`. Trims oldest messages to stay within the model's context limit.

**Mode:** `CHUMP_CONTEXT_HYBRID_MEMORY=1` enables hybrid memory — retrieved episodic summaries are injected as synthetic "assistant recalled" messages, allowing the model to reference events outside the window.

**Token budget:**
- Default context limit: 128k tokens (sonnet-4-7)
- System prompt: ~2–4k tokens
- Lessons block: ~1–3k tokens (when injected)
- Memory injections: ~500 tokens per retrieved episode
- Remaining: ~120k for conversation history

## Known inefficiencies

| Issue | Impact | Gap |
|-------|--------|-----|
| Lessons block injected for all model tiers | Haiku fake-tool amplification (COG-016) | Fixed by COG-016 directive; Sonnet carve-out in COG-023 |
| Memory retrieval is single-hop | Can't answer "what led to X?" multi-hop queries | EVAL-034 |
| No token budget tracking | Large history silently truncates context | No open gap |
| Entity blackboard re-fetches same entities | Redundant SQL reads on long sessions | COG-015 fixed prefetch; drift possible |

## Audit checklist

Before shipping a significant prompt-assembly change:

- [ ] Run `BATTLE_QA_MAX=20 scripts/battle-qa.sh` — pass rate ≥ 85%
- [ ] Check `chump_tool_health` ring buffer — no circuit-breaker trips > 5%
- [ ] Verify lessons block presence/absence matches model tier (`grep COG-016 logs/`)
- [ ] Check token usage in cost ledger — no unexpected spike
- [ ] Run multi-turn coherence scenario from [UI_MANUAL_TEST_MATRIX_20.md](UI_MANUAL_TEST_MATRIX_20.md) #4

## See Also

- [MISTRALRS.md](MISTRALRS.md) — cross-backend context handling
- [OPERATIONS.md](OPERATIONS.md) — env vars for context assembly
- [CHUMP_TO_CHAMP.md](CHUMP_TO_CHAMP.md) — cognitive architecture
