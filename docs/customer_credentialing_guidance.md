# Credentialing and Enrollment: Guidance for the Clinic

*A plain-language companion for a clinic standing up billing. Written to be handed over as-is.
The technical half lives in `docs/edi_enrollment_runbook.md`; you do not need to read that one.*

**Verified:** 2026-09-14. Sources are cited inline. Where something is not sourced it is marked
**unverified** and says what would settle it — please do not treat an unverified line as a
commitment from us.

---

## 1. The sentence that matters most

**Credentialing gates *billing*, not *opening*.**

You can open on schedule. You can see patients, document visits, and run the clinic while payer
enrollment is still in progress. What waits is the *claim*, not the *care*. Claims are held in a
queue and released once each payer's enrollment completes — and because most payers set the
participation effective date back to the date you applied, the held claims are generally
payable when released.

This reframes credentialing from a **launch blocker** into a **cash-timing issue**. It is still
a real issue, and section 6 is blunt about what it does to your first months of cash — but it is
not a reason to delay opening.

The thing that makes the retroactive date early is **applying early**. Retroactivity is measured
from your application date, so every week an application sits unfiled is a week of visits that
can never be billed.

---

## 2. Two different jobs, two different owners

"Payer enrollment" is used for two unrelated pieces of work. They run at the same time, they
have different counterparties, and confusing them is how schedules slip.

| | **EDI / trading-partner enrollment** | **Provider credentialing / network enrollment** |
|---|---|---|
| The question it answers | "May this submitter send transactions for this clinic, and where do the payments go?" | "Is this clinic — and this clinician — in the payer's network, and at what rate?" |
| **Who does it** | **We do.** | **You do**, usually through a credentialing service or platform. |
| Counterparty | The clearinghouse and each payer's EDI unit | Each payer's credentialing / network unit |
| What it produces | Submitter IDs, payer IDs, a signed trading partner agreement, electronic remittance and electronic funds transfer set up per payer | A CAQH profile, a participation contract, a fee schedule, an effective date per clinician |
| What breaks without it | Claims are rejected before anyone looks at them; payments arrive on paper or not at all | Claims are accepted, then denied or paid out-of-network |

Both must be finished before money moves. Neither one is a prerequisite of the other — with one
link: the provider number a payer issues during enrollment is often an input to that same
payer's electronic-remittance paperwork. That is the one place the two tracks touch.

---

## 3. What we need from you, and why each item blocks

Nothing payer-facing can complete without these. We can do a surprising amount before they
arrive (see the runbook), but these set the start of the clock.

| What | Why it blocks |
|---|---|
| Legal entity name and address, fixed | Every downstream record must match it exactly. A mismatch between your registry record, your W-9 and a payer's file is the most common cause of an application being returned weeks later — and a returned application is not a pending one; the clock restarts. |
| Federal tax ID (EIN) | Required on payer applications and on every claim's billing-provider record. |
| Organizational NPI (Type 2) | Identifies the clinic as the billing provider. |
| Individual NPI (Type 1) per clinician | Identifies who rendered the service. Credentialing is per clinician. |
| An accurate, current NPPES record | Payers validate against NPPES. Fix NPPES *before* filing anything, not after a rejection. |
| Current state licences for every clinician | Credentialing verifies licensure directly with the source; an expired or pending licence stops the file. |
| State Medicaid provider number | Required before the state's electronic-transaction paperwork can be filed. |
| Executed payer contracts | The contract, not the application, is what makes you in-network. |
| A bank account for receipts and an authorized signer | Electronic funds transfer enrollment needs both, per payer. |

---

## 4. What to ask every payer, in writing

Ask by email and keep the reply. These four answers are the inputs to your cash forecast, and a
verbal answer from a call-centre agent is not one of them.

1. **"What is the participation effective date, and is it retroactive to our application
   date?"** This single answer determines whether the visits you deliver during the wait are
   billable at all.
2. **"What is your timely-filing limit, measured from the date of service?"** This is the
   deadline on every claim you are holding. It is the difference between a delayed payment and
   a write-off.
3. **"What do you require for electronic claims, electronic remittance advice, and electronic
   funds transfer enrollment, and who is the EDI contact?"** Forward the answer to us — that
   one is our work, we just need the door.
4. **"While credentialing is pending, may services be billed under a credentialed supervising
   provider?"** The answer is payer-specific, scope-of-practice-specific, and sometimes no.
   Do not assume it; get it in writing before relying on it.

---

## 5. Holding claims, not losing them

While a payer's enrollment is pending:

- **Document and code every visit normally, on time.** Charge capture does not wait. A visit
  documented late is harder to code correctly and harder to defend later.
- **Hold the claim; do not drop it.** Held claims sit in a queue with the payer, the date of
  service, and the timely-filing deadline attached to each one.
- **Every held claim carries its own deadline.** The queue is sorted by how soon each claim
  must go out, not by when it was created.
- **Release on the day the effective date lands**, oldest first.
- **Self-pay and sliding-fee patients are unaffected.** That path never touches payer
  enrollment, so it runs from day one.

If a payer's enrollment is going to land *after* the timely-filing deadline of the oldest held
claims, we will tell you before those claims expire, not after. That is a tracked date, not a
judgement call.

---

## 6. What this does to cash

This is the part clinics usually discover rather than plan for, so we state it plainly:

**A December opening plausibly posts as cash in January or February.**

Not because anything went wrong — because that is how the arithmetic works when enrollment
completes after the doors open, claims are held, and payers pay on their own cycle after
release. Section 7 of the runbook shows the calendar. Plan working capital for the gap; do not
plan around the hope that it closes faster.

---

## 7. What we do, and what we do not

Precise enough to put in a services agreement:

**We do:**
- Establish and operate the clearinghouse account and connectivity.
- Resolve payer IDs and confirm, per payer and per transaction, whether enrollment is required.
- Prepare, submit and track EDI/trading-partner enrollment per payer, including state Medicaid
  trading partner agreements and submitter IDs.
- File billing-agent / clearinghouse authorizations naming us as your submitter.
- Enrol electronic remittance advice (835) and electronic funds transfer per payer, and prove
  reassociation of payment to remittance.
- Complete any payer-required connectivity or companion-guide testing.
- Operate claim submission, acknowledgement handling, remittance posting and reconciliation.
- Track timely-filing deadlines on held claims and tell you before any of them expire.

**We do not:**
- Credential the organization or any clinician with any payer.
- Negotiate or execute payer participation contracts or fee schedules.
- Maintain your CAQH profile, licensure, or NPPES record.
- Obtain your NPIs, EIN, or state Medicaid provider number.
- Guarantee a payer's effective date, retroactivity, or processing time. Those are the payer's
  to set; we track and report them.

Credentialing is normally handled by a dedicated credentialing service or platform. We are happy
to work alongside one and to hand it whatever our side produces — but it is your contract, not
ours, and the effective dates it produces are commitments from the payer to you.
