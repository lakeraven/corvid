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
Clearinghouse. **Indian health service eligibility is not among them.** [V]

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

### 0.6 The rule is silent on *how* to verify service eligibility electronically

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

### 0.8 A drafting defect worth recording — and it runs in our favour

Raised in review as "the CMS definition is sloppy — a non-Indian mother of an Indian child
is Medicaid-eligible for life." The specific claim does not survive the text, but the
instinct behind it finds a real defect, and a different one. [J]

**What the text actually says.** §447.51 is a closed four-prong list: (1) member of a
federally recognized tribe; (2) resides in an urban center and meets one of four
sub-criteria; (3) considered by the Secretary of the Interior to be an Indian for any
purpose; or (4) "is considered by the Secretary of Health and Human Services to be an
Indian **for purposes of eligibility for Indian health care services**." [V]

A non-Indian woman pregnant with an eligible Indian's child receives IHS services under
§136.12(a) **as a non-Indian**, and explicitly "only during the period of her pregnancy
through postpartum (generally about 6 weeks after delivery)." [V] She is not "considered
to be an Indian," and the eligibility is time-limited on its face. Same structure for
non-Indian household members served to control acute infectious disease or a public health
hazard. Neither is within §447.51, so neither is a specified excluded individual under
§435.554(c)(2). **No lifetime work-requirement exemption arises from the pregnancy
pathway.** [J, from [V] text]

**The defect that is real.** The IFC asserts three separate times that American Indian
status "is not subject to change," and builds the reverification prohibition on it. [V]

**No prong of §447.51 is immutable.** An earlier draft of this section conceded prongs (1)
and (3); that concession was wrong. [J]

| Prong | How it can change |
|---|---|
| (1) member of a federally recognized tribe | **Disenrollment** — a sovereign act nations do exercise. Also relinquishment, which enrollment in another nation generally requires. Also a change in a nation's federal recognition. |
| (2) urban resident, member or 1st/2nd-degree descendant | Residency can end. A state can withdraw state recognition, on which one branch of this prong depends. |
| (3) considered by the Secretary of the Interior to be an Indian for any purpose | The most stable, but still an administrative determination rather than a fact. |
| (4) considered by the Secretary of HHS to be an Indian for purposes of eligibility for Indian health care services | Content lives in §136.12, whose test is "belonging to the Indian community served by the local facilities and program," with §136.12(b) providing for doubtful cases to be revisited. [V] Community regard can lapse; people move. |

So the rule bars states from ever rechecking a status that is contingent on **every** one of
its four pathways — not merely on the fourth.

**But the disjunction absorbs most of it.** §447.51's prongs are joined by "or," and §136.12
operates independently. [V] A person who loses one basis may still satisfy another: a
disenrolled citizen may remain a first- or second-degree descendant of a member, or remain
regarded as Indian by the community where they live. [J] So in practice the *composite*
status is far more durable than any single prong — which is probably what CMS meant and is
certainly not what CMS wrote.

**Two observations, and the second is the one to carry:**

1. **The IFC never cites §136.12.** Zero occurrences. [V] It routes entirely through
   §447.51, whose operative prong for our population is a bare delegation to the
   Secretary's judgment with no test stated in the regulation itself. That is genuinely
   loose drafting, and it is loose at exactly the point this design depends on.
2. **The looseness runs protectively, not fraudulently.** Its effect is that once a status
   is established it is permanent **by rule**. For the people this design serves that is
   the single most valuable property in the whole rule (§0.2), and it is why the
   transaction is once-per-lifetime. We should not advocate tightening it. We should
   record that we noticed, because a reviewer who finds it independently will otherwise
   assume we did not. [J]

Comments on the IFC closed 31 July 2026, so this is a note for the final rule, not a
comment opportunity. **[G]** on whether a final rule is scheduled.

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

### 1.7 The federal definition is broader than tribal citizenship, and the language must never blur them

Raised in review, and it is the most important framing constraint in this document. [J]

**The set relation.** §447.51's prong (2) reaches a person who resides in an urban center and
is a member of "a tribe, band, or other organized group of Indians, **including those
tribes, bands, or groups terminated since 1940 and those recognized now or in the future by
the State in which they reside**, or who is a **descendant, in the first or second degree**,
of any such member." [V] §136.12 adds the community-regard test. [V]

So the federal service-eligible set includes people whom **no federally recognized nation
claims as a citizen**: members of state-recognized tribes, members of terminated tribes,
second-degree descendants, and people recognized by the community they live in rather than
by a roll.

