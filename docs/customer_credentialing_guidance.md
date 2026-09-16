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
queue and released once each payer's enrollment completes — and **where the payer sets the
participation effective date back to the date you applied**, the held claims remain payable when
released. Medicare does that by regulation and many state Medicaid programs do; some commercial
payers refuse it outright. Which of your payers do is question 1 in section 4 — the held claims
for a payer are only as safe as that payer's written answer and its timely-filing limit.

This reframes credentialing from a **launch blocker** into a **cash-timing issue**. It is still
a real issue, and section 6 is blunt about what it does to your first months of cash — but it is
not a reason to delay opening.

The thing that makes the retroactive date early is **applying early**. Where a payer grants
retroactivity it is measured from your application date, so every week an application sits
unfiled is a week of visits that may never be billable.

### The honest caveat

"You can open on schedule" is true of *your clinic*. It is not automatically true of *every
payer's members*, and we would be misleading you if we left it there. Some payers publish the
opposite instruction — for example:

- UnitedHealthcare: "Credentialing is required for all licensed individual health care
  professionals in order to participate in the UnitedHealthcare networks and prior to seeing
  UnitedHealthcare members."
  ([UHC credentialing FAQ](https://www.uhcprovider.com/content/dam/provider/docs/public/resources/join-network/Credentialing-FAQs.pdf))
- Capital Blue Cross: "Providers should not schedule services with Capital Blue Cross members
  until a second notification of participation in our networks has been issued."
  ([Capital Blue Cross](https://www.capbluecross.com/wps/portal/cap/provider/provider-hub/credentialing-overview-qrg))

So the precise version is: **you open on schedule, and each payer's members become in-network
patients when that payer says so.** A patient whose payer has not yet confirmed participation is
seen out-of-network or self-pay. That is a conversation with the patient rather than a closed
door — and if they are not using insurance, federal rules require you to give them a good-faith
estimate of cost in advance
([CMS](https://www.cms.gov/nosurprises/consumers/understanding-costs-in-advance)).

Neither of these payers is necessarily in your mix; they are cited because they publish their
policy. The action is the same either way: ask each of *your* payers, in writing, before you
open.

### And one workaround to be careful with

"Bill it under a credentialed supervising provider until credentialing lands" is widely
suggested and much narrower than it sounds. The payer policy we were able to verify covers
*unlicensed practitioners working toward licensure*, in specific named states or with prior
approval, requiring a modifier and the supervising provider's identifiers on the claim
([Optum supervision policy](https://public.providerexpress.com/content/dam/ope-provexpr/us/pdfs/adminResourcesMain/supervisory-services/SupServiceReimbursementPolicy.pdf)).
Medicare's incident-to rule permits behavioral health under general supervision, and only the
supervising practitioner may bill for it
([42 CFR 410.26](https://www.law.cornell.edu/cfr/text/42/410.26)).

**We found no payer policy allowing a licensed-but-not-yet-credentialed clinician's work to be
billed under someone else's NPI.** Please do not rely on it unless a payer puts it in writing
for your situation.

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

Both must be finished before a payer pays an in-network claim — self-pay and sliding-fee never
touch either (section 5), and an out-of-network claim needs only the first. Neither one is a prerequisite of the other — with one
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
| State Medicaid provider number | In most states, an input to the state's electronic-transaction paperwork. (Some states waive their registration step for providers using an approved clearinghouse — checking the pilot state's rule is the first thing we do, so this may block less than it appears.) |
| Executed payer contracts | The contract, not the application, is what makes you in-network. |
| A bank account for receipts and an authorized signer | Electronic funds transfer enrollment needs both, per payer. |

---

## 4. What to ask every payer, in writing

Ask by email and keep the reply. These answers are the inputs to your cash forecast, and a
verbal answer from a call-centre agent is not one of them.

1. **"What is the participation effective date, and is it retroactive to our application
   date?"** This single answer determines whether the visits you deliver during the wait are
   billable at all. **Do not assume yes.** Medicare grants it by regulation — the effective date
   is the later of the filing date of an approved application or the date you began furnishing
   services at the location ([42 CFR 424.520](https://www.law.cornell.edu/cfr/text/42/424.520)),
   plus up to 30 days of retrospective billing where circumstances precluded enrolling in
   advance ([42 CFR 424.521](https://www.law.cornell.edu/cfr/text/42/424.521)). Many state
   Medicaid programs are generous too. But at least one commercial payer publishes a flat
   refusal: EmblemHealth and ConnectiCare "will no longer enter provider information into our
   system – under any circumstances – with a retroactive effective date"
   ([notice](https://www.emblemhealth.com/providers/news/no-retroactive-effective-dates-202309)).
2. **"What is your timely-filing limit, measured from the date of service?"** This is the
   deadline on every claim you are holding. It is the difference between a delayed payment and
   a write-off — and behavioral health limits are often *shorter* than medical ones. Cigna
   Behavioral Health, for example, requires claims within 60 days contractually, with claims
   past 90 days denied "unless a longer time is permitted by applicable state law"
   ([Cigna BH](https://static.cigna.com/assets/chcp/resourceLibrary/behavioralResources/medicalMgmt/adminGuide/gettingPaid.html)),
   against Medicare's one calendar year.
   **A 60–90 day filing limit against a 90–120 day credentialing cycle is a direct collision**,
   and it is the reason we track every held claim's deadline individually.
3. **"When will our contract be loaded, as distinct from credentialed?"** These are two
   different dates and the second is the one that makes claims pay. UnitedHealthcare publishes
   "up to 14 calendar days" for credentialing once the application is complete, and then "up to
   60 days for your contract to be loaded into our systems", during which claims are "denied or
   paid at an out-of-network level" ([UHC FAQ](https://www.uhcprovider.com/content/dam/provider/docs/public/resources/join-network/Credentialing-FAQs.pdf)).
4. **"What do you require for electronic claims, electronic remittance advice, and electronic
   funds transfer enrollment, and who is the EDI contact?"** Forward the answer to us — that
   one is our work, we just need the door.
5. **"While credentialing is pending, may services be billed under a credentialed supervising
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

**Holding is not indefinitely safe, and this is the part to watch.** A 60–90 day
behavioral-health filing limit against a 90–120 day credentialing cycle collide directly. When a
held claim approaches its deadline before the payer's effective date lands, there is a decision
to make — submit it and appeal the expected denial, or write it off knowingly — and it has to be
made *before* the date passes.

If a payer's enrollment is going to land after the timely-filing deadline of the oldest held
claims, we will tell you before those claims expire, not after. That is a tracked date, not a
judgement call, and it is why each held claim carries its own deadline rather than a single
queue-wide one.

One more thing worth keeping current while you wait: if your payers use the CAQH Provider Data
Portal, **re-attest every 120 days**. A lapsed attestation stalls credentialing silently, and
verification that ages out of a payer's currency window has to be redone — which restarts time
you have already spent.

---

## 6. What this does to cash

This is the part clinics usually discover rather than plan for, so we state it plainly:

**A December opening plausibly posts as cash in January or February.**

Not because anything went wrong — because that is how the arithmetic works when enrollment
completes after the doors open, claims are held, and payers pay on their own cycle after
release:

1. December visits are delivered and coded on time.
2. Claims for payers not yet fully enrolled are held rather than dropped.
3. Credentialing decisions land on payer timelines — and remember that approval and
   **contract loading** are two different dates, with up to 60 days between them at one payer
   that publishes the figure.
4. Held claims are released once effective dates are known, retroactive where the payer allows.
5. The payer then pays on its own cycle after a clean claim.

Plan working capital for the gap; do not plan around the hope that it closes faster. The single
thing that moves this earlier is **filing complete applications sooner** — not chasing after.
And it is per payer, not uniform: a payer whose application goes in late, or whose credentialing
and contract-loading run to the slow end of the published figures, can push its share of the
cash into March. We track the release date per payer, so you will see which payers are which.

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
