# Spec — AI/AN service-eligibility verification as an eligibility-rail transaction

Status: **draft, for review. No implementation authorized.** Target: a reviewer decides
which of the three carriers in §5 we build to, and whether §9's operator-agnostic seam
holds. The first step in §12 is a findings report, not code.

Scope: how to express "is this person eligible for services from an Indian health
provider?" as a transaction a state Medicaid eligibility system can already consume,
so that the H.R. 1 community-engagement exclusion can be verified without inventing a
proprietary API and without moving any roll, cohort, or clinical record.

Source: an internal architecture brief, §§5.1–5.3. That brief is off-git and not in this
repository; its section numbers are cited below for traceability by the team that holds it.
Conventions follow `rook/docs/specs/federation-openehr-careteam.md`.

---

## Confidence flags

Every substantive claim below carries one. They are not decoration — the brief's own
§9 records that a fabricated interface is the main delivery risk here.

- **[V]** **Verified** — read directly from the cited primary source in this pass
  (Federal Register full text, eCFR, HL7 specification page, a published companion
  guide, or a repository I inspected). Quotes are exact.
- **[J]** **Judgment** — my reasoning from verified facts. Contestable. Argue with it.
- **[G]** **Gap** — I could not establish this. §11 lists what I searched and where the
  paywall or absence sits. **Nothing in this document invents an X12 segment, an X12
  code value, a FHIR profile, or CMS guidance.**

---

## 0. Why this document exists, and what changed since the brief

The brief was written 2026-09-25 and records at §2.1 and §9 item 4 that "CMS has issued
no implementation guidance — so the interface we would build to has not been specified."

**That is now out of date, and the correction changes the design.** [V]

CMS published **CMS-2454-IFC, "Medicaid Program; Community Engagement Requirement for
Certain Individuals," 91 FR 33348 (June 3, 2026)** — an interim final rule with comment
period, amending 42 CFR parts 431, 435, 438, 457, and 600, with States required to
implement no later than 1 January 2027. [V] It was preceded by CMCS Informational
Bulletin of 8 December 2025. [V]

Seven findings from that rule reshape the problem. All seven are [V] unless marked.

### 0.1 The determination is service eligibility, and the rule says so

New **§435.554(c)(2)** defines a specified excluded individual as one who
"meets the definition of Indian at § 447.51 of this subchapter." [V]

**42 CFR 447.51** (verified against eCFR as of 2026-09-01):

> *Indian* means any individual defined at 25 U.S.C. 1603(13), 1603(28), or 1679(a), or
> who has been determined eligible as an Indian, under 42 CFR 136.12.

…and its prong (4): "Is considered by the Secretary of Health and Human Services to be
an Indian for purposes of eligibility for Indian health care services, including as a
California Indian, Eskimo, Aleut, or other Alaska Native." [V]

**42 CFR 136.12** is the IHS "Persons to whom services will be provided" regulation.
Its operative test is community regard, determined by the facility: [V]

> Generally, an individual may be regarded as within the scope of the Indian health and
> medical service program if he/she is regarded as an Indian by the community in which
> he/she lives as evidenced by such factors as tribal membership, enrollment, residence
> on tax-exempt land, ownership of restricted property, active participation in tribal
> affairs, or other relevant factors…

and §136.12(b) assigns doubtful cases to "the medical officer in charge."

**This is the brief's §5.1 thesis, now with a regulatory citation chain:**
§435.554(c)(2) → §447.51 → §136.12. The determination that controls the exclusion is one
prong of which is *made by the health facility at registration*, and tribal enrollment is
listed in §136.12 as merely one piece of evidence among several, not the test. [V]
The integration surface is the health system. [J]

### 0.2 The rule prohibits reverification

Preamble, discussing the exclusion: [V]

> Notably, unlike other exclusions which may change from month to month or be
> time-limited, States will not be required to (and **may not**) reverify someone's
> status as an American Indian for exclusion from the community engagement requirement.

And the rule encourages States to prefer this exclusion over others precisely because
"American Indian status is not subject to change and therefore does not need to be
reverified." [V] American Indians are also exempt from the new 6-month renewal cycle for
the adult group and stay on 12-month renewal. [V]

**Design consequence:** the transaction is **once per person, for life** — not once per
renewal and not monthly. [J] Volume is a function of the unverified backlog plus new
applications, not of the enrolled population times twelve. That makes a federated,
low-capacity endpoint (brief §5.2) viable where a monthly-recheck design would not be,
and it strips away the main argument for bulk anything. [J]

### 0.3 The rule points at a federal conduit, which answers the brief's top unknown

Brief §9 item 1 asks whether CMS is extending the Data Services Hub. The rule's
direction of travel is explicit: [V]

> we expect to provide States information related to community engagement through the
> Hub and/or another Federally operated electronic service. Once those data sources are
> established, States will be required to access that information through the Hub or
> another Federal service, unless the State has approval to use an alternative mechanism.

**§435.557(e)** requires States to connect to a new Hub data source "as soon as
practicable, but no later than 12 months after their initial availability." [V]
**§435.949** already compels Hub use where information is available there. [V]
**§435.945(k)** is the escape hatch — an alternative source or mechanism, "subject to
approval by the Secretary," judged on reducing administrative cost and burden "while
maximizing accuracy, minimizing delay, meeting applicable requirements relating to the
confidentiality, disclosure, maintenance, or use of information." [V]
**§435.557(e)(1)** adds that CMS may deem the waiver unnecessary where the State connects
"from certain alternative Federal electronic services, such as the Emmy API." [V]

The named data sources CMS has lined up so far are the VA and the National Student
Clearinghouse. **AI/AN status is not among them.** [V]

