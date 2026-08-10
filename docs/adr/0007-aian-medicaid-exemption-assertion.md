# ADR 0007: AI/AN Medicaid exemption assertion

**Status:** Accepted
**Date:** 2026-08-09

## Context

Under HR-1 (2025 reconciliation), American Indians/Alaska Natives — explicitly
including Urban Indians and IHS beneficiaries — are exempt from Medicaid
community-engagement/work requirements and from the more-frequent (6-month)
eligibility redeterminations that begin January 2027. Exemption on paper does
not retain coverage: exempt AI/AN still lose coverage to administrative churn
when the exemption is not flagged, asserted, and maintained through the state's
process.

Corvid needs to (1) carry the exemption on the member record from a *verified*
status, (2) surface exempt members the state has erroneously flagged for
work-reporting or 6-month redetermination, (3) produce the documentation a
state needs to honor the exemption, and (4) track outcomes.

Two constraints shape the design:

- Corvid is EHR-agnostic and PG-only. State-process specifics and EHR/RPC
  specifics stay out of the engine.
- The exemption is only defensible if its AI/AN status is verified, not
  self-reported. The authoritative source is baseroll's IAL2/AAL2 verification.

## Decision

**Verified-assertion only, fail-closed.** `MedicaidExemption` rows are written
solely by `MedicaidExemptionService.assert`, which verifies AI/AN /
IHS-beneficiary status through a new adapter method, `verify_ai_an_status`, and
records the verification provenance (source, confidence, snapshot hash,
verified-at) on the row. If the source is unavailable or the person is not
AI/AN, nothing is asserted. There is no self-report path and no silent
fallback.

**A dedicated verification method, broader than tribal enrollment.** The HR-1
exemption covers Urban Indians and IHS beneficiaries who need not be enrolled
in a facility's contracted tribe, so it cannot reuse `verify_tribal_enrollment`
(which is scoped to contracted-tribe enrollment for PRC eligibility).
`verify_ai_an_status` returns `{ ai_an, ihs_beneficiary, basis, confidence,
verified_at }`.

**Two exemption types, tracked separately.** `work_requirement` and
`six_month_redetermination` both flow from the same verified status but are
legally distinct; `assert` writes both by default. At most one *asserted*
exemption of a type per person (partial unique index).

**Deterministic snapshot hash.** The verification snapshot hash excludes the
volatile `verified_at`, so an identical verified status produces an identical
hash — a re-verify against the same upstream data is auditably reproducible.
This deliberately differs from `PrcEligibilityDecision`, whose hash includes
`verified_at`.

**Worklist takes state signals as input.** `ExemptionWorklistService.at_risk`
cross-references active exemptions against caller-supplied state signals
(person + requirement type). Persisting and ingesting those signals (from 271
responses, renewal files, case data) belongs to renewal tracking (#410); the
worklist stays PG-only and depends on no state feed.

**Exemption-scoped outcome events now; fold into #332 later.**
`ExemptionEvent` records life outcomes (asserted, coverage retained,
erroneously disenrolled, appeal filed, coverage reinstated). It is the narrow
precursor to the general `CaseOutcome` model (#332); when #332 lands these
events migrate into it.

## Consequences

### Positive
- The exemption is audit-defensible: every flag carries its verification
  provenance and a reproducible snapshot hash.
- No fabricated positives — an unverifiable status never yields an exemption.
- Ships without waiting on #332 (case outcomes) or #410 (renewal ingestion).

### Negative
- `verify_ai_an_status` is not yet implemented by any production adapter — the
  feature is inert until baseroll exposes verified AI/AN status (see below).
- Two overlapping outcome models exist until #332 folds `ExemptionEvent` in.
- The worklist cannot run autonomously until a signal source (#410) feeds it.

### Alternatives considered
- **Reuse `verify_tribal_enrollment`.** Rejected: too narrow — it is
  contracted-tribe enrollment, and would exclude Urban Indians / IHS
  beneficiaries the HR-1 exemption explicitly covers.
- **Boolean exemption flags on `CaseProgram`.** Rejected: loses verification
  provenance and the audit trail; the exemption is a first-class,
  independently-verified fact, not an enrollment attribute.
- **Depend on #332 `CaseOutcome` for events.** Rejected: #332 is not built;
  a narrow, standalone event model unblocks this feature now.

## Dependencies / blockers

- **baseroll (keystone).** Production use requires baseroll to expose verified
  AI/AN / IHS-beneficiary status via the adapter's `verify_ai_an_status`.
  baseroll's current verification issue covers enrollment/identity/residency
  (`verify_tribal_enrollment` etc.) but not the broader AI/AN-exemption
  assertion; that endpoint still needs to be built. Until then only
  `MockAdapter` implements the method.
- **#410 renewal tracking.** Supplies and persists the state signals the
  at-risk worklist consumes.
- **#332 case outcomes.** `ExemptionEvent` folds into `CaseOutcome` when it
  lands.

## References
- Issue #420 (this feature), #410 (renewal tracking), #332 (case outcomes),
  #413 (FMAP — same eligibility substrate)
- baseroll: enrollment verification endpoints (+ AI/AN-status extension)
- ADR 0001 (id vs identifier), ADR 0003 (PHI tokenization), ADR 0005 (adapter
  injection)
