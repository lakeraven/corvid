# ADR 0007: The engine owns the referral loop and reads any EHR

**Status:** Proposed
**Date:** 2026-10-08 (revised 2026-10-22; owner decisions on key custody, patient lookup and
audit failure recorded the same day)

## Context

Corvid is meant to be EHR-agnostic: a clinic on any certified EHR authorizes PRC care, and a
receiving specialist on any EHR, or none, sees what they need and reports whether the care
happened. Today the closing half of that loop lives in a host application, not in this engine:

| Capability | Where it lives today | Problem |
|------------|----------------------|---------|
| Sending an authorized referral to a receiving provider (the dispatch record, its locking and re-checks) | Host model + controller | Another host gets the workflow but not the hand-off |
| Reading the patient's problems and medications for the specialist | Host `ChartSource` service (SMART Backend Services, `private_key_jwt` RS384) | A second FHIR client beside `Corvid::Adapters::FhirAdapter`, configured by environment variables |
| Publishing the public key set the EHR verifies Corvid against | Host JWKS endpoint | One key per deployment, not per clinic |
| What a receiving provider may see and do (only their dispatches, only while authorized, outcome-only reports) | Host controllers | Authorization rules for clinical data enforced outside the engine |
| Referral rules the host works around: a default medical priority, the intake submitter for dual control, creating referrals without model validations | Host controller constants and comments | Engine defects patched per host |
| Claim lifecycle against the EDI adapter, because `ClaimSubmission#submit!` calls `Corvid.adapter` instead of `Corvid.edi_adapter` | Host controller | Same |
| Facility eligibility rules (on-reservation and SSN-on-file requirements) | Host controller | PRC policy outside the engine |

Some of the engine work this ADR depends on has already landed on main or is open:

- **Fail-closed clinical reads are on main.** #658 added `FhirAdapter#get_conditions` and
  `#get_medications`, and #666 added same-origin paging to `fhir_search`
  (`lib/corvid/adapters/fhir_adapter.rb`). Clinical reads go through `clinical_search`, which
  requires a `Bundle` of type `searchset`, treats a `next` link as unknown (one page only), and
  refuses a page whose `total` disagrees with its entries (`consistent_search_total?`). General
  searches follow only same-origin `next` links (`same_origin_url?`), stop at
  `MAX_SEARCH_PAGES = 100`, and discard everything on a repeated link or the page cap.
- **SMART Backend Services auth is on main via #531 (merged).** It added
  `Corvid::Auth::BackendServicesClient` (`lib/corvid/auth/backend_services_client.rb`: signed-JWT
  client credentials, RS384 and ES384, token caching with a refresh skew) and a `token_source:`
  option on `FhirAdapter` that is resolved per request, with credentials sent only to URLs under
  `base_url`. Static `bearer_token:` still works. #531 holds no keys: key custody and the JWKS
  endpoint were left to the host.
- **Models still use the global adapter.** ADR 0005 moves services to `adapter:` injection but
  leaves models on `Corvid.adapter` until #264. `PrcReferral#sync_status_to_ehr` (an `after:`
  callback on `authorize`, `mark_denied` and `mark_deferred`) and `ClaimSubmission#submit!` both
  call `Corvid.adapter`. ADR 0005 says per-tenant routing across a model callback is not safe
  until #264 lands.

Two further facts shape the decision:

1. **The engine's FHIR adapter is already the right seam.** It speaks FHIR R4 to any server and
   already parses clinical reads fail-closed and, since #531, can authenticate with SMART Backend
   Services through `token_source:`. Nothing yet builds that client per clinic. Certified EHRs expose standard FHIR read APIs, and certification requires SMART Backend
   Services for bulk export; many also allow system-scoped searches for a single patient, which is
   what this read needs, though certification does not require it. A static bearer token works
   with none of them in production.
2. **One EHR connection per process.** Both the adapter and `ChartSource` are configured at boot.
   ADR 0005 already names per-tenant adapter routing as the missing capability; a clinic on one
   EHR and a clinic on another cannot share a deployment.

Several properties are also missing wherever the code lives, and are cheaper to build once in the
engine than per host:

- **Part 2 records.** The problem list reaches the specialist unfiltered. A record that originates
  in a 42 CFR Part 2 program needs the patient's consent before it is disclosed, even for
  treatment.
- **Per-view audit.** The EHR's log records Corvid's client, not the specialist. Nothing
  records which receiving user opened which chart, and when.
- **Revocation and expiry.** A dispatch grants access for as long as the referral stays
  authorized; there is no way to withdraw it and no time limit.
- **Grant granularity.** A dispatch grants access to every user of the receiving organisation.

## Prerequisites

This ADR cannot be implemented in full until these land. Each can be built and merged on its own.

1. **#531, SMART Backend Services in `FhirAdapter` (merged).** The chart read authenticates
   through `Corvid::Auth::BackendServicesClient` passed as `token_source:`. This ADR adds no second
   auth path.
