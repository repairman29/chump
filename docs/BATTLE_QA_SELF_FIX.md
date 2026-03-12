# Battle QA self-fix: run tests and fix yourself

**Trigger phrases (any of these is enough—do not ask for more details):**  
"run battle QA and fix yourself", "battle QA self-heal", "fix battle QA", "battle QA and fix yourself", "run battle QA and fix yourself again".

When you see one of these, start immediately. No need for extra context or issue details—the procedure below is the full instruction. Do not reply with "I need more details" or "what needs addressing"; just run run_battle_qa and follow the loop.

## Loop (up to 5 rounds)

1. **Run battle QA (smoke)**  
   Call `run_battle_qa` with `max_queries: 20` (or 30) so the run finishes in a few minutes. You get back `ok`, `passed`, `failed`, `total`, `failures_path`, `log_tail`.

2. **If ok is true**  
   All passed. Reply that battle QA passed and you're done.

3. **If ok is false**  
   - Read the failures: `read_file` with path `failures_path` (e.g. `logs/battle-qa-failures.txt`).  
   - Each block is `FAIL <id> [category] <query>` then `--- output (last 500 chars) ---` and snippet.  
   - Identify patterns:  
     - **calc**: output often only has startup/tool_routing, no number — fix by ensuring the calculator tool result is printed in your reply, or that you reply with only the number when asked.  
     - **memory**: output ends at "Executing tool: memory" with no "STORED"/"OK" — fix by ensuring after memory store you emit the requested confirmation (e.g. STORED, MEMORY_STORED, OK).  
     - **timeout**: if log_tail or output suggests the run hit the per-query timeout, consider editing `scripts/battle-qa.sh` to increase `BATTLE_QA_TIMEOUT` default, or run with higher `timeout_secs` next time.

4. **Apply fixes**  
   - Use `read_file` on the relevant source (e.g. `src/calc_tool.rs`, `src/memory_tool.rs`, or the code that formats your final reply).  
   - Use `edit_file` or `write_file` to make small, targeted changes so calc replies with the number and memory replies with the confirmation.  
   - If the issue is timeout, you can `read_file` on `scripts/battle-qa.sh` and suggest or apply a higher default timeout.

5. **Re-run**  
   Call `run_battle_qa` again (same smoke size). Repeat until `ok` is true or you've done 5 fix rounds.

## Tips

- Keep fixes minimal: one behavioral change per round (e.g. "always append calc result to final reply").  
- If failures are all timeout, prefer increasing `BATTLE_QA_TIMEOUT` or passing `timeout_secs` to `run_battle_qa` before changing agent code.  
- Full 500-query run is too long for a single tool call; use smoke (20–30) for the fix loop. The user can run the full 500 manually (e.g. `./scripts/run-battle-qa-full.sh`) after you're done.

## Reference

- Query list: `scripts/qa/battle-queries.txt`  
- Failure categories and fix ideas: [BATTLE_QA_FAILURES.md](BATTLE_QA_FAILURES.md)  
- Battle QA overview: [BATTLE_QA.md](BATTLE_QA.md)
