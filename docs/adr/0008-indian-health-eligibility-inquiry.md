# ADR 0008: Indian health eligibility inquiry

**Status:** Proposed
**Date:** 2026-10-11

## Context

H.R. 1 exempts people who meet the Medicaid definition cited at 42 CFR 435.554(c)(2) from community-engagement rules. That citation points at 42 CFR 447.51. A state asks an Indian health care provider — the Indian Health Service, a tribal program, or an urban Indian clinic — one question about one named person: has the provider determined that this person is eligible for services from an Indian health provider?

Enrollment, descent, citizenship, and Alaska Native Corporation shareholding stay with the provider. 42 CFR 136.12 is the provider's own rule for whom it serves. Corvid carries the provider's answer. It does not make a second one.

`person_identifier` is the host's opaque token (ADR 0003). The engine does not accept raw identifiers.

A state uses the provider as an electronic data source under its verification plan. The state-side authority is 42 CFR 435.557(b) and (b)(1)(i)-(iii), which require the state to check reliable data before asking the person, to identify data sources (deciding whether a connection is worth establishing), and to document them in its verification plan; and 42 CFR 435.945(h)-(j): a secure interface, a written agreement, and the verification plan. The `agreement_reference` on each inquiry is that agreement.

42 CFR 435.557(d)(4) bars a state from reverifying the status of a person determined to be a specified excluded individual between regularly scheduled redeterminations, unless it has information the status changed. That supports freezing `eligible`. Freezing `not_eligible` as well rests on the #589 spec (§ 8 item 6), not on (d)(4): enforced at this endpoint, replay means a repeat query cannot be used to watch a determination be withdrawn. Cross-requester replay is deliberate: a per-requester key would let a second requester observe a change the first cannot. The second requester gets a fresh message id and the provider's `asserted_at`, rendered in UTC exactly as the first answer was.

State member guidance, including a state's plain-language explainer, can be broader than 447.51. This engine does not encode any one state's summary.

## Decision

1. **One inquiry, answered from the provider's own determination.** `Corvid::IndianHealthEligibilityService#inquire` reads `indian_health_service_eligibility` from the configured adapter. It does not model enrollment, descent, citizenship, or Alaska Native Corporation shareholding, and it does not record which criterion applied. The person is named by the host's opaque token. The engine does not accept raw identifiers.

2. **Three answers.** The answers are `eligible`, `not_eligible`, and `unknown`, with the asserting provider and the time of the determination when the provider supplied them. A source that cannot be asked is not an answer. That includes an adapter error, a confidence other than `:verified`, a determination outside those three, and a decisive answer that lacks a non-blank string `asserted_by` and a time (`acts_like?(:time)`; a date is not a time). The query log records `unavailable` and `inquire` raises `SourceUnavailable`, carrying that row's message id. The API returns 503. Nothing else in the adapter response is kept. `:unknown` may omit `asserted_by` and `determined_at`; if present, `asserted_by` must be a string and `determined_at` a time.

3. **Replay a given answer, never an unknown.** For one tenant and person, the first `eligible` or `not_eligible` answer is what later inquiries return, including inquiries from other requesters, and the adapter is not called. `unknown` is not frozen. A logged `unavailable` or `refused` is not a replay source. Cross-requester replay is deliberate, for the reason in the context: a per-requester key would let a second requester observe a change the first cannot. The second requester gets a fresh message id and the provider's original `asserted_at`, not a new fact.

4. **Operator-set ceiling, fail closed, and before replay.** `Corvid.configuration.indian_health_eligibility_ceiling` is `{ limit:, period: }` or nil. `limit` must be an Integer greater than or equal to zero, and `period` must be a positive `ActiveSupport::Duration`. Otherwise `inquire` raises `CeilingNotConfigured` and writes nothing. The limit counts non-refused rows for that requester inside the period, in the current tenant. The inquiry that would exceed it is logged as `refused` and raises `CeilingExceeded`, carrying that row's message id. The API returns 429. Refused rows do not count, and rows older than the period do not count.

   The ceiling is checked before replay. A replay still discloses one bit (spec § 8 item 7), so a requester over the ceiling is refused and does not receive the replayed answer.