### 0.4 CMS has already built and open-sourced the shape of the answer

**`github.com/CMSgov/emmy-api`** — "An API that provides a unified, standard interface to
the data sources needed to verify community engagement for the purpose of evaluating
Medicaid eligibility." License **CC0-1.0**. Inspected 2026-09-30. [V]

Its published OpenAPI (`api-spec/v0/dist/openapi.bundled.yaml`) is exactly the transaction
family we need, for two sibling exclusions: [V]

- `POST /api/v1/veteran-disability-ratings` and `POST /api/v0|v1/education-enrollments`
- request body: an identity object (`firstName`, `lastName`, `dateOfBirth` required;
  `oneOf` → `ssn` or `address`)
- response: boolean indicators plus effective dates plus provenance — e.g.
  `totalDisabilityStatusIndicator: true`, `totalDisabilityEffectiveDate: "2023-01-01"`,
  `responseMetadata: { responseCode, responseText }`, and a `data_source` enum whose
  current members are exactly `National Student Clearinghouse` and `Veterans Affairs`
- auth: OAuth 2.0 **client-credentials only**, scope `emmy-api/emmy-api-access`
- a `messageId` UUID header on every response, server-generated, for tracing
- batch endpoints exist for education (`/batch-education-enrollments`), i.e. CMS itself
  draws the per-person/bulk line per data source

**The repository description now begins `[DEPRECATED]`** (as of the 2026-09-30 inspection),
consistent with public reporting that CMS is consolidating Emmy API work into the Federal
Data Services Hub. [V] The *code* is being retired; the *interface contract* is the
precedent, and it is CC0. [J]

### 0.5 The documentation cliff is 1 January 2028, not 1 January 2027

Beginning 1 January 2028, where no reliable information is available to the State or it is
not reasonably compatible with what the individual reported, States "must generally
require that the individual provide documentation when such documentation is reasonably
available." [V] For 2027, the rule tells States to "use these existing data collected on
the application and follow their existing verification policies." [V]

**Design consequence:** the coverage-loss cliff the brief is aimed at lands a year later
than the brief assumes, and the forcing event is the documentation requirement, not the
requirement's start date. [J] That *helps* the sequencing worry in brief §10.1: there is a
real 2027 window to get a data source approved before paper becomes mandatory. [J]

### 0.6 The rule is silent on *how* to verify AI/AN status electronically

The IFC contains **no** reference to X12, to the 270/271 transaction, to IHS data, to
tribal health systems, or to an I/T/U data path. The only instruction is "existing data
collected on the application" and "existing verification policies." [V]
Search-engine summaries circulating on this rule assert that it requires tribal
enrollment documents or BIA-issued documents; **that language is not in the rule text I
read** and should not be repeated. [V]

So there is no interface to conform to — and no interface to be pre-empted by. [J]
The §435.557(b)(1)(ii)/(iii) route (below) is open on its own terms.

### 0.7 The actual regulatory hook is small, specific, and already exists

"Reliable information available to the State" is defined in the preamble to include
"information from electronic data sources that the agency has determined effective
consistent with § 435.557(b)(1)(ii), and as documented in the agency's verification plan
in accordance with § 435.557(b)(1)(iii)." [V] And: [V]

> States must have a process to obtain the information defined as reliable information
> available to the State without seeking information from the individual. The process may
> be automated, such as through an **Application Programming Interface (API)** or other
> electronic interface or could require a worker to manually obtain the information from
> its source.

**That is the hook.** [J] A tribal AI/AN service-eligibility endpoint does not need new
CMS guidance, a new statute, or a Hub slot to be lawful for a State to use. It needs:
a State that determines the source effective under **§435.557(b)(1)(ii)**, names it in the
**§435.945(j)** verification plan per **§435.557(b)(1)(iii)**, executes the written
agreement required by **§435.945(i)**, and exchanges over a secure electronic interface
per **§435.945(h)**. If and when CMS puts AI/AN data on the Hub, **§435.557(e)** then
obliges the State to migrate within 12 months, or seek **§435.945(k)** approval to keep
the direct connection. [V for each citation; J for the composition]

---

## 1. Inviolable constraints

Read these before §5. They come from the brief and are not design latitude.

### 1.1 The response is boolean plus provenance plus timestamp

One bit, who asserted it, and when. **No enrollment roll. No demographics in the
response. No bulk extract. No cohort. No clinical data. No reason codes that narrate
which §136.12 prong was satisfied** — the last one is an addition and it is deliberate:
"determined under §136.12(a)(2) community regard" versus "member of a federally
recognized tribe" is a distinction that re-creates an enrollment disclosure inside a
boolean API. [J]

### 1.2 Operator-agnostic

Brief §5.2 has not decided between federated (each tribe or 638 facility), a tribal
organization operating centrally, and CMS extending the Hub. **The transaction must be
identical in all three.** Any design where the operator's identity appears anywhere but
the provenance field and the endpoint's network address has failed this test. [J] §9 is
the conformance argument.

### 1.3 Queries travel; data does not; the source sees every query

Same commitment as `rook`'s federation layer. The determination stays in RPMS at the
facility that made it. The endpoint reads and answers; it does not replicate. Every
inbound query is logged at the source, attributable to a requesting State and a named
agreement, and visible to the operator. [J]

### 1.4 Nothing accumulates a derived AI/AN cohort on the state side

Brief §5.3. The state retains the determination against the individual record. §10
specifies the controls and which of them are regulation rather than contract.

### 1.5 Do not model tribal enrollment, descent, or citizenship