**America's definition is broader than any tribe's, and deliberately so.** It is a service
program discharging a trust obligation to a population, not a membership roster; the urban
provisions exist because federal relocation policy scattered people away from their
nations in the first place. [J] The breadth is not sloppiness in the way §0.8's defect is
sloppiness — it is the point of the program.

**The asymmetry runs opposite to the usual fear.** The historical grievance is federal
definitions being *narrower* and imposed — Dawes rolls, BIA blood quantum, termination.
Here the federal definition is wider. But it is the same objection either way: **a
definition of who is Indian, made somewhere other than by a nation.** [J] If this design is
ever described as verifying who is Indian, that is the objection it will meet, and the
objection will be correct.

Four consequences. The first is a hard rule.

1. **Naming discipline, enforced like §1.5.** The transaction asserts **"eligible for
   services from an Indian health provider."** It never asserts "is Indian," "Indian
   status," "AI/AN status," or "verified AI/AN." This binds field names, feature files,
   OpenAPI descriptions, log lines, commit messages, PR titles, and anything shown to a
   partner or a state. CMS's own text says "status as an American Indian"; **we quote that
   language, we do not adopt it.**
2. **What we may never claim to a tribal partner.** Not "we help the state identify your
   citizens" — the set is not your citizens. The true claim is narrower, and stronger for
   being true: **"your clinic confirms who your clinic serves."**
3. **Over-inclusion is the misuse direction, and it harms nations rather than
   individuals.** A `true` may describe someone a nation does not recognize. So a portable
   credential (§5.4) will not merely be demanded by parties with no right to it — it will
   be **misread as evidence of tribal membership**, over-inclusively, eroding exactly the
   authority to define citizenship that §1.5 protects. This is a sharper version of
   §5.4.4 item 6 and a reason the credential must carry a scoped purpose and be unusable
   outside Medicaid eligibility determination. [J]
4. **It is why federation is architecturally necessary, not merely preferable.** You cannot
   build a registry of a set defined partly by local community regard. The breadth of the
   definition forces locality. [J]

**Disenrollment is the sharpest demonstration of the gap, and the most politically charged
case this design will ever touch.** Because §447.51 is a disjunction and §136.12 operates
independently (§0.8), a person a nation has **affirmatively declared not to be a citizen**
may remain federally service-eligible, and a clinic determination may read `true` for them.
[J]

That is the over-inclusion direction at its most consequential, and it sets a boundary the
design must hold on both sides: the transaction reports **whether a clinic serves someone**,
and it must be incapable of reporting, implying, or being used to infer **what a nation has
decided about its citizenry**. A nation's enrollment decisions are its own; whether a
clinic may still see that person is a separate decision, made by the clinic under federal
rules. We report the second and must never expose the first. §8 item 6 and §5.4.6 are the
mechanisms. [J]

**A noted digression, resolved elsewhere:** community regard can lapse — someone vouched
for in one year may move away the next. That is real, and it is precisely why the IFC's "not
subject to change" premise fails for this prong. See §0.8; it changes nothing here, because
§0.2 forbids the state from rechecking regardless.

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

## 5. The carriers

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

**Recommended as the ex parte carrier.** [J] It is the only one of the first three that is
consumable by a state in 2027 without a standards-change critical path, structurally
satisfies §1.1, and conforms to a federal pattern instead of competing with one. §5.4
is its complement, not its competitor.

### 5.4 Patient-held verifiable credential (holder-mediated)

Added after review raised it. It is not a variant of §5.3 — it inverts who initiates, and
that inversion resolves two things §5.3 cannot. [J]

Shape: the clinic **issues** a signed credential asserting service eligibility; the
**patient holds** it; the state **verifies** it. Issuer / holder / verifier, the standard
three-party model.

#### 5.4.1 What is authoritatively established

- **W3C Verifiable Credentials Data Model 2.0 is a W3C Recommendation, published
  15 May 2025** — the stage at which W3C recommends wide deployment. VCDM 2.1 is a
  Working Draft (11 May 2026) and is **not** the current Recommendation. [V]
- The VC 2.0 family includes Data Integrity, cryptographic suites, JOSE/COSE securing,
  controlled identifiers, and **status lists** for revocation. [V] Revocation is therefore
  a fetched status document, not a ledger (see §5.5).
- **SD-JWT VC** (`draft-ietf-oauth-sd-jwt-vc`) is Standards Track, was in IETF Last Call
  ending 2026-09-15 at draft-19, with expected publication **2026-12-21**. [V] It provides
  issuer-bounded selective disclosure, which is optional in the spec. [V]
