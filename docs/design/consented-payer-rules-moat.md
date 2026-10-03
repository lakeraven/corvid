# Design: Consented Payer-Rules / Denial-Pattern Layer (the "moat")

**Status:** Proposed — design only, no implementation in this doc
**Date:** 2026-08-14
**Author:** Kimball Bighorse (design), for engineering + Data Governance Board + counsel review
**Tracks:** [lakeraven/corvid#463](https://github.com/lakeraven/corvid/issues/463) (ENG-7)
**Feeds:** ENG-1 (claim scrubbing), ENG-1B (#461, AI coder)

## 0. Why this doc exists

An August 2026 architecture audit found that corvid has **no latent
athenahealth-style network-effect moat**. Per [ADR 0002](../adr/0002-architectural-foundations.md)
and [ADR 0003](../adr/0003-phi-tokenization.md), every table that records a
client outcome — denials, claim results, payer responses, eligibility
decisions — is `TenantScoped` and PHI-tokenized by construction. Corvid
cannot see across tenants, and even within a tenant it cannot see PHI. The
only data shared across all deployments today is public CMS pricing
(`Corvid::FeeScheduleEntry`, `Corvid::CmsFeeScheduleRelease` — no
`tenant_identifier` column, ingested from CMS public files).

That's the correct default. A moat built from client data is not something
that falls out of the architecture — it has to be **deliberately built**,
and building it collides head-on with the same OCAP / data-sovereignty
concerns Lakeraven raises about Snowflake- and Patagonia-style vendors that
pool tribal client data for their own benefit (OCAP community
authorization; Expert Determination for tribal data). This doc is the design for
doing it in a way that survives that comparison: **consent-first, PHI-free,
governed by the tenants who contribute, and legally gated before a line of
implementation code exists.**

This doc does not implement anything. It is the design artifact requested
by ENG-7 task 1; tasks 2 (consent/governance model — folded into §2 here),
3 (legal review — §5), and 4 (prototype) are tracked separately and are
explicitly **not started** by this PR.

## 1. What's shareable vs. what stays siloed

### 1.1 The boundary, precisely

| Category | Shareable (de-identified, aggregate) | Siloed (never leaves tenant) |
|---|---|---|
| Denial reason codes (CARC/RARC from 835 remittance) | Yes — the code itself, e.g. `CO-197` "Precertification/authorization absent" | The free-text rationale behind a specific denial (`denial_reason_token`, `Determination#reasons_token`) |
| Code/modifier edit rules (which CPT+modifier+payer combos get bounced) | Yes — `procedure_code` + `modifier` + `payer_identifier` + outcome | The claim itself, patient, provider, service date |
| Payer adjudication patterns (this payer requires prior auth for this CPT in this state's Medicaid) | Yes — pattern-level, keyed by canonical payer ID + program + jurisdiction | Which tenant/patient hit the pattern |
| Timely-filing behavior (payer X enforces a 90-day window in practice vs. its stated 180) | Yes — observed threshold, aggregated | The specific claims used to observe it |
| Diagnosis codes | Category-level only (ICD-10 chapter/block, e.g. `E08-E13` diabetes), never the leaf code paired with a rare procedure — leaf-code + rare-CPT combinations can be reidentifying in small tribal populations | Leaf ICD-10 code tied to a claim; all `diagnosis_codes_token` content |
| Payer identity | Canonical/public payer ID (NAIC, CMS payer ID, or clearinghouse payer ID) | The tenant's specific payer contract terms, `payer_name_token`, policy numbers |
| Everything else in `corvid_claim_submissions`, `corvid_determinations`, `corvid_billing_transactions` | No | Everything — patient/provider/practitioner identifiers, all `*_token` free text, amounts tied to a specific claim, dates below month-granularity |

**Never shareable, full stop:** anything ADR-0003 already classifies as
PHI (patient/practitioner identity, DOB, MRN, SSN, clinical free text,
policy numbers), any single-claim record, any token (tokens are
per-vault-instance opaque references — even sharing a token cross-tenant is
meaningless, but it's also a potential correlation handle, so the pipeline
never touches raw token values in the shared store).

### 1.2 A wrinkle specific to this codebase

Looking at `app/models/corvid/claim_submission.rb` and
`test/dummy/db/schema.rb`, corvid tokenizes **more than free text** —
`procedure_codes_token` and `diagnosis_codes_token` are token references,
not raw CPT/ICD-10 columns. ADR-0003 groups "diagnoses, conditions" under
PHI categorically, not just diagnosis narratives. That means the
shared-rules pipeline cannot read code-level facts off the `ClaimSubmission`
row directly — it must go through `Corvid.adapter.fetch_text(token)` (or
the future structured equivalent) to dereference, exactly like any other
PHI-adjacent read, and then **discard the token and the tenant linkage
before anything is written to the shared store.** This is not a new vault
capability; it's the existing ADR-0003 §2 dereference path, used for
extraction instead of for rendering.

### 1.3 De-identification guarantees

The shared store must satisfy all of the following, not just "no name
fields":

1. **No patient, claim, provider, or tenant identifier of any kind** —
   not even hashed. A hash of a tenant ID is still a stable correlation
   handle; it is excluded by construction (see §4, the shared table has no
   `tenant_identifier` column at all).
2. **Rule-level and aggregate-level only.** A shared row describes a
   *pattern* ("payer P denies CPT 99214 with modifier 25 absent, program
   Medicaid-state-X"), never a single claim's outcome.
3. **k-anonymity threshold before visibility.** A pattern is only exposed
   through the query API once it has been independently observed by at
   least **N distinct contributing tenants** (default N=5, tunable by the
   Data Governance Board — see §1.4 on why this matters more here than in
   a generic de-identification scheme). Below threshold, the row exists
   internally (accumulating) but is not queryable.
4. **Small-cell suppression**, not just identifier removal. Per the
   standing rule that Safe Harbor is insufficient for tribal data and
   Expert Determination is required,
   the de-identification method for this store must be reviewed as an
   Expert Determination, not asserted as Safe Harbor. Small-cell
   suppression (IHS/CDC-style, suppressing counts below a floor) is
   the statistical-disclosure-control technique that determination will
   likely require in addition to identifier removal — flagged as a
   legal/statistical question, not decided in this doc.
5. **Category-level diagnosis codes**, not leaf codes, when paired with
   procedure codes (§1.1) — because a rare leaf-code + rare-CPT pair from a
   small tribal clinic population can be reidentifying at the *tenant*
   level even with zero patient identifiers.
6. **No timestamps finer than month.** `first_observed_at` /
   `last_observed_at` on shared rows are month-granularity, not the
   claim's actual service date.

### 1.4 Why tribal-scale populations make this harder than the generic case

The generic "de-identified data sharing" playbook (drop names, hash IDs,
publish aggregates) assumes population sizes where k-anonymity is easy to
achieve incidentally. Several corvid tenants are single-facility tribal
clinics serving populations in the hundreds. A "payer X denies CPT Y" count
of 1 in a dataset where only one tenant plausibly submits CPT Y at all is
functionally a tenant-identifying (and via the clinic, potentially
patient-identifying) fact even though no identifier field exists. This is
why the threshold in §1.3.3 is a *tenant-count* threshold (independent
contributing tenants), not a *claim-count* threshold — five tenants each
submitting one claim is safe in a way that one tenant submitting five
claims is not.

## 2. Consent and tribal governance

### 2.1 Principles (OCAP-aligned)

- **Opt-in, not opt-out.** No tenant's data enters the pipeline by
  default. This mirrors the posture already taken for our
  partner integrations and the sovereign-hub work: OSS-self-hosted,
  consent-first, no silent pooling.
- **Ownership (O) and Possession (P):** the tenant retains ownership of
  its underlying claims/denial data at all times; corvid never gains a
  copy of it, only a statistical contribution derived from it inside the
  tenant's own trust boundary (see §4.3 — the extraction job runs *as*
  the tenant, not on tenant data pulled elsewhere).
- **Control (C):** the tenant (through whatever body governs it — a tribal
  Data Governance Board, a facility's own board, per deployment) decides
  whether to contribute, decides whether to consume shared rules, and can
  revoke either independently, at facility granularity if it chooses.
- **Access (A):** contribution is one-way and write-only from the tenant's
  perspective for its *own* raw data — a tenant can audit exactly what it
  contributed (§4.2, the per-tenant audit log) but the shared store itself
  reveals only patterns, never which tenants are behind them, to anyone,
  including the contributing tenants themselves.

### 2.2 Consent model

A new `corvid_payer_rule_consents` record (tenant-scoped, §4.1) captures:

- **Scope**: `contribute`, `consume`, or `both` — a tenant can consume
  shared rules (get denial-risk warnings) without ever contributing, and
  in principle vice versa. Whether consumption should be gated on
  contribution (a "give-to-get" model, common in fraud-signal consortia)
  or open to all tenants regardless of contribution is a **product
  decision, not an architecture decision** — flagged as open in §6.
- **Facility-level override**: a tenant can opt in at the tenant level but
  exclude specific facilities (e.g. a behavioral health division) from
  contribution, because ADR-0002's facility layer already carries
  different sensitivity for some programs.

  **Precedence, because `TenantScoped` filters by tenant only** (and so will
  not enforce this for us — see §4.5): a row with a non-null
  `facility_identifier` ALWAYS wins over the tenant-level row for that
  facility, in both directions. A tenant-level grant therefore means "every
  facility except those with a facility-level row that is not contributing",
  and with no tenant-level grant only facilities with their own contributing
  row are included. The effective set is computed explicitly and applied as a
  `facility_identifier` filter on extraction; a facility that is merely
  *absent* from the consent table is **not** included under a tenant-level
  grant unless the tenant-level row exists. Absence is never permission.
- **Governance reference**: a pointer (host-owned token, not a corvid FK)
  to the actual authorization record — e.g. a tribal Data Governance
  Board resolution, a facility board vote, a signed BAA amendment. Corvid
  does not adjudicate whether the authorization is valid; it records that
  one was presented and by whom (`granted_by_identifier`), and the host
  is responsible for that record's legitimacy — consistent with how
  provenance hooks work elsewhere in the engine (ADR-0002 §7).
- **Time-boxed re-consent**: a `review_due_at` so a Data Governance Board
  decision doesn't become a permanent, unreviewed default. Annual is a
  reasonable default, tunable per tenant.
- **Revocation**: sets `status: revoked`, immediately stops future
  contribution and (if scope included `consume`) future rule lookups.
  What happens to the tenant's *already-aggregated* historical
  contribution is a genuinely hard problem — see §6 (open question,
  legal gate).

### 2.3 Who decides

This is explicitly **not** an engineering decision. The consent record
exists so that engineering can enforce whatever the Data Governance Board
(or equivalent tenant-side authority) decides, per tenant. Corvid's job is
to make "no consent → no data leaves" a structural invariant (§4), not a
policy the pipeline merely tries to honor.

## 3. The sovereignty tension, stated honestly

This feature is, mechanically, the same move Lakeraven criticizes when a
vendor pools client outcome data to build a product advantage: it takes
data that originates from tribal and safety-net clinics and aggregates it
into an asset the platform operator controls. Calling it "de-identified"
does not make the tension disappear — de-identification is a mitigation,
not a justification, and the whole point of the OCAP framework and the
Expert Determination requirement for tribal data is that de-identification
claims need independent verification, not vendor assertion.

What's meant to make this design different from the thing being
criticized, concretely:

1. **Opt-in with a real off switch**, not a EULA checkbox — enforced
   structurally (§4), not just by policy.
2. **Governance authority sits with the tenant**, not with corvid or
   Lakeraven. The Data Governance Board reference in §2.2 is not
   decorative — no consent record, no contribution, full stop.
3. **The moat's output is returned to contributors** (via §5 of ENG-1B and
   claim-scrubbing consumption in ENG-1), not extracted purely for
   Lakeraven's own competitive benefit. If this ships without a clear
   value-return path to the tribes whose data built it, it *is* the thing
   being criticized, just with better de-identification. This is a
   product commitment this doc flags but cannot itself guarantee —
   tracked as an open question in §6.
4. **Nothing patient-identifying or claim-identifying ever leaves the
   tenant's vault boundary**, enforced by schema shape (no tenant/patient
   columns exist in the shared table) rather than by a runtime filter that
   could be bypassed by a bug.
5. **It is not the default.** Corvid remains fully functional, and every
   tenant's outcome data remains fully siloed, with this feature entirely
   off. Contribution is additive, not load-bearing for the product to
   work.

Where this doc is candid about *not* resolving the tension: k-anonymity at
tribal population scale (§1.4) is a real, unsolved-in-general problem, and
"5 distinct tenants" is a starting number, not a proof. That's precisely
why §5 makes counsel + statistical Expert Determination a gate before
implementation, not a formality after.

## 4. Data-model sketch

### 4.1 Consent (tenant-scoped — normal corvid pattern)

```ruby
# app/models/corvid/payer_rule_consent.rb  (sketch, not implemented)
module Corvid
  class PayerRuleConsent < ::ActiveRecord::Base
    self.table_name = "corvid_payer_rule_consents"
    include TenantScoped   # per ADR 0002 — this record itself IS tenant data

    SCOPES   = %w[contribute consume both].freeze
    STATUSES = %w[pending active revoked expired].freeze

    validates :scope, inclusion: { in: SCOPES }
    validates :status, inclusion: { in: STATUSES }
    validates :governance_reference_token, presence: true, if: -> { status == "active" }
    validates :granted_by_identifier, presence: true, if: -> { status == "active" }

    # `active` FAILS CLOSED on the re-consent deadline. Nothing else in this
    # design moves a row to "expired", so a scope of `where(status: "active")`
    # alone would leave an unreviewed board decision authorized forever —
    # exactly what §2.2's time-boxing exists to prevent. A row with no
    # review_due_at is therefore not active either: a missing deadline is an
    # unanswered question, not permission.
    scope :active, -> {
      where(status: "active")
        .where.not(review_due_at: nil)
        .where(review_due_at: Time.current..)
    }
    scope :contributing, -> { active.where(scope: %w[contribute both]) }
    scope :consuming,    -> { active.where(scope: %w[consume both]) }

    # Bumped by any revocation or scope change. The extraction job captures it
    # at the start of a run and re-verifies it at each publish (§4.5), so a
    # revocation invalidates work already in flight.
    # increments on: status change, scope change, facility carve-out change
    attribute :consent_generation, :integer
  end
end
```

Columns: `tenant_identifier`, `facility_identifier` (nullable — facility
carve-out), `scope`, `status`, `granted_by_identifier`,
`governance_reference_token`, `granted_at`, `revoked_at`, `review_due_at`.

### 4.2 Per-tenant contribution audit (tenant-scoped — the tenant's own receipt)

```ruby
# app/models/corvid/payer_rule_contribution_audit.rb  (sketch)
module Corvid
  class PayerRuleContributionAudit < ::ActiveRecord::Base
    self.table_name = "corvid_payer_rule_contribution_audits"
    include TenantScoped

    belongs_to :consent, class_name: "Corvid::PayerRuleConsent"
    # rule_pattern_hash references a row in the shared store by hash only.
    # The missing FK is a readability choice, NOT a control: the hash is the
    # join key either way. See the access-control note below.
  end
end
```

Columns: `tenant_identifier`, `consent_id`, `rule_pattern_hash`,
`claims_contributed_count`, `run_at`. Lets a tenant answer "what did we
contribute, when".

**This table is linkage-bearing, and the schema does not prevent reverse
lookup.** It holds `(tenant_identifier, rule_pattern_hash)` — the same pair
as the §4.3 ledger — so anyone able to read both this table and the shared
store can join them on the hash with no foreign key needed. Dropping the FK
to `SharedPayerRule` buys a little clarity and no protection at all. What
actually constrains the join is **access control, not shape**:

- `TenantScoped` confines tenant reads to the tenant's own rows, so one
  tenant cannot read another's receipts. That part is structural.
- Corvid **staff** access is the real exposure, and it is not solved by
  tenancy. Reads of this table and of §4.3's ledger must be restricted to
  the aggregation role, audited, and excluded from ordinary support
  tooling and any admin UI. A support engineer who can read both tables
  can attribute every shared pattern to the tenant that contributed it.
- The restriction is a deployment and IAM obligation, not something this
  schema enforces. It belongs in the §5 legal review, because "we chose
  not to add a foreign key" is not a de-identification control.

### 4.3 Contributor-linkage ledger (internal only — not a consumer-facing table)

A separate, tightly access-restricted table carries the
`(tenant_identifier, rule_pattern_hash)` pair so the aggregation job can
compute *distinct contributing tenant count* (needed for the k-anonymity
gate in §1.3.3) without storing a tenant list on the shared row itself.

**Correction to an earlier claim in this doc:** this ledger is *not* the only
place that pair exists. The per-tenant audit table (§4.2) necessarily holds it
too — that is what makes the tenant's own receipt possible — so there are two
linkage-bearing tables, not one, and both need the staff-access restrictions
described in §4.2. Any statement elsewhere that linkage exists in exactly one
place is wrong; this is the corrected version.

```ruby
# app/models/corvid/shared_payer_rule_contributor.rb  (sketch — internal, no public read API)
module Corvid
  class SharedPayerRuleContributor < ::ActiveRecord::Base
    self.table_name = "corvid_shared_payer_rule_contributors"
    # Deliberately NOT TenantScoped and NOT exposed via any query object
    # used by consumer-facing code (§4.5). Only the aggregation job and
    # a Data Governance Board audit tool may read it. This table is the
    # one place the "who contributed" fact lives — access to it is
    # itself a governance decision, not an engineering default.
  end
end
```

Columns: `tenant_identifier`, `rule_pattern_hash`, `first_contributed_at`.
Unique on `(tenant_identifier, rule_pattern_hash)`.

### 4.4 The shared store itself — deliberately NOT tenant-scoped

This is the first corvid table to deliberately break the "every table is
`TenantScoped`" invariant from ADR-0002 (`default_scope` raising without
tenant context; "no `unscoped` escape hatch in v1"). That invariant is
correct for outcome data and must stay intact for it — this table is a
narrow, explicit, reviewed exception, precedented by the existing
non-tenant-scoped `Corvid::FeeScheduleEntry` / `Corvid::CmsFeeScheduleRelease`
(public CMS data, no tenant column, ADR-0002 decision 6 territory).

**The invariant is enforced by the absence of a column, not by a scope
check** — there is no `tenant_identifier` on this table for a bug to leak
through, mirroring the type-design principle already used for PHI (ADR-0003
doesn't rely on "remember to redact," it removes the column).

```ruby
# app/models/corvid/shared_payer_rule.rb  (sketch)
module Corvid
  class SharedPayerRule < ::ActiveRecord::Base
    self.table_name = "corvid_shared_payer_rules"
    # No TenantScoped. No tenant_identifier column exists on this table —
    # that is the control, not a runtime check.

    validates :payer_identifier, :claim_type, :denial_category, presence: true

    scope :visible, -> { where("contributing_tenant_count >= ?", MIN_CONTRIBUTING_TENANTS) }
    scope :for_payer, ->(id) { where(payer_identifier: id) }
    scope :for_procedure, ->(code) { where(procedure_code: code) }

    MIN_CONTRIBUTING_TENANTS = 5 # Data Governance Board tunable, see §1.3.3
  end
end
```

Columns (sketch): `payer_identifier` (canonical/public payer ID, not a
tenant's `payer_name_token`), `claim_type`, `procedure_code`,
`modifier_codes` (jsonb array), `diagnosis_code_category` (ICD-10
block-level), `carc_code`, `rarc_code`, `denial_category` (normalized
taxonomy — `medical_necessity` / `timely_filing` / `missing_modifier` /
`eligibility` / `auth_required` / ...), `program` (medicaid / medicare /
commercial), `jurisdiction` (state — Medicaid rules vary by state),
`rule_pattern_hash` (unique — the dedup/upsert key, a hash of the fields
above), `contributing_tenant_count`, `observation_count`,
`first_observed_at` / `last_observed_at` (month granularity, §1.3.6),
`pipeline_version` (so a de-identification methodology change is
traceable — relevant to the Expert Determination in §5).

### 4.5 Extraction pipeline (contribution path)

Runs as **one host-scheduled job per tenant**. There is deliberately no
cross-tenant query: `PayerRuleConsent` is itself `TenantScoped` (§4.1), so
corvid cannot enumerate contributing tenants and must not try — without a
tenant context the query raises, and with one it returns only that tenant.
The tenant list belongs to the **host**, which already knows its tenants;
`unscoped` is not an option here, because bypassing tenancy to find out who
consented is the exact capability this design is supposed not to have.

Authorization is checked **at publish time, not at enumeration time**. A
status recheck alone still races a revocation that lands mid-run, so the job
captures `consent_generation` when it starts and re-verifies it inside the
same lock that revocation takes. A revoke bumps the generation, so in-flight
work fails closed rather than finishing — which is what §2.2's "immediately
stops future contribution" actually requires.

```ruby
# Scheduled by the HOST, per tenant. Corvid never picks the tenant list.
class Corvid::PayerRuleExtractionJob
  def perform(tenant_identifier)
    Corvid::TenantContext.with_tenant(tenant_identifier) do
      consent = Corvid::PayerRuleConsent.contributing.order(:granted_at).last
      return unless consent   # no consent -> no data leaves, structurally

      generation = consent.consent_generation
      # Facility precedence from §2.2 — TenantScoped filters by tenant only,
      # so the facility carve-out has to be applied explicitly here.
      facilities = Corvid::PayerRuleConsent.effective_contributing_facilities

      finalized = Corvid::ClaimSubmission.rejected.or(Corvid::ClaimSubmission.paid)
                    .where(facility_identifier: facilities)
                    .where("updated_at > ?", checkpoint_for(tenant_identifier))

      finalized.find_each do |claim|
        # ADR-0003 dereference path — ephemeral, in-memory, never persisted
        # to any corvid table in raw form.
        carc, rarc = extract_from_remittance(claim)  # structured 835, not free text
        procedures = Corvid.adapter.fetch_text(claim.procedure_codes_token)
        diagnoses  = Corvid.adapter.fetch_text(claim.diagnosis_codes_token)
        payer_id   = canonical_payer_id_for(claim.payer_identifier) # public crosswalk

        pattern = build_anonymized_pattern(payer_id:, claim.claim_type, procedures, diagnoses, carc, rarc, ...)
        hash    = pattern.rule_pattern_hash

        # PUBLISH-TIME AUTHORIZATION. Same lock revocation takes, so a revoke
        # that lands mid-run cannot be overtaken by an in-flight publish.
        Corvid::PayerRuleConsent.with_revocation_lock(tenant_identifier) do
          current = Corvid::PayerRuleConsent.contributing.order(:granted_at).last
          raise Corvid::ConsentWithdrawn if current.nil? ||
                                            current.consent_generation != generation ||
                                            !facilities.include?(claim.facility_identifier)

          new_contributor = Corvid::SharedPayerRuleContributor
            .find_or_create_by(tenant_identifier:, rule_pattern_hash: hash)
            .previously_new_record?
          Corvid::SharedPayerRule.upsert_pattern(pattern, new_contributor:)
          Corvid::PayerRuleContributionAudit.create!(rule_pattern_hash: hash, ...)
        end
      end
    end
  end
end
```

`Corvid::ConsentWithdrawn` aborts the run rather than skipping the row: a
revocation part-way through a batch should stop the batch, not quietly
contribute the first half.

Preferring CARC/RARC from the **structured 835 remittance**
(`corvid_billing_transactions`, `transaction_type: "remittance"`) over
parsing `denial_reason_token` free text is a deliberate choice — it avoids
NLP-derived extraction from clinical/administrative narrative text
entirely, which is both more reliable and a smaller PHI-adjacent surface.

### 4.6 Apply learned rules to new claims (consumption path — feeds ENG-1 / ENG-1B)

```ruby
Corvid::PayerRuleAdvisor.risk_signals_for(
  payer_identifier: canonical_payer_id,
  claim_type:,
  procedure_code:,
  modifier_codes:,
  diagnosis_code_category:,
  program:,
  jurisdiction:
)
# => [{ denial_category: "auth_required", confidence: 0.83,
#       suggested_action: "attach prior authorization before submission" }, ...]
```

- Gated to tenants with an active `consume` consent (§2.2, §6 on whether
  consumption requires contribution).
- Only reads `SharedPayerRule.visible` — patterns below the k-anonymity
  threshold are invisible to this API, same as to everyone else.
- **ENG-1 (claim scrubbing):** called from a pre-submission scrub step
  ahead of `ClaimSubmission#submit!` — surfaces "this payer usually denies
  this CPT+modifier combo" before the 837 goes out.
- **ENG-1B (#461, AI coder):** the coder's code-selection/documentation
  step consumes the same signals as additional context — e.g. "payer X
  requires modifier 25 with this E/M code" informs code suggestion, and
  aggregate denial outcomes are the feedback loop ENG-1B's own issue body
  already names (denials from the clearinghouse plus the payer-rules layer
  retrain/tune the coder).

## 5. Legal-review dependency (explicit gate)

**No implementation work on this feature (beyond this design doc and the
consent-model tables, which don't move any cross-tenant data) proceeds
without counsel sign-off on all of the following:**

1. **De-identification methodology — Expert Determination, not Safe
   Harbor.** Per standing practice for tribal data, the k-anonymity +
   category-generalization + small-cell-suppression approach in §1.3 needs
   a qualified statistician's Expert Determination that the shared store
   does not constitute PHI, not an internal engineering assertion that it
   doesn't.
2. **OCAP / data-sovereignty review**, independent of the general HIPAA
   determination above — governance-authority validity (§2.3), whether the
   consent model in §2.2 actually satisfies each contributing tribe's own
   data-sovereignty policy (these are not uniform), and whether a
   Data Governance Board resolution format needs to be standardized across
   tenants or can vary.
3. **Contract/BAA language.** Existing tenant agreements were not written
   with a "contribute de-identified derived statistics to a shared store"
   clause in mind. Needs an explicit amendment or addendum, reviewed
   before any tenant is asked to opt in — not retrofitted after.
4. **Entity/ownership question.** Corvid's stated scope is to own/store
   *no* patient data. Does a cross-tenant
   aggregate statistics store, even PHI-free, sit inside that invariant,
   or does it need to be a distinctly-governed component (e.g. operated
   under a separate data-sharing agreement, possibly outside the corvid
   engine's own repo/ownership boundary)? This is a structural question
   for counsel + product, not resolved by this doc.
5. **Revocation mechanics (§2.2, §6).** What legal obligation exists to
   unwind a tenant's historical statistical contribution on revocation,
   and what's technically meaningful to promise (a k-anonymized aggregate
   generally cannot be cleanly "subtracted" once merged with other
   tenants' contributions without potentially exposing more than it hides).
6. **Value-return commitment (§3.3).** Whether contributing tenants need a
   contractual (not just aspirational) guarantee of benefit from the rules
   their data helped build — this is as much a legal/contract question as
   a product one.

Until counsel and the Data Governance Board process clear these, this
feature stays in "design reviewed, not built" state. ENG-7's task 4
(prototype) is explicitly out of scope for this PR.

## 6. Open questions

- **Give-to-get vs. open consumption** (§2.2, §4.6): should rule
  consumption be gated on contribution, or available to any consenting
  tenant regardless? Product/business decision.
- **k=5 tenant threshold** (§1.3.3): a starting number pending the Expert
  Determination in §5.1 — may need to be higher, or vary by field
  (diagnosis-adjacent patterns may need a higher floor than pure CARC/RARC
  code patterns).
- **Revocation semantics** (§2.2, §5.5): can/should historical aggregate
  contribution be unwound on revocation, and if so how, without breaking
  the k-anonymity guarantee for other tenants who contributed to the same
  pattern?
- **Where does the shared store live** (§5.4): inside corvid's own schema
  (as sketched in §4.4) or as a separately-governed component/service
  outside corvid's "owns no patient data" boundary, given that this table,
  while PHI-free, is nonetheless a cross-tenant derived-data asset that
  behaves differently from everything else the engine owns?
- **CARC/RARC coverage**: not all payers return structured 835 remittances
  cleanly; how much denial-pattern value is lost by preferring structured
  remittance data over parsing `denial_reason_token` free text (§4.5), and
  is that an acceptable trade for avoiding NLP extraction from
  administrative narrative text?

## References

- [ADR 0002: Architectural foundations](../adr/0002-architectural-foundations.md) — tenancy, `TenantScoped`, no unscoped escape hatch
- [ADR 0003: PHI tokenization](../adr/0003-phi-tokenization.md) — vault/adapter, dereference path, Expert-Determination-adjacent compliance-language discipline
- `app/models/concerns/corvid/tenant_scoped.rb` — the invariant this design deliberately carves an exception into (§4.4)
- `app/models/corvid/claim_submission.rb` — `denial_reason_token`, `procedure_codes_token`, `diagnosis_codes_token`, `payer_name_token`
- `app/models/corvid/determination.rb` — `reasons_token`, denial outcomes
- `app/models/corvid/billing_transaction.rb` — remittance transaction log, source for structured CARC/RARC (§4.5)
- `app/models/corvid/fee_schedule_entry.rb`, `app/models/corvid/cms_fee_schedule_release.rb` — existing precedent for a non-tenant-scoped, PHI-free shared table
- `lib/corvid/tenant_context.rb` — `TenantContext.with_tenant`, reused by the extraction pipeline (§4.5) instead of inventing new cross-tenant query capability
- [lakeraven/corvid#463](https://github.com/lakeraven/corvid/issues/463) (ENG-7)
- [lakeraven/corvid#461](https://github.com/lakeraven/corvid/issues/461) (ENG-1B — coder feedback loop consumer)
- `app/services/corvid/prior_authorization_api_service.rb#denial_reason` — existing denial-text dereference pattern this design deliberately avoids reusing for extraction (free text vs. structured CARC/RARC, §4.5)
