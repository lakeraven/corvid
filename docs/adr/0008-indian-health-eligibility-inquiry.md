# ADR 0008: Indian health eligibility inquiry

**Status:** Proposed
**Date:** 2026-10-11

## Context

H.R. 1 exempts people who meet the Medicaid definition cited at 42 CFR 435.554(c)(2) from community-engagement rules. That citation points at 42 CFR 447.51. A state asks an Indian health care provider — the Indian Health Service, a tribal program, or an urban Indian clinic — one question about one named person: has the provider determined that this person is eligible for services from an Indian health provider?

Enrollment, descent, citizenship, and Alaska Native Corporation shareholding stay with the provider. 42 CFR 136.12 and 42 CFR 435.557(d)(4) are part of the same legal frame. Corvid carries the provider's answer. It does not make a second one.

State member guidance, including a state's plain-language explainer, can be broader than 447.51. This engine does not encode any one state's summary.

## Decision

1. **One inquiry, answered from the provider's own determination.** `Corvid::IndianHealthEligibilityService#inquire` reads `indian_health_service_eligibility` from the configured adapter and returns that determination. It does not model enrollment, descent, citizenship, or Alaska Native Corporation shareholding, and it does not record which criterion applied.
2. **One bit, plus provenance, plus time.** The answer is `eligible`, `not_eligible`, or `unknown`, with the asserting provider and the time of the determination. `unavailable` means the provider could not be asked. Nothing else in the adapter response is kept.
3. **Replay a given answer, never an unknown.** For one tenant and person, the first `eligible` or `not_eligible` answer is what later inquiries return, including inquiries from other requesters, and the adapter is not called. `unknown` and `unavailable` are not frozen.
4. **Operator-set ceiling, fail closed.** `Corvid.configuration.indian_health_eligibility_ceiling` is `{ limit:, period: }` or nil. Unset, `inquire` raises and writes nothing. The limit counts non-refused rows for that requester inside the period, in the current tenant. The inquiry that would exceed it is logged as `refused` and raises. Refused rows do not count, and rows older than the period do not count.
5. **Query log, no stored determination.** Each inquiry appends one `corvid_indian_health_eligibility_inquiries` row: tenant, requester, agreement, person, answer, provenance, time, message id, and whether it was replayed. Corvid does not keep a determination of its own.
6. **Single route.** `POST /corvid/api/v1/indian_health_eligibility/inquire`. No list, search, or batch route. The body names one person. The host sets `X-Requester-Identifier` and `X-Agreement-Reference`. The JSON includes a FHIR R4 `VerificationResult`: `validated` for eligible, `val-fail` for not eligible, `in-process` for unknown and unavailable. `statusDate` and `primarySource` are present only when the provider supplied them. There are no basis or reason codes.

## Consequences

### Positive
- Records that support the determination stay with the provider. Corvid stores the answer it was given.
- Once an answer has been given, repeating the question does not call the provider again.
- An unset ceiling refuses every inquiry, so this cannot run unbounded by accident.

### Negative
- The log cannot explain which criterion the provider applied. A caller that needs that has to ask the provider some other way.
- Replaying the first decisive answer hides a later change at the provider. That change is outside this contract.

### Alternatives considered
- **Model the 447.51 criteria in the engine.** Rejected: that copies records that are not Corvid's and narrates a basis the answer does not need to expose.
- **Encode one state's plain-language summary of who qualifies.** Rejected: those summaries can be broader than 447.51, and they differ by state.
- **Freeze `unknown` the same way as a decisive answer.** Rejected: unknown means the provider has not determined it.

## References
- [Indian health eligibility verification](../specs/aian-eligibility-verification.md) (corvid#589)
- ADR 0003 (no PHI at rest), ADR 0005 (adapter injection)
- 42 CFR 435.554(c)(2), 42 CFR 447.51, 42 CFR 136.12, 42 CFR 435.557(d)(4)
