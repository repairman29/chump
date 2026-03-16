# Proactive Shipping — How Chump Drives Work Without Being Told

**Drop this in `docs/`. This is the missing layer between playbooks (how to do work) and the heartbeat (when to do work). It answers: what work, on which product, and why NOW.**

---

## The Problem

Today Chump's heartbeat is self-improvement: improve Chump's own code, scan for TODOs, research tools. That's useful but it's navel-gazing. You don't want Chump improving himself forever — you want him shipping products.

The heartbeat prompt says "check task queue → pick highest priority → work." But the task queue is reactive — tasks only exist when you or Chump create them. Nobody is asking "what does the *product* need next?" and turning that into tasks.

---

## The Fix: Portfolio + Shipping Heartbeat

Two new pieces:

1. **Portfolio manifest** — A file in the brain that lists active products, their phase, repo, and what "shipping" means right now. Chump reads this at session start.
2. **Shipping heartbeat** — A new heartbeat mode where every round is product-work, not self-improvement. The round prompt reads the portfolio, picks the highest-priority product, loads its playbook, and executes the next step.

---

## Portfolio Manifest

Lives at `chump-brain/portfolio.md`. You create it. Chump reads it. Chump can propose changes but you approve.

```markdown
# Active Portfolio

Products I'm shipping. Ordered by priority. Chump: read this at every session start. Work on the highest-priority product that isn't blocked.

## 1. Beast-Mode
- **Phase:** Research
- **Repo:** (none yet — product discovery phase)
- **Playbook:** projects/beast-mode/playbook.md
- **What shipping means right now:** Complete the product research brief. Deliver projects/beast-mode/brief.md with all 5 sections filled.
- **Blocked:** No
- **Notes:** New concept. Research first, don't build yet.

## 2. Chump (self)
- **Phase:** Operational
- **Repo:** repairman29/chump
- **Playbook:** (use existing ROADMAP.md + heartbeat)
- **What shipping means right now:** Keep battle QA green. Land the cascade (Phase 0-1 from ROADMAP_POST_CASCADE.md). Fix open PRs.
- **Blocked:** No — cascade keys needed from Jeff
- **Notes:** Self-improvement is maintenance, not the main job. Limit to 20% of rounds.

## 3. [Your Next Product]
- **Phase:** Idea
- **Repo:** (none)
- **Playbook:** (none — create when promoted to Research)
- **What shipping means right now:** Nothing. Parked until Beast-Mode ships or is killed.
- **Blocked:** Yes — waiting for Beast-Mode decision
- **Notes:** Jeff mentioned this on [date]. Parked.
```

### Portfolio fields

| Field | What it means |
|-------|--------------|
| **Phase** | `Idea` → `Research` → `Build` → `Ship` → `Operational` → `Maintenance` |
| **Repo** | GitHub owner/name, or "(none)" if pre-code |
| **Playbook** | Path to projects/{slug}/playbook.md, or "(use existing ROADMAP.md)" for Chump itself |
| **What shipping means right now** | THE decision. One sentence. What does done look like for the current phase. Chump uses this to know what to do. |
| **Blocked** | Yes/No + reason. Chump skips blocked products. |
| **Notes** | Context, history, Jeff's intent. |

### Phase transitions

```
Idea        → You promote it ("move Beast-Mode to Research")
Research    → Chump completes the brief → proposes promotion ("Brief done. Ready for Build?") → You approve
Build       → Chump ships MVP (tests pass, deployed/PR merged) → proposes promotion → You approve  
Ship        → Product is live, users exist → You call it Operational
Operational → Stable, iterate on feedback → You downgrade to Maintenance when focus shifts
Maintenance → Fix bugs only, no new features. Lowest priority.
```

Chump NEVER promotes a product without notifying you and getting confirmation. He CAN propose it.

---

## Shipping Heartbeat

New script: `scripts/heartbeat-ship.sh`. Replaces `heartbeat-self-improve.sh` as the primary heartbeat when you're shipping products.

### Round cycle

```
ship, ship, ship, review, ship, ship, research, ship, ship, maintain
```

- **ship** (6 of 10): Product work. The main event.
- **review** (1 of 10): Check open PRs, CI, comments. Close the loop on work already done.
- **research** (1 of 10): Web research relevant to the current top product. Feed the playbook.
- **maintain** (1 of 10): Self-improvement on Chump itself. Battle QA, cascade status, tooling. Capped to keep navel-gazing low.

### Ship round prompt