- **NIST SP 800-63 Revision 4 is final, published July 2025.** [V] IAL/AAL assurance
  levels referenced anywhere in this design mean Rev 4.
- **There is a health-sector precedent: SMART Health Cards.** The HL7 **SMART Health Cards
  and Links IG, v1.0.0, STU 1**, published by HL7 International / FHIR Infrastructure with
  the Verifiable Clinical Information coalition, Argonaut, and CARIN Alliance. Built on
  FHIR R4, JWS (RFC 7515), JWT (RFC 7519), X.509 and DEFLATE. It defines a
  `$health-cards-issue` operation, and credentials travel as a QR code, a
  `.smart-health-card` file, or an operation response. Stated issuers include labs,
  pharmacies, **healthcare providers**, EHRs, public health departments and immunization
  registries. [V]
  **Caveat on how I read it:** I read the continuous build, which declares itself "not an
  authorized publication." The authorized publication's status is **[G]**.
- **The SMART Health Cards IG specifies no eligibility, coverage, or non-clinical attribute
  profile.** [V] So the framework is reusable; the payload is not defined. We would be
  extending, not conforming — which is a weaker position than §5.3's Emmy conformance and
  should be stated as such. [J]

#### 5.4.2 Government precedent, and its measured limits

- **California Identity Gateway** — a state identity-and-eligibility verification platform
  with a digital wallet pilot, described in the CDT Digital Identification ID Pilot Program
  Report (2026). [V]
- **Utah** has directed its Division of Technology Services to recommend on verifiable
  digital credentials and to create a government pilot. [V]
- **No Medicaid program is known to accept a digital credential for eligibility today.**
  **[G]** — I searched and found none; absence of a search result is not proof of absence.
- **What the Medicaid work-requirement pilots actually do:** Louisiana and Arizona are
  piloting mobile-first tools (one from the nonprofit Digital Public Works) that verify
  **income only**, by connecting to payroll providers. They **cannot confirm exemptions**.
  Louisiana texted 13,000 enrollees; **894 completed — under 7%.** Named limits: rural
  connectivity, enrollee awareness, digital literacy. [V]

That 7% is the most important number in this section. [J]

#### 5.4.3 What it fixes — and these are §10 and §9's hard problems

1. **It dissolves the query-pattern disclosure rather than contracting against it.** §10's
   weakest row is operator audit rights over state-side retention, which has no regulatory
   basis. If the patient presents, **the state asks no one**, so there is no query log on
   either side to govern. [J]
2. **It closes §9 rule 2.** The "state has a person and does not know which endpoint to
   ask" problem disappears without a directory — and therefore without the roll
   reconstructed by another route. [J]
3. **It removes the endpoint-capacity blocker**, which the brief's §5.2 names as the
   binding constraint on federation. Issuance has no uptime, no SLA, no inbound traffic. [J]
4. **It turns the 1 Jan 2028 mandate into the adoption driver.** §435.557(b)(2)(ii) requires
   documentation whenever reasonably available; a clinic-signed credential **is**
   documentation, issued by the authority §447.51's definition chain points at. [J]
5. **Staleness is a near-non-issue here, unusually.** §0.2's reverification prohibition means
   the attribute does not change. Wrongly-issued credentials still need a status mechanism,
   but a status check concerns a *credential*, not a person — a materially smaller
   disclosure than §5.3's per-person query. [J]

#### 5.4.4 What it breaks

1. **It is not ex parte, and the statute's architecture is ex parte.** Section 1902(xx)(5)
   requires verification using reliable information available to the State "without
   requiring additional information from an applicant or a beneficiary." The hierarchy is
   ex parte first, ask the person second. A credential requires the person to act. [V for
   the obligation; J for the consequence]
2. **The burden lands on exactly the wrong people.** See §5.4.2's 7%, and §5.6's measured
   exclusion at national scale. This is the reason §5.4 cannot be the only path. [J]
3. **The trust registry is §9 rule 2 relocated.** Verifiers need to know which issuer keys
   are legitimate. That is a list of Indian health care providers and their public keys —
   a list of *institutions*, not people, and I/T/U facility lists are already public. A
   much better trade than a patient directory, but it re-opens a smaller version of the
   brief's §5.2 operator question. [J]
4. **The regulatory path is more expensive than §5.3's.** Naming a data source in a
   verification plan is ordinary permitted machinery. Getting a state to accept a novel
   credential format is a policy decision with no existing hook: **CMS-2454-IFC contains no
   mention of verifiable credentials, wallets, or digital identity.** [V]
