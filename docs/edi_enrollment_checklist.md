# EDI Enrollment Checklist

Executable companion to `docs/edi_enrollment_runbook.md`. The runbook explains *why* and *how
long*; this file is the thing the team ticks. Copy it per clinic, and copy **Stage 2** once per
payer.

## How to use it

- **Owner** is one of `OPERATOR` (us), `CLINIC`, `PAYER`, `CLEARINGHOUSE`, `BANK`.
  Lines owned by `PAYER` / `BANK` are *waiting*, not *working* — they set the critical path.
- **Evidence** is the artifact that proves the line is done. A line is ticked when the artifact
  exists, never when the submission was sent.
  **"We submitted it" is not evidence. Absence of a rejection is not evidence.**
- Record the **date started** and **date the evidence arrived**. The gap is the observed
  duration for that payer — feed it back into the runbook so the next clinic's estimate is
  measured rather than assumed.
- A blocked line gets a one-line reason and a named counterparty contact, not a status colour.

```
[ ]  <action>
     owner:      OPERATOR | CLINIC | PAYER | CLEARINGHOUSE | BANK
     started:    YYYY-MM-DD
     evidence:   <the artifact that proves it>
     received:   YYYY-MM-DD
```

---

## Stage 0 — Clinic prerequisites (once per clinic)

These are the clinic's to obtain. **Nothing payer-facing can complete without them**, but a
great deal of our work can start before they arrive — see the runbook's "productive waiting"
column.

```
[ ]  Legal entity formed; legal name and business address fixed
     owner: CLINIC      evidence: formation document / state registration
     note:  the legal name must match everywhere afterwards — a mismatch between the
            NPPES name, the W-9 name and the payer record is the single most common
            cause of an enrollment being kicked back weeks later.

[ ]  EIN (federal tax ID) issued
     owner: CLINIC      evidence: IRS EIN confirmation letter (CP 575)

[ ]  Organizational NPI (Type 2) issued
     owner: CLINIC      evidence: NPI number + NPPES record showing correct taxonomy,
            legal name, and practice address

[ ]  Individual NPIs (Type 1) for every rendering clinician
     owner: CLINIC      evidence: NPI per clinician, NPPES records current

[ ]  NPPES record accurate and current (taxonomy, address, authorized official)
     owner: CLINIC      evidence: NPPES screenshot/export dated within the last 30 days
     note:  payers validate against NPPES. Fix NPPES BEFORE submitting anything.

[ ]  State professional licences current for every clinician
     owner: CLINIC      evidence: licence numbers + expiry dates

[ ]  State Medicaid provider number / provider ID issued
     owner: CLINIC      evidence: the state-issued provider ID
     note:  this is provider enrollment with the state, not EDI enrollment — but the
            state EDI/trading-partner step usually requires it as an input.

[ ]  Payer contracts / participation agreements executed (per payer)
     owner: CLINIC      evidence: countersigned agreement + effective date per payer

[ ]  Bank account for receipts identified (and, if using the clearinghouse's treasury
     product, the decision to open an account in the clinic's name made)
     owner: CLINIC      evidence: account name, routing/account numbers held securely,
            voided cheque or bank letter

[ ]  Authorized official / signatory identified, with authority to sign trading partner
     agreements and EFT authorizations
     owner: CLINIC      evidence: name, title, contact, and confirmation of signing authority
```

---

## Stage 1 — Clearinghouse account and connectivity (once per clinic)

```
[ ]  Clearinghouse account provisioned (production and test)
     owner: OPERATOR    evidence: account identifier; production and test API keys issued

[ ]  API credentials stored in the secret store; never in the repo
     owner: OPERATOR    evidence: secret path recorded; a `git grep` for the key prefix
            returns nothing

[ ]  Billing provider / organization record created at the clearinghouse
     owner: OPERATOR    evidence: provider record showing NPI + tax ID as they appear in NPPES

[ ]  Payer IDs resolved for every payer in scope, from the clearinghouse payer directory
     owner: OPERATOR    evidence: a payer table — payer name, payer ID, transactions supported
            (270/271, 837P, 835, EFT), enrollment required yes/no per transaction
     note:  the directory is public and needs no account, so this line can be finished on
            day one, before any prerequisite in Stage 0 exists.

[ ]  Test-mode pipeline exercised end to end with a synthetic patient
     owner: OPERATOR    evidence: a test 837P submitted, a 277CA returned, a test ERA
            retrieved, all captured as artifacts
     note:  this is the #561 acceptance criterion and it does NOT require enrollment.
            Run it while enrollment queues.

[ ]  Adapter wired: submit_claim / check_claim_status / fetch_remittances /
     check_eligibility_detailed / search_payers implemented against the real client
     owner: OPERATOR    evidence: #35 merged; tests green against a mock that models the
            transport's real failure behaviour, not an imagined one
```

