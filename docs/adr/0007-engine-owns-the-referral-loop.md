# ADR 0007: The engine owns the referral loop and reads any EHR

**Status:** Proposed
**Date:** 2026-10-08

## Context

Corvid is meant to be EHR-agnostic: a clinic on any certified EHR authorizes PRC care, and a
receiving specialist on any EHR, or none, sees what they need and reports whether the care
happened. Today the closing half of that loop lives in a host application, not in this engine:

| Capability | Where it lives today | Problem |
|------------|----------------------|---------|
| Sending an authorized referral to a receiving provider (the dispatch record, its locking and re-checks) | Host model + controller | Another host gets the workflow but not the hand-off |
| Reading the patient's problems and medications for the specialist | Host `ChartSource` service (SMART Backend Services, `private_key_jwt` RS384) | A second FHIR client beside `Corvid::Adapters::FhirAdapter`, configured by environment variables |
| Publishing the public key set the EHR verifies Corvid against | Host JWKS endpoint | One key per deployment, not per engine |
| What a receiving provider may see and do (only their dispatches, only while authorized, outcome-only reports) | Host controllers | Authorization rules for clinical data enforced outside the engine |
| Referral rules the host works around: the `cancel` event's missing `from:` states, a default medical priority, the intake submitter for dual control, creating referrals without model validations | Host controller constants and comments | Engine defects patched per host |
| Claim lifecycle against the EDI adapter, because `ClaimSubmission#submit!` calls `Corvid.adapter` instead of `Corvid.edi_adapter` | Host controller | Same |
| Facility eligibility rules (on-reservation and SSN-on-file requirements) | Host controller | PRC policy outside the engine |

Two further facts shape the decision:

1. **The engine's FHIR adapter is already the right seam.** It speaks FHIR R4 to any server, but
   authenticates with one static bearer token. Certified EHRs expose standard FHIR read APIs, and
   certification requires SMART Backend Services for bulk export; many also allow system-scoped
   searches for a single patient, which is what this read needs, though certification does not
   require it. A static token works with none of them in production.
2. **One EHR connection per process.** Both the adapter and `ChartSource` are configured at boot.
   ADR 0005 already names per-tenant adapter routing as the missing capability; a clinic on one
   EHR and a clinic on another cannot share a deployment.

Several properties are also missing wherever the code lives, and are cheaper to build once in the
engine than per host:

- **Part 2 records.** The problem list reaches the specialist unfiltered. A substance use
  disorder diagnosis from a 42 CFR Part 2 program needs the patient's consent before it is
  disclosed, even for treatment.
- **Per-view audit.** The EHR's log records Corvid's client, not the specialist. Nothing
  records which receiving user opened which chart, and when.
- **Revocation and expiry.** A dispatch grants access for as long as the referral stays
  authorized; there is no way to withdraw it and no time limit.
- **Grant granularity.** A dispatch grants access to every user of the receiving organisation.

## Decision

1. **The engine owns the referral loop end to end.** Dispatch to a receiving provider, the
   receiving provider's view of the referral, the chart read for that view, and the fulfilment
   report all move into the engine as models and services with their authorization rules. A host
   supplies identity (who is signed in, which account they act for, whether that account is a
   receiving provider) and screens; it makes no access decisions about referrals or clinical data.

2. **One FHIR client, with SMART Backend Services.** `Corvid::Adapters::FhirAdapter` gains
   `private_key_jwt` client-credentials authentication (RS384, `aud` = token endpoint, short-lived
   assertions, token reuse with a floor, eviction on 401), carried over from `ChartSource` with its
   fail-closed parsing: a declared `Bundle` of type `searchset`, exactly one matching patient,
   same-origin paging with a page limit, and a refusal when `total` disagrees with what was read.
   The static-token mode stays for local stand-ins. `ChartSource` is retired; its callers use a
   `Corvid::ChartSummary` service over the adapter.