5. **Containers accrete fields.** The moment the credential carries tribe, enrollment
   number, or blood quantum it becomes a *portable enrollment document* — worse than §5.3,
   because it is durable rather than transient. §1.1 and §1.5 are more load-bearing here,
   not less. Selective disclosure helps only if the credential was minimal to begin
   with. [J]
6. **A portable credential can be demanded.** Landlords, employers, other benefit programs,
   law enforcement. A query cannot be demanded of a patient, because the patient is not in
   the loop. This is a new coercion surface that §5.3 does not have, and §5.6 shows it is
   not hypothetical. [J]

#### 5.4.6 Revocation must not become a disenrollment feed

Falls out of §0.8 and §1.7, and it is the credential analogue of §8 item 6. [J]

A credential whose sole claim is service eligibility must **not** be revoked because an
underlying prong changed. If it were, the status list would publish a machine-readable
signal, timed to a nation's governance action, about a named individual — strictly worse
than the query-pattern residue §5.4 was adopted to eliminate.

Revocation is therefore reserved for **issuance error and key compromise**, and nothing
else. Credentials carry no routine expiry that would force re-presentation and
re-determination, which §0.2 makes unnecessary anyway.

The uncomfortable corollary, stated plainly: a credential may remain valid for someone a
nation has since disenrolled. That is the correct behaviour under §1.7 — the credential
asserts what a clinic determined, not what a nation decided — but it is the kind of thing
that must be said out loud to a tribal partner before it is discovered. [J]

#### 5.4.5 Verdict

**Recommended as the documentation-tier carrier, sequenced second.** [J] It shares §5.3's
determination source, one-bit discipline, provenance rule, and enrollment refusal — it is
a second *presentation* of the same core, not a second system.

### 5.5 Why not a distributed ledger

Asked in review, and a reviewer will ask again, so it is answered in the document. [J]

**First, a conflation to clear:** verifiable credentials do not require a blockchain. VCDM
2.0 secures credentials with JOSE/COSE or Data Integrity proofs and handles revocation
through status lists. [V] Nothing in §5.4 implies a ledger. Aadhaar — the largest identity
system ever built — has none either. [V, §5.6]

**Second, the two candidate uses, and why boring infrastructure wins both:**

| Candidate use | Better answer |
|---|---|
| Issuer key registry | A signed trust list over HTTPS, or DNS-anchored keys. Every state can already consume both. |
| Revocation status | The VC 2.0 status-list mechanism — a fetched document. [V] |

**Third, the disqualifying objections, in order of severity:** [J]

1. **Immutability is a liability when the subject has correction rights.** A §136.12
   determination can be wrong and gets corrected; §136.12(b) exists precisely for doubtful
   cases. A permanent, append-only record of who was asserted to be an Indian beneficiary
   is the opposite of what this design needs — and OCAP requires that a community be able
   to *withdraw*. An immutable ledger cannot honour a withdrawal.
2. **A shared ledger is shared custody.** The design's premise is that each clinic retains
   its own record and no one else sees it. A ledger across tribes creates collective
   visibility by construction — it is the central roll with extra steps and worse
   governance.
3. **Correlation.** Even hashed or pseudonymous entries, written per person per event,
   are a permanent public correlation surface against a small population. Small-cell
   suppression exists in `rook` for a reason; a ledger is its negation.
4. **It adds an adoption blocker to a design whose main virtue is cheap consumption.**
   No state eligibility system can consume a chain. §5.3 is one HTTPS client.
5. **It would read as unserious** to CMS and to tribal counsel, and would cost us the
   credibility the rest of this document is trying to earn.

**The one steelman, stated fairly:** an append-only *transparency log* of issuer key
history, Certificate-Transparency-shaped, containing no personal data and only institutional
keys. That is defensible, it is not a blockchain in any useful sense, and it is strictly
optional — it hardens §5.5's trust list without touching patient data. If anyone wants a
ledger-shaped thing, this is the only place one belongs. [J]

### 5.6 What population-scale DPI already measured

Two national systems are directly instructive, one for the primitive and one for the
mechanism. Both are also warnings, and the warnings are quantified. [J for the framing;
[V] for each figure]

**Aadhaar (India) — validates the primitive, indicts the dependency.**

Its core authentication API answers yes/no, with attribute release (eKYC) a separate,
consented operation. The largest identity deployment in history settled on a **boolean**,
and kept authentication architecturally distinct from attribute disclosure. That is §1.1,
independently arrived at, at national scale. [J]

The exclusion evidence: [V]

- Drèze et al., ~1,000 households in 32 villages in Jharkhand — **exclusion errors as high
  as 20%** where biometric authentication was required for every sale.
