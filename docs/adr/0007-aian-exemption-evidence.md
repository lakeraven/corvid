# ADR 0007: AI/AN exemption evidence

**Status:** Proposed
**Date:** 2026-10-11

## Context

H.R. 1 (2025) requires expansion-adult Medicaid members to meet community-engagement (work or activity) requirements, and exempts American Indians and Alaska Natives. States must decide who is exempt. In practice they hold only part of the evidence:

- State claims show care billed to Medicaid by IHS, tribal, and urban Indian (I/T/U) providers, and many enrollment systems carry a self-reported AI/AN flag.
- Tribal enrollment, descent from an enrolled member, Alaska Native Corporation shareholding, and I/T/U care never billed to Medicaid live with tribes, corporations, and clinics.

Open-source eligibility tools key the exemption off a race/ethnicity field (for example, OSCER's batch upload maps `race_ethnicity = american_indian_or_alaska_native` to the exclusion). Race is not the legal test, so that both over- and under-includes.

Published state criteria (e.g. Oregon Health Authority, Sept 2026) list four bases: enrolled tribal member; child or grandchild of an enrolled member; Alaska Native Corporation shareholder; received care from IHS or a tribal or urban Indian clinic. CMS proof requirements for 2028 are pending.

## Decision

1. **One service, many sources.** `Corvid::AianExemptionService` takes an ordered list of sources (default `[Corvid.adapter]`, per ADR 0005). Each source implements whichever AI/AN evidence methods it can answer (`verify_tribal_enrollment`, `verify_tribal_descent`, `verify_alaska_native_corporation_shareholder`, `list_itu_encounters`); unimplemented methods are skipped. A state deployment lists its claims source first and tribal or clinic sources after it, so state data is consulted before anyone else's.
2. **Absence of evidence is not a negative finding.** Outcomes are `exempt`, `not_established`, and `unavailable`. There is no "not AI/AN" outcome. `not_established` hands the case back to the state's attestation or document path. In FHIR it renders as `in-process`, never `val-fail`.
3. **The I/T/U lookback is a state policy parameter** (`itu_lookback_days`, default unlimited), not an engine constant, because CMS has not set one.
4. **No PHI at rest (ADR 0003).** Each determination persists bases, source class names, and confidence. It does not persist membership numbers, encounter dates, or facility identities. A SHA256 of the raw responses supports reproducibility checks.
5. **FHIR R4 `VerificationResult`** is the interchange format, so OSCER, a state eligibility system, or any FHIR consumer can read a determination without a bespoke contract.

## Consequences

### Positive
- The same engine serves any state; only the configured sources differ.
- Tribal data stays with tribes: Corvid asks a yes/no question and keeps only the answer.
- Matches OSCER's verification data-source contract shape (skipped / success / error), so an OSCER adapter is a thin client.

### Negative
- The bases follow published state criteria, not final CMS guidance. They may need revision when the 2028 proof rules are published.
- Basis codes use a Corvid-local code system URI until a standard value set exists.

### Alternatives considered
- **Race/ethnicity flag.** Rejected: not the legal test.
- **Return `not_exempt` when no evidence is found.** Rejected: it would deny members whose evidence simply isn't in any connected source.

## References
- ADR 0003 (PHI tokenization), ADR 0005 (adapter injection)
- Oregon Health Authority, "OHP Work or Activity Rules": https://www.oregon.gov/oha/hsd/ohp/pages/federal-changes.aspx
- OSCER verification data sources: https://github.com/navapbc/oscer/tree/main/reporting-app/app/services/verification
