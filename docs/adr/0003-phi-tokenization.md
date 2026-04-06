# ADR 0003: PHI tokenization (Stripe-style for HIPAA)

**Status:** Accepted
**Date:** 2026-04-06

## Context

Corvid is a healthcare workflow engine. Without explicit design, it would naturally store Protected Health Information (PHI) — patient names, dates of birth, clinical notes, insurance policy numbers, free-text reasons for referrals, committee rationales — in its own Postgres tables. Any host deploying corvid would inherit a HIPAA-covered data store, with all the operational burden that implies (BAAs, encryption at rest, audit logging, restricted backups, breach notification scope).

We want corvid to follow the **Stripe/PCI playbook**: just as Stripe stores no card data and instead tokenizes cards into opaque references, corvid should store no PHI and instead tokenize all PHI into opaque references resolved by an external vault.

The goal is to make a corvid Postgres dump useless to an attacker without vault access.

## Decision

### 1. Corvid stores no PHI at rest

No `corvid_*` table contains:

- Patient names, dates of birth, MRNs, SSNs
- Practitioner names (other than internal display, which is also tokenized)
- Clinical free text (notes, reasons, rationales, narratives)
- Insurance policy numbers, payer names
- Diagnoses, conditions, clinical observations

**Acceptance criterion:** A corvid database dump, viewed without vault access, must reveal no PHI. An attacker sees only opaque tokens, workflow state (enums), counts, amounts, and timestamps.

### 2. The vault interface is the adapter

Corvid does not define a separate vault concept. The existing `Corvid.adapter` interface is the vault:

```ruby
# Identity lookup — returns reference, not PHI
Corvid.adapter.find_patient(patient_token)
# → PatientReference(identifier: "pt_01HK8B...", ...non-PHI metadata...)

# Dereference for in-memory display (request-scoped)
Corvid.adapter.dereference(token)
# → { display_name: "Doe, Jane", dob: Date.new(1980,1,15), ... }

Corvid.adapter.dereference_many([token1, token2, ...])
# → { token1 => {...}, token2 => {...} }

# Free-text storage (notes, reasons, rationales)
Corvid.adapter.store_text(case_token:, kind: :note, text: "Patient prefers...")
# → "nt_01HK8C..."

Corvid.adapter.fetch_text(text_token)
# → "Patient prefers..."

# Patient search (deferred to v2)
Corvid.adapter.search_patients(query)
# → ["pt_01HK8B...", "pt_01HK8D...", ...]
```

The reference vault implementation is **lakeraven-ehr**, which already holds the clinical record. There is no mandatory standalone `corvid-vault` service in v1. A dedicated vault service may be added later for deployments that need it (e.g. corvid without lakeraven-ehr).

### 3. Tokenization scope

| Field type | Storage in corvid |
|---|---|
| Patient name, DOB, MRN, SSN | Never. Token only (`patient_identifier`). |
| Practitioner name, NPI | Never. Token only (`practitioner_identifier`). |
| Clinical free text (notes, reason, rationale, narrative) | Token only (`*_token` columns reference vault). |
| Insurance policy numbers | Token only (`policy_token`). |
| Payer names | Token only (`payer_token`). |
| jsonb clinical blobs (conditions, attendees, documents) | Single blob token per field. |
| Workflow dates (committee_date, due_at, completed_at) | Stored as date. Workflow-essential. Documented combination risk. |
| Status, priority, decision codes | Stored as enum strings. Not PHI alone. |
| Amounts (estimated_cost, approved_amount) | Stored as decimal. Not PHI alone. |
| `*_identifier` columns | Stored as opaque vault tokens. |