As `rook` §1.2 refuses to model Indigenous clinical content, this spec refuses to model
Indigenous citizenship. **Specifically: do not use the HL7 US Core tribal-affiliation
extension** (`http://hl7.org/fhir/us/core/StructureDefinition/us-core-tribal-affiliation`,
introduced US Core 6.0.0, present through 9.0.0). It carries a `tribalAffiliation`
CodeableConcept bound (preferred) to the v3 `TribalEntityUS` value set — BIA-recognized
tribal entities — plus an optional `isEnrolled` boolean. [V]

It is a real, published, standards-track element, it is in USCDI, and it is **the wrong
one**. It names the nation and asserts enrollment; §435.554(c)(2) asks neither. Using it
would transmit precisely the citizenship signal §1.1 and brief §5.1 exist to avoid, and
would make the endpoint an enrollment oracle by accident. [J] Its existence is a trap, not
an opportunity.

### 1.6 Corvid holds the transaction, never the determination

ADR 0003 (PHI tokenization): "No `corvid_*` table contains … Patient names, dates of
birth, MRNs, SSNs"; acceptance criterion is that a corvid database dump reveals no PHI.
[V, repo] ADR 0002 makes Tenant a hard isolation boundary. [V, repo]

So: corvid may carry the protocol, the inbound query log (tokenized subject, requesting
state, agreement reference, timestamp, outcome), and the audit surface. The determination
is read through the adapter seam from RPMS and **is not persisted by corvid**. Corvid's
existing `Corvid::BillingTransaction` already models exactly this shape — a tokenized
request/response audit row for clearinghouse traffic — and is the obvious parent pattern.
[V, repo] [J for the conclusion]

---

## 2. What the transaction actually is

Stated once, carrier-independent, so §5 can be compared against it:

| | |
|---|---|
| **Question** | Does the responding Indian health care provider hold a current determination that this individual is eligible for services from an Indian health provider, within the meaning of 42 CFR 447.51? |
| **Asker** | A State Medicaid or CHIP eligibility agency (or its systems integrator acting for it under a §435.945(i) agreement) |
| **Answerer** | An Indian health care provider or a body operating on its behalf — I/T/U per 42 CFR 447.51's "Indian health care provider" definition [V] |
| **Subject** | One named individual, supplied by the asker |
| **Answer** | `true` / `false` / `unknown`, plus asserting-party identity, plus assertion timestamp |
| **Frequency** | Once per individual, for life (§0.2) |
| **Legal basis for the asker** | 42 CFR 435.557(b)(1)(ii)–(iii), 435.945(h)–(k) |
| **Legal basis for the answerer** | Not a HIPAA standard transaction (§5.1.2); disclosure analysed under 45 CFR 164.506/164.512(k) or a §435.945(i) agreement — **[G], see §11** |

Note what is *not* in that table: any statement about the individual's tribe, enrollment,
descent, degree, residence, clinical history, or which §136.12 prong applied.

---

## 3. The asymmetry that most analysis gets wrong

Worth isolating before comparing carriers, because it decides the X12 question. [J]

Today's eligibility rail runs **provider → payer**: an I/T/U clinic sends a 270 to the
State Medicaid agency and gets a 271 back. The thing we need runs the **other way**:
the State (payer, and here also the eligibility determiner) asks the clinic (provider)
about a person-level attribute that is not a benefit plan.

That is not a variant of the existing transaction. It is its inverse, on both axes:
direction *and* subject matter. [J] Everything in §5.1 follows from this.

---

## 4. Evaluation criteria

1. **Does the carrier exist today, authoritatively specified, without us inventing
   structure?** (§1 risk, brief §9 item 4.)
2. **Can a state eligibility system consume it in 2027** with a system change of a size a
   state will actually fund inside an existing MES work order?
3. **Does it carry boolean + provenance + timestamp *structurally*** — machine-readable,
   not free text?
4. **Does it leak more than §1.1 permits**, by construction or by convention?
5. **Is it operator-agnostic** (§1.2)?
6. **What is the standards-change critical path**, measured against 1 Jan 2027 / 1 Jan
   2028?

---

## 5. The three carriers

### 5.1 X12 270/271 — Health Care Eligibility Benefit Inquiry and Response

#### 5.1.1 What is authoritatively established

- The HIPAA standard for the eligibility transaction is **ASC X12N/005010X279** (TR3,
  April 2008), per 45 CFR 162.1202(b)(2)(ii), carried forward by (c) and (d)(2)(ii). [V]
- **It is not changing in our window.** 162.1202(c) runs through 14 August 2027,
  (d) covers 14 August 2027 – 14 April 2028, and (e) applies (d)(2) thereafter — and
  (d)(2)(ii) names the *same* 005010X279. Only the NCPDP retail-pharmacy standard changes
  at those dates. Any claim that 270/271 is being re-versioned in 2027–28 is wrong. [V]
- **The Information Source is a payer.** In a real, published state Medicaid companion
  guide (Wisconsin DHS P-00267, ForwardHealth), loop 2100A `NM101` Entity Identifier Code
  is `PR` — "Enter 'PR' to indicate payer" — with the payer's own name in `NM103`. [V]
- Observed `EB01` (Eligibility or Benefit Information) values in that guide: `1` active
  coverage, `6` inactive, `T` card lost/stolen, `R` other or additional payor, `U` contact
  following entity, `MC` managed care, `N` services restricted to the following provider
  (lock-in), with `A`/`B`/`C` for amounts. `EB02` = `IND`. `EB03` carries Service Type
  Codes, repeating up to 12. `EB04` Insurance Type Code. `EB05` Plan Coverage Description
  is a free-text plan name. [V]
- **There is precedent for carrying an exemption in a 271 — as free text.** The same guide
  emits, literally: `MSG*HPSA RECIPIENT, COPAY EXEMPT~`. [V] That is a cost-sharing
  exemption riding the `MSG` (Message Text) segment.
