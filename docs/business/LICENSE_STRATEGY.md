# Chump License Strategy

**Status:** DECISION PENDING — operator sign-off required before any payment infrastructure ships  
**Gap:** INFRA-1506  
**Current license:** MIT  
**Last updated:** 2026-06-22

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

**Jeff, please record your decision here before any payment infrastructure ships:**

```
DECISION: [ MIT / Apache-2 / Dual MIT+Commercial / BSL ]
DATE:
NOTES:
```

After sign-off:
- **If non-MIT chosen:** a follow-up gap will be filed to migrate the LICENSE file, add a CLA process (if dual-license), and notify existing contributors.
- **If MIT retained:** a companion gap will be filed to clarify commercial-use messaging (what Jeff's company offers vs. what the community may build).

---

## Follow-Up Gaps (auto-filed by fleet)

These will be filed once the decision is recorded:

| Trigger | Gap to file |
|---|---|
| Non-MIT chosen | `INFRA-NEW: Migrate LICENSE + CLA process + contributor notification` |
| MIT retained | `INFRA-NEW: Clarify commercial-use messaging for hosted tier` |
| Any path | `INFRA-NEW: Legal review of chosen license before INFRA-1337 ships` |
