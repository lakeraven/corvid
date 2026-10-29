# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed (breaking)
- Host adapters must accept the `date_of_service:` keyword on
  `verify_eligibility` and `check_eligibility_detailed` and echo
  `:date_of_service`. A Medicaid check verified while the service is
  inactive is recorded `not_enrolled` and is not current (re-verify).
  (#712)
- `corvid_eligibility_checklists.application_completed_by` and
  `management_approved_by` are renamed to `application_completed_by_identifier`
  and `management_approved_by_identifier`. They hold a practitioner identifier
  (ADR 0001). `verify_item!` and `EligibilityChecklistService.approve!` still
  take `by:`.
- Claim rejections and denials are now separate. A rejection is a front-end
  refusal before adjudication (999 / 277CA); a denial is the payer's
  adjudicated decision on the 835. `Corvid::ClaimSubmission.rejected` and
  `#rejected?` now mean `rejected` only; use `.denied` / `#denied?` for
  denials, or `.rejected_or_denied` / `#rejected_or_denied?` for the old
  combined meaning. `#mark_rejected!` now writes `rejection_reason_token`
  instead of `denial_reason_token`.

### Added
- Eligibility reads take `date_of_service:` (`Date`, or omitted). A non-Date
  raises `ArgumentError` before the adapter is called, and the message does
  not include the value. `verify_eligibility` and `check_eligibility_detailed`
  include `:date_of_service` (the date answered for, `Date.current` when
  omitted) and `:date_of_service_defaulted`.   `AlternateResourceCheck#verify!`
  accepts the same keyword and passes a referral `service_date` when that
  column holds a `Date`. `AlternateResourceReverification` passes the judged
  date into `verify!` unchanged. A non-Date raises `ArgumentError` from
  `verify!` and is not coerced. An adapter that does not declare
  `date_of_service:` is called without that keyword. When a date was asked, the adapter must echo that
  exact `Date`; a missing, nil, or different `:date_of_service` is not an
  answer and the row is unchanged. `inquiry_date_of_service` stores the asked
  date. When nothing was asked, it stores the adapter's exact `Date`,
  otherwise nil, which clears a previous inquiry. The Medicaid eligibility
  group uses the inquiry date, then the referral service date, then
  `checked_at`.
- Month-bounded eligibility is always `medicaid`, plus any names in
  `month_bounded_eligibility_resource_types` compared case-insensitively.
  Nil or a non-array does not remove medicaid. A check is current only in
  the year-month of `inquiry_date_of_service`. A saved check with no inquiry
  date is not current.
- Placeholder coverage ends are stored as nil on `coverage_end` and
  `renewal_date`. `9999-12-31` is always a placeholder. An Array in
  `placeholder_coverage_end_dates` adds exact `Date`s and ISO 8601 strings
  (`Date.iso8601`); other elements and a non-Array are ignored and do not
  raise. An end more than `placeholder_coverage_end_horizon_years` after the
  inquiry date is also open (25 when that setting is not a positive integer;
  `Time.current.to_date` when there is no inquiry date). An end exactly that
  many years out is kept. `service_active: false` records `not_enrolled`
  even when the plan dates cover the inquiry, and that check is not current.
  A present non-boolean `service_active` is not an answer. Mock
  `verify_eligibility` returns nil when `service_active` is present and not
  exactly true, false, or nil. `check_eligibility_detailed` reads the same
  coverage row and date, including a seeded Medicaid scenario, and keeps an
  explicit nil `coverage_end` instead of defaulting that nil to December 31.
  A non-boolean `service_active`, or a non-boolean `eligible` on the row,
  leaves detailed `eligible` nil (the same undetermined detailed result, not
  eligible false). Boolean `service_active` is still passed through. Plan
  dates that miss the inquiry are not eligible, for both reads.
  `:active_this_month_only` stores the first and last day of the month of
  `Date.current` at seeding; other seeded scenarios still follow the inquiry
  month. FHIR `Coverage.status` is today's state. Missing data is never a
  negative answer. A Coverage matches the requested type when any
  `type.coding` code is the type name or its mapped ActCode. Applicable rows
  are matches whose present period bounds do not exclude the inquiry date.
  When none apply, the answer is eligible false from a matching Coverage
  whose bounds exclude the date. Any applicable row that cannot be judged
  makes the answer nil. Applicable rows that are determinable and agree
  answer from the row with the latest period start; a nil start sorts
  earliest. Disagreeing applicable rows are nil. The first entry is never a
  fallback. A false answer is nil when that type's ActCode is shared with
  another resource type in the adapter map, counted from the map itself. A
  present period bound that excludes the inquiry is eligible false for every
  status. Eligible is true when status is active and either the inquiry is
  in the current year-month and the present period bounds cover it, or both
  start and end are present and cover the inquiry. Explicit `cancelled` is
  eligible false when the inquiry is in the current month and the bounds
  cover it or are absent. A cancelled Coverage whose start and end cover an
  inquiry outside the current month is nil. An absent status, `draft`,
  `entered-in-error`, or any other status is nil when the bounds do not
  exclude the inquiry. Otherwise FHIR `verify_eligibility` returns nil and
  the check row stays unchanged.
- `demo:prc` stamps the seeded Medicaid alternate-resource check with
  `inquiry_date_of_service` of `Date.current`, the date the demo judges, so
  the narrated path authorizes. (#712)
- ZIP-to-CBSA wage-area crosswalk (#371). `corvid_zip_cbsa_crosswalks`
  stores the CMS crosswalk by federal fiscal year (`zip` is five ASCII
  digits; `cbsa` is a five-digit CBSA or a two-digit rural-state code;
  `fiscal_year` is 2000 through 2100). `rake cms:zip_cbsa:import`
  replaces that year's rows from a canonical CSV when the file has data
  rows. Carriage returns are rejected on every line, including comments.
  Imports of the same year are serialized, and a conflicting row aborts
  the import. The year argument must be four digits in 2000..2100, or
  the task aborts with usage before reading the file. `release_label`
  comes only from the third argument (default `manual`), not from a
  file comment.
  A file with no data rows is refused and that year's rows stay
  untouched. `Corvid::PrcFacilityDictionary.cbsa_for` resolves a ZIP or
  ZIP+4 for the fiscal year of the service date, one indexed query per
  call, with no cache. With no row for that year it returns nil and
  institutional pricing stays on the NATIONAL wage index.
- `corvid_claim_submissions.rejection_reason_token`, `denial_reason_codes`
  (CARC/RARC codes), `rejected_at` and `denied_at`. The timestamps are kept
  after the status moves on, so a claim rejected or denied and later paid
  still counts. The migration moves existing rejection reasons out of
  `denial_reason_token` and stamps currently rejected/denied rows with
  `updated_at`.
- `Corvid::ClaimSubmission#mark_denied!(reason_codes:, reason_token:)`.
- KPI helpers on any claim scope: `rejection_rate`, `denial_rate`,
  `first_pass_rate` and `payment_rate`.
- `Corvid::RemittanceProcessor` applies 835 remittances from
  `Corvid.adapter.fetch_remittances`, marking denied line items denied with
  their adjustment codes and paid line items paid.
- Adapters may return `rejection_reason_token` and `denial_reason_codes` from
  `check_claim_status`.

### Deprecated
- `Corvid::ClaimSubmission.acceptance_rate`. It always computed paid over
  finalized claims, which is a payment rate; it now delegates to
  `payment_rate`.

### Removed
- `corvid_case_programs.program_name`. Issue #591 classified the column as
  patient PHI, and it duplicated `program_code`, which is NOT NULL, unique
  per case, and validated against `Corvid::ProgramRegistry`.
  `Corvid::CaseProgram#program_name` is now derived from the stripped registry
  display name. An unregistered code, or a missing or blank display name,
  makes the derived name the raw code. `#as_json` no longer includes
  `program_name`, and `where(program_name:)` no longer works. Passing
  `program_name:` raises `ActiveModel::UnknownAttributeError`. `up` counts a
  stored label as drifted only when it equals none of the three historical
  forms for its code: stripped
  (`display_name.to_s.strip.presence || program_code`), presence
  (`display_name.presence || program_code`), and raw
  (`display_name || program_code`). It raises
  `RemoveProgramNameFromCorvidCasePrograms::UnmappedProgramNames` with that
  count and the count of unregistered codes. Export first, or set
  `CORVID_DISCARD_PROGRAM_NAMES=1` to drop the column anyway. A rollback
  re-adds the column and backfills it with the stripped rule.
- `corvid_cases.patient_name_cached` and `corvid_cases.patient_dob_cached`,
  and `Corvid::Case#cache_patient_data!` which was their only writer. ADR 0003
  states no `corvid_*` table stores a patient name or date of birth; these were
  opt-in but present in the schema, which is what an evaluator reads.
  **Any data in those columns is discarded when the migration runs. Export it
  first if your host called `cache_patient_data!`.** The migration raises
  `ActiveRecord::IrreversibleMigration` on `down` by design — re-adding columns
  that store patient names at rest should be a new decision with a new ADR, not
  a rollback. If you genuinely need them back, the manual path is `add_column`.
- `corvid_cases.closure_reason`. Nothing in the engine read or wrote it.
  `down` adds the nullable string column back; any previous values are gone.
- `corvid_claim_submissions.provider_type`. Nothing in the engine wrote it,
  and a token check would still have accepted PHI-shaped values. `down` adds
  the nullable string column back; any previous values are gone.
- `corvid_prc_payments.check_number` and the `Corvid::PrcPayment#check_number`
  attribute. The #591 PHI disclosure classifies a cheque number as patient
  PHI, and nothing in Corvid read it. `Corvid::PrcImporter` no longer stores
  it; `Corvid::PrcReportParser` still reads it into the in-memory `Payment`
  struct. **Any data in the column is discarded when the migration runs.
  Export it first if your host reads it.** Rolling back re-adds an empty
  nullable column and cannot restore values. (#702)

### Changed
- Postgres CHECK constraints and foreign keys now bound columns that
  accepted any string. Value lists: `corvid_prc_referrals.priority_system`
  (`corvid_v1`), `corvid_prc_eligibility_decisions.provider_confidence`
  (`verified`, `stale`, `unavailable`),
  `corvid_prc_overpayment_analyses.payment_system` (`pfs`, `ipps`, `asc`,
  `opps`) and `recovery_confidence` (`clear`, `stub_estimate`,
  `no_rate_for_year`, `unmapped_procedure`, `unmapped_facility`,
  `missing_service_date`). `corvid_fmap_determinations.jurisdiction` is two
  uppercase letters, and `missing_evidence` is a jsonb array drawn from the
  six-term evidence vocabulary. `best_available_rule_key` and `rule_key`
  reference `corvid_fmap_rules.rule_key`. Nullable columns still allow NULL.
  `corvid_prc_obligations.status` is left unconstrained (owner decision
  pending). The migration counts existing violating rows and aborts without
  updating or coercing them when any row would fail a new constraint.
  Deployments that ran `FhirAdapter` before #665 may have
  `corvid_prc_eligibility_decisions.provider_confidence` values outside
  `verified`, `stale`, and `unavailable`, and the migration will then abort
  with a count. List the offending values before migrating:

      SELECT DISTINCT provider_confidence
      FROM corvid_prc_eligibility_decisions
      WHERE provider_confidence IS NOT NULL
        AND provider_confidence NOT IN ('verified', 'stale', 'unavailable')

  Decide whether to null them (these are audit rows) before re-running.
  `FmapClassificationService.classify!` now raises `RecordInvalid` for a
  jurisdiction that is not two upper-case letters (for example 'ak'), where
  it used to persist a federal-only row.
- `Corvid::TribalEligibilityService` now returns and persists a nil
  `provider_confidence` for out-of-contract adapter confidence. This is an
  API output change.
- `Corvid::Case#display_name` no longer falls back to a stored name. It
  resolves through `Corvid.adapter` for the duration of the call and returns
  `"Unknown Patient"` when the patient cannot be resolved. A host without vault
  access now shows a placeholder rather than a cached name.

### Added
- `test/corvid/no_cached_patient_phi_test.rb` — asserts the two removed columns
  cannot return, that `cache_patient_data!` is gone, and that a resolved
  display name never reaches the persisted row. Runs in CI via `rake test_lib`.
- Initial Rails engine scaffold (gemspec, Engine, Configuration, version)
- Adapter base contract (`Corvid::Adapters::Base`) covering patient,
  practitioner, referral, vault, budget, eligibility, care team
- `Corvid::Adapters::MockAdapter` — in-memory dev/test adapter with
  prefixed ULID vault tokens (NOT a security boundary)
- `Corvid::Adapters::FhirAdapter` — generic FHIR R4 client with
  ServiceRequest extension storage for committee fields
- Value objects (`PatientReference`, `PractitionerReference`,
  `ReferralReference`, `CareTeamMemberReference`) — immutable, typed,
  use `identifier`/`*_identifier` per ADR 0001
- `Corvid::TenantContext` with thread-local storage and fail-loud
  `require_tenant!`
- `Corvid::Configuration` with fail-safe `phi_sanitizer` default,
  `on_provenance` and `fetch_provenance` hooks
- 9 ActiveRecord models (Case, PrcReferral, Task, CareTeam,
  CareTeamMember, CommitteeReview, Determination,
  AlternateResourceCheck, FeeSchedule) with `corvid_*` table prefix,
  string enums, polymorphic same-tenant validation
- `Corvid::TenantScoped` concern with default_scope that raises
  `Corvid::MissingTenantContextError` if no tenant context
- `Corvid::Determinable` concern for record_determination! mixin
- 11 services covering Case/PRC workflows
- Consolidated schema migration with PG CHECK constraints on all enums
- Test/dummy Rails app for engine testing
- 116 tests covering lib, models, and services
- ADRs 0001 (identifier naming), 0002 (foundations),
  0003 (PHI tokenization)
- README, MIT-LICENSE, .gitignore, Rakefile, Gemfile