- 270/271 content and infrastructure are further constrained by **CAQH CORE** operating
  rules, authored under **ACA §1104** and mandatory for HIPAA-covered entities since
  1 January 2013; CORE-certified entities' 270/271 companion guides "must follow the
  format/flow as defined in the CAQH CORE Master Companion Guide Template." [V]
- New structured code values are obtainable: X12 runs a **Code Maintenance Request**
  process (`x12.org/maintenance-requests`), with the External Code List Oversight (ECO)
  subcommittee governing external lists and a separate request form per external list. [V]

#### 5.1.2 HIPAA does not mandate X12 here, and this is the pivotal finding

**45 CFR 162.1201** defines the transaction: [V]

> (a) An inquiry **from a health care provider to a health plan, or from one health plan
> to another health plan**, to obtain any of the following information about **a benefit
> plan for an enrollee**: (1) Eligibility to receive health care under the health plan.
> (2) Coverage of health care under the health plan. (3) Benefits associated with the
> benefit plan.
> (b) A response from a health plan to a health care provider's (or another health plan's)
> inquiry described in paragraph (a).

Our transaction is a state agency asking a provider about a statutory person-attribute.
Wrong direction, wrong parties, and not "information about a benefit plan for an enrollee."
**It falls outside §162.1201 entirely.** [J, from [V] text]

Two consequences, and they point the same way:

1. **No legal obligation to use 270/271.** The compliance argument for X12 — "you must,
   it's HIPAA" — does not apply. [J]
2. **Using it anyway means role-inverting a mandated standard.** The tribal endpoint would
   have to present itself as `NM101=PR`, a payer, which an I/T/U is not; and the State's
   eligibility system would have to emit a 270 as a provider, which it is not. Every
   downstream CORE-certified validator, clearinghouse, and trading-partner agreement in
   the path is built around those roles. [J]

#### 5.1.3 Could the exemption be carried in existing segments?

Honestly: **the only place it fits today is free text, and free text fails §1.1.** [J]

- `MSG` segment — proven to work for exactly this class of fact (`HPSA RECIPIENT, COPAY
  EXEMPT`) [V]. But it is unstructured, not machine-parsed without per-payer string
  matching, and carries no provenance or assertion timestamp. It would reduce a statutory
  exclusion to a string match. [J]
- `EB05` Plan Coverage Description — same objection; it is a plan name field. [V/J]
- `EB03` Service Type Codes — describes *services*, not person attributes. Mapping
  "IHS-service-eligible" onto a service type code is a category error that would break
  every consumer that reads EB03 for its actual purpose. [J]
- `EB01` — I cannot responsibly propose a value. The complete `EB01` code list lives in
  the TR3, which is paywalled. **[G] — see §11.** I will not guess one, and a guessed
  `EB01` value is the single most likely way this document could do damage.
- A structured carrier would require a **code maintenance request** through the X12 ECO /
  CMG process [V]. Its cycle time, and whether a new value could reach a HIPAA-adopted
  TR3 (which requires rulemaking to adopt, per the 162.1202 history) before 1 Jan 2028:
  **[G]**, but the 162.1202 amendment dates (2009 → 2024 → 2025) suggest the answer is
  "not in this window." [J]

#### 5.1.4 What each side would have to do

- **State eligibility system:** become a 270 *sender* in a provider role toward a non-payer
  trading partner — new trading-partner setup, new companion guide ingestion, and a
  271 parser that reads either free text or a code value that does not yet exist. It would
  also have to route around its existing clearinghouse, since this traffic is not
  clearinghouse traffic. [J]
- **Tribal endpoint:** implement a 005010X279A1-conformant 271 generator, assert `NM101=PR`
  falsely, publish a CORE-template companion guide, and likely obtain CORE certification to
  be trusted. For a facility that brief §5.2 concedes "cannot today" run an endpoint at
  all, this is the heaviest of the three options by a wide margin. [J]

#### 5.1.5 Where 270/271 *is* the right answer — a separate, real deliverable

The inverse flow already exists and is unblocked. Once a State has established the
exclusion, it is the **payer**, and it can carry the resulting status back to I/T/U
providers in the 271 it already sends them — which is exactly the shape of
`MSG*HPSA RECIPIENT, COPAY EXEMPT~`. [V/J]

That is worth naming because it is independently valuable, it is the 100%-FMAP and
cost-sharing-exemption use case the brief's §2.1 says to sequence first, and it requires
nothing from the tribal side. **It is not the verification path, and conflating the two is
the error this section exists to prevent.** [J]

#### 5.1.6 Verdict

**Reject as the primary carrier.** It inverts a mandated standard's roles, it is not
legally required for this transaction, it has no structured slot for the fact, and its
standards critical path exceeds the deadline. Keep §5.1.5 as a separate work item. [J]

### 5.2 FHIR CoverageEligibilityRequest / CoverageEligibilityResponse

#### 5.2.1 What is authoritatively established

- Both resources are FHIR R4, **Maturity Level 2, Trial Use**. [V]
- `CoverageEligibilityRequest` scope: "makes a request of **an insurer** asking them to
  provide … (validation) whether the specified coverage(s) is valid and in-force;
  (discovery) what coverages the insurer has for the specified patient; (benefits) the
  benefits provided under the coverage." Required: `status`, `purpose` (1..*), `patient`,
  **`insurer` (1..1)**. [V]
- `CoverageEligibilityResponse` has `outcome` (queued|complete|error|partial),
  `disposition`, and `insurance.inforce`, a `0..1 boolean`: "Flag indicating if the coverage
  provided is inforce currently if no service date(s) specified or for the whole duration
  of the service dates." `purpose = validation` means "validation that the specified
  coverage is in-force at the date/period specified." [V]