2. **#264, models off the global adapter.** Sharing a deployment across clinics (Decision 3)
   needs every write in the loop to use the clinic's connection, including model callbacks such as
   `PrcReferral#sync_status_to_ehr` and `ClaimSubmission#submit!`. Injecting `adapter:` into
   services alone does not do that. Until #264 lands, a deployment serves one EHR connection.
3. **A Part 2 segmentation design.** No such design exists in the repository yet. Decision 5's
   Part 2 rule needs one, written as its own ADR or design doc, before that part is built. The
   rest of the chart read does not wait on it, provided Part 2 programs keep the chart read
   switched off (see Decision 5).

## Decision

1. **The engine owns the referral loop end to end.** Dispatch to a receiving provider, the
   receiving provider's view of the referral, the chart read for that view, and the fulfilment
   report all move into the engine as models and services with their authorization rules. A host
   supplies identity (who is signed in, which account they act for, whether that account is a
   receiving provider) and screens; it makes no access decisions about referrals or clinical data.

2. **One FHIR client.** The chart read uses `Corvid::Adapters::FhirAdapter` with #531's
   `BackendServicesClient` as its `token_source:`. It reuses the fail-closed parsing already on
   main (#658, #666), not a copy of `ChartSource`'s. One rule from `ChartSource` is not on main yet
   and is added to the adapter: resolving a patient by identifier must find exactly one match, or
   the result is unknown. The static-token mode stays for local stand-ins. `ChartSource` is
   retired; its callers use a `Corvid::ChartSummary` service over the adapter.

3. **Each clinic configures its own EHR connection, and the host holds the keys.**
   - The engine ships a tenant-scoped connection record with no secrets in it: the FHIR base URL,
     token URL, client id, signing algorithm, key id and the identifier system that names the
     clinic's patients.
   - The host holds each clinic's private signing keys. The engine never holds, stores or receives
     a private key. Where and how the host keeps them (its credentials store, a key service) and
     how it rotates them is the host's choice.
   - The engine ships a key-lookup interface that the host implements. Given a connection, it
     returns the signing key the host holds for it.
   - The host builds one `BackendServicesClient` per clinic from the connection record and its own
     key, and passes it to the clinic's `FhirAdapter` as `token_source:`.
   - The host serves the JWKS route each clinic registers with its EHR. The engine ships a JWKS
     document builder the route calls, so every host publishes the same public-key document. The
     builder takes public keys only.
   - Adapter resolution follows ADR 0005: services take `adapter:`, and the tenant's connection
     builds it. Per-tenant routing is safe only after #264 (Prerequisite 2).

4. **US Core is the contract.**
   - `MedicationRequest` and `Condition` are required. Both are US Core profiles, and main's
     `get_medications` and `get_conditions` already read them.
   - `MedicationStatement` is optional. It is a base R4 resource, not a US Core profile, so it is
     read only when the server's CapabilityStatement declares a search on it. A server that lacks
     it is still a working connection, and its absence never makes the chart unavailable.
   - Labels follow main: the first coding with a non-empty code supplies the label from
     `coding.display`, falling back to `CodeableConcept.text`.
   - The patient is found from Corvid's opaque patient token (ADR 0003) by the tenant adapter's
     `dereference`, in memory, on every read. It gives the clinic's identifier (the configured
     system and a value), which is then resolved to exactly one EHR Patient. Nothing new is stored:
     no MRN, no EHR Patient id, and no crosswalk table in the engine or the host. A token that
     does not dereference, or matches no patient or more than one, makes the chart unavailable.
     On main, `FhirAdapter#dereference` raises `NotImplementedError`, so the tenant adapter must
     supply a vault-backed implementation.
   - Conformance is proven against more than one server: an open-source FHIR server, the public
     SMART reference server, and at least one commercial EHR sandbox.
   - An EHR that cannot connect degrades to "chart unavailable"; referral, authorization and
     reporting still work.

5. **The properties above are built into the engine's chart read, not left to hosts:**
   - **Part 2.** Whether a record is Part 2 depends on where it came from, not on its code. The
     chart read withholds a record when its security labels or provenance mark it as coming from
     a Part 2 program, unless the referral carries the patient's Part 2 consent. A substance use
     disorder code alone is not treated as proof either way. When a clinic is a known Part 2
     source and its EHR does not supply that metadata, the chart read is withheld in full for that
     clinic. The detailed rules follow the Part 2 design (Prerequisite 3).
   - **Audit.** Every chart view writes an audit event: receiving account, user, referral, time,
     and the resource types returned, never their content (ADR 0003). The event is written durably
     before any chart content is returned. If the write fails, the view is blocked (fail closed):
     no audit record means no chart data, and the user sees "chart unavailable". This supersedes ADR 0003 §14
     ("read audit logging is a host responsibility") **for chart views only**. The reason is that
     the engine now makes the access decision and is the only layer that knows which referral
     granted the view and which resource types went back. Host middleware sees a request, and the
     EHR's log sees only Corvid's client. All other read auditing stays with the host as §14
     says. When this ADR is accepted, §14 gets a pointer to this decision.
   - **Revocation and expiry.** A dispatch can be revoked by the sending clinic and expires after
     a configurable period.
   - **Named clinician.** A dispatch may name a receiving clinician; when it does, only that user
     sees it.

