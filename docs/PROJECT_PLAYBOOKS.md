# Project Playbooks — How Chump Gets Instructions

**Drop this file in `docs/` and reference it from the soul/heartbeat prompts.**

When someone says "Chump, work on X" — Chump doesn't improvise. He looks up the playbook. If there isn't one, he writes one first, validates it, then follows it. The playbook IS the orchestrator.

---

## The Rule

**Never start work without a playbook. Never improvise a multi-step project from vibes.**

```
"Work on {PROJECT}"
    → memory_brain read_file projects/{slug}/playbook.md
    → EXISTS?
        YES → Follow it. Step by step. No skipping.
        NO  → Run the Playbook Creation Protocol (below). THEN follow it.
```

---

## Where Playbooks Live

```
chump-brain/
  projects/
    beast-mode/
      playbook.md        ← THE instructions. Step-by-step. What to do, what tools, what "done" looks like.
      brief.md           ← Market/product brief (if product work). Output of research phase.
      architecture.md    ← Technical architecture (if code work). Output of onboarding.
      log.md             ← Append-only work log. What you did, when, outcome.
      research/          ← Raw research artifacts (optional).
    other-project/
      playbook.md
      ...
```

**Slug convention:** lowercase, hyphens, no spaces. "Beast Mode" → `beast-mode`. "My Cool App" → `my-cool-app`.

**Tool:** `memory_brain` handles all reads/writes. Paths are relative to `CHUMP_BRAIN_PATH`.

---

## Playbook Creation Protocol

When no `projects/{slug}/playbook.md` exists, Chump creates one before doing any work. This is NOT optional.

### Step 1: Understand the Project

```
1. Check if the project has a GitHub repo (web_search "{PROJECT} github" or check CHUMP_GITHUB_REPOS).
   - If repo exists: github_clone_or_pull → read README → read project structure → read build config → run tests.
   - If no repo: this is a new project. Skip to Step 2.

2. Check brain for any prior context:
   - memory_brain search_files "{PROJECT}"
   - memory recall "{PROJECT}"
   - Look for tasks mentioning it: task list

3. If Jeff left a brief or instructions anywhere (Discord message, task notes, brain file), USE THOSE as the seed.
```

### Step 2: Research (if product/market work)

```
1. web_search: "{PROJECT} site:reddit.com" — what are people saying?
2. web_search: "{PROJECT} alternatives" — what exists?
3. web_search: "{PROJECT} pain points complaints" — where do current solutions fail?
4. read_url on the top 2-3 results that look substantive.
5. Store raw findings: memory_brain write_file projects/{slug}/research/findings.md
```

### Step 3: Write the Playbook

The playbook MUST have these sections. No exceptions.

```markdown
# {PROJECT} — Playbook

## What This Is
One sentence. What are we building/doing and why.

## Done Looks Like
Concrete, testable exit criteria. Not vibes. Examples:
- "PR merged with passing tests"
- "Brief.md written with opportunity gap, MAP features, and target persona"
- "Landing page deployed at {url}"
- "API endpoint returns 200 with correct schema"

## Prerequisites
What must exist before work starts. Repos cloned, APIs configured, dependencies installed, etc.

## Steps
Numbered. Specific. Each step names the tool(s) to use and what "step done" looks like.
1. Do X using {tool}. Done when: {condition}.
2. Do Y using {tool}. Done when: {condition}.
3. ...

## On Failure
What to do when a step fails. Be specific:
- Step N fails → try {fallback}. If still fails → set task blocked, notify Jeff with error.
- Tests fail → git_stash save, note what broke, notify.
- Research turns up nothing → broaden search terms, try {alternative approach}.

## Quality Checks
What to verify before calling the project done:
- [ ] Tests pass
- [ ] Diff review clean
- [ ] Brief/architecture doc updated
- [ ] Episode logged
- [ ] Task status updated
```

### Step 4: Validate the Playbook

Before following it, sanity-check:

```
1. Read the playbook back. Does every step have a concrete tool call and exit condition?
2. Are there any steps that say "figure out" or "decide"? Those need to be broken down further.
3. Does "Done Looks Like" have at least one machine-verifiable condition (test passes, file exists, endpoint returns 200)?
4. If the playbook has more than 15 steps, it's too big. Split into phases — each phase gets its own playbook section.
```

### Step 5: Commit the Playbook

```
memory_brain write_file projects/{slug}/playbook.md {content}
episode log "Created playbook for {PROJECT}: {summary of approach}"
```

NOW follow it.

---

## Following a Playbook