#### 5.2.2 The relationship to CMS-0057-F is: none

This matters, because "CMS-0057-F mandates FHIR APIs by 2027" is the argument most likely
to be made for this option, and it does not survive contact with the rule. [J]

CMS-0057-F is **89 FR 8758 (8 February 2024)**, FR document 2024-00895. I searched its
full text. [V]

- Occurrences of `CoverageEligibility`: **zero**. [V]
- It mandates four APIs — Patient Access, Provider Access, Payer-to-Payer, Prior
  Authorization — for MA organizations, state Medicaid/CHIP FFS, Medicaid managed care,
  CHIP managed care, and FFE QHP issuers. Eligibility inquiry is not among them. [V]
- Commenters asked CMS to fold eligibility in. CMS declined: commenters suggested "the
  Provider Access API can potentially replace the need for a separate 270/271 transaction,"
  and CMS responded "we did not propose any related policies." [V]
- Its FHIR work is prior authorization (Da Vinci, X12 278), not eligibility. [V]

So **CMS-0057-F creates no FHIR eligibility obligation and no FHIR eligibility endpoint on
any payer.** It does mean impacted Medicaid agencies will have FHIR server capability and
SMART/OAuth infrastructure in place by 1 Jan 2027 — which is a real, if indirect, argument
for a FHIR-shaped payload. [J]

#### 5.2.3 Semantic fit

Poor, and in a way that cannot be patched. [J] `CoverageEligibilityRequest.insurer` is
`1..1` and the scope statement is "a request of an insurer." To use these resources, the
tribal health provider must be modelled as an **insurer**, and IHS service eligibility
must be modelled as a **Coverage** that is **in force**. That is the same role inversion as
§5.1, carried into FHIR, with the added cost that `inforce` means "this coverage pays" —
a claim an I/T/U endpoint is not making and must not be read as making. [J]

#### 5.2.4 The FHIR resource that does fit — and its maturity problem

**`VerificationResult`** is semantically almost exactly §2's answer: `target` (the resource
validated), `status` (attested | validated | in-process | req-revalid | val-fail |
reval-fail), `statusDate`, `validationType` (nothing | primary | multiple),
`validationProcess`, `primarySource`, `attestation`, `validator`. HL7's stated purpose is
recording "validation requirements, source(s), status and dates for one or more elements…
to be able to determine the likely accuracy of the content." [V]

Boolean-by-status, provenance via `primarySource`/`validator`, timestamp via `statusDate`.
Nothing about tribes, enrollment, coverage, or payment. [J]

**Its problem: Maturity Level 0.** [V] A ML0 Trial Use resource is a weak foundation for a
transaction that gates people's health coverage, and no state eligibility system consumes
it today. [J]

#### 5.2.5 What each side would have to do

- **State:** a client against an endpoint it does not already treat as a payer, plus a
  SMART/OAuth trust relationship with each operator; it inherits no reusable
  CMS-0057-F plumbing because no 0057-F API carries this. [J]
- **Tribal endpoint:** a FHIR server with one operation. Materially lighter than §5.1,
  heavier than §5.3. [J]
- Either way, **we would be authoring a profile or an operation definition.** §1 forbids
  inventing a profile in this document; it does not forbid *proposing that one be authored
  through HL7*, which is a different and legitimate act with a stated owner and process. [J]

#### 5.2.6 Verdict

**Reject `CoverageEligibilityRequest`/`Response` on semantics.** Retain
`VerificationResult` as the **payload vocabulary** for §5.3 — borrow its element names and
status semantics without requiring a FHIR server or betting on a ML0 resource. [J]

### 5.3 Purpose-built minimal API — which is not a fallback

The brief listed this third, as the fallback. The Emmy finding inverts that. [J]

CMS has already built the "purpose-built minimal API" for this exact regulatory purpose,
for two sibling exclusions in the same rule, and released it CC0 (§0.4). [V] A new
transaction that matches that contract is not proprietary and is not an invention — it is
**conformance to the federal pattern for ex parte verification of a specified excluded
individual status**, which is a far better position than either §5.1 or §5.2 affords. [J]

#### 5.3.1 Shape

Follow the Emmy contract, element-for-element where it exists, and borrow
`VerificationResult` vocabulary where it does not:

- `POST` of an identity object. Emmy's required trio is `firstName`, `lastName`,
  `dateOfBirth`, with `oneOf` → `ssn` or `address`. [V]
- Response carries a status indicator, an effective date, a `dataSource`, and
  `responseMetadata { responseCode, responseText }`. [V]
- Server-generated `messageId` UUID per response, returned in a header. [V]
- OAuth 2.0 client-credentials, one client per requesting State agency. [V]
- **Deliberate divergences from Emmy, each justified:** [J]
  - no `address` fallback — SSN-or-nothing matching, because demographic matching against
    an Indian health population produces false positives with sovereignty consequences,
    and a near-match is a disclosure
  - no batch endpoint, ever (§1.1; Emmy has one for education, we must not)
  - `dataSource` names the *asserting provider or operating body*, not a vendor —
    this is the §1.2 seam and the provenance requirement in one field
  - `unknown` is a first-class answer distinct from `false`, because "we hold no
    determination" and "we determined this person is not service-eligible" are different
    facts and conflating them causes wrongful disenrollment [J]

Concrete field definitions are **deliberately not written here.** §12 step 3 authors them,
after step 1's findings report closes §11's gaps. Writing a schema now would be the
fabrication this document's constraints forbid.

#### 5.3.2 What each side would have to do

