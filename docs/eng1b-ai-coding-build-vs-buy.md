# ENG-1B: AI medical coding — build vs. buy

**Status:** Decision draft (ENG-1B, #461)
**Refs:** #460 (agnostic coding/revenue-capture port), #35 (ClearinghouseAdapter in private), #233 (shared adapter contract tests), ADR-0005 (adapter injection), corvid-saas ENG-1 (Stedi live), #463 (ENG-7 payer-rules / denial-pattern layer), lakeraven-private#20 (concrete vendor adapter)

## 1. Problem

Stedi (ENG-1) is the claim *rails*: it moves an already-coded claim to the payer and
brings back 999/277CA/835. The *brain* is missing: given a clinical encounter, produce
correct ICD-10, CPT/HCPCS, and an evidence-based E&M level of service, plus CDI
(documentation-improvement) signals — so the claim that hits the rails is clean and
captures the maximum *legitimate* revenue.

This is existential for the target market. Tribal and safety-net clinics chronically
under-bill; many have **no certified coders at all**. An autonomous coder is not an
optimization there — it is the difference between billing and not billing.

The question: buy a vendor autonomous-coding engine behind the agnostic port defined in
#460, or build one in-house.

## 2. Options

- **Buy:** integrate a vendor autonomous-coding API as a concrete adapter implementing
  the #460 port. The candidate on file (lakeraven-private#20) is a SMART-on-FHIR
  clinical-AI vendor with three modules: CDS/risk scoring, inpatient CDI + coding
  automation with auditable results, and outpatient E&M level-of-service coding. It
  integrates over the same §170.315(g)(10) FHIR surface the whole Lakeraven overlay
  thesis rides, and uses standard terminologies (SNOMED, LOINC, ICD-10, RxNorm).
  "AImedica or similar" — the port keeps us vendor-agnostic; this evaluation is of the
  *category*, with that vendor as the reference candidate.
- **Build:** an in-house coding engine (LLM + rules + terminology services), trained and
  tuned on our own encounter/denial corpus.
- **Hybrid (the recommendation, spoiler):** buy the general-purpose coding brain; build
  the thin tribal/safety-net specialization layer and the denial-feedback loop around
  it — the parts no vendor will ever ship.

## 3. Scoring

| Criterion | Buy (vendor API behind #460 port) | Build (in-house engine) |
|---|---|---|
| **Time-to-value** | **Months.** SMART-on-FHIR delivery means the engine rides the (g)(10) FHIR surface we already expose; the corvid-side work is the #460 adapter + claim-assembly wiring. Revenue recovery for coder-less clinics starts when the adapter ships. | **Years.** A credible autonomous coder needs a large labeled corpus of encounter→code→adjudication outcomes. We have no coding corpus today; our claim volume is pre-revenue. First versions would under-perform a human coder — dangerous in a compliance-sensitive domain (upcoding exposure). |
| **Coverage (ICD-10 / CPT / HCPCS / E&M / CDI)** | **Broad now.** Reference vendor covers inpatient CDI + coding and outpatient E&M level of service with auditable rationale — exactly the #460 port surface (codes + LoS + CDI signals + rationale). Vendors also absorb the brutal annual code-set churn (ICD-10/CPT updates, E&M guideline revisions) as their core business. | **Narrow for years.** E&M leveling alone (2021+ MDM/time rules) is a specialty; CDI is another; inpatient DRG-adjacent coding another. Annual code-set maintenance becomes a permanent internal tax — the same class of burden as the CPT/ACPT BYO problem we already carry on the RPMS side. |
| **Tribal / safety-net fit (IHS/AIR encounters, 100% FMAP, Medicaid-by-state)** | **Zero from any vendor — and that's fine.** No coding vendor knows IHS All-Inclusive Rate (AIR) encounter logic, 100% FMAP pass-through mechanics, or per-state tribal Medicaid quirks (encounter-rate vs FFS, wrap payments, 638-facility billing). But these are *claim-assembly and payer-rules* concerns, not *clinical-coding* concerns: the vendor turns the note into codes; corvid turns codes into the right claim shape for the right payer. This split lands the tribal specialization exactly where #460 and ENG-7 already put it — in our layer, above the port. | **Same work either way.** Building in-house doesn't buy tribal fit — we'd write the same AIR/FMAP/state-Medicaid layer *plus* the general coder underneath it. The specialization layer is ours in both branches; only the giant general-purpose substrate differs. |
| **Cost model** | Per-encounter or subscription API fees; scales with volume, near-zero fixed cost. Fits corvid's recover-and-share-savings RCM posture: vendor cost is a COGS line against measured recovered revenue, priceable into the contingency fee. Margin risk if per-claim fees are high at scale — negotiate volume tiers; the port (#460) keeps switching costs low, which is our leverage. | Heavy fixed cost: ML team, labeled data acquisition, terminology licensing (CPT is AMA-licensed — royalty obligations either way, but vendors already carry the compliance machinery), audit/compliance review of model output. No revenue until it beats the vendor baseline. |
| **Sovereignty / PHI (the OCAP question)** | **The one real risk — gated, not disqualifying.** A commercial cloud AI receiving PHI raises OCAP Access + Possession concerns for tribal data: a third-party engine processing tribal PHI in its cloud requires community authorization, not just a BAA, and de-identification alone is never sufficient. See gate in §4. | **Clean by construction** — an in-house engine can run inside the tribe's or Lakeraven's own environment. This is the strongest argument for build, and it survives as the *contingency*: if no vendor will meet the BYOC/governance gate for tribal accounts, the port lets us ship a self-hosted engine for those tenants only, while vendor-served non-tribal tenants subsidize it. |

## 4. Recommendation: **Buy-first behind the port, with a hard sovereignty gate**

1. **Buy** the general-purpose coding brain: implement the #460 port's concrete vendor
   adapter in lakeraven-private (lakeraven-private#20), mirroring the
   ClearinghouseAdapter-in-private pattern (#35). Corvid stays vendor-free; the adapter
   is injected per ADR-0005 and proven against the shared contract tests (#233). The
   mock adapter satisfies the port for dev/CI.
2. **Build the moat, not the substrate.** In corvid (public, agnostic): the tribal/
   safety-net claim-assembly layer (AIR encounter rates, 100% FMAP routing,
   Medicaid-by-state rules) and the ENG-7 denial-feedback loop (§6). These compound with
   our proprietary data; a generic coder never will.
3. **Sovereignty gate (carried from lakeraven-private#20) — a deployment precondition,
   not a footnote.** Before *any tribal deployment* of a vendor coding engine:
   - Establish the vendor's PHI handling: persist vs. ephemeral processing; training on
     customer data (must be off); subprocessors.
   - Require at least one of: **BYOC** (engine runs in the tribe's/Lakeraven's
     environment), **contractual ephemeral-processing + no-retention** terms under a
     BAA, or (weakest, insufficient alone for tribal data) de-identification.
   - For tribal tenants specifically: **community authorization via the tribe's data
     governance process** is required *in addition to* any technical control — OCAP
     means de-ID/BAA never substitutes for authorization. Expert Determination, not
     Safe Harbor, for any de-ID path.
   - Non-tribal safety-net tenants (standard HIPAA posture) may go live on the vendor
     cloud under a BAA without waiting on the BYOC track.
   - **Per-tenant adapter routing makes the gate enforceable in code:** ADR-0005's
     injection means a tribal tenant can be pinned to a BYOC/self-hosted adapter (or
     the mock, i.e. no AI coding) while other tenants use the vendor cloud adapter.
     The gate is a routing rule, not a policy PDF.
4. **Preserve the build option as leverage.** The port + contract tests mean a future
   in-house or second-vendor engine is a swap, not a rewrite. Revisit build when (a) we
   hold a denial-outcome corpus large enough to train on (ENG-7 accumulates exactly
   this), or (b) vendor economics or the sovereignty gate fail.

## 5. Interface: encounter → codes → claim → Stedi

Flow through the #460 port, end to end:

```
RPMS (or any EHR)
  │  §170.315(g)(10) FHIR — Encounter, Condition, Procedure,
  │  DocumentReference (clinical note), Observation, Coverage
  ▼
corvid: encounter assembly (FHIR bundle for the visit)
  │
  ▼
CodingAdapter port (#460)                        ┌─ concrete impls (lakeraven-private)
  in:  FHIR encounter bundle                     │   • vendor cloud adapter (BAA tenants)
  out: CodedEncounter =                          │   • BYOC/self-hosted adapter (tribal)
       ICD-10 dx, CPT/HCPCS px,        ◄─────────┤   • mock adapter (dev/CI, corvid)
       E&M level of service,                     └─ contract tests #233 assert parity
       CDI signals, per-code auditable rationale
  │
  ▼
corvid claim assembly  ← tribal/safety-net layer applied HERE, above the port:
  │                       AIR encounter-rate vs FFS shaping, 100% FMAP routing,
  │                       Medicaid-by-state rules, payer-rules screens (ENG-7)
  ▼
ClearinghouseAdapter (#35, lakeraven-private) → Stedi (ENG-1, corvid-saas)
  │   837 out;  999 / 277CA / 835 back
  ▼
835 reconciliation + denial capture (feeds §6)
```

Boundary rules restated: the port and its types live in corvid (public, agnostic); every
vendor-specific detail lives in lakeraven-private; RPMS specifics stay in rpms-rpc — corvid
sees only FHIR. CDI signals flow *backwards* to the clinician surface (lakeraven-ehr) as
documentation prompts before claim submission, which is where "max legitimate capture"
is actually won.

## 6. Denials feedback loop (with ENG-7)

The coder must get better on *our* payer mix, which no vendor's general model tracks.

1. **Capture:** every Stedi denial/adjustment (835 CARC/RARC, 277CA rejections) is
   linked back to the originating `CodedEncounter` — including the per-code rationale
   the port requires — giving a labeled record: *codes + rationale + payer + outcome*.
2. **Pattern layer (ENG-7, #463):** the consented payer-rules / denial-pattern layer
   aggregates these into payer-specific rules ("payer X denies 99214 with dx Y absent
   documentation Z"). Consent posture and PHI-minimization for that layer are ENG-7's
   scope, not decided here.
3. **Apply, in order of leverage:**
   - **Pre-submission screens** in corvid claim assembly: ENG-7 rules run over the
     coder's output before the 837 goes out — catches vendor blind spots immediately,
     no vendor cooperation needed. This is the primary loop and it is entirely ours.
   - **Vendor tuning:** feed denial patterns to the vendor where their API accepts
     feedback/appeals signals; track vendor-attributable denial rate per contract
     tests as the ongoing buy-vs-build scorecard.
   - **Corpus accumulation:** the same records become the training corpus that makes a
     future in-house engine viable (§4.4). The feedback loop is how "buy" finances the
     option to "build."

## 7. Decision summary

| Question | Answer |
|---|---|
| Build or buy? | **Buy** the coding brain (vendor adapter behind #460, per lakeraven-private#20); **build** the tribal claim-assembly layer + ENG-7 feedback loop. |
| Tribal deployments? | **Blocked** until the sovereignty gate passes: BYOC or ephemeral-BAA terms **plus** tribal data-governance authorization; enforced per-tenant via adapter routing. |
| Lock-in? | Bounded by the port + contract tests (#460/#233); build option preserved and progressively financed by the ENG-7 denial corpus. |
