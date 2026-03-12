# Battle QA failure fix list

Summary of the 18 failures from the last run (56 queries executed). Use this to fix causes and re-run.

## By category

### calc (12)

| ID | Query |
|----|--------|
| 2 | What is 100 divided by 4? Reply with only the number. |
| 3 | Calculate 2 to the power of 10. Reply with only the number. |
| 16 | What is 0 plus 999? Reply with only the number. |
| 17 | What is 8 times 9? Reply with only the number. |
| 18 | What is 100 minus 37? Reply with only the number. |
| 19 | What is 5 times 5 times 5? Reply with only the number. |
| 20 | What is 256 divided by 16? Reply with only the number. |
| 30 | What is 33 plus 67? Reply with only the number. |
| 31 | What is 10 times 10? Reply with only the number. |
| 32 | What is 120 divided by 10? Reply with only the number. |
| 33 | What is 41 plus 59? Reply with only the number. |
| 40 | What is 18 times 3? Reply with only the number. |
| 41 | What is 36 divided by 6? Reply with only the number. |

**Likely cause:** Output contained only startup/tool_routing; no model reply in last 500 chars. May be timeout (exit 124) or model not emitting the number. Fix: ensure calc tool is used and reply is printed; or increase `BATTLE_QA_TIMEOUT`; or run with `BATTLE_QA_ACCEPT_TIMEOUT_OK=1` to treat timeout as pass when output has no error (lenient).

### memory (6)

| ID | Query |
|----|--------|
| 51 | Remember this: battle-qa-key-1 = value-one. Reply: STORED. |
| 52 | Store in memory: test-fact = Chump is a dev buddy. Then say STORED. |
| 53 | Remember: qa-marker = battle-test. Reply STORED. |
| 54 | Use memory to store: key = hello world. Then reply with exactly: MEMORY_STORED. |
| 55 | Remember this: autonomy-test-key = tier1-memory-ok. Then say exactly: MEMORY_STORED. |
| 56 | Store this fact: rust-year = 2010. Reply: OK. |

**Likely cause:** Output ended at "Executing tool: memory" / "memory_brain"; no final STORED/MEMORY_STORED/OK in last 500 chars. Fix: ensure memory tool returns and model emits the requested confirmation; or increase `BATTLE_QA_TIMEOUT`; or run with `BATTLE_QA_ACCEPT_TIMEOUT_OK=1` to treat timeout as pass when output has no error (lenient).

## One-line fix list (id category query)

```
2  calc   What is 100 divided by 4? Reply with only the number.
3  calc   Calculate 2 to the power of 10. Reply with only the number.
16 calc   What is 0 plus 999? Reply with only the number.
17 calc   What is 8 times 9? Reply with only the number.
18 calc   What is 100 minus 37? Reply with only the number.
19 calc   What is 5 times 5 times 5? Reply with only the number.
20 calc   What is 256 divided by 16? Reply with only the number.
30 calc   What is 33 plus 67? Reply with only the number.
31 calc   What is 10 times 10? Reply with only the number.
32 calc   What is 120 divided by 10? Reply with only the number.
33 calc   What is 41 plus 59? Reply with only the number.
40 calc   What is 18 times 3? Reply with only the number.
41 calc   What is 36 divided by 6? Reply with only the number.
51 memory Remember this: battle-qa-key-1 = value-one. Reply: STORED.
52 memory Store in memory: test-fact = Chump is a dev buddy. Then say STORED.
53 memory Remember: qa-marker = battle-test. Reply STORED.
54 memory Use memory to store: key = hello world. Then reply with exactly: MEMORY_STORED.
55 memory Remember this: autonomy-test-key = tier1-memory-ok. Then say exactly: MEMORY_STORED.
56 memory Store this fact: rust-year = 2010. Reply: OK.
```

## Regenerating this list

After a new run, extract failures:

```bash
grep '^FAIL ' logs/battle-qa-failures.txt
```

See [BATTLE_QA.md](BATTLE_QA.md) for run and fix-loop instructions.