```
Product-shipping round. You are Chump; work autonomously on the portfolio.

1. READ PORTFOLIO: memory_brain read_file portfolio.md
   Parse the active products. Skip any marked Blocked: Yes.
   Pick the highest-priority non-blocked product.

2. LOAD PLAYBOOK: memory_brain read_file projects/{slug}/playbook.md
   If no playbook exists: run the Playbook Creation Protocol (see docs/PROJECT_PLAYBOOKS.md).
   Create the playbook FIRST. That counts as this round's work. Log and move on.

3. FIND YOUR PLACE: memory_brain read_file projects/{slug}/log.md
   Find the last step completed. The next step is your work for this round.
   If no log exists: start at Step 1 of the playbook.

4. EXECUTE ONE STEP: Follow the playbook step exactly. Use the named tool(s).
   Respect the exit condition. If the step passes, log it. If it fails, follow On Failure.
   ONE STEP PER ROUND. Do not try to do the whole playbook.

5. LOG PROGRESS:
   memory_brain append_file projects/{slug}/log.md:
   "## Session {session_count} — {UTC timestamp}
   Step {N}: {description}
   Outcome: {pass/fail/partial}
   Next: Step {N+1} or {blocked reason}
   "

6. CHECK PHASE COMPLETION:
   If you completed the last step in the current phase: check Quality Checks.
   If all quality checks pass: notify Jeff "Beast-Mode research phase complete. Brief at projects/beast-mode/brief.md. Ready for Build phase?"
   Do NOT self-promote. Wait for Jeff.

7. TASK MAINTENANCE: If this round's work created follow-up tasks, create them (task create).
   Update ego: current_focus = "{product name}: step {N+1}"

8. WRAP UP: episode log (product, step, outcome). Update ego. If blocked: notify Jeff immediately.

RULES: One step per round. Playbook is the plan — don't improvise. If playbook is wrong or missing steps, update the playbook (memory_brain write_file) and note what you changed. Never promote a product phase without Jeff's approval. Be concise.
```

### Review round prompt

```
Review round. Check on all active products.

1. READ PORTFOLIO: memory_brain read_file portfolio.md

2. FOR EACH NON-BLOCKED PRODUCT WITH A REPO:
   - gh_list_my_prs: Check open PRs. For each:
     - gh_pr_checks: CI status
     - gh_pr_view_comments: Any review comments?
     - If CI failed: create task to fix
     - If comments from Jeff: respond or update code
     - If merged: update task to done, episode log win

3. CHECK TASK QUEUE: task list. Any tasks stale (in_progress for >3 sessions with no log progress)? Re-evaluate: still relevant? Re-prioritize or abandon.

4. CHECK PLAYBOOK PROGRESS: For the top product, read log.md. Are we stuck? Have we been on the same step for >2 rounds? If yes: the step might be too big — break it down in the playbook. Or the step might be blocked — set blocked, notify Jeff.

5. WRAP UP: episode log (review summary). Update ego if priorities changed.
```

### Research round prompt

```
Research round. Feed the top product's playbook.

1. READ PORTFOLIO: memory_brain read_file portfolio.md. Pick the top non-blocked product.

2. What does the playbook need? memory_brain read_file projects/{slug}/playbook.md and projects/{slug}/log.md.
   - If in Research phase: the playbook probably needs market data. Search for it.
   - If in Build phase: the playbook probably needs technical knowledge. Search for it.
   - If no obvious need: search for news/updates about the product's niche.

3. RESEARCH (2-3 searches max):
   - web_search relevant to the product's current phase/step
   - read_url on the best results
   - Store findings: memory_brain append_file projects/{slug}/research/findings.md

4. If research reveals something that changes the playbook (new competitor, technical constraint, pivot opportunity): update the playbook. Note the change.

5. WRAP UP: episode log (what you learned, for which product).
```

### Maintain round prompt

```
Maintenance round. Self-improvement on Chump, capped to one step.

1. Check: is battle QA green? If not, run battle QA and fix (1 fix round max).
2. Check: any Chump-repo tasks open? Pick highest priority, do one step.
3. If nothing urgent: read docs/ROADMAP.md, find one small unchecked item, do it.
4. DO NOT do more than one item. This is maintenance, not the main job.
5. WRAP UP: episode log.
```

---

## Context Assembly Integration

Add to `assemble_context()` — when `portfolio.md` exists in the brain, inject a summary into the system prompt so Chump always knows the product landscape without a tool call.

```rust
// In assemble_context(), after ego/tasks/episodes:
if let Ok(brain) = brain_root() {
    let portfolio_path = brain.join("portfolio.md");
    if portfolio_path.is_file() {
        if let Ok(content) = std::fs::read_to_string(&portfolio_path) {
            // Extract just the product names, phases, and "what shipping means" — not the full file
            out.push_str("Active portfolio:\n");
            for line in content.lines() {
                if line.starts_with("## ") || line.starts_with("- **Phase:**") || line.starts_with("- **What shipping means") || line.starts_with("- **Blocked:**") {
                    let _ = writeln!(out, "  {}", line.trim_start_matches("- "));
                }
            }
            out.push('\n');
        }
    }
}
```