- **State:** one HTTPS client with client-credentials OAuth, one new field in the
  eligibility record, one entry in the §435.945(j) verification plan. This is the smallest
  state-side change of the three by a large margin — and if the State already integrated
  the Emmy API for VA or NSC data, it is a new base URL and a new client registration
  against a contract its vendor has already implemented. [J]
- **Tribal endpoint:** one authenticated POST route, a read of the existing RPMS
  registration determination, a query log, and no persistence of the determination.
  Deployable by a site with the capacity brief §5.2 describes as the binding constraint. [J]

#### 5.3.3 Verdict

**Recommended carrier.** [J] It is the only one of the three that is consumable by a state
in 2027 without a standards-change critical path, structurally satisfies §1.1, and
conforms to a federal pattern instead of competing with one.

---

## 6. Recommendation

| | §5.1 X12 270/271 | §5.2 FHIR CoverageEligibility | §5.3 Minimal API (Emmy-shaped) |
|---|---|---|---|
| Exists today, authoritatively specified | **Yes** [V] | Yes, ML2 Trial Use [V] | Yes, as a CC0 federal precedent [V] |
| Semantic fit | Inverts roles; no slot for the fact | Requires modelling I/T/U as insurer | Direct |
| Boolean + provenance + timestamp, structurally | **No** — free text only [V/J] | Partly (`inforce`) [V] | Yes |
| Leak surface beyond §1.1 | Benefit/plan context by construction | Coverage/payment implication | Minimal by design |
| Operator-agnostic | Poor — payer identity is structural | Moderate | Yes — one provenance field |
| Standards critical path | X12 ECO + HIPAA rulemaking — **misses 2028** [J] | HL7 profile authoring | None |
| State-side change | Largest | Medium | Smallest |
| Tribal-side change | Largest | Medium | Smallest |

**Build §5.3, with `VerificationResult`'s vocabulary, as an electronic data source under
42 CFR 435.557(b)(1)(ii) named in the State's §435.945(j) verification plan.** [J]

**Carry §5.1.5 as a separate, smaller work item** — the State→provider 271 that reports the
established exclusion and cost-sharing exemption back to I/T/U clinics. It is independently
useful, it is the brief §2.1 "value if the date moves" increment, and it requires nothing
from tribal infrastructure. [J]

**Treat the Hub as the destination, not the competitor.** §435.557(e) means that if CMS
ever puts AI/AN verification on the Hub, every State must migrate to it within 12 months.
A design that is a §435.557(b)(1)(ii) source today and a Hub-backed source later is the
same transaction with a different base URL — *provided* §9 holds. [J]

---

## 7. What the state eligibility system must do (recommended carrier)

1. Determine the source effective under §435.557(b)(1)(ii) and document it in the
   verification plan per §435.557(b)(1)(iii) / §435.945(j). [V for the obligation]
2. Execute a written agreement with "appropriate safeguards limiting the use and disclosure
   of information" — §435.945(i). [V] This is where §10's controls live.
3. Exchange over a secure electronic interface as defined in §435.4 — §435.945(h). [V]
4. Inform the individual that the agency will obtain and use information available to it —
   §435.945(f). [V] Not optional, and worth noting because it is the only point in the flow
   where the individual learns a tribal endpoint was queried.
5. Store **the determination**, against the individual record. Not the query, not a flag
   that means "we asked a tribal endpoint about this person." (§1.4, §10.)
6. **Never reverify** — §435.554(c)(2) per the §0.2 preamble prohibition. [V] A state
   system that re-queries at each renewal is non-conformant with the rule, not merely
   impolite.

## 8. What the tribal endpoint must expose

1. One authenticated route answering §2's question for one named individual.
2. A read of the determination already recorded at RPMS registration. The authoritative
   RPMS field(s) and the RPC path to them: **[G]**, §11 — this is step 1 of §12 and it is
   the one gap that blocks implementation outright.
3. A query log the operator can read: requesting state, agreement reference, subject token,
   timestamp, answer returned, `messageId`. Pattern after
   `Corvid::BillingTransaction.log_transaction!`. [V, repo]
4. Revocation: per-requester credentials the operator can withdraw unilaterally, without
   coordinating with us or with any other operator. [J]
5. Nothing else. No search, no list, no batch, no "patients matching" endpoint, no
   reporting surface over the query log beyond the operator's own view.

---

## 9. Operator-agnosticism — the §1.2 conformance argument

Brief §5.2's three models must be indistinguishable to the state client. [J] The test:

| | Federated (per tribe / 638) | Tribal organisation (e.g. NIHB) | CMS Hub |
|---|---|---|---|
| Base URL | per-operator | one | Hub endpoint |
| Request body | identical | identical | identical |
| Response schema | identical | identical | identical |
| `dataSource` value | the asserting provider | the asserting provider | the asserting provider |
| Who holds the record | the facility | the facility | the facility |
| Who sees the query | the facility | facility **and** the organisation | facility **and** CMS |
| Credential issuer | the operator | the organisation | CMS |
| State's reg. basis | §435.557(b)(1)(ii) | §435.557(b)(1)(ii) | §435.949 |

Two design rules fall directly out of that table, and they are the whole of §1.2's
engineering content: [J]

1. **`dataSource` names the asserting provider, never the operator.** If a tribal
   organisation or CMS relays the answer, the provenance field still names the facility
   that holds the determination. Otherwise federating later, or centralising later,
   silently rewrites history in the state's record.
2. **Discovery is out of band.** No registry endpoint, no "which endpoint serves this
   person" lookup. A directory that maps individuals to tribal endpoints *is* the
   enrollment roll we refused to build, reconstructed by a different route. How a State
   knows which endpoint to ask is a governance question for brief §5.2, and the answer
   must not be a query against this transaction. [J]

