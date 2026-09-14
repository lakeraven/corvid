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

## 1. The distinction: two jobs, two owners

"Payer enrollment" conflates two pieces of work with different counterparties, different
artifacts and different owners. The customer quote depends on getting this right, so the
boundary is stated here in the form it goes into a services agreement.

| | **EDI / trading-partner enrollment** | **Provider credentialing / network enrollment** |
|---|---|---|
| The question it answers | "May this submitter send transactions on behalf of this billing provider, and where do the remittances and funds go?" | "Is this organization — and each clinician — in this payer's network, and at what rate?" |
| **Owner** | **Us** (the billing operator) | **The clinic**, typically via a credentialing service or platform |
| Counterparty | Clearinghouse + each payer's EDI unit | Each payer's credentialing / network unit |
| Artifacts | Payer IDs, submitter/trading-partner ID, trading partner agreement, billing-agent authorization, 837 enrollment, 835/ERA enrollment, EFT enrollment, connectivity test results | CAQH profile, credentialing file, participation contract, fee schedule, per-clinician effective date |
| Failure if skipped | Claims rejected at the front door; remittances arrive on paper or not at all | Claims accepted and then denied, or paid out-of-network |
| Gate it controls | Whether a claim can be **transmitted and reconciled** | Whether a claim can be **paid in network** |

**They run in parallel.** Neither is a prerequisite of the other, with one coupling: a
payer-issued provider number from credentialing is frequently an input field on that same
payer's ERA/EFT enrollment. Sequence the ERA/EFT step after the provider number for payers
that require it; everything else on our side proceeds independently.

### Scope statement (services-agreement form)

**We perform:** clearinghouse account establishment and connectivity; payer-ID resolution and
per-transaction enrollment-requirement determination; preparation, submission and tracking of
EDI/trading-partner enrollment per payer, including state Medicaid trading partner agreements
and submitter IDs; billing-agent/clearinghouse authorizations naming us as submitter; ERA (835)
and EFT enrollment per payer, including proof of payment-to-remittance reassociation; any
payer-required connectivity or companion-guide testing; and ongoing claim submission,
acknowledgement handling, remittance posting and reconciliation.

**We do not perform:** credentialing of the organization or any clinician with any payer;
negotiation or execution of participation contracts or fee schedules; maintenance of the
clinic's CAQH profile, licensure or NPPES record; obtaining NPIs, EIN, or state Medicaid
provider numbers. **We do not guarantee** any payer's effective date, retroactivity, or
processing time — those are the payer's to set; we track and report them.

---

## 2. Dependency structure

Before any duration: the shape of the graph. This is what determines whether a number is on the
critical path or merely inconvenient.

```
  ┌─ CLINIC track ────────────────────────────────────────────────────────┐
  │  legal entity ─► EIN ─► NPI (Type 2) ─┬─► NPPES accurate               │
  │                  clinician NPIs ──────┘                                │
  │                       │                                                │
  │                       ├─► state Medicaid provider enrolment ─► prov. # │
  │                       └─► credentialing per payer ─► contract ─► eff.  │
  └───────────────────────────────────┬───────────────────────────────────┘
                                      │ (provider # / tax ID / NPI feed in)
  ┌─ OUR track ────────────────────────▼──────────────────────────────────┐
  │  payer-ID resolution  ──────────────────────────┐   (no dependency)   │
  │  clearinghouse account ─► credentials ─► billing-provider record      │
  │        │                                        │                     │
  │        ├─► TEST MODE pipeline proof ────────────┘   (no enrolment)    │
  │        │                                                              │
  │        └─► per payer:  TPA/EDI agreement ─► submitter ID              │
  │                             │                                         │
  │                             ├─► 837 enrolment ─► connectivity test    │
  │                             ├─► 835/ERA enrolment                     │
  │                             └─► EFT enrolment ─► prenote ─► reassoc.  │
  └───────────────────────────────────────────────────────────────────────┘
```

### Strictly sequential (cannot be compressed)

1. **Legal entity → EIN → NPI → NPPES accuracy.** Each is an input to the next. An NPI cannot
   be obtained without the entity and tax ID; payers validate against NPPES.
2. **NPI + tax ID → billing-provider record at the clearinghouse → any payer enrollment.**
   Enrollment identifies a *specific* billing provider; there is nothing to enrol before it
   exists.
3. **Trading partner agreement → submitter ID → claims that a payer will accept.** For payers
   that assign a submitter ID (characteristically Medicare and Medicaid), claims without it
   fail at the front door regardless of everything else being correct.
4. **835/ERA enrollment → electronic remittance → automated posting and reconciliation.**
   No shortcut: ERA enrollment is required by every payer, universally.
5. **EFT enrollment → prenote (where used) → funds to the clinic's account.**
6. **Credentialing decision → effective date → releasing held claims for that payer.**

### Runs in parallel (and must, or the schedule fails)

- **Every payer against every other payer.** Enrollment is per-payer and per-transaction;
  there is no ordering between payers. Work them all at once. Sequencing payers is the single
  most expensive avoidable mistake in this runbook.
- **Our EDI track against the clinic's credentialing track.** See section 1.
- **837, 835 and EFT enrollment within a payer**, once the submitter ID exists — they are
  separate enrollments on separate queues.
- **The entire claims pipeline build (#561) against all enrollment.** The clearinghouse's test
  mode covers 837P/837I/837D, returns 277CA acknowledgements, and returns test remittances,
  none of which requires enrollment. **The #561 end-to-end acceptance proof can therefore be
  finished before a single payer enrollment completes.**
- **Eligibility (#563) ahead of claims (#561).** Most payers do not require enrollment for
  270/271 eligibility at all, so front-desk verification can be live well before billing is.
  This is a real scheduling win and it is easy to miss.

### Productive waiting — what to do before each prerequisite arrives

The wait is only idle if we let it be.

| Waiting on | What we do meanwhile |
|---|---|
| Legal entity / EIN | Resolve payer IDs from the public payer directory; build the payer table (transactions supported, enrollment required per transaction). Needs no account and no clinic identifiers. |
| Organizational NPI | Stand up the clearinghouse account and test-mode credentials; wire the adapter (#35); assemble the enrollment form set per payer so only identifiers remain blank. |
| NPPES propagation | Run the full test-mode pipeline proof for #561 with a synthetic patient: 837P → 277CA → test ERA, every artifact captured. |
| State Medicaid provider number | Complete the state's trading partner agreement up to the fields that need the provider number; identify the state's EDI contact and companion guide; read the companion guide and encode its edits into the pre-bill scrub (#527). |
| Payer contracts | Build the held-claims queue and the timely-filing tracker (section 6). Nothing about it depends on a payer. |
| Credentialing decisions | Bring eligibility (#563) live for payers that need no enrollment; finish denial-workqueue scaffolding (#557). |

<!-- DURATIONS, CALENDAR, PLATFORM NOTES AND SOURCES FOLLOW -->