- State of Aadhaar Report (2020) — **over 30%** of those who hit authentication failure at
  a ration outlet **did not receive rations at all**.
- Right to Food Campaign — **more than 20 starvation deaths** documented in 2017 where
  Aadhaar problems blocked PDS access.
- India's Public Accounts Committee has flagged biometric verification failure excluding
  genuine beneficiaries and called for a review of UIDAI. UIDAI's documented response to
  such reports has been blanket denial.

Causes: fingerprints worn by manual labour, biometric degradation with age, connectivity
gaps, server failures, wrong seeding or linking. [V] **Every one of those maps onto a rural
tribal population.** [J]

Set beside §5.4.2's Louisiana result — under 7% completion — these are two independent
measurements, different continents, different scales, same finding: **a verification rail
that gates benefits excludes at the margin, and the margin is poor, rural, elderly,
disabled and offline.** [J]

Aadhaar is also the canonical case of one identifier becoming a universal key through
seeding across databases — §5.4.4 item 6, realised. [J]

**gov.br (Brazil) — contributes graduated assurance.**

Bronze: account with data validated against tax, social security, or traffic databases.
Silver: facial biometrics against the driver's licence database, or internet-banking
validation, or institutional login. Gold: facial biometrics against the Electoral Justice
database, the national ID QR code, or ICP-Brasil PKI. [V]

The transferable idea is not biometrics. It is that **one service accepts several strengths
of proof rather than mandating one** — which is what §435.557(b)(2)(iii) already requires
when it obliges agencies to accept information other than documentation where none is
reasonably available. Tiering is not a workaround for the rule; it is the rule. [J]

**CadÚnico (Brazil) — the model to refuse, explicitly.**

A single central registry of low-income families, gateway to 30-plus federal programs,
widely regarded as administratively successful. [V] It is also §5.2's federal option taken
to its conclusion: one roll, state-held, as the entrance to all benefits — the thing the
brief says never to ask for.

The distinction to state carefully, because CadÚnico will be raised as a counterexample:
**Brazilians' own state holds their registry; AI/AN people would have a different sovereign
holding theirs.** That is a jurisdictional difference, not a privacy one, and it is why the
comparison fails even where the engineering succeeds. [J]

**From neither system: a universal identifier.** The Aadhaar number and the CPF are what
made both powerful and both dangerous. Facility-scoped HRNs are the correct granularity; a
national AI/AN identifier would be the roll with a primary key. [J]

### 5.7 Precedent a state already accepts: delegated certification

Raised in review, and it is the best state-facing framing in this document, because it is
mundane. [J]

**California smog check.** A licensed private station performs the test. The BAR-97
Emissions Inspection System transmits the result to the **Vehicle Information Database
(VID)**; the VID transmits an electronic certificate of compliance to the **DMV**, which
relies on it for registration. The station also hands the customer a **Vehicle Inspection
Report (VIR)** and keeps a copy. The Bureau of Automotive Repair licenses stations and
technicians, and the VID tracks station and technician data. [V]

So a state agency already gates a benefit on an assertion made by a distributed network of
accredited non-state parties, consuming a pass/fail rather than the underlying
measurements. "You already do this for cars" is a cheaper opening with a state Medicaid
agency than any argument from first principles. [J]

**The structural observation worth more than the rhetoric: smog check runs both of this
document's carriers at once.** The electronic certificate to DMV is the ex parte path
(§5.3). The VIR in the customer's hand is the holder-mediated path (§5.4). The same system
does both, for the same determination, and neither is considered redundant. That is the
two-tier recommendation in §6, already deployed at scale in an unrelated domain. [J]

**Where the analogy breaks, and it matters:** **BAR licenses the stations.** The state is
the accreditor. A state Medicaid agency cannot be the accreditor of tribal clinics — I/T/U
status is federal and sovereign, and a state licensing tribal health programs to speak
about their own patients inverts the sovereignty the design exists to protect. [J]

**Design consequence for §5.5's trust list:** the issuer trust anchor must be **federal
(the IHS/I/T/U facility list) or tribal — never a state**. Each state verifies against a
list it does not control. Record this as a constraint, not a preference.

Also: the subject of a smog check is a car. No privacy interest, no sovereign, no
query-pattern disclosure. The analogy is for the state-facing pitch and for the two-path
structure. It carries nothing into §10. [J]

---

## 6. Recommendation

