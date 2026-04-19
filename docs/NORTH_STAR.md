# Chump — North Star

> The founder's statement. Not a roadmap. Not a spec. The thing everything else is measured against.

---

## The Bet

Most AI development is a race to scale: bigger models, more compute, higher API bills. Chump is a bet against that race.

**The thesis:** You do not need frontier models to solve complex problems and deliver real value. You need an agent with the right architecture — one that can trust its own work, stay autonomous, self-correct when wrong, and persist across sessions without losing context. A small, well-structured agent running on a MacBook or a Raspberry Pi should outperform a stateless call to GPT-4 on any task that takes longer than one conversation.

The cognitive architecture underneath Chump — free energy, surprise tracking, belief state, neuromodulation, precision weighting, memory graphs, counterfactual reasoning — is not a research project. It is the mechanism that makes this possible. Every module exists to answer the same question: how does an agent stay grounded, coherent, and useful over time, without a human watching every step?

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

This is what "heartbeat matches user intent" means. The cognitive layer (neuromodulation, precision controller, belief state, surprise tracker) is the mechanism. When Chump's belief about what the user wants drifts from what they actually want, the system detects it — surprise spikes, precision shifts, a correction happens. The heartbeat resynchronizes.

This is not a metaphor. It is the design requirement every cognitive module is built to serve.

---

## What Success Looks Like

Chump runs unattended for a week, managing a real project, making real decisions — and the work it produces is something a competent human would be proud to have done.

No babysitting. No "are you sure?" prompts every ten minutes. It grinds. It self-corrects. It asks when it genuinely doesn't know. It surfaces what it found. The user comes back to progress, not chaos.

That is the bar.

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
