# Compliance templates — RMF-style Markdown shells

**Purpose:** Offline, copy-paste **placeholder** sections you can fill in a text editor or git repo. Useful for **pilot scoping**, **internal drafts**, and **aligning vocabulary** with ISSOs — **not** a complete System Security Plan (SSP) and **not** a path to Authorization to Operate (ATO).

**Not legal advice.** This is not a substitute for your **ISSO**, **RMF process**, **organizational policy**, or **legal counsel**. NIST and DoD publications are authoritative for control text and assessment procedures.

**No cloud API:** These templates are plain Markdown. Use them in an air-gapped workflow if your program requires it.

---

## How to use

1. Copy the block you need into `docs/`, Notion, Word (paste as text), or eMASS/GRC exports.
2. Replace every `[BRACKETED]` or `_Underscored_placeholder_` with program-specific content.
3. Remove sections that do not apply; add your organization’s required headings.
4. Keep a **revision table** at the bottom of each working document (template §7).

---

## NIST RMF orientation (non-authoritative summary)

The **NIST Risk Management Framework** (RMF) is often described in seven steps: **Prepare**, **Categorize**, **Select**, **Implement**, **Assess**, **Authorize**, **Monitor**. Your **SSP** and **attachment** structure must follow **your** authorizing official and **your** template (e.g. eMASS, CSAM, ServiceNow GRC). These shells are **agnostic** to that tooling.

---

## 1. System overview (SSP-style shell)

```markdown
# System overview — [SYSTEM_NAME]

| Field | Value |
|-------|--------|
| System name | [SYSTEM_NAME] |
| System acronym | [ACRONYM] |
| System owner | [ROLE / ORG] |
| ISSO / primary security contact | [NAME, EMAIL] |
| Authorization boundary summary | [ONE PARAGRAPH: what is in vs out of scope] |
| Deployment type | [e.g. on-premises VM / isolated VPC / single-user pilot laptop] |
| Data classification / categories | [e.g. synthetic only / FCI / CUI — per program] |
| Last updated | [YYYY-MM-DD] |

## 1.1 Mission / business purpose

[Describe the business or mission function this system supports.]

## 1.2 Users and roles

| Role | Description | Privilege level |
|------|-------------|-----------------|
| [ROLE_A] | [DESCRIPTION] | [e.g. admin / user / read-only] |
| [ROLE_B] | | |

## 1.3 Interconnections (high level)

| Connected system / service | Purpose | Data flow |
|----------------------------|---------|-----------|
| [SYSTEM_OR_SERVICE] | [WHY] | [IN / OUT / BIDIRECTIONAL] |
```

---

## 2. Information system boundary

```markdown
# Information system boundary — [SYSTEM_NAME]

## 2.1 In-scope components

- **Hardware:** [LIST OR “NONE — software-only on host X”]
- **Software:** [LIST — include OS, runtime, major applications]
- **Network:** [SEGMENTS, FIREWALL RULES SUMMARY, OR “ISOLATED”]
- **People / processes:** [OPERATORS, CHANGE CONTROL OWNER]

## 2.2 Explicitly out of scope

- [ITEM — e.g. “Corporate email,” “Internet general browsing,” “Unrelated SaaS”]

## 2.3 Diagram reference

[Insert or link to **CUI-appropriate** architecture diagram: e.g. `artifacts/boundary-YYYYMMDD.png`]

## 2.4 Data flows (summary)

| Data type | Origin | Destination | Storage | Encryption (Y/N / where) |
|-----------|--------|-------------|---------|---------------------------|
| [TYPE] | | | | |
```

---

## 3. Control implementation narrative (repeat per control)

```markdown
## [CONTROL_ID] — [CONTROL_TITLE]

**Baseline / overlay:** [e.g. MODERATE / agency overlay name]

### Implementation statement (draft)

[Describe **how** the organization implements this control in this system — operational language, not marketing.]

### Responsible role

[ROLE_NAME]

### Inherited / shared / system-specific

- [ ] System-specific implementation  
- [ ] Inherited from [COMMON_CONTROL_PROVIDER]  
- [ ] Hybrid — explain: [TEXT]

### Evidence artifacts (planned or collected)

| Artifact | Location / ID | Date | Notes |
|----------|---------------|------|-------|
| [e.g. config export, scan report, policy PDF] | [PATH OR TICKET] | [DATE] | |

### Assessment notes (assessor use)

[Findings, clarifications, follow-ups — keep factual.]
```