| | §5.1 X12 270/271 | §5.2 FHIR CoverageEligibility | §5.3 Minimal API | §5.4 Held credential |
|---|---|---|---|---|
| Exists today, authoritatively specified | **Yes** [V] | Yes, ML2 Trial Use [V] | Yes, CC0 federal precedent [V] | Yes — VCDM 2.0 Rec. [V] |
| Semantic fit | Inverts roles; no slot | I/T/U as insurer | Direct | Direct |
| Boolean + provenance + timestamp | **No** — free text only [V/J] | Partly (`inforce`) [V] | Yes | Yes |
| Leak surface beyond §1.1 | Benefit/plan context | Coverage implication | Minimal | Minimal, but **durable** |
| Operator-agnostic | Poor | Moderate | Yes | Yes — no endpoint at all |
| Standards critical path | X12 ECO + rulemaking — **misses 2028** [J] | HL7 profile authoring | None | Payload profile; SD-JWT VC RFC due 2026-12-21 [V] |
| Regulatory hook | n/a | n/a | **Exists today** | Policy decision; rule is silent [V] |
| Ex parte? | yes | yes | **yes** | **no** — person must act [V] |
| Query-pattern leak (§10) | contractual | contractual | contractual | **none** |
| §9 directory problem | unsolved | unsolved | unsolved | **solved** |
| Endpoint capacity needed | yes | yes | yes | **no** |
| Coercible from the patient | no | no | no | **yes** |
| State-side change | Largest | Medium | Smallest | Medium |
| Tribal-side change | Largest | Medium | Small | Smallest |

**Build §5.3 and §5.4, in that order, as two presentations of one determination.** [J]
§5.3 is the ex parte tier the statute prefers and has a regulatory hook today. §5.4 is the
documentation tier that the 1 Jan 2028 mandate creates demand for, and it is the only
option that dissolves §10's query-pattern residue and §9's directory problem. Neither is
sufficient alone — §5.6's measured exclusion is why.

**Specify the determination-read layer once, carrier-agnostically.** Both carriers share
the same source (RPMS `1111`/`1112`), the same one-bit discipline, the same
provenance-names-the-clinic rule, and the same enrollment refusal. Only the presentation
differs.

### 6.1 Tier the evidence; never remove the floor

From §5.6's gov.br finding and §435.557(b)(2)(iii), which already obliges agencies to accept
information other than documentation where none is reasonably available: [V for the
obligation; J for the ladder]

| Tier | Evidence | Carrier |
|---|---|---|
| 1 | Clinic-signed credential | §5.4 |
| 2 | Clinic response to an ex parte query | §5.3 |
| 3 | Existing AI/AN data already on the state application | status quo |
| 4 | **Self-attestation** | status quo — and NCUIH's actual ask of CMS [V] |

**Strengthen the top; never remove the bottom.** A design that displaces tier 4 argues
against the advocacy organizations whose support this needs, and §5.6 shows what happens
when a verification rail becomes the only path. Our claim is that tiers 1–2 *reduce how
often* tiers 3–4 are reached — not that they replace them. [J]

### 6.2 On self-attestation and citizenship — the sovereignty argument this design wins

Raised in review: a person should not be able to claim citizenship of another sovereign as
a matter of course, and Indian Country has an unresolved problem with false claiming.

Both true, and **neither is what this transaction does.** §435.554(c)(2) asks whether a
person is eligible for services from an Indian health provider — a determination made by a
*facility*, not citizenship conferred by a *nation*. So the design threads between the two
failure modes that otherwise bracket this problem: [J]

- **Pure self-attestation** lets an individual assert a relationship to a sovereign that
  the sovereign never confirmed.
- **Enrollment verification** asks a nation to confirm its citizenry to a state.

A clinic assertion does neither. It also already embeds community judgment rather than
individual claim — §136.12's test is whether the person "is regarded as an Indian by the
community in which he/she lives." [V]

**What this design does not solve, and must not claim to:** false claiming of Indian
identity generally — in employment, grants, admissions, the arts, academia. That is
governed elsewhere, by nations, and §1.5 and §13 keep this work out of it. Being clear
about the boundary is what makes the narrower claim credible. [J]

**Carry §5.1.5 as a separate, smaller work item** — the State→provider 271 that reports the
established exclusion and cost-sharing exemption back to I/T/U clinics. It is independently
useful, it is the brief §2.1 "value if the date moves" increment, and it requires nothing
from tribal infrastructure. [J]

**Treat the Hub as the destination, not the competitor.** §435.557(e) means that if CMS
ever puts AI/AN verification on the Hub, every State must migrate to it within 12 months.
A design that is a §435.557(b)(1)(ii) source today and a Hub-backed source later is the
same transaction with a different base URL — *provided* §9 holds. [J]

---