5. **Query log, no stored determination.** Each inquiry appends one `corvid_indian_health_eligibility_inquiries` row: tenant, requester, agreement, person, answer, provenance, time, message id, and whether it was replayed. Corvid stores no determination of its own. The query log records the answer the provider gave. `unavailable` and `refused` record that the inquiry did not receive an answer; they are not answers.

6. **One lock.** `inquire` runs under one transaction-scoped Postgres advisory lock per tenant, from the ceiling check through the log insert; the ceiling and the replay lookup are checked once, under that lock. There is no second lock. The wait for that lock is bounded by a `lock_timeout`, reset once the lock is held; on timeout `inquire` raises `Busy`, nothing is logged, and the API returns 503 without a message id. The adapter call runs in a savepoint, so an adapter whose own query fails is logged as `unavailable` rather than aborting the transaction. When `inquire` opens the outermost transaction, refused and unavailable rows are committed before the exception is raised. Inside an enclosing transaction they are only as durable as that transaction, and a rollback removes them while the caller still holds their message id; hosts call `inquire` outside one.

7. **Single route.** `POST /corvid/api/v1/indian_health_eligibility/inquire`. No list, search, or batch route. The body names one person by the host's opaque token. The host sets `X-Requester-Identifier` and `X-Agreement-Reference`. The JSON includes a FHIR R4 `VerificationResult` when there is an answer: `validated` for eligible, `val-fail` for not eligible, `in-process` for unknown. `val-fail` means the provider determined the person is not eligible for its services. It is not a finding about who the person is, and a state may still establish the exemption another way. `statusDate` and `primarySource` are present only when the provider supplied them. There are no basis or reason codes. A source that cannot be asked is a 503, not a `VerificationResult`.

## Consequences

### Positive
- Records that support the determination stay with the provider. Corvid stores no determination of its own; the query log records the answer the provider gave.
- Once an answer has been given, repeating the question does not call the provider again, so a repeat query cannot watch a determination be withdrawn.
- An unset or ill-typed ceiling writes nothing, so this cannot run unbounded by accident.

### Negative
- The log cannot explain which criterion the provider applied. A caller that needs that has to ask the provider some other way.
- Replaying the first decisive answer hides a later change at the provider. That change is outside this contract, including for a second requester.
- The advisory lock is per tenant. Inquiries for different people in the same tenant take the same lock, and it is held across the adapter call. The host must give its adapter a bounded timeout.
- A replay returns without a provider round trip, so it may be faster than a first answer.
- Refused rows are written for every attempt over the ceiling and do not count toward it. A client that retries in a loop adds a row per attempt; the host should rate-limit.

### Alternatives considered
- **Model the 447.51 criteria in the engine.** Rejected: that copies records that are not Corvid's and narrates a basis the answer does not need to expose.
- **Encode one state's plain-language summary of who qualifies.** Rejected: those summaries can be broader than 447.51, and they differ by state.
- **Freeze `unknown` the same way as a decisive answer.** Rejected: unknown means the provider has not determined it.
- **Key replay by requester.** Rejected: a second requester could then observe a change the first cannot.
- **Replay before the ceiling.** Rejected: a replay still discloses one bit (spec § 8 item 7).
- **Return "the source could not be asked" as an answer.** Rejected: that is a 503, not a determination.

## References
- https://github.com/lakeraven/corvid/pull/589
- ADR 0003 (opaque tokens; no PHI at rest), ADR 0005 (adapter injection)
- 42 CFR 435.554(c)(2), 42 CFR 447.51, 42 CFR 136.12
- 42 CFR 435.557(b), (b)(1)(i)-(iii), and (d)(4)
- 42 CFR 435.945(h)-(j)
