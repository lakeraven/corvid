# EDI and Trading-Partner Enrollment Runbook

**Status:** working runbook, first issue. **Verified:** 2026-09-14.
**Companion artifacts:** `docs/edi_enrollment_checklist.md` (the executable checklist),
`docs/customer_credentialing_guidance.md` (the handout for the clinic).
**Related issues:** #562 (this runbook), #561 (claims end to end), #563 (eligibility 270/271),
#35 (clearinghouse adapter), #527 (pre-bill scrub), #557 (denial workqueue).

---

## 0. Why this document exists

EDI enrollment is the **longest-lead item** in standing up a clinic's revenue cycle. Its
execution time is comparable to provider credentialing, and most of that time is *waiting on a
payer*, not working. A day lost discovering the sequence is a day of cash deferred, and the
sequence is not discoverable from any single source — it is spread across a clearinghouse's
docs, a state Medicaid trading-partner packet, a federal EFT form, and each payer's own EDI
unit.

So the sequence is written down here, in dependency order, before we need it.

### Reading rules for this document

Durations in this runbook are of two kinds and they are **not** interchangeable:

- **Working time** — ours. Compressible by doing the work sooner or in parallel.
- **Waiting time** — a payer's or a bank's queue. **Not compressible.** The critical path is
  the sum of the waiting times, not the sum of our effort.

Every duration and requirement below carries a citation and a confidence label:

| Label | Meaning |
|---|---|
| **AUTHORITATIVE** | Published by the party that controls the outcome (CMS, the eCFR, a state Medicaid agency, the payer, the clearinghouse). |
| **SECONDARY** | Published by a credible third party, not the controlling party. |
| **UNVERIFIED** | We believe it, we have not sourced it. The document states what would verify it. |

**An unlabelled duration is a defect.** A plausible timeline presented as fact is the specific
failure mode this document guards against: it produces a customer commitment we cannot keep.

### A note on citations

Corvid is a public repository. Government, regulatory and payer sources are cited by URL.
**Our clearinghouse partner is deliberately not named**, per the workspace naming policy for
public repos; its documentation is quoted verbatim and attributed as "clearinghouse partner
documentation", with the page identified well enough for anyone with the vendor list to find
it. The URL set is maintained outside this repository.

---

<!-- SECTIONS BELOW ARE BEING FILLED FROM VERIFIED RESEARCH -->
