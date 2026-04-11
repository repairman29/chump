# Defense wedge: execution runbook

**Companion:** [DEFENSE_MARKET_RESEARCH.md](DEFENSE_MARKET_RESEARCH.md) (context, partners, compliance). **Not legal advice.**

SBIR/STTR is **frozen** until DSIP shows otherwise (`dodsbirsttr.mil`). This runbook assumes you sell via **primes/integrators**, **DIU CSO/OT**, or **pilot MOUs**—not SBIR Phase I.

---

## What to do next (order matters)

| Step | Outcome | Time |
|------|---------|------|
| **1** | **SAM.gov** active registration (UEI, entity info current) | 1–2 h |
| **2** | **One-page pilot charter** filled in (template below) | 1 h |
| **3** | **10-target list** (names or roles + company) | 1 h |
| **4** | **5 outbound messages** sent (template below) | 2 h |
| **5** | **Book 2 calls**; run **discovery script** on calls | 1–2 weeks |

Do **not** wait for engineering perfection. Pilot A uses **synthetic data only** (see research doc).

---

## Step 1 — SAM.gov (today)

1. Open [SAM.gov](https://sam.gov) → sign in → **Workspace** → verify your entity is **Active** and **no expiration** blockers.
2. Note your **UEI** and (if assigned) **CAGE**; you will be asked for them on NDAs and vendor onboarding.
3. If you lack an entity: start **entity registration** (multi-day government processing—start now).

**Optional:** Capabilities statement (1–2 pages PDF: who you are, past performance, cage/uei, NAICS). Not required for first coffee chat; needed for formal vendor portals.

---

## Step 2 — Pilot charter (fill in and save as PDF or Notion)

Copy and replace bracketed fields.

```
PILOT CHARTER — RMF / ATO documentation assistant (Pilot A: synthetic data only)

Sponsor: [Company / org name]
Vendor: [Your name / LLC]
Dates: [Start] – [End] (recommend 30 calendar days)

Problem: Cybersecurity workforce spends excessive time drafting and reconciling RMF/SSP 
narratives and evidence traceability for review.

Pilot scope (in):
- Ingest: [synthetic system description + sample control list OR redacted template]
- Output: Draft SSP narrative sections + control-to-evidence mapping suggestions
- Human: ISSO/ISSM reviews all outputs; no auto-submit to eMASS/GRC

Pilot scope (out):
- No CUI, no classified, no production credentials, no autonomous changes to live systems

Success metric (pick ONE primary):
- [ ] Time to first review-ready draft for [N] controls: baseline ___ → target ___
- [ ] % sections requiring major rewrite: baseline ___ → target ___

Risks / mitigations:
- Model hallucination → human review gate + citation to provided sources only
- Data spill → synthetic only; air-gapped or customer boundary if promoted to Pilot C

Next step if successful: Pilot B (FCI) or customer IL5 boundary — separate charter.
```

---

## Step 3 — Ten-target list (who to put on it)

Aim for **buyers or teaming leads**, not random engineers.

| # | Company type | Role title to hunt (LinkedIn / site) |
|---|----------------|--------------------------------------|
| 1–2 | **Large integrator** (e.g. Leidos, Booz, SAIC, CACI, Parsons) | BD capture manager, **cyber GRC**, digital modernization |
| 3–4 | **Defense prime** (pick your geography) | **Supply chain cyber**, **RMF**, enterprise IT subcontracts |
| 5–6 | **Smaller cyber boutique** (CMMC, RMF consulting) | Founder / practice lead (often fastest pilot) |
| 7–8 | **Fed-focused VAR** / reseller with **DoD** case studies | Partner manager |
| 9–10 | **Your warm network** | Anyone with a **badge** or **recent subcontract** |

**DIU:** Monitor [diu.mil](https://www.diu.mil) CSOs; first outreach is often **after** you have a 2-minute demo on synthetic data.

---

## Step 4 — Outbound (copy, personalize 2 lines, send)

### A. Warm intro (best)

```
Subject: quick question — RMF draft throughput pilot (synthetic data)

Hi [Name],

I’m exploring a 30-day pilot with [their org type]: an assistant that drafts SSP-style 
control narratives and evidence traceability from an inventory export — human ISSO 
reviews everything; no CUI in v1.

If you’re the wrong person, who owns cyber GRC tooling or innovation pilots on your side?

[Your name] | [phone] | [1-line proof: e.g. shipped X at Y]
```

### B. Cold LinkedIn (short)

```
Hi [Name] — building human-in-the-loop RMF/SSP drafting support (synthetic pilot first). 
Open to a 15m fit call to see if this overlaps your GRC or digital modernization work?
```

### C. Integrator teaming angle

```
Subject: teaming — ATO documentation acceleration (pilot, not SBIR)

We have a narrow prototype: LLM-assisted SSP drafts + traceability suggestions with 
approval gates and audit logs; runs customer-boundary friendly. SBIR is paused; 
we’re looking for a pilot host or subcontract path. Open to a brief call with your 
cyber BD or capture lead?
```

---

## Step 5 — Discovery call script (15 minutes)

Ask; don’t pitch slides.

1. **Who** owns RMF/SSP workload today—ISSO staff, integrator, hybrid?
2. **Where** do drafts live (e.g. Word, eMASS, ServiceNow GRC)?
3. **What** is the **one bottleneck**—first draft, evidence mapping, POA&M text, reciprocity?
4. **What** would make a 30-day pilot **credible** internally (security review, legal, IL5)?
5. **Who** has budget for a **small pilot** ($0 internal LOE vs paid CRAD)?

Close with: *“I’ll send a one-page charter; can we pick a synthetic dataset format you’re comfortable with?”*

---

## Demo definition (minimum viable, week 2–4)

If you need something **in hand** before calls:

- **Input:** CSV or JSON of fake “systems” + list of controls (e.g. 20 NIST 800-53 controls, **unclassified** public text).
- **Output:** Markdown or Word sections per control + “evidence” placeholders.
- **UI:** Notebook, CLI, or simplest web form—buyer cares about **governance story** as much as pixels.

Chump’s angle: **intent → tool calls → logged steps → human gate** (map to their RAI concerns).

---

## Weekly tracker (copy to spreadsheet)

| Week | Outbound sent | Calls booked | Calls done | Pilot charter sent | Follow-up |
|------|---------------|--------------|------------|--------------------|----------|
| 1 | | | | | |
| 2 | | | | | |

---

## When someone says yes

1. Send **pilot charter**; agree **synthetic data** format.
2. NDA if they require it (use their paper if possible).
3. Schedule **30-day** check-in with the **single success metric**.
4. Document **lessons** in a short **after-action** (feeds your capabilities statement).

---

## Re-check (monthly)

- **DSIP** banner: still frozen or reopened?
- **DIU** new CSOs relevant to cyber or logistics (secondary wedge).
