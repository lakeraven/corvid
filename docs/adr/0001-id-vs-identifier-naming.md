# ADR 0001: Reserve `id`/`*_id` for Rails keys; use `identifier`/`*_identifier` for external IDs

**Status:** Accepted
**Date:** 2026-04-06

## Context

Corvid stores Case-domain workflow state in its own Postgres tables (`corvid_cases`, `corvid_prc_referrals`, etc.) but many of those tables hold references to entities owned by external systems — patients live in the EHR, practitioners live in the EHR, clinical ServiceRequests live in the EHR. These references are stored as opaque strings (vault tokens, per ADR 0003) and resolved via the adapter at read time.

The default Rails convention suffixes reference columns with `_id`, regardless of whether they're foreign keys to local tables or pointers to external systems. This conflates two distinct concepts:

1. **Rails keys** — primary and foreign keys managed by ActiveRecord, backed by `belongs_to` associations, joinable, guaranteed to exist locally
2. **External identifiers** — opaque strings whose meaning depends on the adapter wiring, resolved at runtime via `Corvid.adapter`, not backed by any local table

Conflating them creates three problems:

- **Reader confusion.** A new contributor sees `cases.patient_id` and reasonably assumes there's a `patients` table. There isn't — Patient is an adapter concept.
- **Foot-guns.** Easy to accidentally treat external IDs as Rails FKs (e.g. using them in `joins`, trusting them to resolve locally, adding `belongs_to :patient`).
- **Tool alignment.** Rails tooling (`bin/rails generate`, scaffolds, migrations) assumes `*_id` means FK. Our usage fights the framework.

## Decision

Adopt the following naming convention across the Corvid engine:

- **`id`** — Rails primary key
- **`*_id`** — Rails foreign key to a Corvid-owned table; used with `belongs_to`
- **`identifier`** — opaque external/vault token, resolved via adapter
- **`*_identifier`** — opaque external/vault token with a role suffix (`patient_identifier`, `referral_identifier`, `tenant_identifier`, etc.)

Applies to:

1. Database columns on Corvid-owned tables
2. Value object fields (`PatientReference`, `PractitionerReference`, etc.)
3. Adapter method parameters and return hashes
4. Service method keyword arguments that accept external references

### Schema mapping

| Old | New |
|---|---|
| `cases.patient_id` | `cases.patient_identifier` |
| `prc_referrals.referral_id` | `prc_referrals.referral_identifier` |
| `care_team_members.practitioner_id` | `care_team_members.practitioner_identifier` |
| `committee_reviews.reviewer_id` | `committee_reviews.reviewer_identifier` |
| `determinations.determined_by_id` | `determinations.determined_by_identifier` |
| `tasks.assignee_id` | `tasks.assignee_identifier` |
| (new) | All tables: `tenant_identifier` (NOT NULL), `facility_identifier` (nullable) |

Rails foreign keys (`facility_id`, `case_id`, `care_team_id`, `prc_referral_id`, polymorphic `taskable_id` / `determinable_id`) are unchanged.

### Value object rename

`ReferralRecord` previously had a field called `identifier` holding the EHR-assigned authorization number (e.g. `"AUTH-2024-100"`). Under the new convention, `identifier` is reserved for the opaque vault token, so this field is renamed to `authorization_number` — a more descriptive name for what it actually holds.

```ruby
ReferralRecord.new(
  identifier: "rf_01HK8B...",        # vault token
  patient_identifier: "pt_01HK8C...", # vault token
  authorization_number: "AUTH-2024-100"  # business value (not a token)
)
```

## Consequences

### Positive

- **Unambiguous reading.** A contributor can tell at a glance whether a column is a Rails FK or an external reference.
- **FHIR alignment.** FHIR draws exactly the same line: `id` = server technical ID, `identifier` = business identifier from another system. Corvid's domain is healthcare-adjacent, so this is semantically correct.
- **Framework alignment.** `*_id` now only appears where Rails tooling expects it.
- **Safer refactoring.** Much harder to accidentally add `belongs_to :patient` when the column is `patient_identifier` rather than `patient_id`.

### Negative

- **Verbosity.** `late_notification_documented_by_identifier` is long. We accept verbosity over ambiguity.
- **Host migration cost.** Hosts consuming Corvid must use `*_identifier` everywhere. Since the engine is pre-1.0, this cost is minimal.

### Alternatives considered

- **Keep `*_id` and document in comments.** Rejected — comments don't prevent `belongs_to` mistakes, ambiguity remains in every query and test.
- **`external_id` / `*_external_id`.** Rejected — less precise than `identifier`. FHIR convention is clearer.
- **`reference` / `*_reference`.** Rejected — FHIR uses `reference` to mean a specific format (`resourceType/id`). Overloading would confuse FHIR-literate readers.

## References

- [FHIR Resource Identity](https://hl7.org/fhir/resource.html#identifiers)
- [Rails naming conventions](https://guides.rubyonrails.org/active_record_basics.html#schema-conventions)
- ADR 0002 (architectural foundations)
- ADR 0003 (PHI tokenization)