---

## 4. Evidence traceability matrix (starter)

```markdown
# Control-to-evidence traceability — [SYSTEM_NAME]

| Control ID | Implementation summary (one line) | Evidence type | Evidence locator | Owner | Status |
|------------|-----------------------------------|---------------|------------------|-------|--------|
| [AC-2] | | | | | [Planned / Collected / Assessed] |
| [AU-2] | | | | | |
| [SC-13] | | | | | |
```

---

## 5. POA&M-style finding (single row / card)

Use one block per finding; track in spreadsheet or GRC if preferred.

```markdown
### Finding ID: [POAM-YYYY-NNN]

| Field | Value |
|-------|--------|
| Weakness / risk | [SHORT_TITLE] |
| Related control(s) | [IDS] |
| Severity / risk rating | [PER PROGRAM SCALE] |
| Description | [FACTS — no speculation] |
| Mitigation / remediation plan | [ACTIONS, OWNERS, DATES] |
| Milestone date | [YYYY-MM-DD] |
| Residual risk statement | [AFTER PLANNED MITIGATIONS] |
| Authorizing official awareness | [Y/N / DATE] |
```

---

## 6. AI / agent platform boundary (for human-in-the-loop tools)

*Use when the system includes an **orchestrator** (e.g. Chump-class agent) with tools, approvals, and logs.*

```markdown
# AI-assisted component — [COMPONENT_NAME]

## 6.1 Description

[What the component does; **human-in-the-loop** steps; what is **not** autonomous.]

## 6.2 Trust boundaries

| Surface | Trust tier | Notes |
|---------|------------|-------|
| [e.g. WASM tools] | Bounded execution | [Contract / no host FS in default config] |
| [e.g. shell / run_cli] | Host-trust | [Allowlist / approvals in use: Y/N] |
| [e.g. outbound HTTP tools] | Network | [Disabled in air-gap mode: Y/N — cite config] |

## 6.3 Configuration knobs (operational)

| Setting | Purpose | Pilot / prod value |
|---------|---------|---------------------|
| [e.g. CHUMP_AIR_GAP_MODE] | [Disable general-Internet tools at registration] | |
| [e.g. CHUMP_TOOLS_ASK] | [Human approval before listed tools] | |
| [e.g. CHUMP_TOOL_RATE_LIMIT_*] | [Throttle selected tools] | |

## 6.4 Logging and audit

[Where tool invocations and approvals are recorded — e.g. local DB tables, log paths. **No sensitive data** in this template.]

## 6.5 Residual limitations

[What the assessor should **not** assume — e.g. “Does not replace EDR,” “Not a WAF.”]
```

---

## 7. Document revision log (append to working copies)

```markdown
| Version | Date | Author | Summary of change |
|---------|------|--------|-------------------|
| 0.1 | [YYYY-MM-DD] | [NAME] | Initial shell from Chump COMPLIANCE_TEMPLATES |
| | | | |
```

---

## Related Chump docs

- [DEFENSE_PILOT_EXECUTION.md](DEFENSE_PILOT_EXECUTION.md) — pilot charter, outreach, demo scope  
- [DEFENSE_PILOT_REPRO_KIT.md](DEFENSE_PILOT_REPRO_KIT.md) — technical repro, air-gap, approvals  
- [TOOL_APPROVAL.md](TOOL_APPROVAL.md) — trust ladder, `CHUMP_TOOLS_ASK`, WASM vs `run_cli`  
- [HIGH_ASSURANCE_AGENT_PHASES.md](HIGH_ASSURANCE_AGENT_PHASES.md) — **WP-4.2** work package  

---

## Changelog (this file)

| Date | Change |
|------|--------|
| 2026-04-09 | Initial templates for WP-4.2 (offline Markdown shells only). |