---

## Stage 2 — Per-payer block

**Copy this whole block once per payer.** Fill the header, then work the lines. Most of these
run concurrently *across* payers; within a payer they are ordered.

```
PAYER: ______________________   PAYER ID: __________   TYPE: Medicaid | Medicare | Commercial
```

```
[ ]  Confirm which transactions this payer requires enrollment for
     owner: OPERATOR    evidence: directory entry or API response per transaction
     note:  ERA (835) always requires enrollment. Eligibility (270/271) usually does not.
            Claims (837) is payer-dependent.

[ ]  Collect the payer's enrollment requirements and forms
     owner: OPERATOR    evidence: the requirement list / form set, dated

[ ]  Trading Partner Agreement (state Medicaid) or EDI Enrollment Agreement (Medicare/
     commercial) prepared
     owner: OPERATOR    evidence: completed agreement ready for signature

[ ]  Agreement signed by the authorized official
     owner: CLINIC      evidence: signed agreement (PDF), dated

[ ]  Agreement submitted
     owner: OPERATOR    evidence: submission confirmation / tracking number

[ ]  Submitter ID / trading partner ID issued
     owner: PAYER       evidence: the ID string itself
     note:  Medicare and Medicaid typically require a payer-assigned submitter ID on every
            claim. Without it, claims fail at the front door.

[ ]  Billing-agent / clearinghouse authorization filed (the payer is told that this
     submitter may transact on the provider's behalf)
     owner: OPERATOR    evidence: the payer's acknowledgement, not just our submission

[ ]  837 claim submission enrollment approved
     owner: PAYER       evidence: enrollment status "approved" for 837 with this payer

[ ]  835 / ERA enrollment approved
     owner: PAYER       evidence: enrollment status "approved" for 835
     note:  until this is approved, remittances do not arrive electronically and the
            reconciliation half of #561 cannot run for this payer.

[ ]  EFT enrollment approved (payer deposits to the clinic's account)
     owner: PAYER/BANK  evidence: EFT enrollment approved; prenote settled if used

[ ]  ERA and EFT reassociation confirmed — a payment matches its remittance by trace number
     owner: OPERATOR    evidence: one payment matched to one 835 by reassociation trace number

[ ]  Connectivity / companion-guide test passed where the payer requires one
     owner: PAYER       evidence: the payer's test acceptance notice

[ ]  First production claim accepted (277CA accepting, not rejecting)
     owner: OPERATOR    evidence: the 277CA

[ ]  First production remittance received and posted
     owner: OPERATOR    evidence: the 835 and the posted payment
```

---

## Stage 3 — Go-live gate

Every line must be true for a payer before we tell the clinic that payer is billable.

```
[ ]  Payer ID confirmed against a real accepted claim, not against the directory alone
[ ]  Submitter ID present on outbound claims
[ ]  837 enrolled/approved   [ ]  835 enrolled/approved   [ ]  EFT enrolled/approved
[ ]  A 277CA has come back ACCEPTING a claim for this payer
[ ]  An 835 has been received, parsed, and posted for this payer
[ ]  Payment and remittance reassociate by trace number
[ ]  Credentialing effective date for this payer is known and recorded
[ ]  Timely-filing limit for this payer is known and recorded, with the date the
     oldest held claim must be submitted by
[ ]  The held-claims queue for this payer has a release date and an owner
```

---

## Evidence register

One table per clinic. This is what an auditor — or the customer — reads.

| Payer | Payer ID | Submitter ID | TPA signed | 837 appr. | 835 appr. | EFT appr. | First 277CA | First 835 | Cred. effective date | Timely filing |
|---|---|---|---|---|---|---|---|---|---|---|
| *Example Health Plan* | 00000 | | | | | | | | | |
| *Example State Medicaid* | 00000 | | | | | | | | | |

---

## Anti-patterns this checklist exists to prevent

- **Ticking a line because a form was sent.** The payer's queue is the schedule; our outbox is
  not. Only a returned artifact closes a line.
- **Treating the payer directory as proof of a working connection.** A directory entry says a
  route exists, not that this billing provider may use it.
- **Discovering the submitter ID requirement at first submission.** It is a Stage 2 line for
  exactly this reason.
- **Letting ERA enrollment trail claim enrollment.** Claims going out with remittances coming
  back on paper is a reconciliation problem that costs more than the enrollment wait.
- **Holding claims with no release date.** A held claim without a timely-filing date on it is a
  future write-off.