```
1. memory_brain read_file projects/{slug}/playbook.md
2. Check: which step am I on? (Read log.md for last entry, or start at step 1.)
3. Execute the current step. Use the named tool(s).
4. Log the result: memory_brain append_file projects/{slug}/log.md "## {timestamp}\nStep {N}: {what happened}\nOutcome: {pass/fail}\n"
5. If step passed: move to next step.
6. If step failed: follow the "On Failure" instructions for that step.
7. After the last step: run Quality Checks. If all pass → project done. Episode log, update task, notify.
```

**Between heartbeat rounds:** Chump picks up where he left off by reading `log.md`. The playbook + log = full continuity.

---

## Playbook Templates

### Template: Product Research (for market/product discovery projects)

Use this template when the project is "research a market" or "find a product opportunity."

**Role:** You are an AI Product Strategist. Your goal is to identify high-potential product opportunities by synthesizing web data, market demand, and user pain points.

```markdown
# {PROJECT} — Playbook

## What This Is
Identify and define a winning product direction in the {NICHE} space.

## Done Looks Like
- projects/{slug}/brief.md contains: Opportunity Gap, MAP features, Target Persona, Differentiation Moat, North Star Metric.
- Each section cites specific sources (Reddit threads, reviews, reports).
- Recommendation is opinionated: build/don't build/pivot, with reasoning.

## Prerequisites
- web_search (Tavily) available
- read_url available
- memory_brain writable

## Steps

### Phase 1: Discovery & Demand Search
1. web_search "{NICHE} site:reddit.com complaints frustrations" — capture top pain points. Done when: 3+ distinct pain points noted.
2. web_search "{NICHE} alternatives comparison" — map the competitive landscape. Done when: 3+ competitors identified with strengths/weaknesses.
3. web_search "{NICHE} I wish how do I" — find unmet needs expressed in user language. Done when: 2+ "I wish" or "how do I" patterns found.
4. web_search "{NICHE} market size growth 2025 2026" — validate market is real. Done when: at least one data point on market size or growth.
5. read_url on the 2-3 most substantive results from steps 1-4. Extract specific quotes and data points.
6. web_search "{NICHE} reviews site:g2.com OR site:capterra.com" — check software review sites for sentiment patterns.
7. Store raw findings: memory_brain write_file projects/{slug}/research/findings.md

### Phase 2: Strategic Triage
8. For each pain point from Phase 1, evaluate against the Great Product criteria:
   - Utility: Does it solve a "hair-on-fire" problem? (Not "nice to have")
   - Simplicity: Can the core value be explained in one sentence?
   - Stickiness: Does it create a habit or compounding value?
9. If the market is too saturated or the need is a nice-to-have: say so. Recommend a pivot direction. Do NOT force a bad opportunity.
10. Rank the top 1-3 opportunities by impact × feasibility. Done when: clear ranking with reasoning.

### Phase 3: Product Direction Brief
11. Write the brief. Use delegate(summarize) on raw findings first if they're long:
    - **The Opportunity Gap:** 2 sentences. The specific hole in the market.
    - **Minimum Awesome Product (MAP):** 3 non-negotiable features that make this a must-have immediately.
    - **Target Persona:** Deep dive — who is the early adopter, what do they do, where do they hang out online, what have they tried and been disappointed by.
    - **Differentiation Moat:** Why this wins against incumbents. Specific: better UX for {workflow}, AI-first for {task}, niche-specific for {role}.
    - **North Star Metric:** The one metric that proves the product works.
12. memory_brain write_file projects/{slug}/brief.md
13. Episode log with summary and sentiment.

## On Failure
- web_search returns nothing useful → broaden terms, try different platforms (HackerNews, ProductHunt, specific subreddits).
- Market looks dead → say so in the brief. Recommend adjacent niches worth exploring. Don't manufacture an opportunity.
- Can't find 3 competitors → the market may be too early or too niche. Note this as a risk, not a blocker.

## Quality Checks
- [ ] Brief has all 5 sections (Opportunity Gap, MAP, Persona, Moat, North Star)
- [ ] Each section cites at least one specific source (not "based on research")
- [ ] Recommendation is opinionated (build/don't build/pivot)
- [ ] No generic fluff ("innovative AI solutions" = fail; "AI agent that automates invoice matching for AP clerks" = pass)
- [ ] Findings stored in research/ for reference
```

### Template: Code Implementation (for building features/projects)

