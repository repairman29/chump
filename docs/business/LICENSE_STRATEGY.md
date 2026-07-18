# Chump License Strategy

**Status:** DECIDED — AGPLv3 (applications, workspace default) + Apache-2.0 (named library crates); operator signed off 2026-07-18  
**Gap:** INFRA-1506 (closed) · follow-ups: INFRA-3336 (crates.io republish), INFRA-3337 (legal review before INFRA-1337)  
**Current license:** AGPL-3.0-only default across the workspace; 8 library crates Apache-2.0 — see [NOTICE](../../NOTICE); each crate's `Cargo.toml` is authoritative  
**Last updated:** 2026-07-18

---

## Why This Decision Is Load-Bearing

Chump is approaching monetization (hosted tier INFRA-1337, enterprise SKU INFRA-1338). The license chosen now will:

- Determine whether cloud providers can offer Chump-as-a-service without paying
- Affect whether enterprise legal teams approve adoption
- Set the tone for open-source community trust and contributions
- Constrain or enable future revenue models

Once contributors ship code under a given license, changing it requires contributor consent or a CLA retroactive sweep — both are expensive. **Decide before any commercial infrastructure lands.**

---

## Option Comparison Table

| Dimension | MIT (current) | Apache-2 | Dual MIT + Commercial | BSL / Source-Available |
|---|---|---|---|---|
| **Summary** | Full permissive, no restrictions | Permissive + patent grant + attribution | Free for community use; commercial use requires a license | Source visible but use-restricted for N years, then open |
| **Commercial fork risk** | High — anyone can fork, commercialize, keep improvements closed | High — same as MIT; patent grant reduces litigation risk | Low — commercial forks require a paid license | Very low — direct commercial use is the restricted class |
| **Enterprise adoption** | Easy — legal teams auto-approve | Easy — preferred by many enterprises over MIT (patent clarity) | Moderate — requires a paid license for commercial SaaS use | Varies — BSL is understood by legal; some resist "not OSI-approved" |
| **OSI open-source** | Yes | Yes | Community tier: Yes; Commercial license: No | No — BSL is source-available, not open-source by OSI definition |
| **Cloud provider risk** | Any cloud can offer Chump-as-a-service free | Same as MIT | Cloud providers need a commercial license to offer hosted Chump | Cloud providers are the primary restricted class |
| **Community contributions** | Frictionless — no CLA needed | Frictionless — Apache contributor terms implicit | Possible chilling effect unless community tier is clearly defined | Significant chilling effect — contributors are wary of asymmetric benefit |
| **Precedents** | Linux (kernel), curl, most CLI tools | Kubernetes, TensorFlow, HashiCorp pre-2023 | GitLab (EE modules), Metabase | Sentry (2019→), CockroachDB (2019→), HashiCorp (2023→ BSL) |
| **Revenue model fit** | Weak — hosted tier competes with free forks | Weak — same as MIT | Strong — hosted tier is the commercial use case | Strong — hosted tier is exactly the restricted class |
| **Legal complexity** | Minimal | Low | Moderate (dual-license CLA + commercial terms needed) | Moderate (BSL grant terms, change date clause) |
| **Reversibility** | Easy to tighten later (with CLA) | Easy to tighten later (with CLA) | Can relax commercial tier; hard to go more permissive without CLA | Change date makes it open eventually; can tighten before change date |

---

## Deep Analysis per Option

### Option A: Stay MIT

**Keep the current `LICENSE` file unchanged.**

- Zero legal work required.
- Maximizes contributor goodwill and adoption velocity.
- Nothing prevents AWS/GCP from wrapping Chump as a managed service and taking the market.
- Best path if: Chump's moat is network effects / data / UX rather than the code itself, or if we plan to generate revenue purely via consulting/support rather than SaaS hosting.

**Risk:** With a fleet coordination engine this novel, staying MIT is an explicit bet that no cloud giant forks it before we reach critical mass.

### Option B: Apache-2

**Re-license to Apache-2 (minimal burden, contributor CLAs not required for the switch since Apache-2 is broader in some dimensions).**

- Adds an explicit patent grant — relevant if Chump's multi-agent coordination approach is patentable.
- Still fully permissive; cloud providers face zero restriction.
- Marginally preferred by enterprise legal over MIT for IP risk clarity.
- Does not address the cloud fork risk at all.

**Risk:** A cosmetic improvement. Doesn't change the commercial landscape.

### Option C: Dual MIT + Commercial (Community + Commercial License)

**Community-tier MIT for non-commercial / personal / OSS use; a separate commercial license for production SaaS deployments of Chump.**

