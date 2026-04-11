# Chump-style agents and the defense market

Grounded research map for positioning **human-supervised, tool-using agents** (intent→action, memory, bounded autonomy) toward U.S. national-security software buyers and partners. Complements [MARKET_EVALUATION.md](MARKET_EVALUATION.md) (commercial ICP). **This is not legal or compliance advice**—verify all acquisition and security requirements with counsel and official issuances.

---

## 1. SBIR/STTR authority verification

### Official sources to check (authoritative)

| Source | URL | Notes |
|--------|-----|--------|
| Defense SBIR/STTR Innovation Portal (DSIP) | `https://www.dodsbirsttr.mil` | Solicitations, submission status; **site banner is the live program status** |
| Defense SBIR/STTR public site | `https://www.defensesbirsttr.mil` | Program news, BAA schedule |
| SBIR.gov topics | `https://www.sbir.gov` | Cross-agency topic mirrors |

### DSIP announcement (primary source — still “frozen” as of April 2026)

The **DSIP** landing/login experience (`dodsbirsttr.mil`, e.g. submissions login) carries an **Announcement** that matches what operators see in-browser:

- **As of October 1, 2025**, authorization for the **SBIR/STTR program has lapsed**; functionality tied to **SBIR/STTR execution is paused**.
- **SBIR BAA 25.4 Release 12** and **STTR BAA 25.D Release 12**: pre-release timing is **extended**; topics are to open on the **first Wednesday following program reauthorization** (not on a fixed calendar until reauthorization).
- **FY26 solicitation releases are paused.**
- DSIP support remains for **account** issues; **program** reopening is **watch the site** for reauthorization updates.

Treat this as **authoritative** for “can we submit / are topics live?”—stronger than trade press alone.

**Repository check (April 2026):** HTTP `GET` to `https://www.defensesbirsttr.mil/SBIR-STTR/Opportunities/` returned **403 Forbidden** from this environment. Treat programmatic scraping as unreliable; **confirm program status in a browser** (DSIP) as above.

### Reauthorization in Congress (supplemental — does not un-freeze DSIP until enacted)

When DSIP still shows the pause, use **Congress + legal/trade summaries** to judge *when* the freeze might lift. Examples of reporting during the lapse:

- [SBIR.org — SBIR/STTR omitted from 2025 NDAA deal](https://sbir.org/news/sbir-sttr-omitted-2025-ndaa/)
- [Inside Government Contracts — Senate passage of reauthorization bill (March 2026)](https://www.insidegovernmentcontracts.com/2026/03/is-congress-finally-reauthorizing-sbir-sttr-and-whats-changing/)

Reporting in **March 2026** describes **S. 3971** / **Small Business Innovation and Economic Security Act** (House/Senate variants) that would extend authority (commonly cited end date **September 30, 2031**) and introduce changes such as **Strategic Breakthrough Awards** and **tighter supply-chain due diligence**. **Presidential signature and enrolled text** determine what is actually in force—**re-check** [congress.gov](https://www.congress.gov) and DoD SBIR pages before relying on SBIR as your **primary** wedge.

### Practical takeaway

- **Do not** assume open BAAs or new Phase I/II awards without verifying DSIP and current statute.
- **Do** use SBIR **topic language** (e.g. N251-019, N252-089, Army interoperability topics) as **requirements intelligence** for product and OTA conversations even when SBIR is paused.
- **Parallel paths:** DIU **Commercial Solutions Opening (CSO)** + **Other Transaction (OT)** prototypes, **direct OTAs** with components, and **subcontracts** to primes remain relevant when SBIR is frozen.

---

## 2. Primary wedge use case and pilot metrics

### Selected lane: cybersecurity RMF / ATO documentation assistant

**Rationale:** Clear alignment with published Navy SBIR **N251-019** (neuro-symbolic AI agents for **RMF/ATO package** development), measurable outputs, and a natural fit for **Chump-style** patterns: long-form structured generation, tool calls into CMDB/GRC exports, human review gates, and audit trails—not autonomous “cyber effects.”

Reference topic (content may be historical if solicitation closed): [Navy N251-019](https://navysbir.us/n25_1/N251-019.htm).

### Secondary lane (backup narrative): sustainment decision support

**DIU Joint Sustainment Decision Tool (JSDT)** problem framing—courses of action, branch planning, what-if in contested logistics—maps well to **planner + tool** agents. Use when the buyer is **JLEnt / DLA / INDOPACOM**-aligned rather than **cyber workforce**. Reference: [DIU JSDT awards announcement](https://www.diu.mil/latest/two-contracts-awarded-to-modernize-decision-making-for-dows-joint-logistics).

### Data-class assumptions (pilot)

| Phase | Data | Rationale |
|-------|------|-----------|
| **Pilot A** | **Synthetic or anonymized** configuration narratives only; **no CUI** | Fast legal/compliance path; demo and integration risk reduction |
| **Pilot B** | **FCI** (Federal Contract Information) only, per contract clause | Common for early vendor engagement before CUI systems |
| **Pilot C** | **CUI** in **customer-controlled** boundary (authorized cloud or on-prem) | Requires **CMMC** scoping, **DoD-approved** tooling where applicable, RMF for your system |

### 30 / 60 / 90 day pilot metrics (ATO assistant)

| Horizon | Goal | Example metrics |
|---------|------|-------------------|
| **30 days** | Prove structured draft quality | Time to first **SSP control narrative draft** from imported inventory; **% sections** requiring **major** human rewrite (target band agreed with ISSO) |
| **60 days** | Prove workflow integration | **# of evidence artifacts** linked automatically (e.g. scans, configs); **traceability** from control → evidence → draft paragraph |
| **90 days** | Prove adoption + risk reduction | **Cycle time** from intake to “review-ready” package; **defects found in assessor pre-review**; optional **analyst hours** saved (survey + time study) |

---

## 3. Compliance architecture (deployment story)

Design goal: **customer trust** = *your software runs in **their** authorized boundary*, with **explicit human approval** for consequential actions and **immutable logs** for assessors.

### Inference and data plane

- **Default posture:** **Customer-hosted** inference (gov cloud tenant, **IL5**/authorized boundary, or **on-prem** / air-gapped)—consistent with Chump’s **local inference** story ([INFERENCE_PROFILES.md](INFERENCE_PROFILES.md), [AGENTS.md](../AGENTS.md)).
- **No silent exfiltration:** Model prompts, retrieved chunks, and tool outputs stay inside the **agreed security boundary**; if using a vendor API, contract must address **data retention**, **training opt-out**, and **subprocessors**.

### Logging and audit

- **Append-only** (or WORM-backed) **audit log**: user id, session, tool invocations, model version, retrieval sources, **approval** events for high-risk tools.
- **Separation of duties:** configuration of **which tools exist** vs **who may approve** execution.

### Human approval gates

| Tier | Examples | Gate |
|------|----------|------|
| **Read-only** | Search docs, summarize policies | Standard user |
| **Write-low** | Draft SSP text, open tickets | Same user + optional peer review |
| **Write-high** | Push to GRC, modify firewall rules, execute scripts | **Named approver** + **MFA** + **ticket correlation** |

Map directly to DoD **Responsible AI** themes (governance, warfighter trust, TEVV): [RAI Strategy PDF](https://media.defense.gov/2022/Jun/22/2003022604/-1/-1/0/Department-of-Defense-Responsible-Artificial-Intelligence-Strategy-and-Implementation-Pathway.PDF), [Task Force Lima executive summary](https://www.ai.mil/Portals/137/Documents/Resources%20Page/2024-12-TF%20Lima-ExecSum-TAB-A.pdf).

### CMMC scope (when CUI is in play)

- If the system **processes, stores, or transmits CUI** for a DoD contract, expect **CMMC Level 2** (or higher) requirements to flow per solicitation—see [DoD CIO CMMC](https://dodcio.defense.gov/cmmc/About/).
- **Scope minimization:** SaaS that holds **CUI** expands your **CMMC boundary**; **on-prem / customer-managed** deployment often shifts assessment scope to the **customer** or a **managed service** partner—**architect deliberately** with a C3PAO-minded advisor.

### Positioning discipline

- Sell **decision support** and **supervised automation**, not **autonomous cyber effects** or **autonomous targeting**.
- Treat **ITAR/EAR** and **data rights** (DFARS 252.227-7013 etc.) as **first-class** when ingesting engineering or logistics artifacts.

---

## 4. Partner map: primes, integrators, and OT paths

Use this as a **starting point** for relationship mapping—not an endorsement or exclusive list. Align each conversation with a **specific problem statement** (e.g. JSDT-style logistics, cyber ATO throughput, fusion cell summarization).

### Large primes (platforms of record, subcontracting on-ramps)

| Organization | Typical alignment for agentic workflow |
|--------------|----------------------------------------|
| **Lockheed Martin** | C2, sustainment, enterprise IT programs |
| **RTX (Raytheon)** | Sensors, effects integration, mission software |
| **General Dynamics** | IT, shipboard/subsystems, cyber services |
| **Northrop Grumman** | C2ISR, space, cyber |
| **Boeing** | Mobility, training, digital aviation-adjacent workflows |
| **BAE Systems, Inc.** | C2, maritime, land systems integration |
| **L3Harris** | Communications, ISR processing |

### Systems integrators and IT services (OTAs, task orders, teaming)

| Organization | Typical alignment |
|--------------|-------------------|
| **Leidos** | Enterprise cyber, health IT, large-scale integration |
| **Booz Allen Hamilton** | Analytics, cyber, AI adoption consulting |
| **SAIC** | Engineering services, digital modernization |
| **CACI** | Cyber, C2ISR software, intelligence support |
| **Parsons** | Infrastructure, cyber, critical systems |

### Fast paths and vehicles

| Path | Role |
|------|------|
| **DIU CSO → OT prototype** | Commercial-first prototype with mission partner; follow-on production possible under OT statutes—see [DIU software acquisition reform](https://www.diu.mil/latest/advancing-dod-operational-capabilities-with-software-acquisition-reform) |
| **Consortia-managed OTAs** | **ATI**, **NSTXL**, and similar intermediaries run **broad OT** vehicles; members respond to **call topics**—useful when you lack your own prime contract vehicle |
| **Prime subcontract** | Fastest **execution** path if you bring a **narrow, certified** capability (pilot metrics, deployment kit, SBOM) |

### Example problem-statement alignment

| Partner type | Example hook |
|--------------|----------------|
| **DIU + JLEnt** | JSDT-style **sustainment COA** and **what-if** planning ([DIU JSDT](https://www.diu.mil/latest/two-contracts-awarded-to-modernize-decision-making-for-dows-joint-logistics)) |
| **NAVAIR / cyber workforce** | **ATO/RMF** draft + evidence linking (N251-019-class problem) |
| **Army / integration shops** | **LLM-assisted interoperability** between legacy systems (Army SBIR interoperability topic family) |

---

## 5. Acquisition context (summary)

- **Software Acquisition Pathway (SWP)** and emphasis on **CSO + OT** for software are widely reported as **DoD direction** for new software efforts—see reporting on the **March 2025** memorandum (e.g. [DefenseScoop](https://defensescoop.com/2025/03/07/hegseth-memo-dod-software-acquisition-pathway-cso-ota/)) and DIU’s CSO/OT materials linked above.
- **GenAI in DoD:** use only **component-approved** tools for sensitive workloads; public reporting describes **GenAI.mil** as a **CUI / IL5** enterprise direction for Navy and Air/Space components—verify with **current service memos** (e.g. trade summary: [CDO Magazine on GenAI.mil](https://www.cdomagazine.tech/us-federal-news-bureau/us-navy-mandates-genai-mil-for-enterprise-cui-il5-ai-use)).

---

## 6. Chump ↔ defense mapping (product language)

From [CHUMP_PROJECT_BRIEF.md](CHUMP_PROJECT_BRIEF.md): **infer intent**, **act with tools**, **heartbeat/autonomy** with oversight. In defense packaging:

- **Intent → action** becomes **mission workflow** with **explicit policy** and **approvals**.
- **Memory / blackboard** becomes **audit-relevant state** with **retention** and **classification** rules.
- **Local inference** ([INFERENCE_PROFILES.md](INFERENCE_PROFILES.md)) becomes **disconnected / contested** and **data-sovereignty** selling points.

---

## Revision note

Re-verify **SBIR authority**, **CMMC phase** dates, and **service-specific AI policies** before proposals or pilots; this document is a **snapshot** for engineering and GTM planning inside the Chump repo.
