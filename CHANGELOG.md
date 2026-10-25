# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed (breaking)
- `corvid_fmap_determinations.claim_reference` is renamed to `claim_identifier`
  (ADR 0001). `FmapDetermination#claim_identifier` and
  `FmapClassificationService.classify!(claim_identifier:)` replace
  `claim_reference`. When present, the value must be an opaque token
  (`Corvid::OpaqueToken::FORMAT`, ADR 0003 §4), checked on the model and by
  a CHECK. The immutability error no longer includes the token.
- Each `evidence_refs` element must be an object with exactly the keys
  `supports` and `ref`: `supports` is one of `FmapRule::CALLER_EVIDENCE_KINDS`
  and `ref` is an opaque token. The model reports that contract without
  including the stored value. `FmapClassificationService.classify` and
  `classify!` raise `ArgumentError` before storing a non-token ref, and that
  message does not include the value. The CHECK requires a JSON array of
  those objects, so a bare object, a nested array, or a non-string `ref` is
  rejected. Blank refs are still dropped by `FmapRule.normalize_evidence`
  and are not stored.
- `corvid_prc_referrals.current_activity` free text is replaced by the string
  enum `current_activity_code` (`submitted_via_fhir_pas`,
  `assigned_to_reviewer`) and `reviewer_identifier` (an opaque token, required
  when the code is `assigned_to_reviewer`). `PrcReferral#current_activity` is
  derived display text ("Submitted via FHIR PAS" / "Assigned to reviewer")
  and does not include the reviewer token. The migration maps only the exact
  engine literal `Submitted via FHIR PAS` to `submitted_via_fhir_pas`. Every
  other `current_activity` value is dropped and is not parsed.
- `ReplaceFreeTextWithTokens#up` aborts, before changing the schema, when any
  `claim_reference` is not a token or any `evidence_refs` value is not an
  array of `{ supports, ref }` entries. The error reports row counts only
  and does not include the stored values.
- The model and `FmapClassificationService` never echo stored values. The
  database backstop's CHECK-violation detail can: Postgres includes the
  failing row when a write bypasses validations (`update_columns`,
  `insert_all`, `upsert_all`). Callers should not log raw
  `ActiveRecord::CheckViolation` messages.
- Claim rejections and denials are now separate. A rejection is a front-end
  refusal before adjudication (999 / 277CA); a denial is the payer's
  adjudicated decision on the 835. `Corvid::ClaimSubmission.rejected` and
  `#rejected?` now mean `rejected` only; use `.denied` / `#denied?` for
  denials, or `.rejected_or_denied` / `#rejected_or_denied?` for the old
  combined meaning. `#mark_rejected!` now writes `rejection_reason_token`
  instead of `denial_reason_token`.

### Added
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
- `corvid_cases.patient_name_cached` and `corvid_cases.patient_dob_cached`,
  and `Corvid::Case#cache_patient_data!` which was their only writer. ADR 0003
  states no `corvid_*` table stores a patient name or date of birth; these were
  opt-in but present in the schema, which is what an evaluator reads.
  **Any data in those columns is discarded when the migration runs. Export it
  first if your host called `cache_patient_data!`.** The migration raises
  `ActiveRecord::IrreversibleMigration` on `down` by design — re-adding columns
  that store patient names at rest should be a new decision with a new ADR, not
  a rollback. If you genuinely need them back, the manual path is `add_column`.

### Changed
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