## 7. What the state eligibility system must do (§5.3, the ex parte tier)

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

## 8. What the tribal endpoint must expose (§5.3)

1. One authenticated route answering §2's question for one named individual.
2. A read of the determination already recorded at RPMS registration — file #9000001,
   fields `1111` / `1112` only, never `.07` / `1108` / `1109` / `1110` (§11 item 3). Field
   `1108` TRIBE OF MEMBERSHIP would move on a disenrollment; `1111` / `1112` need not.
   Reading the enrollment fields would make the endpoint sensitive to a nation's governance
   actions, which is §1.7's prohibition expressed as a field list.
3. A query log the operator can read: requesting state, agreement reference, subject token,
   timestamp, answer returned, `messageId`. Pattern after
   `Corvid::BillingTransaction.log_transaction!`. [V, repo]
4. Revocation: per-requester credentials the operator can withdraw unilaterally, without
   coordinating with us or with any other operator. [J]
5. Nothing else. No search, no list, no batch, no "patients matching" endpoint, no
   reporting surface over the query log beyond the operator's own view.
6. **An immutable first answer.** On any repeat query about the same subject, the endpoint
   returns the **original** answer with its **original** timestamp, or refuses — it must not
   perform a fresh determination.

   Reason, and it is not fastidiousness: §0.8 establishes that every prong can change, and
   disenrollment is one way (§1.7). If the endpoint re-determined on each call, a state
   that asked twice could observe the bit change — and a change in that bit, for this
   population, is readable as a tribal governance action leaking through a Medicaid API.
   §0.2 forbids the state from re-asking, so the hole is mostly closed by regulation; but a
   guarantee that depends on the consumer obeying someone else's rule is not a guarantee.
   **Enforce §0.2 at the source.** [J]

   This also makes the endpoint idempotent, which is independently worth having.

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

