# Design: AI medical coding — build vs. buy (ENG-1B)

**Status:** Proposed — decision draft, no implementation in this doc
**Date:** 2026-10-22
**Tracks:** [lakeraven/corvid#461](https://github.com/lakeraven/corvid/issues/461) (ENG-1B)
**Refs:** #460 (agnostic coding / revenue-capture port), #35 (clearinghouse adapter in the private repo), #233 (shared adapter contract tests), [ADR 0005](../adr/0005-adapter-injection.md) (adapter injection, Proposed), #264 (decouple models from `Corvid.adapter`), #463 / [consented-payer-rules-moat.md](consented-payer-rules-moat.md) (ENG-7), #600 (claim linked to its referral), #652 / #660 / #657 (state Medicaid rules, resolver, eligibility groups), lakeraven-private#20 (concrete vendor adapter)

Replaces the draft in #464. Vendor and product names are deliberately left
out of this public repo, per the naming policy enforced by the
private-boundary scan. "The vendor" is the reference coding-engine candidate
tracked in the private repo. "A clearinghouse" is whichever clearinghouse the
private clearinghouse adapter (#35) talks to.

If this decision is accepted it can become an ADR (0009 or 0010, depending on
what #623 takes; not 0007 or 0008).

## 1. Problem

A clearinghouse is the claim *rails*: it moves an already-coded claim to the
payer and brings back 999 / 277CA / 835. The *brain* is missing: given a
clinical encounter, produce correct ICD-10, CPT/HCPCS and an evidence-based
E&M level of service, plus CDI (documentation-improvement) signals, so the
claim that reaches the rails is clean and captures the maximum *legitimate*
revenue.

This matters most for the target market. Tribal and safety-net clinics
chronically under-bill, and many have no certified coders at all. There an
autonomous coder is not an optimization; it is the difference between billing
and not billing.

The question: buy a vendor autonomous-coding engine behind the agnostic port
defined in #460, or build one in-house.

## 2. Options

- **Buy:** integrate a vendor autonomous-coding API as a concrete adapter
  implementing the #460 port. The reference candidate (lakeraven-private#20)
  is a SMART-on-FHIR clinical-AI vendor with three modules: CDS / risk
  scoring, inpatient CDI and coding automation with auditable results, and
  outpatient E&M level-of-service coding. It integrates over the same
  §170.315(g)(10) FHIR surface the overlay thesis rides, and uses standard
  terminologies (SNOMED CT, LOINC, ICD-10, RxNorm). The port keeps corvid
  vendor-agnostic, so this evaluates the *category*, with that vendor as the
  reference.
- **Build:** an in-house coding engine (LLM + rules + terminology services),
  trained and tuned on our own encounter and denial corpus.
- **Hybrid (the recommendation):** buy the general-purpose coding brain;
  build the thin tribal / safety-net claim-assembly layer and the denial
  feedback loop around it — the parts no vendor will ship.

## 3. Scoring

| Criterion | Buy (vendor API behind the #460 port) | Build (in-house engine) |
|---|---|---|
| **Time-to-value** | **Months.** SMART-on-FHIR delivery means the engine rides the (g)(10) FHIR surface; the corvid-side work is the #460 port, the FHIR reads it needs (§5 — not yet in `FhirAdapter`), and claim-assembly wiring. Revenue recovery for coder-less clinics starts when the adapter ships. | **Years.** A credible autonomous coder needs a large labeled corpus of encounter → code → adjudication outcomes. We have no coding corpus today and claim volume is pre-revenue. Early versions would under-perform a human coder, which is dangerous in a compliance-sensitive domain (upcoding exposure). |
| **Coverage (ICD-10 / CPT / HCPCS / E&M / CDI)** | **Broad now.** The reference candidate covers inpatient CDI and coding and outpatient E&M level of service with auditable rationale — the #460 port surface (codes, level of service, CDI signals, rationale). Vendors also absorb annual code-set churn (ICD-10 / CPT updates, E&M guideline revisions) as their core business. | **Narrow for years.** E&M leveling alone (2021+ MDM / time rules) is a specialty; CDI is another; inpatient DRG-adjacent coding another. Annual code-set maintenance becomes a permanent internal tax. |
| **Tribal / safety-net fit (IHS / AIR encounters, FMAP, state Medicaid)** | **None from any vendor — and that's fine.** No coding vendor knows IHS All-Inclusive Rate (AIR) encounter logic, FMAP mechanics, or per-state tribal Medicaid differences (encounter rate vs. FFS, wrap payments, 638-facility billing). Those are *claim-assembly and payer-rules* concerns, not *clinical-coding* concerns: the vendor turns the note into codes; corvid turns codes into the right claim for the right payer. That puts the tribal specialization where #460 and ENG-7 already put it — in our layer, above the port. | **Same work either way.** Building in-house doesn't buy tribal fit — we'd write the same claim-assembly layer *plus* the general coder underneath it. |
| **Cost model** | Per-encounter or subscription fees; scales with volume, near-zero fixed cost. Fits corvid's recover-and-share-savings RCM posture: vendor cost is a COGS line against measured recovered revenue. Margin risk if per-claim fees are high at scale — negotiate volume tiers; the port keeps switching costs low, which is our leverage. | Heavy fixed cost: ML team, labeled data, terminology licensing (CPT is a licensed code set — see §7), audit and compliance review of model output. No revenue until it beats the vendor baseline. |
| **Sovereignty / PHI (OCAP)** | **The one real risk — gated, not disqualifying.** A commercial cloud AI receiving tribal PHI raises OCAP Access and Possession concerns: a third-party engine processing tribal PHI requires community authorization, not just a BAA, and de-identification alone is never sufficient. See the gate in §4. | **Clean by construction** — an in-house engine can run inside the tribe's or Lakeraven's own environment. This is the strongest argument for build, and it survives as the *contingency*: if no vendor meets the gate for tribal tenants, the port lets us ship a self-hosted engine for those tenants only. |

## 4. Recommendation: buy first behind the port, with a hard sovereignty gate

1. **Buy** the general-purpose coding brain: the #460 port's concrete vendor
   adapter lives in the private repo (lakeraven-private#20), mirroring the
   clearinghouse-adapter-in-private pattern (#35). Corvid stays vendor-free.
   The adapter is proven against the shared contract tests (#233); the mock
   adapter satisfies the port for dev and CI.
2. **Build the moat, not the substrate.** In corvid (public, agnostic): the
   tribal / safety-net claim-assembly layer — AIR encounter-rate vs. FFS
   shaping, applying the member's state Medicaid rules through
   `Corvid::StateMedicaidRules` (#652), `Corvid::MedicaidRuleSetResolver`
   (#660) and the recorded eligibility group (#657) — and the ENG-7 denial
   feedback loop (§6). These compound with our own data; a generic coder
   never will. Whether FMAP routing belongs in this layer at all is an open
   question (§7).
3. **Sovereignty gate (carried from lakeraven-private#20) — a deployment
   precondition, not a footnote.** Before *any tribal deployment* of a vendor
   coding engine:
   - Establish the vendor's PHI handling: persisted vs. ephemeral processing;
     training on customer data (must be off); subprocessors.
   - Require at least one of: the engine runs **in our environment** (the
     tribe's or Lakeraven's), or **contractual ephemeral processing with no
     retention** under a BAA. De-identification is the weakest path and is
     insufficient alone for tribal data; any de-ID path uses Expert
     Determination, not Safe Harbor.
   - For tribal tenants, **authorization through the tribe's data-governance
     process** is required *in addition to* any technical control. Under
     OCAP, a BAA or de-identification never substitutes for authorization.
   - Non-tribal safety-net tenants (standard HIPAA posture) may go live on
     the vendor cloud under a BAA without waiting on the in-environment
     track.
   - **Enforcement is meant to be per-tenant adapter routing.** Once
     per-tenant injection exists, a tribal tenant can be pinned to an
     in-environment adapter (or the mock, i.e. no AI coding) while other
     tenants use the vendor cloud adapter. That is the target, not today's
     state: ADR 0005 is still Proposed, it covers services only, and models
     still reach the global `Corvid.adapter` (#264). Until both land, the gate
     is enforced by deployment configuration and process, and the code-level
     routing rule is a dependency of this decision, not a property of it.
4. **Preserve the build option as leverage.** The port and contract tests
   make a future in-house or second-vendor engine a swap, not a rewrite.
   Revisit build when (a) we hold a denial-outcome corpus large enough to
   train on (ENG-7 accumulates exactly this), or (b) vendor economics or the
   sovereignty gate fail.

## 5. Interface: encounter → codes → claim → clearinghouse

### 5.1 Port contract (#460)

- **In:** a FHIR bundle for one encounter.
- **Out:** a `CodedEncounter` — ICD-10 diagnoses, CPT/HCPCS procedures, E&M
  level of service, CDI signals, and a per-code auditable rationale.
- **Undecided vs. none.** The contract must keep these apart, and corvid must
  fail closed on the first:
  - `nil` for a code list (or the level of service) means **the coder could
    not decide**. The encounter routes to human review; nothing is billed
    from it automatically.
  - `[]` means **the coder decided there are no codes** of that kind, with a
    rationale saying why.
  - Absence of a field, a timeout, or an adapter error reads as `nil`, never
    as `[]`. Absence of data never verifies.
- Contract tests (#233) assert the mock and every concrete adapter honour
  this distinction.

### 5.2 FHIR reads the coder needs

The encounter bundle needs Encounter, Condition, Procedure, DocumentReference
(clinical note), Observation and Coverage. Of these, `FhirAdapter` today reads
only Condition (`get_conditions`). **Encounter, Procedure, DocumentReference,
Observation and Coverage reads are not yet in `FhirAdapter`** and are
prerequisite work under #460.

### 5.3 Flow

```
EHR (RPMS or any other)
  │  §170.315(g)(10) FHIR — Encounter, Condition, Procedure,
  │  DocumentReference, Observation, Coverage
  │  (only Condition is read by FhirAdapter today; the rest are #460 work)
  ▼
corvid: encounter assembly (FHIR bundle for the visit)
  │
  ▼
Coding port (#460)                               ┌─ concrete impls (private repo)
  in:  FHIR encounter bundle                     │   • vendor cloud adapter (BAA tenants)
  out: CodedEncounter =                          │   • in-environment adapter (tribal)
       ICD-10 dx, CPT/HCPCS px,        ◄─────────┤   • mock adapter (dev/CI, corvid)
       E&M level of service,                     └─ contract tests #233 assert parity
       CDI signals, per-code rationale
       (nil = undecided → human review; [] = none)
  │
  ▼
corvid claim assembly  ← tribal / safety-net layer applied here, above the port:
  │                       AIR encounter rate vs. FFS shaping,
  │                       StateMedicaidRules (#652) via the resolver (#660)
  │                       and eligibility group (#657),
  │                       ENG-7 pre-submission screens (consented-payer-rules-moat.md)
  ▼
ClaimSubmission linked to its PRC referral (#600);
  submit! refuses unless that referral is authorized
  │
  ▼
ClaimSubmission#submit! → Corvid.adapter.submit_claim  (global adapter, #264)
  │   → clearinghouse adapter (#35, private repo) → a clearinghouse
  │   837 out;  999 / 277CA / 835 back
  ▼
835 reconciliation + denial capture (feeds §6)
```

Notes on the flow as it stands on main:

- **#600:** a claim is linked to the referral it bills and is billed only
  once that referral is authorized (`enforce_referral_authorization_gate!`).
  Coded output never bypasses this gate; a well-coded claim for unauthorized
  care is still refused.
- **Submission path:** `ClaimSubmission` still submits through the global
  `Corvid.adapter`, not a dedicated EDI / clearinghouse adapter instance.
  Per-tenant routing of submission (and of the coder, §4.3) waits on #264
  and ADR 0005.

Boundary rules: the port and its types live in corvid (public, agnostic);
every vendor-specific detail lives in the private repo; EHR-specific RPC
stays in its own integration — corvid sees only FHIR. CDI signals flow
*backwards* to the clinician surface as documentation prompts before claim
submission, which is where maximum legitimate capture is actually won.

## 6. Denial feedback loop (ENG-7)

The design of the denial-pattern layer — what is shareable, consent and
governance, PHI minimization, legal gating, and how learned rules are applied
to new claims — lives in
[consented-payer-rules-moat.md](consented-payer-rules-moat.md) (#463, #592)
and is not restated here. That doc already names ENG-1B as a consumer (its
§4.6 consumption path and the "§5 of ENG-1B" return path).

What this decision adds:

- **Linkage:** every denial or adjustment (835 CARC/RARC, 277CA rejection) is
  linked back to the originating `CodedEncounter`, including the per-code
  rationale the port requires, within the tenant.
- **Consumption point:** ENG-7's pre-submission screens run in claim assembly
  (§5.3) over the coder's output, before the 837 goes out — catching vendor
  blind spots without vendor cooperation.
- **Build-option scorecard:** vendor-attributable denial rate is tracked as
  the ongoing buy-vs-build measure, and the in-tenant records are the corpus
  that would make a future in-house engine viable (§4.4) — subject to the
  moat doc's consent and governance rules for anything that crosses tenants.

## 7. Open questions for the owner

1. **Vendor data-handling terms.** Does the vendor offer in-environment
   deployment, or contractual ephemeral processing with no retention and no
   training on customer data under a BAA? Who are its subprocessors? Until
   answered, no tribal deployment (§4.3).
2. **FMAP routing.** Does "100% FMAP routing" belong in claim assembly at
   all? 100% FMAP for services received through IHS / tribal facilities is a
   federal-state reimbursement mechanism, so it may sit outside the claim the
   provider submits. If it does not belong in claim assembly, §4.2 and §5.3
   drop it.
3. **CPT licensing.** Who holds the CPT license for codes the vendor emits
   and corvid stores and displays — the vendor, Lakeraven, or each tenant —
   and what does that mean for the build option?

## 8. Decision summary

| Question | Answer |
|---|---|
| Build or buy? | **Buy** the coding brain (vendor adapter behind #460, kept in the private repo per lakeraven-private#20); **build** only the tribal / safety-net claim-assembly layer and consume the ENG-7 loop. |
| Tribal deployments? | **Blocked** until the sovereignty gate passes: in-environment processing or no-retention processing under a BAA, **plus** tribal data-governance authorization. Per-tenant adapter routing is the intended enforcement once ADR 0005 and #264 land. |
| Port semantics? | `nil` = coder could not decide (human review, never billed automatically); `[]` = no codes. |
| Lock-in? | Bounded by the port and contract tests (#460 / #233); the build option is preserved and progressively financed by the denial corpus. |
