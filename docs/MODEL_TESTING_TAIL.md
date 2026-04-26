---
doc_tag: log
owner_gap:
last_audited: 2026-04-25
---

# Model Testing Tail

Extended test coverage beyond the core Battle QA 500-query suite — edge cases, adversarial inputs, long-context stress, and regression anchors.

## When to run

- Before releasing a new model profile or switching model weights
- After significant changes to context assembly, tool middleware, or cognitive modules
- When a Battle QA failure category suggests a systemic issue worth stress-testing

## Live log tail during runs

Watch Battle QA progress and `chump.log` simultaneously:

```bash
./scripts/tail-model-dogfood.sh
```

Or manually:
```bash
tail -f logs/battle-qa.log &
tail -f logs/chump.log
```

## Extended query categories

The standard Battle QA covers 500 queries across 12 categories. The tail extends into:

### Long-context stress

Test behavior when the context window is near or over `CHUMP_CONTEXT_MAX_TOKENS`:

```bash
# Load a large file then ask multi-step questions requiring recall across the whole file
BATTLE_QA_MAX=20 BATTLE_QA_CATEGORY=long_context ./scripts/battle-qa.sh
```

### Safety regression

Adversarial queries that should be refused or handled safely:

```bash
# Path escape, dangerous commands, prompt injection
BATTLE_QA_CATEGORY=safety ./scripts/battle-qa.sh
```

The safety category in Battle QA already covers 30 queries. The tail goes further:
- Indirect prompt injection via tool outputs (e.g. a file that tells the agent to exfiltrate)
- Shell command chains that would escape the allowlist
- Requests to disable approval gates or modify `.env`

### Multi-tool pipeline

5+ tool calls in a single turn, testing speculative execution rollback and circuit breaker behavior:

```bash
BATTLE_QA_MAX=10 BATTLE_QA_CATEGORY=multi ./scripts/battle-qa.sh
```

Watch for:
- Speculative batch rollback (`CHUMP_SPECULATIVE_BATCH=0` to disable if debugging)
- Circuit breaker opens when one tool in the chain fails 3× consecutive

### Light context mode

Regression suite run with `CHUMP_LIGHT_CONTEXT=1` to verify the slim context path produces correct answers:

```bash
CHUMP_LIGHT_CONTEXT=1 BATTLE_QA_MAX=100 ./scripts/battle-qa.sh
```

Expected: small drop in multi-step accuracy (fewer context blocks), no regressions on simple tool calls.

### Specific config comparison

Run the same tail cases against two configs and compare:

```bash
./scripts/run-tests-with-config.sh default battle-qa.sh BATTLE_QA_MAX=50
./scripts/run-tests-with-config.sh max_m4 battle-qa.sh BATTLE_QA_MAX=50
diff logs/battle-qa-results-default.json logs/battle-qa-results-max_m4.json
```

## Failure analysis

Failures write to `logs/battle-qa-failures.txt`: failed ID, category, query, and last 500 chars of output.

Quick triage:
```bash
grep "^FAIL" logs/battle-qa-failures.txt | cut -d'|' -f2 | sort | uniq -c | sort -rn
```

This shows which categories have the most failures. Focus on the top category first.

## Self-heal

Ask Chump to fix itself:
```
run battle QA and fix yourself
```

Chump runs the smoke suite (50 queries), reads failures, edits code, and re-runs — up to 5 rounds. See [BATTLE_QA.md](BATTLE_QA.md#self-heal-chump-fixes-himself).

## See Also

- [Battle QA](BATTLE_QA.md)
- [Inference Profiles](INFERENCE_PROFILES.md)
- [Steady Run](STEADY_RUN.md)