Rule 2 is the uncomfortable one. It means the recommended design does **not** solve "the
State has a person and does not know which tribe to ask." §11 records that as an open
problem, not a solved one.

---

## 10. What the state retains — the §5.3 controls

Brief §5.3 requires that no derived AI/AN cohort accumulate on the state side. Separating
what regulation already gives us from what must be contracted matters, because the brief
says to raise this in writing first, and a list that overstates the regulatory baseline
will not survive a tribal partner's counsel. [J]

| Control (brief §5.3) | Status |
|---|---|
| State retains the determination, not a derived cohort | **Contract.** The rule requires retention *of* the determination (§435.557 verification record); it says nothing against also retaining the query. [V/J] |
| No secondary use of query logs | **Contract.** §435.945(i) requires agreements with "appropriate safeguards limiting the use and disclosure"; the specific prohibition is ours to write. [V/J] |
| Operator holds audit rights over **state-side** retention | **Contract, and the hard one.** Nothing in part 435 gives a data source audit rights over a State's retention. This has to be negotiated and is the clause most likely to be resisted. [J] |
| Retention period specified and enforced | **Contract.** Default state record schedules will otherwise apply. [J] |
| Individual is told | **Regulation** — §435.945(f). [V] |
| Secure interface | **Regulation** — §435.945(h), §435.4. [V] |
| Written agreement exists at all | **Regulation** — §435.945(i). [V] |

Three further points, which are ours and not in the brief: [J]

- **§0.2 helps more than any contract clause.** Because the State may not reverify, the
  conformant query volume is one per person, once. A design that cannot re-ask cannot
  accumulate a longitudinal query pattern.
- **The `unknown` answer is the leak.** A `false` or `unknown` for a person the state
  nonetheless believes may be AI/AN is the §5.3 disclosure in its purest form — the state
  learns the *absence* of a determination, which is information about the individual's
  relationship to the Indian health system that no one asserted. The agreement must treat
  `unknown` as creating no record beyond "not verified by this means."
- **We should ask for query-log symmetry.** The operator's log and the state's log describe
  the same events; the operator having a right to compare them is cheaper to agree now than
  to retrofit, and is the only practical enforcement of the four contract rows above.

---

## 11. Gaps — what I could not establish, and what I searched

Listed because brief §9 item 4 is right that an unadmitted gap is the failure mode here.

1. **[G] The complete X12 `EB01` / `NM101` (2100A) code lists, and whether any existing
   value fits.** The TR3 (005010X279A1) is sold by X12 / Washington Publishing Company and
   is not publicly readable. I read what free, authoritative sources show of real usage —
   Wisconsin DHS P-00267 (ForwardHealth companion guide), and the search result set for the
   CMS HETS 270/271 companion guide, the CMS MMSEA §111 companion guide, and the CAQH CORE
   Eligibility & Benefits Data Content Rule EB.1.0. A commercial clearinghouse's web
   rendering of X279A1 requires JavaScript and returned no content to a fetch. **I did not obtain the
   normative code lists, and I have not proposed a value.**
2. **[G] X12 ECO/CMG cycle time**, and whether a new code could reach a HIPAA-adopted TR3
   before 1 Jan 2028. The request process is verified to exist; its timeline is not.
3. **[G] The authoritative RPMS field and RPC that hold the §136.12 / §447.51
   determination.** This is step 1 of §12 and the only gap that blocks implementation.
   Not researched in this pass — it is an `rpms-rpc` / `lakeraven-ehr` question, not a
   standards question.
4. **[G] The HIPAA Privacy Rule basis for the tribal endpoint's disclosure.** Whether this
   is 45 CFR 164.512(k) (government programs providing public benefits), 164.506
   (health care operations), an authorization, or a §435.945(i) agreement acting as the
   vehicle. Not researched. It gates §7 step 2 and should be the second question a lawyer
   is asked.
5. **[G] Whether CMS has published a process for onboarding a *non-federal* data source to
   the Hub.** §435.557(e) and §435.949 assume CMS establishes the connection; nothing I
   found describes a tribal or third-party path onto the Hub.
6. **[G] How a State determines which endpoint to ask** (§9 rule 2). Open problem, by
   design rather than by oversight.
7. **[G] Current state practice** — brief §9 item 2, how AHCCCS or any state verifies AI/AN
   status today. Not researched here; it is BD research, and the IFC's "follow their
   existing verification policies" makes it a *per-state* answer rather than one answer.
8. **[Partially G] TCEDI.** I verified CMS Transmittal **R13839OTN**, CR 14473, issued
   25 June 2026, implementation 31 December 2026: "Implementation of The Technical
   Consolidation of the Electronic Data Interchange (TCEDI) as the **Production Translator
   for Inbound and Outbound X12 Transactions for Part A/B MACs**." [V] I could **not**
   verify, in this pass, a contractor announcement of 30 September 2026 describing seven
   consolidated contractor systems, one billion claims annually, or visibility into claims,
   remittance advice and eligibility inquiries. Those figures are reported to us secondhand
   and are not established here.
   **The inference TCEDI supports is narrow and should be stated narrowly:** federal
   eligibility-adjacent plumbing is X12-based and consolidating. It is *Medicare Part A/B
   MAC* X12 translation. It is **not** Medicaid eligibility determination, it is not a
   state-facing rail, and it does not make 270/271 the right carrier for §2's transaction —
   §5.1.2 is the reason, and TCEDI does not touch it. [J]
9. **[G] CMS voluntary module pre-certification requirements** — brief §9 item 5. Not
   researched. It decides packaging, not protocol.

---