**Workflow dates:** Dates like `committee_date` are workflow-essential and stored. They can be identifying in combination with other data. The engine never stores DOB directly (that's identity-class PHI). Combination risk is documented as a host responsibility.

### 4. Token format: prefixed ULIDs

Tokens are prefixed ULIDs:

```
pt_01HK8B7Z9XCQVG3F8N5K0R4MWB    patient
pr_01HK8B7Z9XCQVG3F8N5K0R4MWC    practitioner
rf_01HK8B7Z9XCQVG3F8N5K0R4MWD    referral
nt_01HK8B7Z9XCQVG3F8N5K0R4MWE    note
rn_01HK8B7Z9XCQVG3F8N5K0R4MWF    rationale
rs_01HK8B7Z9XCQVG3F8N5K0R4MWG    reason
po_01HK8B7Z9XCQVG3F8N5K0R4MWH    policy
py_01HK8B7Z9XCQVG3F8N5K0R4MWI    payer
cn_01HK8B7Z9XCQVG3F8N5K0R4MWJ    conditions blob
tnt_01HK8B7Z9XCQVG3F8N5K0R4MWK   tenant
fac_01HK8B7Z9XCQVG3F8N5K0R4MWL   facility
```

**Why ULID + prefix:**
- ULIDs are sortable (timestamp-prefixed)
- Prefix shows token type without revealing PHI
- Operators can grep logs by type (`grep pt_` for patient tokens)
- Opaque to anyone without vault access

The engine does not generate tokens (the vault does). Engine receives tokens from adapters and stores/queries them.

### 5. MockAdapter vault

For dev and tests, `MockAdapter` includes an in-memory vault:

```ruby
class Corvid::Adapters::MockAdapter < Base
  def initialize
    @text_store = {}
    @patients = {}
    # ...
  end

  def store_text(case_token:, kind:, text:)
    token = "#{kind_prefix(kind)}_#{ULID.generate}"
    @text_store[token] = text
    token
  end

  def fetch_text(token)
    @text_store[token]
  end
end
```

**MockAdapter is not a security boundary.** It is for dev and test only. Production deployments must wire a real vault adapter.

### 6. `cases.conditions` (jsonb)

Single blob token for the entire conditions payload in v1. The engine stores `conditions_token` which dereferences to the original jsonb. Splitting into per-condition tokens is deferred to v2 if per-condition editing is needed.

### 7. Production migration story

Hosts adopting corvid in production must run a one-time PHI migration:

1. **Vault write** — push existing PHI text into the vault, receive tokens
2. **Verify** — confirm round-trip: `fetch_text(token) == original`
3. **DB update** — replace text column with token in corvid table
4. **Optional clear** — delete the text from any host duplicate

This runs with vault credentials. It is a one-time migration, scheduled with maintenance window. It is **not** a hot path; the engine does not lazy-migrate.

Bridge mode (legacy rows keep text until touched) is acceptable as a short-term mitigation but should be scheduled for full migration. New rows always use tokens.

### 8. Search

**v1: punt.** No patient/name search inside corvid. Hosts implement search via vault, return matching token lists, then query corvid filtered by `WHERE patient_identifier IN (...)`.

**v2: optional `adapter.search_patients(query)`** returning token lists only. Engine receives tokens, does not see names.

### 9. Fixtures and seed data

Test fixtures use obviously synthetic strings:

- `"TEST PATIENT 001"`, `"MOCK NOTE 001"`, `"SYNTHETIC RATIONALE"`
- Not realistic clinical prose
- Not realistic-sounding fake names like "DOE,JANE"

This reduces accidental PHI-shaped data in screenshots, error messages, and contributor environments. It also exercises the token round-trip end-to-end with non-PHI content.

### 10. PHI sanitizer (still required)

Even with tokenization, PHI can transit corvid memory during a request:

- Adapter responses contain dereferenced PHI in memory until the request ends
- Exception messages from the adapter may contain PHI
- Logs may inadvertently capture PHI from in-memory objects

The `Corvid.configuration.phi_sanitizer` hook stays. Default is **fail-safe redact-all**: if the host does not configure a sanitizer, corvid replaces all log/exception strings with a generic `[REDACTED]` rather than passing through. This prevents accidental PHI leakage when sanitizer wiring is forgotten.

```ruby
# Default behavior
Corvid.sanitize_phi("Patient Doe, Jane has issue X")
# → "[REDACTED]"

# With host sanitizer
Corvid.configure do |c|
  c.phi_sanitizer = ->(msg) { PhiSanitizer.redact(msg) }
end
Corvid.sanitize_phi("Patient Doe, Jane has issue X")
# → "Patient [REDACTED] has issue X"
```

### 11. Adapter error wrapping

All adapter exceptions must be sanitized before re-raising:

```ruby
def find_patient(token)
  adapter.find_patient(token)
rescue => e
  raise Corvid::AdapterError, Corvid.sanitize_phi(e.message)
end
```

### 12. Soft delete and retention

Corvid does not implement soft-delete columns (`deleted_at`). Retention policies are a host responsibility under HIPAA. The engine provides a `Corvid::Case#purge` cascading helper for deletion-on-request, but does not orchestrate retention timelines.

### 13. Column-level encryption

Not needed for v1. Since no PHI is stored at rest, there is nothing to encrypt at the column level. Hosts that want defense-in-depth can enable Postgres TDE or disk-level encryption at the infrastructure layer.

If a future need emerges (e.g. encrypting `notes_token` itself), an opt-in `Corvid.configuration.encrypt_phi_fields = true` flag can be added later.

### 14. Read audit logging

Read audit logging is a host responsibility. Corvid exposes `Corvid.current_tenant_identifier` and `Corvid.current_user_identifier` for host middleware to record. The engine does not implement its own request audit log.

## Consequences

### Positive

- **Reduced PHI footprint at rest in corvid.** A leaked corvid database dump is useless without vault access.
- **Postgres backups can use standard storage** (S3 standard) rather than HIPAA-eligible only — operational cost reduction.
- **Sentry / error tracking is naturally PHI-free** for engine code paths that don't dereference.
- **Open-source contributors can work on corvid** without ever touching real PHI.
- **Per-tenant breach scope is limited** — vault is the single point of compromise, not every corvid deployment.
- **Audit logging at the vault layer** is a single chokepoint instead of scattered across many services.

### Negative

- **Vault round-trips for every UI render.** List views must batch dereference, which adds latency. Mitigations: `dereference_many`, request-scoped memoization, host-side TTL caches with PHI controls.
- **Vault becomes a critical dependency.** Engine workflow runs without vault, but any user-facing rendering needs it.
- **Search is harder.** Cannot `WHERE patient_name LIKE 'Doe%'` in corvid. Host must search via vault, return tokens.
- **Reporting is harder.** Reports that need PHI joins must run in the vault layer or aggregate de-identified.
- **Token rotation strategy needed.** If a token is exposed (e.g. in a leaked URL), the vault must support rotation. v1 punts on this; tokens are stable.
- **Production migration is mandatory** for hosts moving from text-stored PHI to tokenized PHI.
- **Engineering discipline required for in-memory PHI.** PHI still flows through corvid memory during requests; sanitizer hook and error wrapping are essential.

### Compliance language (avoid overreach)

This ADR makes engineering claims, not legal claims:

- ✓ "Corvid stores no PHI at rest in `corvid_*` tables"
- ✓ "Corvid Postgres dumps contain only opaque tokens and workflow state"
- ✓ "PHI may transit corvid memory during a request via adapter responses"
- ✗ "Corvid is not a HIPAA Business Associate" (legal conclusion)
- ✗ "corvid-saas is HIPAA-Lite" (legal conclusion)
- ✗ "Hosts running corvid don't need a BAA" (legal conclusion)

Tokenization reduces PHI at rest in corvid. Whether a corvid deployment requires BA-level handling depends on host-specific factors (logging, support access, request memory) and is determined by counsel, not by this ADR.

### Alternatives considered

- **Persist PHI with column encryption only.** Rejected — encryption doesn't help with backups, error logs, or developer access. Tokenization is the stronger control.
- **Identity-only tokenization (names + DOB), keep free text.** Rejected — clinical free text is the largest PHI surface. Tokenizing only names doesn't get the "Postgres dump test" win.
- **Standalone `corvid-vault` microservice from day one.** Rejected — adds an operational dependency that v1 doesn't need. Reference vault = lakeraven-ehr is sufficient.
- **Apartment-style schema isolation as a substitute for tokenization.** Rejected — schema isolation prevents cross-tenant access but does nothing about within-tenant PHI exposure. Different concern.

## References

- [HIPAA 18 Identifiers (Safe Harbor)](https://www.hhs.gov/hipaa/for-professionals/privacy/special-topics/de-identification/index.html)
- [Stripe PCI tokenization model](https://stripe.com/docs/security/guide)
- [ULID specification](https://github.com/ulid/spec)
- ADR 0001 (id vs identifier naming)
- ADR 0002 (architectural foundations)