3. **Each clinic configures its own EHR connection.** A tenant-scoped connection record holds the
   FHIR base URL, token URL, client id and the identifier system that names the clinic's patients.
   Secrets are encrypted at rest. The engine keeps one signing key set, published by an engine
   route, which each clinic registers with its EHR. Adapter resolution follows ADR 0005: services
   take `adapter:`, and the tenant's connection builds it.

4. **US Core is the contract.** The chart summary reads `Condition` and both `MedicationRequest`
   and `MedicationStatement`, labels from `CodeableConcept.text` then `coding.display`, and
   resolves the patient by the clinic's configured identifier system. Conformance is proven
   against more than one server: an open-source FHIR server, the public SMART reference server,
   and at least one commercial EHR sandbox. An EHR that cannot connect degrades to "chart
   unavailable"; referral, authorization and reporting still work.

5. **The properties above are built into the engine's chart read, not left to hosts:**
   - Part 2: conditions and medications tagged or coded as substance use disorder records are
     withheld unless the referral carries the patient's Part 2 consent, following the engine's
     Part 2 segmentation design. Withholding is stated on the page, never silent.
   - Every chart view writes an audit event: receiving account, user, referral, time, and the
     resource types returned, never their content.
   - A dispatch can be revoked by the sending clinic and expires after a configurable period.
   - A dispatch may name a receiving clinician; when it does, only that user sees it.

6. **The engine's own defects are fixed in the engine**, not patched by hosts: `cancel` gets
   explicit `from:` states, referral creation validates, `ClaimSubmission` uses the EDI adapter,
   and facility eligibility rules become facility configuration.

7. **Screens: the engine ships services first; shipping views is a separate decision.** This ADR
   moves every rule and decision into the engine and leaves hosts with thin controllers that call
   engine services. Whether the engine also ships mountable screens (with host layout and
   authentication hooks) is deferred: it depends on how many hosts exist and how much their screens
   diverge.

## Consequences

### Positive
- Any host, and any clinic's certified EHR, gets the whole loop, including the authorization,
  audit and Part 2 rules.
- One FHIR client to harden and test instead of two.
- Clinics on different EHRs can share a deployment.
- The host shrinks to identity, screens and deployment configuration.

### Negative
- Engine migrations for dispatches, fulfilment-report source, EHR connections and view audit;
  hosts that already hold dispatch rows need a data migration.
- Encrypted per-tenant secrets add key-management work the environment-variable model avoided.
- Commercial EHR sandboxes require app registration per vendor before conformance can be
  proven; until then "any certified EHR" describes the design, not a tested property.
- Not every certified EHR allows system-scoped single-patient searches. Where one offers only
  bulk export, the chart read needs a bulk `$export` scoped to the patient or a per-vendor
  path, and is slower.
- Part 2 filtering depends on how the source EHR marks those records, which varies; an EHR that
  does not mark them requires the clinic to withhold the chart read for Part 2 programs.

### Alternatives considered
- **Keep the loop in the host.** Rejected: every host would reimplement access rules for clinical
  data, and the engine would not be EHR-agnostic in practice.
- **Keep `ChartSource` beside the adapter.** Rejected: two FHIR clients with different
  authentication and parsing rules drift apart.
- **Expose the loop only through the engine's JSON API.** Deferred: the API is not mounted until
  its authentication design is settled, and hosts still need the same services underneath.
- **Push referrals into the specialist's EHR.** Out of scope: delivery into another EHR is a
  messaging problem (Direct with C-CDA, closed-loop referral profiles where supported), not a
  FHIR read; it can be added later as another dispatch channel.

## References
- ADR 0003: PHI tokenization (Corvid stores no name, birth date or clinical content)
- ADR 0005: Adapter dependency injection in services
- `Corvid::ReferralFulfilment` and the fulfilment report trail
- HL7 US Core Implementation Guide; SMART App Launch: Backend Services
