---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# Chump — North Star

> The founder's statement. Not a roadmap. Not a spec. The thing everything else is measured against.

---

## The Bet

Most AI development is a race to scale: bigger models, more compute, higher API bills. Chump is a bet against that race.

**The thesis:** You do not need frontier models to solve complex problems and deliver real value. You need an agent with the right architecture — one that can trust its own work, stay autonomous, self-correct when wrong, and persist across sessions without losing context. A small, well-structured agent running on a MacBook or a Raspberry Pi should outperform a stateless call to GPT-4 on any task that takes longer than one conversation.

The cognitive architecture underneath Chump — free energy, surprise tracking, neuromodulation, precision weighting, memory graphs, counterfactual reasoning — is the design hypothesis we are betting on, not a validated mechanism. It is what we believe will make a small agent stay grounded, coherent, and useful over time without a human watching every step. Each module is an answer to that question that we are testing, not asserting. Some early findings have been positive (task-class-aware lessons block: EVAL-025, EVAL-030); others have been net-negative or null pending further work (neuromodulation cross-architecture: EVAL-029; belief_state: removed in REMOVAL-003; surprisal/full architecture: gated on EVAL-035 + EVAL-043). See [`docs/process/RESEARCH_INTEGRITY.md`](../process/RESEARCH_INTEGRITY.md) for what is currently validated, what is prohibited from being claimed, and which gaps gate which claims.

---

## What Chump Is

Chump is the gold standard framework for building autonomous AI agents. Written in Rust. Built for the future.

Not a chatbot wrapper. Not a Discord bot. Not a demo. A foundation — local-first, air-gapped capable, designed to run forever and grind — that becomes whatever anyone needs it to be.

The interfaces (Discord, web, CLI, PWA) are entry points. The agent underneath is the product.

---

## The North Star Experience

Someone gets a new machine. They hit the Chump GitHub page. They see one command. They run it.

A PWA opens.

It asks: do you want to use a local model (we'll help you download one) or connect to a cloud provider with your own API keys? Either works. You own the choice.

It walks through file permissions — Chump can see your local files, but you control exactly what. Rich, explicit, reversible.

It opens a private MCP marketplace — every connector you could want, self-hosted, running on your hardware. GitHub. Slack. Calendar. Your database. Your tools. No middleman, no SaaS subscription, no data leaving your machine unless you choose.

Then it starts asking questions. Not "what do you want to do today" — deeper. What are you working on? What matters to you? What does success look like this week?

Chump is learning who you are. It is starting to build a model of your intent — not just your words, but what you are actually trying to accomplish. It will remember. It will act. It will check its work. It will come back.

That is the experience. First run to trusted agent in one session.

---

## The Heartbeat

Chump's internal state synchronizes with the user's actual intent.

Not what they typed. Not the last message in the conversation. What they are trying to accomplish — the goal underneath the request, the thing they would say if they had time to explain it fully.

This is what "heartbeat matches user intent" means. The cognitive layer (neuromodulation, precision controller, surprise tracker — `belief_state` is currently a 170-line inert stub per REMOVAL-003) is the candidate mechanism we are building toward. When Chump's model of what the user wants drifts from what they actually want, the design intent is for the system to detect it — surprise spikes, precision shifts, a correction happens — and for the heartbeat to resynchronize. Whether this candidate mechanism actually delivers on that intent is what EVAL-035 (belief-state revival) and EVAL-043 (full ablation suite) are designed to determine; until they ship, the cognitive layer is not "the mechanism," it is the mechanism we are testing.

This is not a metaphor. It is the design requirement every cognitive module is built to serve — and the standard each one will be measured against.

---

## What Success Looks Like

Chump runs unattended for a week, managing a real project, making real decisions — and the work it produces is something a competent human would be proud to have done.

No babysitting. No "are you sure?" prompts every ten minutes. It grinds. It self-corrects. It asks when it genuinely doesn't know. It surfaces what it found. The user comes back to progress, not chaos.

That is the bar.

---

## The Fleet

Consumer hardware is not powerful enough today to run a 70B model on a single machine. It will be — but not yet. Most people respond to this by paying a cloud provider. Chump responds differently.

A network of Raspberry Pis, old laptops, or cheap mini-PCs running Chump instances can collectively do what no single machine can. Each node runs its own local model, or the network splits a larger model across nodes using distributed inference. Nodes coordinate — sharing tasks, splitting work, supervising each other, healing when one goes down. The mesh grinds autonomously. The user doesn't manage the fleet; Chump manages it.

This is not a future feature. The coordination infrastructure already running in this codebase — ambient event streams, lease files, worktree isolation, mutual supervision, gap-preflight — is the prototype of this fleet protocol. It was built to coordinate AI agents writing code. The same architecture scales to a network of physical machines running inference.

The fleet vision:
- **Any hardware.** Pi 4, old ThinkPad, NUC, whatever you have. If it can run llama.cpp, it can join the fleet.
- **Model splitting.** A 70B model split across four Pis is accessible today. Coordination overhead is the bottleneck, not hardware — and that is a solvable software problem.
- **No single point of failure.** Nodes supervise each other. A crashed node's work is picked up. The fleet keeps grinding.
- **Air-gapped by default.** The whole mesh can operate without internet. Local models, local storage, local coordination. Nothing leaves unless you choose.
- **Mad Max scalable.** You can stand this up with hardware you already own, right now, years before consumers have the power to run it on a single device. That window is the advantage.

The FLEET-* gaps in this repository are not theoretical overhead. They are the foundation of this. Preserve and extend them.

---

## What Chump Is Not

- Not dependent on any one model provider. Swap the backend; the agent persists.
- Not a cloud service. Your data, your hardware, your keys.
- Not fragile to context length. Memory consolidation and episodic recall replace the context window.
- Not a research demo that stops working when the paper is done. The A/B harness (hallucination rates, task pass rates, Wilson CIs, cross-family judges) exists because we measure what we claim. If it doesn't work, we find out and fix it.

---

## For Every Agent Reading This

When you are deciding what to work on, what to prioritize, what to build — measure it against these four questions:

1. Does this make the agent more autonomous and trustworthy without requiring bigger models?
2. Does this move the first-run experience closer to the vision above?
3. Does this help Chump's heartbeat synchronize more accurately with user intent?
4. Would this work in an air-gapped environment on a $500 machine?

If the answer to all four is no, it is probably not the next thing to build.
