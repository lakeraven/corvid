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

**An unlabeled duration is a defect.** A plausible timeline presented as fact is the specific
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
  ┌─ CLINIC track ──────────────────────────────────────────────────────────┐
  │  legal entity ─► EIN ─► NPI (Type 2) ─┬─► NPPES accurate                │
  │                  clinician NPIs ──────┘                                 │
  │                       │                                                 │
  │                       ├─► state Medicaid provider enrollment ─► prov. # │
  │                       └─► credentialing per payer ─► contract ─► eff.   │
  └───────────────────────────────────┬─────────────────────────────────────┘
                                      │ (provider # / tax ID / NPI feed in)
  ┌─ OUR track ────────────────────────▼────────────────────────────────────┐
  │  payer-ID resolution  ──────────────────────────┐   (no dependency)     │
  │  clearinghouse account ─► credentials ─► billing-provider record        │
  │        │                                        │                       │
  │        ├─► TEST MODE pipeline proof ────────────┘   (no enrollment)     │
  │        │                                                                │
  │        └─► per payer:  TPA/EDI agreement ─► submitter ID                │
  │                             │                                           │
  │                             ├─► 837 enrollment ─► connectivity test     │
  │                             ├─► 835/ERA enrollment                      │
  │                             └─► EFT enrollment ─► prenote ─► reassoc.   │
  └─────────────────────────────────────────────────────────────────────────┘
```

### Strictly sequential (cannot be compressed)

1. **Legal entity → EIN → NPI → NPPES accuracy.** Each is an input to the next. An NPI cannot
   be obtained without the entity and tax ID; payers validate against NPPES.
2. **NPI + tax ID → billing-provider record at the clearinghouse → any payer enrollment.**
   Enrollment identifies a *specific* billing provider; there is nothing to enroll before it
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

---

## 3. Prerequisites the clinic must satisfy

Ordered by when they are needed. "Blocks" names the first thing that cannot proceed without it.

| # | Prerequisite | Published duration | Blocks |
|---|---|---|---|
| 1 | Legal entity formed; legal name and address fixed | State-specific — **UNVERIFIED** here. *Verified by:* the formation state's registry. | Everything. The name must match across NPPES, the W-9 and every payer record. |
| 2 | **EIN** (federal tax ID) | **Online: immediate.** Fax: **~4 business days.** Mail: **~4 weeks.** (IRS — AUTHORITATIVE) | NPI application, payer applications, billing-provider record. |
| 3 | **NPI, Type 2** (organization) and **Type 1** (each clinician) | **Allow 15 working days** before contacting the enumerator (CMS MLN Matters SE0751 — AUTHORITATIVE). Commonly ~10 days electronic / ~20 business days paper (SECONDARY). | Billing-provider record; every payer and EDI application. |
| 4 | **NPPES record accurate** (legal name, taxonomy, address, authorized official) | Included in #3; corrections re-queue. | Payer validation. A mismatch here surfaces as a rejection weeks later. |
| 5 | State professional licences, current, per clinician | State-specific — **UNVERIFIED**. | Credentialing; some Medicaid retroactivity is conditioned on licensure being active for the earliest service date. |
| 6 | **State Medicaid provider number** | State-specific — **UNVERIFIED** as a general figure. *Verified by:* the pilot state's provider-enrollment page. | The state's trading partner agreement, which usually takes the provider number as an input. |
| 7 | **Payer contracts / participation agreements** executed | Follows credentialing — see §5. | In-network payment. Not EDI transmission. |
| 8 | Bank account for receipts + authorized signer | Clinic-side. If the clearinghouse's treasury product is used, an account is provisioned in the clinic's name via its banking partner — a clinic decision, not a technical step. | EFT enrollment. |

**What we do while each is outstanding** is in §2, "Productive waiting". The short version: payer-ID
resolution, clearinghouse account setup, adapter work (#35) and the entire test-mode pipeline
proof for #561 need **none** of the above.

---

## 4. The EDI runbook: per-payer steps and durations

Durations are **published figures from named sources**, not estimates. Where a payer is not
listed, the runbook's instruction is to *find its published figure*, not to interpolate.

### 4.1 Once per clinic

| Step | Owner | Duration | Source / confidence |
|---|---|---|---|
| Resolve payer IDs from the clearinghouse's public payer directory; record transactions supported and enrollment-required per transaction | Us | Hours | Directory is public and searchable; a payer API exists. Clearinghouse partner docs, 2026-09-14 — AUTHORITATIVE |
| Provision clearinghouse account, production + test credentials | Us | Same day | Clearinghouse partner docs — AUTHORITATIVE |
| Create the billing-provider record (NPI + tax ID exactly as in NPPES) | Us | Hours | — |
| Run the full test-mode pipeline proof (837P → 277CA → test ERA) | Us | Days | "Test mode works for all three 837 claim types: 837P professional, 837D dental, and 837I institutional." — clearinghouse partner changelog, 2026-09-09 — AUTHORITATIVE |

### 4.2 Per payer — the steps

Within a payer these are ordered; across payers they are fully parallel.

1. **Determine what this payer requires.** ERA (835) enrollment is **always** required; other
   transactions are payer-dependent; most payers require **no** enrollment for 270/271
   eligibility. *(Clearinghouse partner docs — AUTHORITATIVE.)*
2. **Obtain the form set** (trading partner agreement, EDI enrollment agreement, ERA
   authorization, EFT authorization).
3. **Signature by the clinic's authorized official.** Some states accept only digital or ink
   signatures, **not typed** — e.g. Oregon: "Both the provider and EDI submitter must read and
   sign this form. OHA only accepts digital signatures or ink signatures (not typed
   signatures)." ([OHA EDI](https://www.oregon.gov/oha/hsd/ohp/pages/edi.aspx) — AUTHORITATIVE)
4. **Submit and obtain the submitter / trading partner ID.** Medicare and Medicaid
   characteristically require a payer-assigned submitter ID on every claim.
5. **Billing-agent / clearinghouse authorization** — the payer is told this submitter may
   transact for this provider.
6. **837 claim enrollment**, then any required connectivity test.
7. **835 / ERA enrollment.**
8. **EFT enrollment**, plus bank verification where required.
9. **Prove reassociation**: one payment matched to one remittance by trace number.

### 4.3 Per payer — published durations

| Payer class | Step | Published duration | Source / confidence |
|---|---|---|---|
| **Medicare** | CMS-855B/855I via PECOS, no site visit | **95% within 15 calendar days; 100% within 50 calendar days** | CMS processing standards as published by a MAC ([First Coast](https://medicare.fcso.com/enrollment/cms-855-enrollment-application-processing-timeframes)) — AUTHORITATIVE |
| **Medicare** | Same, with site visit / development | **95% within 50 days; 100% within 85 days** | same — AUTHORITATIVE |
| **Medicare** | Paper 855, no site visit | **95% within 30 days; 100% within 65 days** | same — AUTHORITATIVE |
| **Medicare** | EDI enrollment agreement → submitter ID | **~15 business days**: "Your Submitter ID and software (if applicable) will be processed within 15 business days of receipt of completed forms." | MAC EDI enrollment packet — AUTHORITATIVE |
| **Medicare** | CMS-588 EFT | **15-day bank pre-certification**: "All EFT requests are subject to a 15-day pre-certification period in which all accounts are verified by the qualifying financial institution." | MAC CMS-588 instructions — AUTHORITATIVE |
| **State Medicaid** | Trading partner agreement — fast end of the observed range | **"within five business days"** (Indiana) | [IHCP](https://www.in.gov/medicaid/providers/business-transactions/electronic-data-interchange-edi-solutions/trading-partner-registration-procedure/) — AUTHORITATIVE |
| **State Medicaid** | TPA — middle | **"Allow 30 days for processing"** (Minnesota); **"Allow up to 30 days from date of receipt for processing"** (Texas) | [MN DHS](https://www.dhs.state.mn.us/main/idcplg?IdcService=GET_DYNAMIC_CONVERSION&RevisionSelectionMethod=LatestReleased&dDocName=ENROLL-28); [TMHP](https://www.tmhp.com/topics/edi/get-started) — AUTHORITATIVE |
| **State Medicaid** | TPA — slow end | **"Please allow 30 to 45 days for processing"** (Oregon) | [OHA](https://www.oregon.gov/oha/hsd/ohp/pages/edi.aspx) — AUTHORITATIVE |
| **State Medicaid** | Connectivity testing where required | Texas: **"All trading partners must successfully submit five error-free batches of 50 transactions for each transaction type"**, then "You can begin sending transactions within 24 hours of receiving confirmation" | [TMHP](https://www.tmhp.com/topics/edi/get-started) — AUTHORITATIVE |
| **Commercial** | ERA enrollment — fast | **7 business days** ("Quartz will process your ERA Authorization Agreement within seven business days") | [Quartz](https://quartzbenefits.com/providers/electronic-data-interchage/835-authorization/) — AUTHORITATIVE (payer-published) |
| **Commercial** | ERA enrollment — middle | **10 business days** ("Cigna will finalize your registration within 10 business days of receiving it") | [Cigna](https://static.cigna.com/assets/chcp/resourceLibrary/medicalResourcesList/medicalDoingBusinessWithCigna/eServices/eSrvcsERA.html) — AUTHORITATIVE (payer-published) |
| **Commercial** | ERA enrollment — slow | **~30 days** ("Once we receive the request from your vendor/clearinghouse, it takes about 30 days to set up ERA/835 delivery") | [UnitedHealthcare](https://www.uhcprovider.com/en/resource-library/edi/edi-transactions.html) — AUTHORITATIVE (payer-published) |
| **Any** | Our clearinghouse's own side of enrollment | **See §6 — its own documentation publishes three different figures.** | Clearinghouse partner docs — AUTHORITATIVE but internally inconsistent |

*These payers and states are cited because they publish a number. None is asserted to be in the
pilot's payer mix.*

**There is no federal SLA on payer EDI/ERA/EFT enrollment turnaround.** The CAQH CORE EFT & ERA
operating rules (380 EFT Enrollment Data, 382 ERA Enrollment Data) standardize the enrollment
*data set* and require plans to offer electronic enrollment; a full read of the Phase III rule
set found **no mandated maximum processing time**
([CORE Phase III rule set](https://www.caqh.org/sites/default/files/core/phase-iii/EFTERA_CompleteRuleSet_0.pdf)
— AUTHORITATIVE, absence confirmed against the rule text). The timing rules that *do* exist
govern remittance delivery, not enrollment: CORE 370 requires the 835 no sooner than three
business days before and no later than three business days after the EFT effective entry date.

**Consequence:** a payer that is slow has no deadline we can hold it to. Escalation is
relationship work, not a contractual remedy. Plan against the published upper bound.

### 4.4 Observed range, for planning

| | Fast (all cited) | Plan against | Cited worst |
|---|---|---|---|
| Medicare EDI submitter ID | 15 business days | 15 business days | 15 business days |
| State Medicaid TPA | 5 business days | **30–45 days** | 45 days + testing |
| Commercial ERA per payer | 7 business days | **30 days** | 30 days |
| EFT bank verification | — | **15 days** (Medicare pre-cert) | 15 days |

**Planning rule: 4–6 weeks per payer for the EDI half, once the prerequisites exist**, with
state Medicaid at the top of that range and requiring the provider number first. This is the
band supported by the citations above; it is not a guarantee, because no payer owes us one.

---

## 5. The credentialing half — what we hand the customer

Full text in `docs/customer_credentialing_guidance.md`. The two points that change the schedule:

- **Credentialing gates billing, not opening.** The clinic can open, see patients and document
  on schedule while claims are held, then submit once enrollment completes.
- **Retroactivity is measured from the application date**, so filing early — and filing
  *complete* — is the lever. A returned application is not a pending one.

**One caveat that must travel with the first point, or we mislead the customer.** "Open on
schedule" is true of the clinic. It is not automatically true of *a given payer's members*.
Two payers publish the opposite instruction:

- UHC: "Credentialing is required for all licensed individual health care professionals in
  order to participate in the UnitedHealthcare networks and prior to seeing UnitedHealthcare
  members" ([UHC FAQ](https://www.uhcprovider.com/content/dam/provider/docs/public/resources/join-network/Credentialing-FAQs.pdf)
  — AUTHORITATIVE).
- Capital Blue Cross: "Providers should not schedule services with Capital Blue Cross members
  until a second notification of participation in our networks has been issued"
  ([Capital BCBS](https://www.capbluecross.com/wps/portal/cap/provider/provider-hub/credentialing-overview-qrg)
  — AUTHORITATIVE).

So the accurate framing is: **the clinic opens on schedule; each payer's members are seen
in-network only once that payer says so.** Patients of a not-yet-participating payer are seen
out-of-network or self-pay — a different conversation with the patient, and one that triggers a
No Surprises Act good-faith estimate where the patient is not using insurance ([CMS](https://www.cms.gov/nosurprises/consumers/understanding-costs-in-advance)
— AUTHORITATIVE). This is still not a reason to delay opening. It is a reason to know, per
payer, which of three states each patient is in: **in-network**, **out-of-network**, or
**self-pay**. Front-desk eligibility (#563) is what surfaces that at check-in rather than at
denial.

**Billing under a credentialed supervising provider is narrower than it is usually assumed to
be.** The one payer policy we verified covers *unlicensed practitioners working toward
licensure*, in five named states plus prior approval elsewhere, with a U5 modifier and the
supervising provider's NPI on the claim
([Optum reimbursement policy 2024RP202A](https://public.providerexpress.com/content/dam/ope-provexpr/us/pdfs/adminResourcesMain/supervisory-services/SupServiceReimbursementPolicy.pdf)
— AUTHORITATIVE). Medicare's incident-to rule allows behavioral health services "under general
supervision", and "only the supervising physician (or other practitioner) may bill Medicare for
incident to services" ([42 CFR 410.26](https://www.law.cornell.edu/cfr/text/42/410.26) —
AUTHORITATIVE). **We found no payer policy authorizing a licensed-but-not-yet-credentialed
clinician's work to be billed under another provider's NPI.** Do not suggest it as a workaround;
ask the payer in writing, per payer.

Evidence that retroactivity is real, and its limits:

- **Medicare.** The effective date is "the later of— (i) The date of filing of a Medicare
  enrollment application that was subsequently approved by a Medicare contractor; or (ii) The
  date that the provider or supplier first began furnishing services at a new practice
  location" ([42 CFR 424.520(d)](https://www.law.cornell.edu/cfr/text/42/424.520) —
  AUTHORITATIVE). On top of that, retrospective billing is allowed for services provided up to
  "Thirty days prior to their effective date if circumstances precluded enrollment in advance of
  providing services to Medicare beneficiaries" — ninety days after a Presidentially-declared
  disaster ([42 CFR 424.521](https://www.law.cornell.edu/cfr/text/42/424.521) — AUTHORITATIVE).
- **State Medicaid varies, and can be generous.** Colorado: "Providers are able to request an
  enrollment effective date up to ten (10) months prior to the current date"
  ([HCPF](https://hcpf.colorado.gov/backdating-enrollment) — AUTHORITATIVE source; quote
  verified via the page's indexed text and the linked backdate form, direct fetch blocked).
  North Carolina grants retroactive dates conditionally, including where "Medically necessary
  services were rendered and the provider's credentials, licensure, certifications, etc., were
  active and in good standing for the earliest effective date of service"
  ([NC Medicaid](https://medicaid.ncdhhs.gov/providers/provider-enrollment/provider-enrollment-application)
  — AUTHORITATIVE).
- **Behavioral-health Medicaid can be explicitly generous.** North Carolina, behavioral-health
  specific: a taxonomy effective date "can be up to 365 retroactive, but cannot precede the
  effective date of the required credential"
  ([NCTracks BH enrollment FAQs](https://www.nctracks.nc.gov/content/public/providers/faq-main-page/faqs-for-Behavioral-Health-Provider-Enrollment.html)
  — AUTHORITATIVE). Note the limit: retroactivity cannot precede the *credential*, which is why
  clinician licensure being current early matters.
- **Washington is the counter-example among Medicaid programs.** Default enrollment is
  effective "on the date the agency approves the provider application for enrollment or a date
  designated by the agency", with case-by-case exceptions, and exceptions "do not supersede or
  otherwise change the agency's timely billing requirements"
  ([WAC 182-502-0005](https://apps.leg.wa.gov/wac/default.aspx?cite=182-502-0005) —
  AUTHORITATIVE).
- **At least one commercial payer publishes a flat refusal.** "Effective Dec. 19, 2023,
  EmblemHealth and ConnectiCare will no longer enter provider information into our system —
  under any circumstances — with a retroactive effective date"
  ([EmblemHealth](https://www.emblemhealth.com/providers/news/no-retroactive-effective-dates-202309)
  — AUTHORITATIVE).

> **The brief's framing needed correcting here.** "Most payers grant effective dates retroactive
> to the application date" is **true for Medicare by regulation**, **commonly true for state
> Medicaid** (with cited exceptions), and **not established for commercial payers — where we
> found an explicit, published refusal.** Do not put the general form in a customer commitment.
> Ask each payer in writing and record the answer.

**Some state laws force the issue**, and are worth checking for the pilot's state before
assuming a payer's default:

- **Ohio:** "a contracting entity shall complete the credentialing process not later than
  ninety days after the contracting entity receives that credentialing form", and a
  non-compliant entity is liable for "a civil penalty payable to the provider in the amount of
  five hundred dollars per day … or retroactive reimbursement to the provider"
  ([ORC 3963.06](https://codes.ohio.gov/ohio-revised-code/section-3963.06) — AUTHORITATIVE).
- **Texas** expedited credentialing: "for payment purposes only, the issuer shall treat the
  applicant physician as if the physician were a participating provider"
  ([Ins. Code 1452.104](https://codes.findlaw.com/tx/insurance-code/ins-sect-1452-104/) —
  AUTHORITATIVE **for physicians**; whether it extends to licensed therapists is
  **UNVERIFIED**).
- **Arizona**, effective 2026-04-01: credentialing within 60 calendar days, loading within 30,
  and payment for services "from the date included on the notice of complete credentialing
  application"
  ([SB 1291 fact sheet](https://www.azleg.gov/legtext/57leg/1R/summary/S.1291HHS_ASPASSEDCOW.DOCX.htm)
  — AUTHORITATIVE as a legislative summary, not statute text).

**Credentialing duration — payer-published stages, not a single number.** No payer publishes an
end-to-end "90–120 days". That figure is an emergent total, and should be labelled as such:

| Stage | Published figure | Source |
|---|---|---|
| Credentialing review, once the application is complete | "up to 14 calendar days" | [UHC credentialing FAQ](https://www.uhcprovider.com/content/dam/provider/docs/public/resources/join-network/Credentialing-FAQs.pdf) — AUTHORITATIVE |
| **Contract loading after approval** | **"up to 60 days"** — and until then claims are "denied or paid at an out-of-network level" | same — AUTHORITATIVE |
| Initial application response (behavioral health) | "within six weeks after reviewing the application" | [Cigna BH admin guide](https://static.cigna.com/assets/chcp/resourceLibrary/behavioralResources/medicalMgmt/adminGuide/practitionerSelection.html) — AUTHORITATIVE |
| Committee decision notification | "within 30 days" (Cigna BH); "within 60 days following credentialing committee review" (Capital Blue Cross) | Cigna BH as above; [Capital BCBS](https://www.capbluecross.com/wps/portal/cap/provider/provider-hub/credentialing-overview-qrg) — AUTHORITATIVE |
| End-to-end, behavioral health | 90–120 days, sometimes 180 | **SECONDARY** (credentialing-industry aggregate; no payer promises it) |

**The contract-loading step is the one that surprises people.** Credentialing approval is not
billability; a payer can approve in 14 days and still take 60 more to load the contract, during
which claims deny or pay out-of-network. Track approval and loading as two separate dates.

**Verification currency is a hidden deadline.** NCQA's limit is **180 calendar days** for
primary-source verification and the application/attestation at the credentialing decision
([NCQA 2025 CRPN corrections](https://wpcdn.ncqa.org/www-prod/wp-content/uploads/2025-CRPN-Policy-Updates_11-18-24.pdf)
— AUTHORITATIVE; the same document sets 120 days for work-history verification). Some payers
apply a tighter window — Capital Blue Cross requires the CAQH application, attestation and
verifications "current and dated within 120 days of the credentialing committee decision".
**CAQH re-attestation is every 120 days** and lapsing it stalls credentialing
(UHC FAQ, Cigna BH admin guide — AUTHORITATIVE). *If a file ages past the window, verification
is redone and the clock effectively restarts.*

**Timely filing is the constraint on holding claims — and behavioral health is often shorter
than medical.** Cited limits:

| Payer | Limit | Source |
|---|---|---|
| Medicare | **1 calendar year** from date of service | [CMS MLN](https://www.cms.gov/outreach-and-education/mln/wbt/mln7388180-mln-wbt-1450/1450/lesson01/08/index.html) (per ACA §6404) — AUTHORITATIVE |
| Cigna, medical | **90 days** participating; **180 days** out-of-network | [Cigna](https://static.cigna.com/assets/chcp/resourceLibrary/clinicalReimbursementPayment/medicalClinicalReimburseWhenToFile.html) — AUTHORITATIVE |
| **Cigna Behavioral Health** | **60 days** contractual; claims not submitted within **90 days** are denied "unless a longer time is permitted by applicable state law" | [Cigna BH](https://static.cigna.com/assets/chcp/resourceLibrary/behavioralResources/medicalMgmt/adminGuide/gettingPaid.html) — AUTHORITATIVE |

**A 60–90-day behavioral-health filing limit against a 90–120-day credentialing cycle is a
direct collision.** Holding claims is not indefinitely safe. Every held claim must carry its
payer's limit, and a claim approaching it needs a decision — submit and appeal the denial,
or write it off knowingly — before the date passes, not after.

---

## 6. What the clearinghouse platform changes buy us — and what they do not

Verified 2026-09-14 against the clearinghouse partner's public documentation and changelog.
Three capabilities shipped together on **2026-09-09**.

**1. Claims-lifecycle API.** "You can now use [the] Claims Lifecycle API endpoints to retrieve
the same claim records that power the claims view in the [vendor] portal." The timeline
endpoint "Returns a claim's full history: submissions, 277CA claim acknowledgments, and claim
payment information from Electronic Remittance Advice (ERAs)", and "A resubmitted claim carries
every attempt on one timeline."

> **Correction to the brief.** The timeline documents **277CA and ERA payment information.
> 999 functional acknowledgements are not listed as timeline events.** #561 lists "999/277CA"
> acknowledgement handling; the 999 half needs a separate source. Flagged to #561 rather than
> assumed.

**2. Test mode across all 837 types.** "Test mode works for all three 837 claim types: 837P
professional, 837D dental, and 837I institutional" — submit test claims, validate against the
claim-edits database, attach documents, receive 277CA acknowledgements, and receive test ERAs
from a test payer.

> **The limit that matters: enrollment itself is not available in test mode.** "You must
> complete the enrollment in production — you can't submit enrollments with a test API key or
> in test mode." Test mode parallelizes the **pipeline**, not the **enrollment**.

**3. Treasury / EFT with automatic reassociation.** "You can now enroll for EFTs, then receive
and automatically reconcile payments from payers"; EFT enrollment rides "the same transaction
enrollment process you already use for ERAs"; matching is "based on the reassociation trace
number returned in both". Note the precision: the automatic match is **payment ↔ ERA by trace
number**; **ERA ↔ claim** is the lifecycle timeline. A deposit account is provisioned in the
provider's name via a banking partner — a clinic decision, not merely a technical step.

### The claim that did not survive checking

The brief stated that the vendor "did NOT ship enrollment automation, so the lead time stands."

**The premise is wrong; the conclusion is right, for a different reason.** Enrollment automation
exists and predates the 2026 release: one-click transaction enrollment shipped **2025-06-05**,
and enrollment is documented as "streamlined, fully managed, API-based", with the vendor
"handl[ing] the entire enrollment process for you, including submitting the required information
to the payer and monitoring the status of the enrollment."

The lead time stands anyway, because **the automation compresses our working time, not the
payer's queue**. An enrollment submitted in one API call still waits in the same payer inbox.
This distinction is the whole reason §0 separates working time from waiting time.

### An unresolved conflict in the vendor's own numbers

Three different published figures, same vendor, as of 2026-09-14:

| Source page | Figure |
|---|---|
| Transaction-enrollment docs | "Most enrollments are completed within 24 - 48 hours." … "some payers may take up to 30 days" |
| Credentialing-and-enrollment docs | "Transaction enrollment typically takes 2-6 weeks, depending on the payer." |
| Marketing | "Get providers live in days, not weeks." |

**Plan against 2–6 weeks.** The optimistic figures are not schedule inputs until the vendor
reconciles them. **ACTION (owner: us, this sprint):** ask the vendor which figure is the
planning figure and record the answer here with its date.

### Other verified platform facts with schedule consequences

- **ERA (835) enrollment is always required**; other transactions are payer-dependent.
- **Most payers require no enrollment for 270/271 eligibility** — so #563 can go live
  materially earlier than #561. Take that win.
- **Medicare and Medicaid characteristically require a payer-assigned submitter ID on all
  claims.**
- **The payer directory is public** and needs no account — payer-ID resolution is a day-one
  task with no prerequisites.
- **The vendor does not do credentialing.** Its own documentation says so, which is a useful
  independent confirmation of the boundary in §1.
- **UNVERIFIED:** no vendor page was found covering state Medicaid trading partner agreements
  or billing-agent authorization specifically. *Verified by:* asking the vendor directly for
  the pilot's state, or reading that state's TPA packet ourselves. Until then, assume the
  state's own process governs.

### A structural surprise worth carrying into every state

Some states do **not** require the provider to register as a trading partner at all when an
approved clearinghouse is used. Indiana: providers are not required to register as trading
partners if they use a "Clearinghouse that has been approved by the IHCP" or an approved
billing service ([IHCP](https://www.in.gov/medicaid/providers/business-transactions/electronic-data-interchange-edi-solutions/trading-partner-registration-procedure/)
— AUTHORITATIVE).

**So the first question for any state is not "how do we complete the TPA" but "does this state
require one from us at all, given our clearinghouse?"** The answer can remove a 30–45 day item
from the critical path outright. Ask it before filling in a single form.

---

## 7. Critical path and calendar

### The chain that sets the date

Longest strictly-sequential path, from a standing start, to **first electronic remittance from
a state Medicaid payer**:

```
entity ─► EIN (same day online)
       ─► NPI (allow 15 working days)
       ─► NPPES accurate
       ─► state Medicaid provider number (state-specific; UNVERIFIED)
       ─► state TPA + submitter ID (5 business days … 30–45 days, cited range)
       ─► 837 enrollment + connectivity test (state-specific; TX: 5 error-free batches of 50)
       ─► 835/ERA enrollment (7 business days … 30 days, cited range)
       ─► EFT enrollment + bank verification (15-day pre-cert where applicable)
       ─► first claim ─► first remittance
```

**Everything else fits inside this chain**: the clearinghouse account, adapter (#35), the
test-mode pipeline proof (#561), eligibility (#563), and every other payer's enrollment.

### The December pilot, counted backwards

Today is **2026-09-14** (Sprint 1). A **2026-12-01** opening is **11 weeks** away.

| If the clinic already holds NPI + EIN + state Medicaid provider number | Then |
|---|---|
| **Yes** | The EDI half is 4–6 weeks per payer on the cited figures. Starting now, **billing-ready by 1 December is achievable with roughly 5 weeks of slack.** Enrollment must still start immediately — the slack is the buffer for a returned application, not spare time. |
| **No** | NPI (≈3 weeks) + state Medicaid provider enrollment (unverified, commonly months) + TPA (30–45 days) **exceeds 11 weeks for the Medicaid payer.** Commercial payers may still make December. **Medicaid billing then lands in January.** |

**This conditional is the single most important output of this runbook.** It must be answered
this sprint, because it is the difference between "start now and we are fine" and "December
Medicaid revenue does not exist." It is answered by one question to the clinic: *do you have
these three numbers today?*

### Cash timing — state it, do not let it be discovered

**A December opening plausibly posts as cash in January or February.**

The arithmetic, with each link cited above:

1. Visits are delivered from the December opening and coded on time.
2. Claims for payers whose credentialing or enrollment is incomplete are **held**, not dropped.
3. Credentialing decisions land on payer timelines (planning figure 90–120 days from
   application for commercial; see §5 for confidence).
4. Held claims are released once effective dates are known — for Medicare and most state
   Medicaid programs, retroactive to the application date, so the December services remain
   billable.
5. The payer then pays on its own cycle after a clean claim.

December services → claims released late December into January → payment on the payer's cycle →
**cash in January–February**. This is the expected case, not the pessimistic one. Working
capital should be planned for it. Nobody should discover it in February.

---

## 8. Where this touches the code

The runbook is operational, but three items land in the engine:

- **#35 (clearinghouse adapter).** The billing contract in `lib/corvid/adapters/base.rb` covers
  `submit_claim`, `check_claim_status`, `fetch_remittances`, `check_eligibility_detailed`,
  `search_payers`, `process_payment`, `refund_payment`. **It has no enrollment surface** — no
  way to submit an enrollment or read its status — even though the clearinghouse exposes an
  enrollment API. Today enrollment status lives only in this checklist. *Recommendation: add
  enrollment submission and status to the adapter contract so the evidence register can be
  populated programmatically rather than by hand.* Filed as a follow-up rather than done here,
  because it is a contract change and belongs with #35.
- **#561 (claims end to end).** Its acceptance proof runs entirely in test mode and does not
  wait for enrollment — see §2. Its "999/277CA" acknowledgement handling needs a 999 source;
  the lifecycle timeline does not provide one.
- **#563 (eligibility).** Un-gated earlier than claims, because most payers require no
  enrollment for 270/271.

There is no payer or enrollment model in the engine today (`app/models/corvid/` has
`claim_submission`, `billing_transaction`, `payment`, but no payer or enrollment). That is a
deliberate open question, not an omission: enrollment state may be operational rather than
engine state. It should be decided, not defaulted.

---

## 9. Sources and verification status

**Cited and authoritative:** IRS EIN timeframes; CMS MLN Matters SE0751 (NPI); CMS 855
processing standards as published by a MAC; MAC EDI enrollment packet (submitter ID); MAC
CMS-588 instructions (EFT pre-certification); Indiana, Minnesota, Texas and Oregon Medicaid EDI
pages; 42 CFR 424.520, 424.521 and 410.26; Colorado HCPF backdating; NC Medicaid and NCTracks
behavioral-health enrollment; WAC 182-502-0005; ORC 3963.06; Texas Ins. Code 1452.104; Arizona
SB 1291 fact sheet; CAQH CORE Phase III EFT & ERA rule set; NCQA 2025 CRPN corrections; UHC
credentialing FAQ and EDI pages; Cigna medical and behavioral-health administrative guides;
Capital Blue Cross credentialing guide; EmblemHealth retroactive-date notice; Quartz ERA page;
Optum supervision reimbursement policy; CMS No Surprises good-faith-estimate guidance; the
clearinghouse partner's documentation and 2026-09-09 changelog.

**Corrections this research forced on the original brief** — recorded so the reasoning is not
re-litigated:

| Brief said | Finding |
|---|---|
| The clearinghouse "did NOT ship enrollment automation, so the lead time stands" | Enrollment automation shipped 2025-06-05 and enrollment is fully managed and API-based. **The conclusion holds for a different reason:** automation compresses our working time, not the payer's queue. |
| The claims-lifecycle API covers "999/277CA" | The timeline documents 277CA and ERA payment information. **999 is not listed.** Raised against #561. |
| "Most payers grant effective dates retroactive to the application date" | True for Medicare by regulation, commonly true for state Medicaid, **not established for commercial** — one payer publishes an unconditional refusal. |
| Credentialing gates billing, not opening | True of the clinic; **two payers publish that their members should not be seen until participation is confirmed.** Those patients are out-of-network or self-pay. |

**Explicitly unverified, with what would settle each:**

| Unverified | What verifies it |
|---|---|
| Entity-formation duration | The formation state's registry |
| State Medicaid **provider** enrollment duration (as distinct from the TPA) | The pilot state's provider-enrollment page |
| Commercial retroactive effective dates, per payer | Each payer's written answer, per §4 of the customer guidance |
| The 90–120-day end-to-end credentialing figure | No payer publishes it; the specific payer's provider manual is the only real answer |
| Per-payer timely-filing limits | Each payer's manual; record in the evidence register |
| Whether the clearinghouse handles state Medicaid TPAs and billing-agent authorization | Ask the vendor for the pilot state, or read the state's packet |
| Which of the vendor's three enrollment-duration figures is the planning figure | Ask the vendor; record the answer and its date |
| Whether the pilot state exempts providers using an approved clearinghouse from TPA registration | That state's trading-partner page |
| Whether Texas expedited credentialing extends beyond physicians to licensed therapists | Texas Ins. Code ch. 1452, full chapter |
| A 999 acknowledgement source in the current platform | Vendor docs or the SFTP/X12 path; tracked on #561 |

**Maintenance rule.** Every observed duration from this pilot goes back into §4.3 with the date
observed and the payer class. Within one clinic this document stops being a compilation of other
people's published figures and becomes a record of measured ones. Published figures are what we
plan with until then — never invented ones.