Pattern used by Metabase, GitLab EE modules, and many infra tools. Requires:
1. A CLA (Contributor License Agreement) so we can dual-license contributed code.
2. A commercial license template (standard; lawyers can adapt SSPL or custom terms).
3. Clear community-tier definition (e.g., "non-commercial, research, or internal single-org use").

**Revenue model fit:** Directly monetizes the hosted-tier use case — any company running Chump as a SaaS product for others needs a commercial license.

**Community risk:** Contributors must sign a CLA, which introduces friction. Community projects that want to build on Chump need to stay within community-tier terms or pay.

### Option D: Business Source License (BSL / BUSL)

**Re-license to BSL 1.1 with a "Change Date" (e.g., 4 years) after which the code converts to Apache-2.**

Pattern: HashiCorp (Terraform/Vault 2023), Sentry, CockroachDB.

Key BSL terms:
- Source is visible and forkable.
- A "Additional Use Grant" allows specific uses (e.g., "non-production use, personal use, internal use by organizations with < $X ARR").
- Production commercial use (especially hosted SaaS for third parties) is restricted.
- After the Change Date, becomes Apache-2 automatically — so contributors know their work eventually goes fully open.

**Revenue model fit:** Directly targets cloud SaaS competitors and enterprise self-hosted commercial use.

**Community risk:** Not OSI-certified. Some open-source purists reject BSL projects outright. HashiCorp lost meaningful community trust with the Terraform→BSL move; OpenTofu forked. Risk is proportional to how established the community is at time of change.

---

## Recommendation (Fleet Analysis)

Given:
- Chump is pre-revenue but approaching hosted tier
- The primary commercial risk is a cloud provider or well-funded fork running Chump-as-a-service
- Community is currently small (early adopters, not a large established OSS community)
- Jeff is a solo operator; CLA overhead is manageable

**Recommended path: Option C (Dual MIT + Commercial)**

Reasoning:
1. The community is small enough that the CLA friction is low right now. Waiting until there are 100+ contributors makes this harder.
2. Dual-license is the most enterprise-friendly of the non-permissive options — legal teams understand it and it doesn't raise "not OSI" concerns for the community tier.
3. It directly monetizes the hosted SaaS use case without restricting personal/research/OSS use.
4. If the commercial license proves too restrictive for adoption, it can be relaxed. Going the other direction (MIT → commercial) after significant contributor growth is the hard path.

**Fallback: Option D (BSL)** if the dual-license CLA setup proves too complex to execute before INFRA-1337 ships. BSL requires no per-contributor CLA — the licensor (Jeff) holds all the original IP and re-licenses it. Less community-friendly but lower operational overhead.

---

## Operator Sign-Off

```
DECISION: AGPLv3 (applications, workspace default) + Apache-2.0 (8 named library crates)
DATE: 2026-07-18
NOTES: Operator direction: "I don't want others making money off our stuff."
       AGPL closes the host-it-and-re-rent loophole (network copyleft) while the
       Apache library tier keeps the reusable substrate adoptable. This is a
       fifth option ("owned and protected commons") relative to the A-D table
       above — it shipped in PR #3189 (12 crates) and was completed under
       CREDIBLE-128 (remaining 22 crates flipped MIT -> AGPL-3.0-only).
       Honest caveat, recorded: AGPL does not prohibit commercial use outright;
       it forces anyone offering Chump as a service to publish their changes,
       which removes the free-rider commercialization path. A stricter
       noncommercial restriction (PolyForm-NC / BSL) remains available later
       via INFRA-3337's review, since the operator holds all the copyright.
```

Migration + notification status:
- **Migration:** executed (PR #3189 + CREDIBLE-128 completion sweep, 2026-07-18).
- **Contributor notification:** waived with rationale — every human commit is the
  operator under aliased identities (repairman29 / "Your Name" / local-machine);
  remaining authors are bots (dependabot, github-actions, agent harnesses) acting
  as tools of the operator. No third-party human copyright holders exist to
  notify. Versions already published to crates.io under MIT remain MIT
  (irrevocable) — republish tracked in INFRA-3336.
- **CLA:** not required for the AGPL/Apache split (no dual commercial tier yet);
  revisit if INFRA-1337/1338 introduce a commercial license tier.

---

## Follow-Up Gaps

Filed 2026-07-18 alongside the sign-off (per CREDIBLE-128):

| Trigger | Gap |
|---|---|
| Non-MIT chosen — migrate + notify | Executed in-tree (PR #3189 + this PR); notification waived, see above |
| crates.io still hosts MIT versions | INFRA-3336 — republish all crates under the new licenses (operator token) |
| Any path — legal review | INFRA-3337 — legal review of the AGPL/Apache split before INFRA-1337 ships |
