# Problem validation checklist (before a new repo or product)

Use this when Chump (or you) proposes **a new repository, tool, or customer-facing surface**. Goal: avoid building on unvalidated assumptions. Pair with [PRODUCT_ROADMAP_CHIEF_OF_STAFF.md](PRODUCT_ROADMAP_CHIEF_OF_STAFF.md) wave W4 and [TRUST_SPECULATIVE_ROLLBACK.md](TRUST_SPECULATIVE_ROLLBACK.md) where relevant.

---

## 1. Problem

- [ ] **Who** has the pain (named ICP or internal role, not “everyone”)?
- [ ] **What** happens today without your fix (workflow, cost, risk)?
- [ ] **How often** and **how painful** (frequency × severity in plain language)?
- [ ] **Evidence:** link, screenshot, ticket, log line, or interview note — not only a hunch.

---

## 2. Outcome

- [ ] **Observable success:** what will be true in 4–8 weeks if this works?
- [ ] **Non-goals:** what you will explicitly not build in v1.
- [ ] **Kill / sunset rule:** what signal means stop or pivot (usage, revenue, support load)?

---

## 3. Constraints

- [ ] **Privacy / data:** PII, retention, where data lives ([STORAGE_AND_ARCHIVE.md](STORAGE_AND_ARCHIVE.md)).
- [ ] **Security:** auth, secrets, supply chain — who can deploy?
- [ ] **Ops:** who runs it 24/7; on-call; cost ceiling (infra + API).

---

## 4. Smallest validation

- [ ] **Cheapest experiment** before a full repo (script, landing page, spreadsheet, design partner)?
- [ ] **One metric** you will watch first (sign-up, task done, latency, support deflection).

---

## 5. Ship / scaffold

- [ ] If validated: use **`./scripts/scaffold-side-repo.sh`** (see [SCRIPTS_REFERENCE.md](SCRIPTS_REFERENCE.md)) for LICENSE, CI stub, README, issue template.
- [ ] Add the product to **`cos/portfolio.md`** in the brain (template: [templates/cos-portfolio.md](templates/cos-portfolio.md)).

---

## Episode stub (log in Chump after validation)

After you complete the checklist (yes or no to building), log an episode so COS memory has a trace:

- **summary:** `problem_validation: <short name> → build|defer|kill`
- **tags:** `cos,validation,w4`
- **sentiment:** `win` if clear decision; `neutral` if deferred; `loss` if killed after investment

Example (Discord or tools): *episode log with summary “problem_validation: Foo CLI → defer until 2 design partners”*.