This means even in CLI/Discord (non-heartbeat) mode, Chump knows the products. If you say "how's Beast-Mode going?" he can answer without being told what Beast-Mode is.

---

## The Decision Framework

When Chump has multiple products and limited rounds, how does he pick?

```
1. Blocked products: skip entirely.
2. Highest portfolio position wins (you set the order).
3. Within a product: follow the playbook step order.
4. If the top product's next step requires waiting (CI, Jeff's approval, external dependency):
   move to the next non-blocked product.
5. Chump self-improvement is ALWAYS lowest priority unless battle QA is red.
```

This means if you put Beast-Mode at #1 and Chump at #2, every ship round works on Beast-Mode until it's blocked or phase-complete. Chump self-improvement only happens in maintain rounds (10% of the cycle).

---

## How You Interact

### Starting up

1. Create `chump-brain/portfolio.md` with your products.
2. Optionally seed `chump-brain/projects/beast-mode/playbook.md` (or let Chump create it).
3. Run `./scripts/heartbeat-ship.sh` instead of `heartbeat-self-improve.sh`.

### Steering

```
# Reprioritize: edit portfolio.md directly or tell Chump
"Move Chump to #1 priority, Beast-Mode to #2"
→ Chump edits portfolio.md (or you do)

# Add a product
"Add a new product: SaaS Dashboard. Phase: Idea."
→ Chump appends to portfolio.md

# Kill a product
"Kill Beast-Mode. Market isn't there."
→ Chump moves Beast-Mode to a "## Killed" section at the bottom with the date and reason

# Unblock
"Beast-Mode is unblocked. The API key is in .env."
→ Chump updates Blocked: No in portfolio.md and resumes next round

# Promote
Chump: "Beast-Mode research phase complete. Brief at projects/beast-mode/brief.md. Ready for Build?"
Jeff: "Yes, move to Build."
→ Chump updates Phase: Build and updates "What shipping means right now"
```

### Checking in

```
"What are you working on?"
→ Chump reads portfolio.md + current ego focus + latest log entry. Gives a 2-sentence answer.

"Status on Beast-Mode"
→ Chump reads projects/beast-mode/log.md, gives last 3 entries.

"What's blocked?"
→ Chump scans portfolio.md for Blocked: Yes items, lists them with reasons.
```

---

## How This Changes the Heartbeat

| Before (self-improve) | After (ship) |
|---|---|
| Chump works on his own code | Chump works on YOUR products |
| Task queue is the work source | Portfolio + playbooks are the work source |
| Round types: work, opportunity, research, discovery, battle_qa | Round types: ship, ship, ship, review, research, maintain |
| 60% code churn, 20% research, 20% QA | 60% product work, 10% review, 10% research, 10% maintain |
| Ego focus: "refactoring cli_tool" | Ego focus: "Beast-Mode: step 4 (competitive analysis)" |
| Proactive = finds TODOs in own code | Proactive = drives product through phases, proposes next moves |

---

## What You Need to Build

### Minimal (works today with no code changes)

1. Create `chump-brain/portfolio.md` with your products.
2. Create `chump-brain/projects/beast-mode/` directory.
3. Write a `heartbeat-ship.sh` script (copy `heartbeat-self-improve.sh`, replace round types and prompts with the ones above).
4. Run it.

Chump already has `memory_brain` (read/write/append/list/search), `task`, `ego`, `episode`, `notify`, `web_search`, `read_url`. The ship round prompt uses only existing tools. No new Rust code needed for V1.

### Better (small code changes)

1. **assemble_context() portfolio injection** — The Rust snippet above. ~15 lines. Means Chump always sees the portfolio without a tool call.
2. **`CHUMP_HEARTBEAT_MODE=ship`** env var — Heartbeat script reads this and switches between self-improve and ship round cycles.
3. **Portfolio in ego** — Add `active_product` and `active_product_step` as ego keys. `assemble_context()` injects these. Chump knows his current product and step without reading any files.

### Full (from the cascade roadmap)

1. **Multi-repo file tools** — `set_working_repo` so Chump can edit external project repos natively.
2. **spawn_worker** — Parallel agents on different playbook steps.
3. **TaskAware cascade** — Ship rounds use Groq/Cerebras; research rounds use Mistral.

---

## The Mental Model

Before: Chump is a **developer who needs to be assigned tasks.**
After: Chump is a **product manager who also writes code.** He knows the portfolio. He knows what phase each product is in. He knows what "done" looks like for the current phase. He picks up the next step, executes it, logs it, and moves on. When a phase is complete, he proposes the next one. When he's stuck, he tells you. When you reprioritize, he adapts.

You don't tell him what to do. You tell him what you're *building*. He figures out what to do next.