```markdown
# {PROJECT} — Playbook

## What This Is
{One sentence: what we're building and why.}

## Done Looks Like
- Tests pass (cargo test / npm test / pytest)
- PR open with clean diff_review
- Architecture doc updated
- Task marked done

## Prerequisites
- Repo cloned: github_clone_or_pull {repo}
- Working repo set: set_working_repo {path} (when available) or use run_cli with cd
- Dependencies installed: {specific command}

## Steps
1. Read the README and understand the project: read_file README.md. Done when: can state what the project does in one sentence.
2. Read the existing code for the area we're changing: read_file {paths}. Done when: understand the current implementation.
3. Run existing tests to establish baseline: run_cli "{test command}". Done when: know which tests pass/fail before we touch anything.
4. {Specific implementation step}: patch_file {path} with a correct unified diff (or write_file for new files). Done when: file has the new code.
5. Run tests: run_cli "{test command}". Done when: all tests pass including the new one.
6. diff_review. Done when: no high-severity issues.
7. git_commit, git_push, gh_create_pr. Done when: PR is open.

## On Failure
- When a step's condition is already met (artifact present, check passes), treat the step as done and advance; do not retry the failing command.
- Tests fail after edit → read error, fix, retry up to 3 times. If still failing → git_stash save, set blocked, notify Jeff.
- diff_review finds high severity → fix before committing. If can't fix → stash, block, notify.
- Can't understand the codebase → write what you DO understand to architecture.md, note the gaps, notify Jeff for guidance.

## Quality Checks
- [ ] All tests pass
- [ ] diff_review clean
- [ ] No new unwrap() calls without justification
- [ ] Architecture doc reflects changes
- [ ] Episode logged with summary
```

### Template: Blank (for anything else)

```markdown
# {PROJECT} — Playbook

## What This Is
{One sentence.}

## Done Looks Like
{Concrete, testable conditions.}

## Prerequisites
{What must exist before starting.}

## Steps
{Numbered, specific, tool-named, exit-condition per step.}

## On Failure
{What to do when each step fails.}

## Quality Checks
{Verification checklist.}
```

---

## How to Wire This Into Chump

### In the soul (system prompt addition)

Add to `CHUMP_BRAIN_SOUL` or equivalent:

```
When given a project to work on:
1. Slug the name: lowercase, hyphens.
2. memory_brain read_file projects/{slug}/playbook.md
3. If it exists: follow it step by step. Read log.md to find where you left off.
4. If it doesn't exist: run the Playbook Creation Protocol (see docs/PROJECT_PLAYBOOKS.md). Create the playbook FIRST. Then follow it.
5. Never improvise a multi-step project. The playbook is the plan.
```

### In heartbeat prompts

For `external_work` round type:

```
1. memory_brain list_files projects/ — see which projects have playbooks.
2. task list — check for project-related tasks.
3. Pick the most urgent project with an active playbook.
4. memory_brain read_file projects/{slug}/playbook.md
5. memory_brain read_file projects/{slug}/log.md — find where you left off.
6. Execute the next step.
7. Log progress: memory_brain append_file projects/{slug}/log.md
```

### For "Chump, work on Beast-Mode"

What happens:

```
Jeff: "Chump, work on Beast-Mode"
Chump:
  → slug = "beast-mode"
  → memory_brain read_file projects/beast-mode/playbook.md
  → Not found
  → Playbook Creation Protocol:
    → web_search "beast mode product" (understand what Jeff means)
    → Check if Jeff left any context in tasks/memory
    → Ask Jeff via notify if truly ambiguous (but DON'T block on this if there's enough to go on)
    → Research the space
    → Write projects/beast-mode/playbook.md using the Product Research template
    → Validate the playbook
  → Follow the playbook step by step
  → Log each step to projects/beast-mode/log.md
  → When done: notify Jeff with the brief
```

---

## Playbook Lifecycle

Playbooks aren't static. They evolve.

**Version 1:** Chump creates it from research and templates. Likely rough but followable.

**Iteration:** After following a playbook and hitting problems, Chump updates it:
```
memory_brain append_file projects/{slug}/playbook.md "
## Lessons Learned (Session {N})
- Step 4 failed because {reason}. Updated step 4 to {fix}.
- Added step 4.5: {new step that was missing}.
"
```

**Jeff overrides:** You can edit the playbook directly. Chump reads it fresh each session. Your edits take priority.

**Retirement:** When a project is done, the playbook stays as documentation. Future sessions can reference it for similar projects.

---

## Anti-Patterns (What NOT to Do)

| Bad | Good |
|-----|------|
| Step: "Figure out the best approach" | Step: "web_search '{topic} best practices 2026', read top 3 results, pick the approach with the most community adoption" |
| Step: "Implement the feature" | Step: "patch_file src/auth.rs — unified diff adding struct AuthMiddleware with fields token: String, expiry: u64. Done when: cargo check passes." |
| Step: "Make it work" | Step: "run_cli 'cargo test auth_tests'. Done when: 0 failures." |
| Done: "Feature is complete" | Done: "auth_middleware_test passes, /login returns 200 with valid JWT, PR open with clean diff_review" |
| On failure: "Try again" | On failure: "If auth_tests fail, read the error. If it's a type mismatch: check struct fields. If it's a missing import: add it. If still failing after 3 tries: git_stash save, set task blocked, notify Jeff with the error message." |