## 12. Sequence

**Step 1 is a findings report. No code until it is reviewed.**

1. **Findings report** (`docs/specs/aian-eligibility-verification-findings.md`), closing
   §11 items 3 and 4 and nothing else:
   - the RPMS field(s) and RPC path that hold the §136.12 / §447.51 determination, how
     FileMan represents it across versions in the wild, and what a site that has never
     curated it actually contains
   - the Privacy Rule basis for the disclosure, stated as a question for counsel with the
     candidate provisions named
   - a one-page restatement of §2's table with those two rows filled in
   This is a read-only research pass against `rpms-rpc` and a staging RPMS. It produces a
   document, and it is where the design either survives or is revised. If the
   determination is not reliably recorded at registration across real sites, §0.1's thesis
   is weaker than the brief believes and the whole design changes.
2. **Correct the source brief.** Its §2.1 and §9 item 4 say CMS has issued no
   implementation guidance. §0 of this document supersedes that, and §0.5's 1 Jan 2028
   documentation cliff changes its §10.1 sequencing argument. Whoever holds that brief
   should update it before it is relied on again.
3. **Interface definition.** Only after step 1. The OpenAPI document and the
   `VerificationResult`-derived payload vocabulary, with every field traced to either the
   Emmy contract [V] or a `VerificationResult` element [V]. Reviewed by a second vendor
   lens before any implementation, per `SOFTWARE-FACTORY.md` step 0.
4. **Governance review before implementation, not after.** Brief §5.2's operator question
   and §5.3's retention terms, taken to NIHB/NCUIH as the brief's §10.2 step 6 directs.
   §9's two design rules and §10's contract rows are the specific artifacts to take into
   that room. The §10 table is drafted so that it can be handed over as-is.
5. **Reference implementation**, federated shape, in corvid, behind the §1.6 boundary:
   protocol and query log in corvid, determination read through the adapter, nothing
   persisted. Gate seat authors the feature files and failing tests first.
6. **The §5.1.5 companion item** — State→provider 271 reporting of the established
   exclusion — scoped separately once step 1 lands. It shares none of this design's
   blockers.

Steps 1 and 2 are cheap and can run now. Steps 3–6 should not start before step 1 is
reviewed, and step 5 should not start before step 4, for the reason brief §5.3 gives:
OCAP-compatible by construction is a different artifact from OCAP-compatible until
someone looks closely.

---

## 13. Explicitly out of scope

- **Tribal enrollment, descent, citizenship, blood quantum, or membership** in any
  representation. Including the US Core `tribalAffiliation` extension and its `isEnrolled`
  boolean (§1.5), and including as an optional field, a debug field, or a reason code.
- **Which §136.12 prong was satisfied.** The answer is one bit (§1.1).
- Any bulk, batch, list, search, cohort, or reporting endpoint — even though the Emmy
  precedent includes one for education data (§5.3.1).
- A registry or directory mapping individuals to tribal endpoints (§9 rule 2).
- Authoring an HL7 FHIR profile or an X12 segment, code value, or external code list
  entry in this repository. Proposing that one be authored through HL7 or X12, with the
  owner and process named, is in scope; writing one here is not.
- Deciding who operates the endpoint. That is brief §5.2, it is a governance decision, and
  §9 exists so that this design does not need the answer.
- The state-side user experience, notices, and appeal path when the answer is `false` or
  `unknown`. Real, consequential, and not a protocol question.
- CMS voluntary module pre-certification packaging (§11 item 9).
- Medicare claims EDI, TCEDI integration, and anything on the Part A/B MAC rail
  (§11 item 8).
- Changes to corvid's PHI tokenization boundary (ADR 0003) or tenancy model (ADR 0002).
  If this design appears to require one, the design is wrong.

---

## 14. Primary sources

Statute and regulation, read directly:

- CMS-2454-IFC, *Medicaid Program; Community Engagement Requirement for Certain
  Individuals*, 91 FR 33348 (June 3, 2026), FR doc 2026-11094 — full text
- 42 CFR 435.554(c)(2), 435.557(b)(1)(ii)–(iii) and (e), 435.945(f)–(k), 435.949 — eCFR
- 42 CFR 447.51 (*Indian*, *Indian health care provider*) — eCFR
- 42 CFR 136.12 (*Persons to whom services will be provided*) — eCFR
- 45 CFR 162.1201, 162.1202 — eCFR
- CMS-0057-F, 89 FR 8758 (February 8, 2024), FR doc 2024-00895 — full text
- CMCS Informational Bulletin, December 8, 2025 (cited in the IFC; PDF did not render)

Standards and specifications:

- HL7 FHIR R4 `CoverageEligibilityRequest`, `CoverageEligibilityResponse`,
  `VerificationResult`
- HL7 US Core `us-core-tribal-affiliation` (STU 9 / v9.0.0; introduced 6.0.0)
- ASC X12N/005010X279A1 TR3 — **paywalled, not read** (§11 item 1)
- Wisconsin DHS P-00267, ForwardHealth 270/271 companion guide
- CAQH CORE Eligibility & Benefits (270/271) rules; CORE Master Companion Guide Template
- X12 Code Maintenance Request process; External Code List Oversight (ECO) subcommittee

Code and precedent:

- `github.com/CMSgov/emmy-api`, CC0-1.0, OpenAPI `api-spec/v0`, inspected 2026-09-30
  (repository description marked `[DEPRECATED]`)
- CMS Transmittal R13839OTN (CR 14473), TCEDI as Part A/B MAC X12 production translator
- This repository: ADR 0002, ADR 0003, `Corvid::BillingTransaction`,
  `Corvid::Adapters::Base#check_eligibility_detailed`
