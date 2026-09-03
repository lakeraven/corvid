# Corvid as a Workforce Chassis: Fit Assessment and Module Design

**Status:** Proposed design — for review before any implementation issue is opened
**Date:** 2026-09-03
**Scope:** A second domain on the Corvid engine — training/workforce case
management (learner enrollment, cohort referrals, braided-funding
authorizations and obligations, coaching tasks and teams, selection
committees, placements) — plus a crisis-navigation case type with an HSDS
resource-directory adapter.

This document answers a specific ask: *does the Corvid chassis generalize
cleanly to a second, non-health domain, and what would the module look like?*
The upstream architecture it implements is HumaneFrame
([humaneframe.org/tech/architecture](https://humaneframe.org/tech/architecture),
CC BY-SA 4.0), whose Phase 0 needs no AI: verified capability (a learner-owned
credential ledger), made portable (open credential standards), matched to real
demand (a job marketplace), with humans coaching in between. Corvid is proposed
as the operational middle of that system. The learner ledger and the
marketplace are **out of scope** for Corvid; this design treats both as
external systems reached through adapters.

Names in this document are synthetic ("Example Nation", "the Nation's
workforce department"). Funding programs cited are public federal statutes
(WIOA §166, P.L. 102-477, TANF, Perkins §117, DOL Registered Apprenticeship).

---

## 0. Summary of conclusions

| Question | Short answer |
|---|---|
| Does the chassis generalize? | The **tenancy, tokenization, `Case`/`CaseProgram`/`ProgramRegistry`, `Task`, `CareTeam`, `Determinable`, `RulesEngine`, and the append-only approval-event pattern** generalize as-is or with renames. **`PrcReferral`, `EligibilityChecklist`, `AlternateResourceCheck`, `CommitteeReview`, the adapter's budget/EDI/clinical surface, and the MLR/CMS stack are a first vertical, not a chassis** — they must not be stretched to fit. |
| Module shape | A separate engine gem, `corvid-workforce` (`Corvid::Workforce::*`, tables `corvid_wf_*`), depending on `corvid`. Mounted alongside `corvid` by a host app. |
| Hard case | Braided funding is **not** payer-of-last-resort with more payers. It is *N funders × M cost categories with per-category sequencing, per-funder eligibility, caps and budgets*, producing an allocation set that is approved as a unit and obligated per line. Design in §3. |
| Pre-1.0 core changes | Adapter role interfaces; `subject_identifier`/`actor_identifier` naming; `Case` must stop knowing `prc_referrals`; polymorphic `CommitteeReview`; data-driven checklist; a core lifecycle event log; actor kind (`human`/`system`/`agent`). List in §4. |
| Tokenization | ADR 0003 holds with a workforce token-kind set (§5). The "dump reveals no PII" property holds **only if** the module does not port `patient_name_cached`, tokenizes coaching notes, and never stores DOB, SSN, addresses, or wages joined to an identity. Add a CI dump test. |
| Weaver/HSDS | A `crisis_navigation` case type with deterministic triage (versioned ruleset), an HSDS read adapter (offline-cacheable reference data), and warm-handoff tasks whose terminal state is human-confirmed. §6. |
| Event sourcing | **Event-logged state machines**, not full event sourcing: an append-only `corvid_transitions` log is the record of truth for lifecycle; AASM status columns are projected caches; `on_provenance` becomes a subscriber. Full event sourcing only inside the external ledger. ADR 0007 (proposed). |
| Effort | ~20–25 engineer-weeks for a Phase 0 deployment supporting one 15–20-learner cohort with braided funding (ledger and marketplace external). ~10–12 weeks for a minimal single-funder launch. §7. |

---

## 1. Fit assessment

Method: for each chassis concern, read the code (not the README) and ask
what a workforce deployment would have to *pretend* to use it. The worst
outcome is credential/competency semantics forced into claims-shaped models,
so §1.3 names the specific places that would happen.

### 1.1 Generalizes as-is (or with a rename)

| Concern | Evidence | Verdict |
|---|---|---|
| **Tenancy** (`TenantScoped`, `TenantContext`, ADR 0002) | Row-based `tenant_identifier` + optional `facility_identifier`; fail-loud default scope; host owns Tenant/Facility metadata. | **As-is.** Nation/program → tenant; chapter houses, college sites, employer sites → facilities. Cross-facility reporting within a Nation is exactly the ADR 0002 sharing rule. |
| **`Case` + `CaseProgram` + `ProgramRegistry`** | `ProgramRegistry.register(code, milestones:)` was built precisely so "non-IHS programs can enroll without engine forks". `ProgramTemplateService` materializes milestone `Task`s. | **As-is for the enrollment spine.** A learner's enrollment in a pathway is `Case` + `CaseProgram(program_code: "coder_pathway")`; the pathway's milestone ladder (prep modules, practice exams, exam sitting, apprenticeship start) is a `ProgramRegistry` entry. **Rename needed:** `Case.patient_identifier` → `subject_identifier` (§4). **Fix needed:** `lifecycle_status` is unenforced (#507) and workforce leans on it. |
| **`Task`** | Polymorphic `taskable`, milestone fields, assignee token, due/overdue/complete. | **As-is** for coaching to-dos and quests. Smells: the priority enum is clinical (`routine/urgent/asap/stat`); `description` is plaintext (fine for template text, not for coaching narrative — that goes in `notes_token`); `assignee` resolves via `find_practitioner`. |
| **`CareTeam` / `CareTeamMember`** | Free-text `role`, lead flag, dates, tenant-scoped team. | **As-is** as the coach–mentor–navigator team. `name`/`description` are plaintext (team names are not PII; keep them template-shaped). |
| **`Determinable` / `Determination`** | Outcome + `decision_method` (`automated`/`staff_review`/`committee_review`) + actor token + `reasons_token`. | **As-is** for funding-eligibility and selection determinations. **Not** for competency claims or endorsements (§1.3). |
| **`RulesEngine`** | Pure DAG-of-facts evaluator with `failed_facts` explanations; ruleset is an injected plain class. | **As-is, and it is the best-fitting piece.** One ruleset per funding source (WIOA §166, 477/TANF, Perkins) yields eligible/ineligible with reasons — deterministic and explainable, which is exactly what "AI proposes, humans adjudicate" requires. |
| **Append-only approval events** (`ManagementApprovalEvent`) | Immutable rows (`readonly?` when persisted), server-set `occurred_at`, `checklist_version_hash` binding the approval to the content approved; approve-then-alter invalidation. | **Generalize.** This is the exact shape a funding authorization needs (approval bound to a digest of the allocation set). It should become the core lifecycle log (ADR 0007), not stay PRC-only. |
| **`ApprovalAuthority`** | Per-tenant grantee registry with progressive gate (no-op until configured). | **Generalize roles.** `ROLES` is hard-coded to `prc_director`/`delegated_approver`. Workforce needs `program_director`, `fiscal_officer`, and *source-scoped* approvers. |
| **Tokenization discipline** (ADR 0003, `phi_sanitizer`, `store_text`/`fetch_text`) | Vault = adapter; prefixed ULIDs; fail-safe redact-all sanitizer. | **As-is in principle**; needs a workforce token-kind set and a registry instead of the hard-coded clinical kinds (§5). |
| **Money** (ADR 0004, `CurrencyImmutable`) | Integer cents + per-row currency. | **As-is.** Obligations and reimbursements are money; multi-currency is irrelevant but harmless. |
| **Host hooks** (`Corvid.configure`) | Adapter, sanitizer, provenance lambdas. | **As-is in shape**, wrong in granularity — one global adapter (§1.2, §4). |

### 1.2 PRC-shaped — do not reuse, learn from

| Concern | Why it does not transfer | What to do |
|---|---|---|
| **`PrcReferral` AASM** | The pipeline encodes 42 CFR 136: alternate-resource review, medical priority 1–4, committee threshold, 72-hour emergency notification, CHS status sync to the EHR. Every guard is domain law. | Build `Workforce::FundingRequest` with its own AASM. Copy the *pattern* (submit → eligibility review → approval → authorize, with dual control and digest-bound approval), not the class. |
| **`EligibilityChecklist`** | Seven fixed boolean columns that are PRC audit categories. Workforce needs a different checklist **per funding source** (e.g. §166: Indian status, age, low-income/underemployed, selective service; 477/TANF: benefit status; Perkins: college enrollment). | Core gets a data-driven `Checklist` (definition in a registry, items as rows) that keeps the digest + approve-then-alter guard. PRC can migrate to it or keep its table. |
| **`AlternateResourceCheck` / payer-of-last-resort** | Resource types are Medicare/Medicaid/private insurance; `verify_eligibility(person, resource_type)` is an insurance-coverage query; the logic is "prove every other payer is exhausted, then one payer pays". Braided funding is *several funders paying concurrently for different cost categories*, with sequencing per category. Payer-of-last-resort is the degenerate case (one category, ordered list). | New `FundingAllocation` model + deterministic `BraidPlanner` (§3). Do not add funders to `RESOURCE_TYPES`. |
| **Budget / obligations via adapter** | In PRC the EHR (RPMS) is the system of record for money; the adapter exposes `get_budget_summary`/`create_obligation`/`record_payment` and `PrcObligation` is an *import mirror*. In workforce there is no accounting system behind Corvid for participant-level obligations — **Corvid is the obligation ledger.** | First-class `Workforce::Obligation`/`Expenditure` engine models, event-logged, with optional export to the Nation's finance system. This inverts a PRC assumption and is the single biggest fit gap. |
| **`CommitteeReview`** | `belongs_to :prc_referral`; money amounts; `apply_to_referral!` drives the PRC AASM; medical priority. | Make `reviewable` polymorphic (pre-1.0), or the module ships `SelectionReview`. Cohort selection and apprenticeship placement committees are generic "panel reviews a subject and records a decision with rationale". |
| **Adapter `Base`** | ~50 methods: patient/practitioner/referral/vault/budget/site params/care team/clinical reads/eligibility/tribal enrollment/EDI/payments. A workforce deployment implements ~8 of them. `FhirAdapter` even raises on vault methods. | Split into **role interfaces** (§4.1). Workforce implements Identity + Vault + Ledger (+ BenefitsVerification); PRC implements Identity + Vault + EHR + Budget + EDI. |
| **MLR / CMS reference tables** | 12 global (non-tenant) tables and ~10 services of Medicare pricing math. Dormant in workforce; already the clearest separable chunk. | Extract to `corvid-mlr`. A second domain makes this obvious; do it before polishing adjudication-grade pricing (#320–#354). |
| **`Case has_many :prc_referrals`** | The generic model knows its PRC child. | Invert: PRC module extends `Case` (concern) instead. |
| **Naming** | `patient_identifier`, `practitioner_identifier`, `care_team`, `clinical_necessity`. | Alias now, rename before 1.0 (§4.2). Polymorphic `*_type` strings are a data contract (ADR 0002 §4), so this only gets more expensive. |

### 1.3 Where competency semantics would leak into claims-shaped models

Corvid must hold **workflow about** credentials, never the credentials. The
three leaks to design against:

1. **Competency claim as a `Determination`.** A learner asserting "I can code
   E/M visits" is not something a coordinator approves/denies. It is a
   ledger event (`competency_claimed`) the learner signs. Corvid may *react*
   (open a "schedule assessment" task) but records only a token to the
   ledger event.
2. **Mentor endorsement as `CommitteeReview` approval.** An endorsement is a
   mentor's signed assertion in the learner's ledger. A *selection committee*
   may consult endorsements, and that consultation is a `SelectionReview`
   decision — but the endorsement itself is never a Corvid row beyond a
   credential-reference token.
3. **Marketplace match as eligibility.** Competency matching (employer
   profile vs. learner credentials) is set arithmetic in the marketplace.
   Corvid receives a `placement_offered` event and runs the *placement
   workflow*; it never re-derives whether a learner "qualifies".

Rule, enforceable in code review: **the workforce module stores
`credential_reference_token` columns and `LedgerEventReceipt` rows; it has no
model whose name is Competency, Skill, Badge, Endorsement, or Credential.**

### 1.4 The homelessness / foster-care claim

Corvid's README lists social-services case management as a use case. The
code does not yet demonstrate it: everything outside `Case`/`Task`/`CareTeam`
is PRC. HumaneFrame's Weaver Protocol (deterministic crisis triage → HSDS
directory → warm handoff to a paid navigator) is the first concrete
social-services shape, and §6 shows it maps onto `Case` + a small AASM + an
adapter. Landing it would make the README claim true.

---

## 2. Module shape

### 2.1 Packaging decision: a separate engine gem

```
corvid                (public, generic chassis)
├── corvid-prc        (eventually: PrcReferral, checklist, committee, ARC, tribal eligibility)
├── corvid-mlr        (eventually: CMS tables, PrcOverpaymentAnalyzer)
└── corvid-workforce  (this design: Corvid::Workforce::*, tables corvid_wf_*)

host app (Jumpstart-based, e.g. a fork of corvid-saas):
  mounts Corvid::Engine and Corvid::Workforce::Engine,
  owns auth/roles/UI, wires adapters per tenant
```

Why a gem and not a namespace in `corvid`:

- The design goal is *prove the chassis generalizes*. A second domain in a
  separate gem forces every needed seam to exist as a public engine API —
  which is the extraction work anyway.
- Stewardship. The chassis and the two domain packs may end up with
  different maintainers; a nonprofit steward inheriting `corvid-workforce`
  should not inherit MLR pricing math.
- ADR 0002 §5 said "revisit the flat namespace at ~20 models". Corvid has 33.

Why a gem and not just a host app: the host app owns UI/auth; the workforce
*domain* (funding braids, obligations) must be reusable by a second Nation's
host without copying models.

### 2.2 Model map

Reused from core (no new tables):

| Concept | Core model | Notes |
|---|---|---|
| Learner's enrollment in a pathway | `Corvid::Case` + `Corvid::CaseProgram` | `subject_identifier` = learner token (`lr_…`). `program_code` from `ProgramRegistry` (e.g. `coder_pathway`). |
| Pathway milestone ladder | `ProgramRegistry` entry → `Task` rows via `ProgramTemplateService` | Milestones complete when the ledger emits the matching event (§2.4). |
| Coaching to-dos / quests | `Corvid::Task` (taskable = Case) | Freeform coaching narrative → `notes_token`. |
| Coach–mentor–navigator team | `Corvid::CareTeam` / `CareTeamMember` | Roles: `coach`, `mentor`, `navigator`, `employer_liaison`. |
| Decisions | `Corvid::Determination` via `Determinable` | On `FundingRequest`, `CohortMembership`, `Placement`. |
| Approver registry | `Corvid::ApprovalAuthority` (generalized) | Roles registry-driven; optional `scope` (funding source code). |
| Panel review | `Corvid::CommitteeReview` (polymorphic) | Cohort selection, placement committee. |

New in `corvid-workforce` (`corvid_wf_*`, all `TenantScoped` unless noted):

| Model | Purpose | Key columns |
|---|---|---|
| `Cohort` | A delivery instance of a pathway at a site | `program_code`, `facility_identifier` (site), `starts_on`, `ends_on`, `capacity`, `status` (planned/open/running/closed) |
| `CohortMembership` | The learner's path into and through a cohort — this *is* the referral | `case_id`, `cohort_id`, `referral_source` (chapter/college/self/employer/navigator), `referred_by_identifier`, AASM `status` |
| `FundingSource` | A funder the tenant braids (per fiscal year) | `code` (`wioa_166`, `pl477_tanf`, `perkins_117`, `scholarship`, `wioa_ojt`, `nation_general`), `fiscal_year`, `allowed_cost_categories` (string[]), `per_participant_cap_cents`, `sequence_rank_by_category` (jsonb: category → rank), `ruleset_class`, `checklist_definition_code`, `approver_role`, `active` |
| `FundingBudget` | Appropriation per source/FY/facility | `funding_source_id`, `facility_identifier`, `appropriated_cents`; obligated/expended are computed from obligations and cached |
| `FundingRequest` | The authorization unit (the "wizard" persists here) | `case_id`, `cohort_membership_id`, AASM `status`, `submitted_by_identifier`, `allocation_digest`, `version`, `supersedes_id` (amendments) |
| `CostLine` | What is being funded | `funding_request_id`, `category` (`tuition`, `exam_fee`, `materials`, `transport`, `childcare`, `stipend`, `ojt_wage_subsidy`, `tools`), `amount_cents`, `vendor_identifier` (token), `period_start/end` |
| `FundingEligibilityDecision` | Append-only: is this learner eligible for this source right now | `case_id`, `funding_source_id`, `eligible`, `reason_codes` (jsonb), `ruleset_version`, `facts_digest`, `decision_method` (`automated`/`staff_review`/`agent_proposed`), `decided_by_identifier`, `actor_kind`, `valid_until` |
| `FundingAllocation` | One braid line: source × cost line → amount | `funding_request_id`, `cost_line_id`, `funding_source_id`, `amount_cents`, `sequence_rank`, `eligibility_decision_id` |
| `SourceApproval` | Per-source approval event, digest-bound (or: rows in the core transitions log with `metadata.funding_source_code`) | `funding_request_id`, `funding_source_id`, `action` (approved/rejected/invalidated), `actor_identifier`, `allocation_digest`, `occurred_at` — **immutable** |
| `Obligation` | Money committed against a source on authorize | `funding_allocation_id`, `funding_source_id`, `funding_budget_id`, `amount_cents`, `fiscal_year`, AASM `status` (`obligated` → `partially_liquidated` → `liquidated` \| `deobligated`), `cap_cents` for recurring lines |
| `Expenditure` | A payment/reimbursement liquidating an obligation | `obligation_id`, `amount_cents`, `paid_on`, `payee_identifier` (token), `evidence_token` (invoice/payroll), `recorded_by_identifier` — **immutable** |
| `Placement` | Apprenticeship / OJT / job | `case_id`, `employer_identifier` (token), `kind` (`ojt`, `registered_apprenticeship`, `hire`), `starts_on`, `hourly_wage_cents`, `subsidy_rate_bps`, `ojt_contract_token`, AASM `status` |
| `LedgerEventReceipt` | Idempotent inbox of learner-ledger events | `source`, `source_event_id` (unique with source), `event_type`, `subject_identifier`, `occurred_at`, `payload_token`, `processed_at` |
| `ChecklistDefinition` / `ChecklistItem` (core candidates) | Per-source documentation checklist | definition: `code`, `items` (jsonb: key, label, requires_source/by); item rows: `checklistable` (polymorphic), `key`, `verified`, `verified_at`, `source`, `by` |

Not modeled (by design, §1.3): Competency, Badge, Endorsement, Credential,
Skill, Employer competency profile.

### 2.3 State machines

`CohortMembership.status`

```
referred ─▶ screened ─▶ selected ─▶ enrolled ─▶ completed
   │           │            │           │
   │           │            └─▶ waitlisted ─▶ selected
   │           └─▶ not_selected           └─▶ withdrawn
   └─▶ withdrawn
```

- `select` may be fired by a human or by `CommitteeReview#apply_to_reviewable!`.
- `enroll` guard: cohort has capacity and the learner has an authorized
  `FundingRequest` **or** tenant config allows unfunded enrollment.
- `withdraw` after-hook: opens a "review open obligations for deobligation"
  task on every `obligated`/`partially_liquidated` obligation.

`FundingRequest.status`

```
draft ─▶ proposed ─▶ submitted ─▶ eligibility_review ─▶ braid_review ─▶ approval_pending ─▶ authorized
                                                                          │                      │
                                                                          ├─▶ denied              ├─▶ amended (new version, back to braid_review)
                                                                          └─▶ deferred            └─▶ closed
any in-flight ─▶ cancelled
```

- `draft` and `proposed` are the only states an `agent` actor may create or
  move into. `propose` is the AI seam: an agent may fill cost lines, attach
  a suggested allocation, and pre-fill eligibility *facts* — as a proposal.
- `submit` requires a human `submitted_by_identifier` (dual control seed).
- `begin_eligibility_review` after-hook runs every active source's ruleset
  and persists `FundingEligibilityDecision` rows (fail-closed per source
  when facts are `unavailable`, same as `TribalEligibilityService`).
- `propose_braid` after-hook runs `BraidPlanner` and writes allocations;
  `allocation_digest` = SHA256 over ordered `(cost_line, source, amount)`.
- `request_approval` guard: every cost line fully allocated **or** the
  request carries an explicit `unfunded_gap_accepted_by_identifier`; every
  source's checklist complete.
- `approve_source(source)` guards: actor ≠ submitter; actor is an active
  `ApprovalAuthority` for that source's `approver_role` (or unscoped
  `program_director`); event records the current `allocation_digest`.
- `authorize` guard: for every source in the braid, the latest
  `SourceApproval` is `approved` **and** its digest equals the current
  digest (approve-then-alter guard, lifted from `PrcReferral`). After-hook:
  in one transaction create one `Obligation` per allocation and refresh
  budget caches; emit `authorization_granted` and `obligation_incurred`.
- Any change to cost lines or allocations after any approval writes an
  `invalidated` `SourceApproval` for every approved source and returns the
  request to `braid_review` (the digest makes this self-enforcing even if a
  callback is skipped).
- `amend` creates a new `FundingRequest` version with `supersedes_id`; the
  authorized version stays authorized; obligations are adjusted by *delta*
  events on `authorize` of the new version, never edited.

`Obligation.status`

```
obligated ─▶ partially_liquidated ─▶ liquidated
    │               │
    └───────────────┴─▶ deobligated   (remaining balance released; recorded amount)
```

- Only `Expenditure.create!` moves `obligated → partially_liquidated →
  liquidated` (sum(expenditures) vs. amount/cap). Recurring lines (OJT wage
  reimbursement) are one obligation with a `cap_cents` and many
  expenditures.
- `deobligate` requires a reason token and an authority.

`Placement.status`: `offered → accepted → active → completed | ended_early`.
Wage-subsidy expenditures reference the placement's obligation.

### 2.4 Plug points: the ledger adapter in place of the FHIR adapter

The engine reaches identity and credentials the way it reaches an EHR today:
through an adapter that is also the vault (ADR 0003 §2). The workforce module
requires three adapter **roles** (§4.1 defines the split):

**`Adapters::Identity`** — `find_person(token) → PersonReference`
(display name, preferred language, site — for in-memory staff display only),
`search_people(query) → [PersonReference]`, `find_staff(token)`,
`dereference(token)`, `dereference_many(tokens)`.

**`Adapters::Vault`** — `store_text(subject_token:, kind:, text:) → token`,
`fetch_text(token)`, `store_blob(...)`/`fetch_blob` for evidence documents.

**`Adapters::Ledger`** (new) —

```ruby
# Credential references only — never the credential body.
list_credentials(person_token) → [CredentialReference(identifier: "cr_…", achievement_code:, issuer_identifier:, issued_on:, status: :active|:revoked)]
find_credential(credential_token) → CredentialReference | nil

# Inbound events (pull with a cursor; or the host wires a webhook to the same receiver)
pull_events(since_cursor:) → { events: [LedgerEvent(source:, source_event_id:, event_type:, subject_token:, occurred_at:, payload_token:)], next_cursor: }

# Consent: staff can only dereference within a learner-granted sharing window
request_sharing_window(person_token:, scope:, purpose:, ttl:) → ConsentReference(identifier: "cs_…", expires_at:)
sharing_window_active?(person_token:, scope:) → bool

# Outbound: workflow facts the learner may choose to record (never auto-issued as credentials)
publish_workflow_event(subject_token:, event_type:, occurred_at:, payload:) → source_event_id
```

Behavioral differences from the PRC vault that the module must handle:

- **The vault is the learner's, not the program's.** `dereference` can
  legitimately return `nil` when no sharing window is active. Views render
  the token and a "request access" affordance instead of a name.
- **Credential facts arrive as events.** `LedgerEventReceipt` is idempotent
  on `(source, source_event_id)`; a receipt for `badge_issued` with
  `achievement_code` matching a milestone `Task.milestone_key` completes
  that task and records a `Determination(decision_method: "automated")`
  pointing at the receipt.

**`Adapters::BenefitsVerification`** (optional, host-implemented) —
`verify_benefit_status(person_token, program) → { enrolled:, confidence:, verified_at: }`
for TANF/477 and similar facts; falls back to a staff-recorded attestation
(`at_` token) with `confidence: :attested`.

A `MockLedgerAdapter` ships in the module with an in-memory event stream so
the whole braid can run in tests and demos without the real ledger.

### 2.5 Non-human actors

The engine currently identifies actors by opaque identifier only. The module
needs, and core should add, an **actor kind**:

- `TenantContext.current_actor = { identifier:, kind: :human | :system | :agent }`
  (also fixes ADR 0003's promise of `Corvid.current_user_identifier`, which
  does not exist).
- Every lifecycle transition records `actor_identifier` and `actor_kind`
  (ADR 0007).
- Engine-level invariant, not a controller check: an `agent` actor may only
  fire events whose target state is in the model's declared
  `AGENT_ALLOWED_STATES` (for `FundingRequest`: `draft`, `proposed`; for
  `Task`: create with `status: pending`; for `FundingEligibilityDecision`:
  `decision_method: agent_proposed` rows only, which the ruleset ignores as
  evidence). Anything else raises `Corvid::ActorNotPermitted`. This is
  testable and survives a UI bypass.
- AI never fires `approve_source`, `authorize`, `deny`, `select`,
  `deobligate`, or writes an `Expenditure`.

---

## 3. The hard case: braided-funding authorization

### 3.1 Why it is not payer-of-last-resort

PRC's rule is: for one service, establish that every alternate payer is
unavailable, then the single program pays. Workforce braids are:

- **Several funders pay at once**, each for the cost categories its statute
  allows (a training grant may pay tuition and exam fees but not childcare;
  a family-assistance program may pay support services but not tuition).
- **Sequencing is per category**, set by the tenant (e.g. tuition:
  scholarship → Perkins → WIOA training account → 477; support services:
  477/TANF → WIOA supportive services; OJT wages: WIOA OJT reimbursement ≤
  the statutory share → employer).
- **Eligibility is per funder**, each with its own documentation.
- **Caps and budgets bind**: per-participant caps per source; per-source
  budgets per fiscal year and site.
- **Funder-of-last-resort exists** (the Nation's own funds) — as the source
  ranked last for every category, i.e. the PRC rule is a special case.

### 3.2 Flow

1. **Intake.** Coach or navigator (or an agent, as `proposed`) drafts a
   `FundingRequest` from the cohort's cost template (tuition, exam voucher,
   materials, support services; later an OJT wage line on placement).
2. **Eligibility pass** (`begin_eligibility_review`). For each active
   `FundingSource`: gather facts through adapters (`verify_identity`,
   tribal enrollment, residency, `verify_benefit_status`, college
   enrollment, age band, prior participation) and staff attestations
   (`at_` tokens); run `RulesEngine.new(source.ruleset_class.new)`; persist
   `FundingEligibilityDecision` with `reason_codes`, `ruleset_version`,
   `facts_digest`. Unavailable facts fail closed for that source only.
3. **Braid proposal** (`propose_braid`). `BraidPlanner` is deterministic:
   for each cost line, walk sources in the tenant's rank order for that
   category, restricted to sources that are eligible, allow the category,
   have per-participant cap remaining and budget remaining; fill greedily;
   the remainder is an `unfunded_gap`. Output: `FundingAllocation` rows and
   the `allocation_digest`. An agent may attach an *alternative* proposal;
   the planner's output is the record and a human must explicitly choose the
   alternative (a normal edit, which re-digests).
4. **Braid review.** Specialist confirms allocations; completes each
   source's `Checklist` (data-driven definitions); attaches evidence tokens.
5. **Approval.** One `approve_source` per source in the braid, by a distinct
   approver holding authority for that source; each bound to the digest.
   Tenants may configure a single `program_director` role to approve all
   sources.
6. **Authorize.** All approvals current → obligations created per allocation
   in one transaction; budgets refreshed; `authorization_granted`,
   `obligation_incurred` logged.
7. **Liquidation.** Expenditures (tuition invoice, exam voucher redemption,
   monthly stipend, OJT payroll reimbursement with payroll evidence token)
   against obligations; recurring lines auto-`liquidate` at cap.
8. **Amendment.** New version supersedes; delta obligations on authorize.
9. **Withdrawal / completion.** Membership state change opens deobligation
   review tasks; `deobligate` releases balances back to budgets with a
   reason.
10. **Funder audit export.** Per source: every dollar traced to its
    eligibility decision (ruleset version + facts digest), checklist digest,
    approver, and timestamps — a filtered replay of the lifecycle log. This
    is why the lifecycle log must be the record of truth (ADR 0007).

### 3.3 Invariants (tests to write first)

- Σ allocations per cost line ≤ cost line amount; equality unless
  `unfunded_gap_accepted_by_identifier` is set.
- Every allocation references an `eligible: true` decision for its source
  that was `valid_until` ≥ authorization time.
- `authorize` is impossible while any source approval digest ≠ current
  digest.
- Σ obligations per (source, FY, facility) ≤ appropriated (or tenant
  opts into over-obligation with a flag and an authority).
- Σ expenditures per obligation ≤ amount (or cap).
- No `agent` actor ever appears as `actor_identifier` on
  `SourceApproval`, `authorize`, `deny`, `Expenditure`, or a final
  eligibility decision.
- Obligations and expenditures are never updated or deleted (DB-enforced).

---

## 4. Extraction implications and pre-1.0 API decisions

A second domain converts several "someday" items into blocking decisions.
Ordered by how much more expensive they get after 1.0:

### 4.1 Adapter role interfaces (replaces the single `Adapters::Base`)

Split `Corvid::Adapters::Base` into role modules and let hosts register
implementations per role (and, per ADR 0005/0006, per tenant):

```ruby
Corvid.configure do |c|
  c.adapters.register(:identity, MyIdentityAdapter.new)
  c.adapters.register(:vault,    MyVaultAdapter.new)
  c.adapters.register(:ehr,      Corvid::Adapters::FhirAdapter.new(...))   # PRC
  c.adapters.register(:budget,   ...)                                       # PRC
  c.adapters.register(:edi,      ...)                                       # PRC
  c.adapters.register(:ledger,   Corvid::Workforce::Adapters::LedgerAdapter.new(...)) # workforce
  c.adapters.register(:hsds,     ...)                                       # navigation
end
Corvid.adapters[:identity]   # resolves for current tenant when a router is configured
```

Roles: `identity`, `vault`, `ehr` (referrals, care team, clinical reads,
site params), `budget`, `enrollment_verification` (tribal enrollment,
identity documents, residency), `edi`, `ledger`, `benefits_verification`,
`hsds`. `Corvid.adapter` stays as a deprecated facade that returns a
composite for one release. Contract tests (#233) become per-role.

### 4.2 Naming: subject and actor

- `Case.patient_identifier` → `subject_identifier`
  (`alias_attribute :patient_identifier` for one release).
- `Task.assignee_identifier`, `CareTeamMember.practitioner_identifier`,
  `ApprovalAuthority.practitioner_identifier`, `*_by_identifier` → keep
  column names where they are already role-neutral (`assignee`, `*_by`);
  rename `practitioner_identifier` → `actor_identifier`.
- `Case#patient` → `Case#subject`; `Task#assignee` resolves via
  `adapters[:identity].find_staff`.
- Polymorphic `taskable_type`/`determinable_type` strings are unaffected;
  new workforce types (`Corvid::Workforce::FundingRequest`) join them.

### 4.3 Invert `Case → prc_referrals`

Remove `has_many :prc_referrals` from `Corvid::Case`; the PRC module adds it
via `Corvid::Case.include(Corvid::Prc::CaseExtension)`. Same for
`Task#fhir_taskable_type`'s PRC mapping (move to a registry of
`taskable_type → FHIR resource`).

### 4.4 Polymorphic `CommitteeReview`

`belongs_to :reviewable, polymorphic: true`; `apply_to_reviewable!`
dispatches to a `Reviewable` concern the subject implements
(`apply_committee_decision!(decision)`). Money columns stay optional.

### 4.5 Data-driven checklist in core

`Corvid::ChecklistDefinition` (registry, like `ProgramRegistry`) +
`Corvid::ChecklistItem` rows on a polymorphic `checklistable`, preserving
`non_approval_items_digest` and the approve-then-alter guard. PRC's seven
items become one definition.

### 4.6 `ApprovalAuthority` roles from a registry, with optional scope

`Corvid::ApprovalRoleRegistry.register("program_director", ...)`; add
`scope` (nullable string, e.g. a funding-source code). `active_approver?`
takes `role:` and optional `scope:`.

### 4.7 Core lifecycle event log — ADR 0007

`corvid_transitions`, append-only, written by an `EventLogged` concern from
AASM `after_all_transitions`; `ManagementApprovalEvent` becomes the first
migrated client; `on_provenance`/`fetch_provenance` become
subscriber/reader over it. See `docs/adr/0007-lifecycle-event-log.md`.

### 4.8 Actor kind in `TenantContext`

`current_actor_identifier`, `current_actor_kind`; recorded on every
transition; `Corvid::ActorNotPermitted` for agent actors outside declared
proposal states (§2.5). This is also the seam #529 (governed-AI contract)
needs.

### 4.9 Token-kind registry (ADR 0003 §4)

`Corvid::TokenKinds.register(:learner, "lr")` etc.; `store_text(kind:)`
validates against registered kinds; MockAdapter mints with the registered
prefix. §5 lists the workforce kinds.

### 4.10 Cross-product event envelope (#261 / #249)

The ledger is the first real external event producer/consumer. Fix the
envelope now: `(source, source_event_id, event_type, occurred_at,
subject_token, payload)` with idempotency on `(source, source_event_id)`;
`LedgerEventReceipt` is its first consumer; the transitions log (with a
`published_at` column) is its outbox.

### 4.11 Smaller items

- Enforce `Case.lifecycle_status` as a state machine (#507).
- Make `Task.priority` values registry-extensible or domain-neutral.
- Do not carry `patient_name_cached`/`patient_dob_cached` into any generic
  API; leave it as a PRC-host opt-in and document that workforce must not
  use it (#506 covers the PRC deviations).
- Move `features/prc/care_teams.feature` and generic scenarios out of
  `features/prc/` so the generic suite is visibly generic.

### 4.12 Priority shifts

- **Up:** adapter role split, event log, naming, MLR extraction — each is
  now needed by two consumers.
- **Down:** adjudication-grade MLR pricing (#320–#354) is PRC-only and
  should follow the `corvid-mlr` extraction rather than precede it.
- **Unchanged:** HIE/exchange, Da Vinci, terminology epics — PRC/health only.

---

## 5. Tokenization mapping (ADR 0003 applied to learner PII)

### 5.1 Token classes for a workforce deployment

| Prefix | Kind | Resolves to (in memory only) | Minted by |
|---|---|---|---|
| `lr_` | learner | PersonReference (display name, language, site) | ledger / identity adapter |
| `st_` | staff (coach, mentor, navigator, approver) | StaffReference | identity adapter |
| `em_` | employer / organization | OrganizationReference (public business data) | identity adapter |
| `cr_` | credential reference | CredentialReference (achievement code, issuer, dates, status) | ledger |
| `cs_` | consent / sharing-window grant | ConsentReference (scope, expiry) | ledger |
| `le_` | ledger event payload | event body | ledger |
| `nt_` | coaching note / narrative | text | vault |
| `rn_` / `rs_` | rationale / reason | text | vault |
| `at_` | staff-recorded attestation (income band, benefit status, selective service, etc.) | structured attestation | vault |
| `ev_` | evidence document (invoice, payroll record, transcript, OJT contract) | blob | vault |
| `bn_` | benefits-verification response blob | structured | vault |
| `tnt_` / `fac_` | tenant / facility | (unchanged) | host |

Never stored, in any column: name, DOB, SSN, address, phone, email, wage
*joined to a learner token* (see below), tribal enrollment number,
transcript contents, credential bodies (VC/Open Badge JSON).

### 5.2 Field-by-field

| Field | Storage |
|---|---|
| Age eligibility | `age_band_verified` boolean + `verified_at` + source — never DOB |
| Selective service / SSN presence | boolean via `verify_identity_documents`-style adapter call |
| Residency / service area | boolean + `service_area_code` + source (as PRC does) — never address |
| Income / low-income status | `at_` attestation token + boolean outcome |
| Benefit status (TANF etc.) | `bn_` token + boolean + confidence |
| Enrollment / exam / placement dates | stored (workflow-essential); documented combination risk |
| Amounts (tuition, stipend, obligation) | stored cents — not PII alone |
| **Hourly wage on `Placement`** | stored cents, but `Placement.subject` is a token and `employer_identifier` is a token — the combination is the same class of risk as PRC's dates+amounts. Tenants that consider wage sensitive set `wage_in_vault = true` and the module stores `wage_token` instead. Default: **token** (safer default than PRC's). |
| Coaching notes, crisis notes | `nt_` token, never `Task.description` |
| Task description | template text from `ProgramRegistry` milestones or tenant task templates only; freeform requires `notes_token` |
| Team name | template-shaped ("Cohort 3 support team"); never a learner's name |

### 5.3 Does "Postgres dump reveals no PII" hold?

Yes, under three conditions the module must enforce and CI must test:

1. **No cached identity columns.** The module never adds `*_name_cached`;
   `Corvid::Case.cache_patient_data!` is unavailable to workforce hosts
   (guarded by a configuration flag, default off for non-PRC programs).
2. **Freeform text is always tokenized.** Rubocop-style custom cop (or a
   schema test) asserting every `text`/long `string` column in `corvid_wf_*`
   is either an enum, a template, or `*_token`.
3. **A dump test.** In CI: migrate, run the synthetic seed (obviously fake
   strings such as `"TEST LEARNER 001"`), `pg_dump`, and assert none of the
   seed's PII-class strings appear. This is the workforce analogue of #519.

Residual combination risk (dates + amounts + facility + cohort size of
15–20) is real: with a small cohort, "the learner who withdrew on this
date" can be re-identified by an insider with program knowledge. Document
it as a host responsibility as ADR 0003 does; mitigate by keeping
`facility_identifier` opaque (`fac_` tokens, not site names) and by
not storing cohort roster order.

The sovereignty twist strengthens the property: because the vault is the
learner's ledger and dereference needs an active sharing window, even an
authenticated staff session cannot bulk-resolve tokens — the ledger, not
Corvid, enforces who can see what and when.

---

## 6. Weaver / HSDS: crisis navigation as a Corvid case type

### 6.1 Shape

- `Corvid::Case` with `CaseProgram(program_code: "crisis_navigation")`.
  Subject may be an unidentified walk-in (`lr_` token minted by the identity
  adapter as a provisional identity, upgraded on consent).
- `Workforce::CrisisIntake` (or a `corvid-navigation` sub-module later):

```
received ─▶ triaged ─▶ matched ─▶ handoff_offered ─▶ handoff_accepted ─▶ connected ─▶ closed
   │           │                        │
   │           └─▶ escalated (imminent) │
   └─▶ abandoned ◀──────────────────────┘ (no contact within SLA; human-confirmed)
```

### 6.2 Deterministic triage

`Workforce::CrisisTriageRuleset` on `Corvid::RulesEngine`: inputs are
yes/no facts (immediate physical danger, shelter tonight, food today,
children present, domestic violence indicated, medical emergency) → `tier`
∈ {imminent, urgent, routine} with `failed_facts` as the explanation.
The ruleset is versioned; the version is recorded on the transition.
An agent may **draft facts** from an intake conversation; the tier is always
computed by the ruleset, and `imminent` immediately: (a) creates a `stat`
`Task` to the on-duty navigator with `due_at = now + tenant SLA`, (b)
records the tenant's emergency-services escalation instruction on the case,
and (c) never waits on directory matching.

### 6.3 HSDS adapter role

Open Referral HSDS is public organizational data (services, locations,
hours, eligibility text), not PII — so it is **reference data**, and the one
place the offline-reads guardrail applies naturally.

```ruby
# Adapters::Hsds
search_services(taxonomy_terms:, area_code:, filters: {}) → [ServiceReference(identifier:, name:, organization:, phones:, hours:, eligibility_text:, last_updated:)]
find_service(service_identifier) → ServiceReference
directory_provenance → { source:, snapshot_at:, record_count: }
```

Host implementation: nightly HSDS bulk import into a read-replicated table
served with cache headers so the navigator's device can search offline
(service-worker cache of the directory). All *writes* (intake, triage,
handoff) are online-only per the Phase 0 posture.

### 6.4 Warm-handoff task semantics

A warm handoff is a `Corvid::Task` with `kind: :warm_handoff` (new column,
enum) on the intake, and three timestamps the module adds through a
`Corvid::Workforce::HandoffTask` extension:

- `offered_at` — navigator assigned, SLA clock starts (`due_at`).
- `accepted_at` — the navigator acknowledges (a human action; the system
  never auto-accepts).
- `contact_made_at` — introduction made (three-way call, in-person walk-over,
  or confirmed message) — records `service_identifier` and the `cs_` consent
  token for what was shared with the receiving service.
- `confirmed_at` — receiving service confirms intake. **Only this closes the
  handoff**, and only a human records it.

Missed SLA → `overdue` scope surfaces it on the on-duty dashboard and
escalates to the backup navigator (a second task, not a state change).
Notes are `nt_` tokens. The case stores the HSDS `service_identifier`, never
the receiving org's case number for the person.

---

## 7. Effort estimate — Phase 0, one vertical, one cohort

Assumptions: one 15–20-learner cohort with 3–4 braided funding sources; the
learner ledger and marketplace exist externally with a frozen API (mocked
first); one experienced Rails engineer with agentic assistance; the host app
is a fork of `corvid-saas`; Hotwire server-rendered UI.

| Workstream | Engineer-weeks | Notes |
|---|---|---|
| Core pre-1.0 seams (§4.1–4.9: adapter roles, naming aliases, transitions log, polymorphic committee, checklist, actor kind, token registry) | 3–4 | Parallelizable with the module if two people |
| `corvid-workforce` domain: cohorts/memberships, sources/budgets/requests/cost lines/allocations/obligations/expenditures, `BraidPlanner`, 3–4 funder rulesets + checklists, approvals, invariants tests | 5–6 | Rulesets are the schedule risk — funder documentation rules, not code |
| Ledger adapter role + mock + `LedgerEventReceipt` idempotency + milestone completion | 1.5–2 | Needs the ledger API contract frozen early |
| Host app: auth/roles → `ApprovalAuthority`, specialist/coach/director UIs, dashboards, tenant onboarding, per-tenant adapter wiring | 4–5 | Largest UI surface |
| Funder audit exports and reports | 1–1.5 | Replay of transitions log |
| Weaver/HSDS: intake AASM, triage ruleset, HSDS import + offline read cache, handoff tasks | 2–3 | Can follow cohort 1 |
| BDD features, CI dump test, ADRs/docs | ~2 | Woven through |
| Deployment, backups, runbook, pilot support | 1.5–2 | |
| **Total** | **≈ 20–25** | ≈ 5–6 months for one engineer; ≈ 3 months with two |

Minimal launch (cohort intake + tasks/coaching + single-funder
authorization and obligations, no OJT, no Weaver): **≈ 10–12 weeks**.

Explicitly not in the estimate: the ledger itself, the marketplace, mobile
apps, data migration from any existing spreadsheets/systems, and
funder-specific reporting formats beyond a CSV/JSON audit export.

---

## 8. Decisions requested

1. Approve the **separate-gem** packaging (`corvid-workforce`) and the
   commitment to extract `corvid-prc` / `corvid-mlr` over time.
2. Approve **ADR 0007** (lifecycle event log) as the answer to "event
   sourcing, and where".
3. Approve the pre-1.0 core changes in §4.1–4.9 as the extraction backlog,
   sequenced adapter roles → event log → naming → checklist/committee.
4. Confirm the **AI seam** rule (§2.5): agents create/move only into
   declared proposal states; enforced in the engine.
5. Confirm the **wage-in-vault** default (§5.2).

Once agreed, one "implement this design" issue is opened as the marker; this
document holds the reasoning.

## References

- ADR 0002 architectural foundations; ADR 0003 PHI tokenization; ADR 0004
  monetary values; ADR 0005 adapter injection; ADR 0006 deployment topology
- ADR 0007 (proposed) lifecycle event log — `docs/adr/0007-lifecycle-event-log.md`
- Issues: #222/#264 adapter DI, #233 adapter contract tests, #249 cross-product
  ADRs, #261 event bus, #231 idempotency, #507 case lifecycle enforcement,
  #506/#519 PHI-at-rest invariants, #529 governed-AI contract, #518 W3C VC
  attestation
- HumaneFrame architecture (CC BY-SA 4.0): humaneframe.org/tech/architecture
- Standards: Open Badges v3 / CLR (1EdTech), W3C Verifiable Credentials,
  HSDS (Open Referral), Rich Skill Descriptors (OSMT)