6. **The chart has three distinct empty states, and screens must show them differently.** Each
   section (conditions, medications) is one of:
   - **Unavailable: `nil`.** The read failed, the connection is missing, the page broke a parsing
     rule, the patient token did not resolve to exactly one patient, or the audit write failed. The
     section says the chart could not be read. It is never shown as "none".
   - **None: `[]`.** The server answered cleanly with no matching records. The section says there
     are none on file.
   - **Withheld.** Records were held back under Part 2. The section says some records are withheld
     for lack of consent. It does not say how many or what kind. A withheld section is never shown
     as "none", and a fully withheld chart is never shown as "unavailable".

   `ChartSummary` returns these as distinct values. Absence of data never reads as "no problems"
   or "no medications".

7. **The engine's own defects are fixed in the engine**, not patched by hosts: referral creation
   validates, `ClaimSubmission` uses the EDI adapter, and facility eligibility rules become
   facility configuration.

8. **Screens: the engine ships services first; shipping views is a separate decision.** This ADR
   moves every rule and decision into the engine and leaves hosts with thin controllers that call
   engine services. Whether the engine also ships mountable screens (with host layout and
   authentication hooks) is deferred: it depends on how many hosts exist and how much their screens
   diverge.

## Consequences

### Positive
- Any host, and any clinic's certified EHR, gets the whole loop, including the authorization,
  audit and Part 2 rules.
- One FHIR client to harden and test instead of two, building on parsing that is already tested.
- Once #264 lands, clinics on different EHRs can share a deployment.
- The host shrinks to identity, screens and deployment configuration.

### Negative
- Engine migrations for dispatches, fulfilment-report source, EHR connections and view audit;
  hosts that already hold dispatch rows need a data migration.
- Per-clinic connections add configuration, and each host must store and rotate clinics' signing
  keys and serve the JWKS route (with the engine's document builder).
- A chart view depends on the audit store: when it cannot be written, specialists see "chart
  unavailable" even if the EHR is up.
- Resolving the patient token on every read costs a vault lookup per view.
- Multi-clinic deployments wait on #264.
- Commercial EHR sandboxes require app registration per vendor before conformance can be
  proven; until then "any certified EHR" describes the design, not a tested property.
- Not every certified EHR allows system-scoped single-patient searches. Where one offers only
  bulk export, the chart read needs a bulk `$export` scoped to the patient or a per-vendor
  path, and is slower.
- Part 2 filtering depends on how the source EHR labels those records, which varies; an EHR that
  does not label them means the chart read stays off for Part 2 programs.

### Alternatives considered
- **Keep the loop in the host.** Rejected: every host would reimplement access rules for clinical
  data, and the engine would not be EHR-agnostic in practice.
- **Keep `ChartSource` beside the adapter.** Rejected: two FHIR clients with different
  authentication and parsing rules drift apart.
- **Expose the loop only through the engine's JSON API.** Deferred: the API is not mounted until
  its authentication design is settled, and hosts still need the same services underneath.
- **The engine holds the signing keys and serves the JWKS.** Rejected: it would give the engine
  secret custody and an encryption-key dependency, against #531's design, and make a key leak an
  engine-wide concern. A uniform JWKS document comes from the engine's builder instead.
- **A stored crosswalk from patient token to EHR Patient id** (in the host or the engine).
  Rejected: it puts a new patient identifier at rest, which ADR 0003 avoids; the adapter's
  `dereference` already resolves tokens in memory.
- **Show the chart when the audit write fails, and log the failure.** Rejected: clinical data
  could then be disclosed with no record of who saw it.
- **Push referrals into the specialist's EHR.** Out of scope: delivery into another EHR is a
  messaging problem (Direct with C-CDA, closed-loop referral profiles where supported), not a
  FHIR read; it can be added later as another dispatch channel.

## References
- ADR 0003: PHI tokenization (Corvid stores no name, birth date or clinical content). §14 is
  superseded for chart views only (Decision 5).
- ADR 0005: Adapter dependency injection in services, and its model-callback limitation
- #531 (merged): SMART Backend Services for `FhirAdapter` (`Corvid::Auth::BackendServicesClient`)
- #264: Decouple models from the `Corvid.adapter` global
- #658, #666: fail-closed condition and medication reads, same-origin paging
- `Corvid::ReferralFulfilment` and the fulfilment report trail
- HL7 US Core Implementation Guide; SMART App Launch: Backend Services
