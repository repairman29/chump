# Memory Graph vs FTS5: What Associative Recall Does That Keyword Search Can't

**Phase 2.3 of the [Hermes Competitive Roadmap](HERMES_COMPETITIVE_ROADMAP.md).** This document demonstrates specific queries that Chump's memory graph answers correctly but Hermes-Agent's FTS5-only search cannot.

**Reference:** Hermes's own documentation admits this weakness: "cannot recognize that 'Alice' and 'my coworker Alice' refer to the same person" ([source](https://vectorize.io/articles/hermes-agent-memory-explained)).

---

## The Core Difference

**FTS5 (what Hermes uses):** Indexes words. Finds messages that contain query keywords.

**Memory Graph (what Chump uses):** Indexes *relationships between entities*. Finds answers by traversing the connection structure.

Both start from the same input (past conversations, stored facts). The graph adds a second layer: extracted subject-relation-object triples that encode meaning, not just text.

---

## Example 1: Multi-Hop Entity Resolution

### Stored facts (both agents):
- "Alice works at Acme Corp"
- "Acme Corp uses Rust for their backend"
- "Jeff is also at Acme"

### Query: "What language does Jeff's team use?"

**FTS5 (Hermes):** Searches for "Jeff" + "team" + "language". Returns any message containing those words. In this case, finds nothing useful because "Jeff" appears in one fact and "language" in none.

**Memory Graph (Chump):** 
1. Extract entities: `Jeff`, `team`, `language`
2. Expand via graph: `Jeff` → `at` → `Acme` → `uses` → `Rust`
3. Return: "Rust (inferred from Jeff at Acme; Acme uses Rust)"

**Why it works:** The graph has edges that connect facts even when no single message contains both endpoints.

---

## Example 2: Transitive Relationship Queries

### Stored facts:
- "Sarah manages the billing team"
- "The billing team owns the checkout service"
- "The checkout service uses Stripe"

### Query: "Who should I ask about Stripe integration?"

**FTS5:** Returns messages mentioning "Stripe". The best hit is "The checkout service uses Stripe." — doesn't answer the question.

**Memory Graph:**
1. Entity: `Stripe`
2. Reverse edges: `checkout` → `uses` → `Stripe` (so `checkout` owns it)
3. Reverse again: `billing team` → `owns` → `checkout`
4. Reverse again: `Sarah` → `manages` → `billing team`
5. Answer: Sarah

---

## Example 3: Entity Disambiguation

### Stored facts:
- "Alice is a frontend engineer"
- "My coworker Alice likes React"
- "Alice Thompson presented at the conference"

### Query: "What does Alice work on?"

**FTS5:** Returns all three messages. User has to figure out if they're the same Alice.

**Memory Graph:** Within the session's coreference scope, "Alice" and "my coworker Alice" resolve to the same graph node (when entity extraction identifies them as the same referent). Returns: "Alice (frontend engineer, likes React, presented at conference)" — a single unified entity view.

**Caveat:** This works when the entity extractor recognizes the coreference. Chump's extraction isn't perfect, but the data model supports merging in a way FTS5 fundamentally cannot.

---

## Example 4: Reinforcement Through Repetition

### Scenario: Over multiple sessions, you mention "the bug in the auth flow" 5 times.

**FTS5:** Returns 5 matches. No notion of which is most relevant or which entity is most important.

**Memory Graph:** The `auth flow` → `has` → `bug` edge gets its `weight` column incremented with each mention (we reinforce triples on repeat insertion with +0.5 per hit). High-weight edges rank higher in Personalized PageRank traversal, so repeatedly-discussed topics surface naturally.

---

## Example 5: Cross-Session Continuity

### Session 1:
- User: "I'm working on the billing migration"
- Chump stores: `user` → `working_on` → `billing migration`

### Session 2 (hours/days later):
- User: "Any updates on that?"

**FTS5:** Has no idea what "that" means. Has to search recent messages, probably gets the last user message, fails to resolve reference.

**Memory Graph:** "That" gets resolved to recent high-weight entities from the graph, with `billing migration` being the most salient. PageRank scores rank it high because it was reinforced.

**Why this matters:** Natural conversation uses pronouns heavily. FTS5 can't handle reference resolution; the graph can.

---

## Live Demo

With Chump running, try these commands in the CLI or PWA:

```bash
# Populate the graph
chump "I just started a project called Chump. It's written in Rust."
chump "Chump has a consciousness framework inspired by Active Inference."
chump "Active Inference was proposed by Karl Friston."

# Query that requires multi-hop traversal
chump "Whose ideas influenced my Chump project?"
# Expected: "Karl Friston's (via Active Inference, which Chump's consciousness framework is inspired by)"
```

With Hermes, the same query returns messages containing "influenced" or "ideas" — not the actual answer.

---

## Visualization

Chump exposes graph structure via:

```bash
# Get graph as DOT (pipe to graphviz for PNG)
curl http://localhost:3000/api/brain/graph.json | jq .

# Get summary stats
curl http://localhost:3000/api/brain/graph/stats
```

Or via the agent:
```
skill_manage action=view name=memory-graph-tutorial
memory_graph_viz action=stats
memory_graph_viz action=demo_queries
```

---

## Implementation Details

**FTS5 (Hermes):**
- SQLite virtual table with tokenizer
- Scores by BM25
- No entity extraction
- No cross-message structure

**Memory Graph (Chump):**
- `chump_memory_graph` table with `(subject, relation, object, weight)` rows
- 60+ relation types extracted from stored text (is, has, uses, works_on, etc.)
- Personalized PageRank (α=0.85, ε=1e-6) for multi-hop traversal
- Bounded BFS for connected component discovery
- Valence scores per relation (positive/negative sentiment)
- Reinforcement on repeated insertion (+0.5 weight)

Combined with Chump's **3-way RRF merge** (keyword FTS5 + semantic embeddings + graph traversal), queries get the best of all three retrieval strategies.

---

## Caveats

- The graph is only as good as triple extraction. Regex-based extraction has limitations.
- LLM-assisted extraction (via the delegate worker) produces better triples but is slower.
- Over long time horizons, the graph grows large. Chump doesn't yet have automatic decay/pruning (Phase 3.x work).
- Entity disambiguation within one session is easier than across sessions.

---

## Verdict

For **flat keyword search**: FTS5 is fine and Hermes does well.

For **semantic search over many documents**: Both have options (Chump via fastembed, Hermes via external providers).

For **multi-hop reasoning, entity resolution, transitive queries, and relationship-aware recall**: The memory graph is categorically better. This is not about speed or polish — it's about *having a capability at all* that FTS5-only systems lack.

This is one of Chump's structural advantages. Hermes cannot add this without rebuilding their memory architecture.

---

**Sources:**
- [Vectorize: How Hermes Agent Memory Actually Works](https://vectorize.io/articles/hermes-agent-memory-explained)
- `src/memory_graph.rs` in this repo (Personalized PageRank implementation)
- `src/memory_graph_viz.rs` in this repo (graph export + visualization)
- HippoRAG paper (inspiration for the associative graph pattern)
