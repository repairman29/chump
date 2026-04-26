---
doc_tag: log
owner_gap:
last_audited: 2026-04-25
---

# Problem Validation Checklist

COS Wave 4.1 deliverable. Framework for validating that a proposed new product or feature addresses a real problem before building. Used with `scripts/scaffold-side-repo.sh`.

## Checklist (run before committing to a new product initiative)

### 1. Problem clarity

- [ ] Can you state the problem in one sentence without mentioning the solution?
- [ ] Who experiences this problem? (user type, frequency, severity)
- [ ] What do people do today instead? (current workaround)
- [ ] What makes this painful? (why the workaround is inadequate)

### 2. Evidence

- [ ] At least 3 independent signals this is a real problem (user quotes, search volume, GitHub issues, forum posts, research papers)
- [ ] At least 1 person who has expressed urgency ("I wish I could...", "I'm frustrated by...")
- [ ] Can you reproduce the pain yourself in under 10 minutes?

### 3. Market

- [ ] Are there existing solutions? List them.
- [ ] Why do existing solutions fall short? (specific gap, not "they're not as good")
- [ ] What is the accessible market? (rough estimate — don't be precise)
- [ ] Is the problem growing or shrinking in importance?

### 4. Fit

- [ ] Does this align with Chump's North Star (personal ops + cognitive architecture + fleet)?
- [ ] Does this leverage Chump's differentiated capabilities (memory graph, eval harness, single Rust binary)?
- [ ] Could this be a capability extension rather than a new product?

### 5. Build vs. partner vs. skip

- [ ] Build: effort, timeline, and first milestone (S/M/L)
- [ ] Partner: is there an existing system to integrate with instead?
- [ ] Skip: what would have to be true for this to be worth ignoring?

## Example: Cross-agent benchmarking (FRONTIER-007)

**Problem:** No standard way to compare Chump vs goose vs AutoGen on the same task set. Capability claims are unverified.

**Evidence:** goose has no published benchmarks. AutoGen's eval set is adversarial-focused. Chump's own harness is internal only.

**Market:** AI engineer / researcher audience evaluating agent systems. Growing (agent systems exploding).

**Fit:** Directly leverages Chump's A/B eval harness. Could position Chump as the empirical standard-setter.

**Decision:** Build (FRONTIER-007, M effort). Milestone: run Chump + goose + AutoGen on Chump's existing fixtures at n=20.

## See Also

- [PRODUCT_REALITY_CHECK.md](PRODUCT_REALITY_CHECK.md) — current product gaps
- [MARKET_EVALUATION.md](MARKET_EVALUATION.md) — competitive landscape
- [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) — what's shipping this quarter