(§5.4 largely dissolves this section; see §5.4.3 item 1. These controls govern the ex parte
tier, which ships first and is the one the statute prefers.)

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
3. **[Partially closed] The RPMS field holding the §136.12 / §447.51 determination.**
   Established from `rpms-rpc/lib/rpms_rpc/api/tribal.rb`, whose field numbers are recorded
   there as verified against the FOIA data dictionary and the live DD (per `rpms-ops`
   `docs/REGISTRATION_RPC_CONTRACTS.md` §5 and the `AGED1.m`/`AGED2.m` field maps). File
   **#9000001 IHS PATIENT (`^AUPNPAT`)**: [V, repo]

   | Field | Name | Class |
   |---|---|---|
   | `.07` | TRIBAL ENROLLMENT NO. | enrollment — **do not read** |
   | `1108` | TRIBE OF MEMBERSHIP (→ TRIBE #9999999.03) | enrollment — **do not read** |
   | `1109` | TRIBE QUANTUM | descent — **do not read** |
   | `1110` | INDIAN BLOOD QUANTUM | descent — **do not read** |
   | **`1111`** | **CLASSIFICATION/BENEFICIARY** (→ BENEFICIARY #9999999.25) | the determination |
   | **`1112`** | **ELIGIBILITY STATUS** (set `I`/`D`/`C`/`P`) | the determination |
   | `1118` | CURRENT COMMUNITY | context |

   Reads run on the generic FileMan RPCs (`DDR GETS ENTRY DATA` / `DDR LISTER` /
   `DDR VALIDATOR`) via `RpmsRpc::DdrFileman`, returning `GETS^DIQ` internal/external
   pairs. [V, repo]

   **That the determination and the enrollment data sit in adjacent fields of the same file
   is the central implementation hazard.** §1.5's rule must become a test that fails if
   `.07`, `1108`, `1109` or `1110` appear anywhere in the read path.

   **Still open — and now the first question in the findings report:** the semantics of
   `1112`'s `I`/`D`/`C`/`P` set. If ELIGIBILITY STATUS encodes direct-care versus
   purchased/referred-care *scope* rather than the §136.12 beneficiary determination, then
   `1111` is the only correct field and `1112` is a decoy. **[G]** — not guessed here.
   Also open: how both fields behave at a site that has never curated them, and across
   FileMan versions in the wild. **[G]**
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
10. **[G] The authorized-publication status of the HL7 SMART Health Cards and Links IG.**
   I read the continuous build, which declares itself "not an authorized publication"
   while reporting v1.0.0 / STU 1. The balloted artifact's status is unestablished. [V on
   what the build says; G on the publication]
11. **[G] Whether any Medicaid or CHIP program accepts a digital credential for
   eligibility today.** I searched and found none; state activity I did find is
   identity-and-wallet infrastructure (California Identity Gateway and its wallet pilot;
   Utah's directed pilot), not benefit-attribute credentials. Absence of a result is not
   proof of absence.
12. **[G] Whether any payload profile exists anywhere for an eligibility or coverage
   attribute as a verifiable credential.** The SMART Health Cards IG specifies none. [V]
   If one exists, we conform instead of authoring — the same move the Emmy finding bought
   for §5.3, and worth one more search before §12 step 3.
13. **[G] Wallet and device reality for the served population.** §5.6 quantifies the
   failure mode at national scale and §5.4.2 at pilot scale, but neither measures *our*
   population. Smartphone penetration, connectivity, and wallet viability across
   participating sites is a field question, and §5.4 should not be scoped before someone
   answers it.
14. **[G] Whether a final rule following CMS-2454-IFC is scheduled** (§0.8).

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
7. **§5.4 credential track, after §5.3 ships and not before.** Sequencing reason, not
   preference: §5.3 has a regulatory hook today and §5.4 needs a state policy decision, so
   building §5.4 first means asking for the harder thing with nothing deployed. Two
   prerequisites that are not ours: §11 item 12 (does a payload profile already exist) and
   §11 item 13 (device and connectivity reality at participating sites). The trust-anchor
   constraint from §5.7 — federal or tribal, never a state — is settled and does not need
   re-litigating.

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
- **Any distributed ledger or blockchain** (§5.5). The sole exception a reviewer may raise
  is an append-only transparency log of *institutional issuer keys*, carrying no personal
  data; that is optional hardening of §5.5's trust list and nothing more.
- **A universal AI/AN identifier** of any kind, national or cross-site (§5.6). Facility-
  scoped HRNs are the correct granularity.
- **Displacing self-attestation** (§6.1 tier 4). The design reduces how often it is
  reached; it does not replace it, and must not be sold as replacing it.
- **False claiming of Indian identity outside Medicaid** — employment, grants, admissions,
  the arts, academia (§6.2). Governed by nations, elsewhere.
- Advocating that CMS tighten the §447.51 definition or the reverification prohibition
  (§0.8). We record the defect; we do not campaign against a provision that protects the
  people this serves.
- Biometric identity proofing of any kind. §5.6's exclusion evidence is specifically
  biometric, and nothing here requires it.
- **Describing this transaction as verifying who is Indian** (§1.7). Not in code, not in a
  PR title, not in a deck. The assertion is service eligibility, determined by a facility.
- **Policing, reporting, or enabling inference of enrollment or disenrollment** (§1.7,
  §8 item 6, §5.4.6). A nation's decisions about its citizenry must not be observable
  through this transaction, including by repeated querying or by revocation timing.
- **Any use of the transaction or credential outside Medicaid or CHIP eligibility
  determination** (§1.7 consequence 3). Because the federal set over-includes relative to
  tribal citizenship, reuse elsewhere is not merely out of scope — it is wrong, and wrong
  in the direction that undermines nations' authority to define their own citizenry.

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

- W3C Verifiable Credentials Data Model **2.0**, W3C Recommendation, 15 May 2025
  (v2.1 is a Working Draft, 11 May 2026, and is not the Recommendation)
- IETF `draft-ietf-oauth-sd-jwt-vc` (SD-JWT VC), Standards Track, Last Call to 2026-09-15,
  expected publication 2026-12-21
- NIST SP 800-63 Revision 4, final, July 2025
- HL7 SMART Health Cards and Links IG v1.0.0 / STU 1 — **continuous build read, not the
  authorized publication**
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

Comparative and empirical:

- Drèze et al., Jharkhand household survey (biometric authentication exclusion);
  State of Aadhaar Report 2020; Right to Food Campaign 2017 documentation; India's
  Public Accounts Committee review of UIDAI
- gov.br assurance tiers (bronze / silver / gold); Cadastro Único and Bolsa Família
- KFF Health News on Louisiana and Arizona Medicaid work-requirement technology pilots
  (income-only verification; 894 of 13,000 completion)
- California Department of Technology, Digital Identification ID Pilot Program Report
  (2026); Utah Division of Technology Services verifiable-credential pilot direction
- California Bureau of Automotive Repair Smog Check Manual / Reference Guide
  (licensed station → VID → DMV certificate of compliance; customer-held VIR)
- CMS Transmittal R13839OTN (CR 14473), TCEDI as Part A/B MAC X12 production translator
- This repository: ADR 0002, ADR 0003, `Corvid::BillingTransaction`,
  `Corvid::Adapters::Base#check_eligibility_detailed`
