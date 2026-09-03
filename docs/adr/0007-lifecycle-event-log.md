# ADR 0007: Lifecycle event log (event-logged state machines, not event sourcing)

**Status:** Proposed
**Date:** 2026-09-03

## Context

Corvid is conventional ActiveRecord: AASM state machines on mutable rows
(`PrcReferral`, `Payment`), string status columns elsewhere (`Case`,
`Task`, `CommitteeReview`), and Rails timestamps. Audit today is a
collection of ad hoc mechanisms, each grown for one purpose:

- `ManagementApprovalEvent` — append-only, immutable once persisted
  (`readonly?`), server-set `occurred_at`, digest-bound to the checklist it
  approved. The best-designed audit artifact in the engine, and PRC-only.
- `Determination` (via `Determinable`) — decision records with actor and
  method; mutable in principle.
- `PrcEligibilityDecision` — eligibility decide audit with facts snapshot
  hash.
- `BillingTransaction`, `ApiCallLog` — EDI and API logs.
- The host hooks `on_provenance` / `fetch_provenance` (ADR 0002 §7).

The provenance hooks are the mechanism ADR 0002 offered as the audit
contract. In practice they commit to almost nothing:

- `on_provenance` defaults to `nil` and is called from **three** sites
  (`ProgramTemplateService#record_provenance`, `HepBWorkflowService`,
  `ProgramCaseAuditService`), all Case-program milestones. **No AASM
  transition on `PrcReferral` emits provenance.** Authorizations, denials,
  committee decisions, and deferrals leave no provenance record unless the
  host reads AASM columns after the fact.
- The kwargs are unspecified beyond `target_type`, `target_id`, `activity`,
  `recorded` (plus `agent_who_identifier` in one caller). Nothing records
  `from`/`to` state, actor kind, or content digest.
- `fetch_provenance` defaults to `-> { [] }`, so a host that forgets the
  hook gets a silently empty audit trail.

Two new requirements make this insufficient:

1. **A second domain (workforce) with funder compliance audits.** Braided
   funding requires proving, per funder, that every obligated dollar traces
   to an eligibility decision (ruleset version, facts digest), a completed
   checklist, and a distinct approver — months later, to an auditor who did
   not watch it happen. That is a replayable, attributable, tamper-evident
   lifecycle history.
2. **Non-human actors.** AI participants must be recorded as such on every
   mutation they make, and restricted to proposal states. That needs an
   actor kind on the record of each transition, not on a mutable row.

The cross-product event bus (#261) and cross-product ADRs (#249) also need a
single place events originate from.

Three options were weighed with the codebase in front of us:

- **A. Full event sourcing** (events are the only write model; state is
  always projected; e.g. Rails Event Store).
- **B. Event-logged state machines** — AASM keeps guards and named events in
  Ruby; an after-transition callback appends an immutable row to a thin
  transitions table; the status column is a projected cache; the log is the
  record of truth and the publish point.
- **C. Status quo plus more `on_provenance` calls.**

## Decision

**Option B.** Corvid adopts event-logged state machines as the engine-wide
audit and lifecycle mechanism. Full event sourcing is not adopted anywhere
inside Corvid; it belongs only in external systems whose *content* is the
event stream (a signed credential ledger), and Corvid consumes those streams
through adapters.

### 1. One table: `corvid_transitions`

| Column | Notes |
|---|---|
| `id` | |
| `tenant_identifier`, `facility_identifier` | `TenantScoped` |
| `subject_type`, `subject_id` | polymorphic; namespaced class name (ADR 0002 §4) |
| `event_name` | AASM event or explicit lifecycle event (`authorization_granted`, `obligation_incurred`, `expenditure_recorded`) |
| `from_state`, `to_state` | nullable for non-state events |
| `actor_identifier` | opaque token (ADR 0001) |
| `actor_kind` | `human` \| `system` \| `agent` (string enum + CHECK) |
| `occurred_at` | **server-set**; caller values discarded |
| `metadata` | jsonb, **token-keyed** — may hold tokens, digests, codes, amounts, identifiers; never PHI/PII text (ADR 0003) |
| `content_digest` | SHA256 of the domain content the event acted on (e.g. checklist digest, allocation digest), when applicable |
| `prev_digest` | SHA256 of the previous transition row for the same `(subject_type, subject_id)` — a per-subject hash chain |
| `published_at` | nullable; outbox marker for the cross-product bus (#261) |

Append-only is enforced at **three** layers: `readonly?` when persisted
(as `ManagementApprovalEvent` does), a database rule/trigger rejecting
`UPDATE`/`DELETE`, and no engine API to mutate. Cleanup for `Case#purge`
uses a dedicated privileged path.

### 2. One concern: `Corvid::EventLogged`

```ruby
module Corvid::EventLogged
  extend ActiveSupport::Concern
  included do
    has_many :transitions, as: :subject, class_name: "Corvid::Transition"
    aasm do
      after_all_transitions :record_transition
    end
  end

  def record_transition
    Corvid::Transition.append!(
      subject: self,
      event_name: aasm.current_event,
      from_state: aasm.from_state, to_state: aasm.to_state,
      actor: Corvid::TenantContext.current_actor,      # identifier + kind
      metadata: transition_metadata,                   # model-provided, token-keyed
      content_digest: respond_to?(:content_digest) ? content_digest : nil
    )
  end
end
```

Models without AASM (e.g. `Expenditure`) call `Corvid::Transition.append!`
explicitly from `after_create`.

### 3. The status column is a projected cache

Transitions are the record of truth; `status` exists for indexing and
queries. The transition writer is the only sanctioned writer of `status`.
A `Corvid::Transition.rebuild_status!(subject)` helper recomputes the cache
from the log for repair and for tests that assert log/state agreement.

### 4. `on_provenance` / `fetch_provenance` become subscriber and reader

- `on_provenance`, when configured, is invoked for every appended
  transition with the row's attributes (superset of today's kwargs;
  `activity` maps to `event_name`, `recorded` to `occurred_at`). Existing
  hosts keep working.
- `fetch_provenance` defaults to reading `corvid_transitions` for the
  target instead of `[]`. Hosts that store provenance elsewhere may still
  override.
- The three current `on_provenance` call sites are replaced by explicit
  transitions.

### 5. Actor kind and agent restriction

`Corvid::TenantContext.current_actor = { identifier:, kind: }`. When
`kind == :agent`, `Corvid::Transition.append!` raises
`Corvid::ActorNotPermitted` unless the subject class declares the target
state in `AGENT_ALLOWED_STATES`. This is the engine-level enforcement of
"AI proposes, humans adjudicate" (#529).

### 6. Migration of existing audit artifacts

- `ManagementApprovalEvent` is the first client: its rows become
  transitions with `event_name` ∈ {`management_approved`,
  `management_rejected`, `management_approval_invalidated`} and
  `content_digest = checklist_version_hash`. The class remains as a scoped
  reader for one release.
- `PrcReferral` includes `EventLogged`; every AASM event is logged.
- `Determination` and `PrcEligibilityDecision` stay as domain records but
  gain a transition on create so they appear in the unified timeline.

### 7. What stays out

- No projections framework, no event upcasting, no replay-to-rebuild as the
  normal read path.
- No PaperTrail in the engine; attribute versioning of mutable fields is a
  host concern (there are few mutable non-token attributes to version).
- No signatures on Corvid transitions. Corvid is an operational system with
  a trusted database; per-subject hash chaining gives tamper-evidence
  adequate for funder audits. Cryptographic signing belongs to the external
  ledger where issuers, not the program, are the trust anchors.

## Consequences

### Positive

- Every lifecycle change is attributable (who, what kind of actor, when),
  replayable with domain meaning (event name, from/to, digest), and
  tamper-evident (hash chain) — meets funder-audit requirements without
  event-sourcing machinery.
- One place for cross-product events to originate (#261 outbox) and for
  provenance to be read (#249).
- The AI seam is enforceable and testable in the engine.
- Removes the silent-empty-audit failure mode of the current hook defaults.
- Same pattern a sibling Lakeraven project adopted for enrollment and
  eligibility lifecycles, so reviewers already know it.

### Negative

- Two audit mechanisms exist during migration (transitions +
  `ManagementApprovalEvent`/`Determination`); a crisp boundary must be kept.
- Status cache can drift if code bypasses the transition writer; mitigated
  by `rebuild_status!` tests and by keeping direct `update!(status:)` out of
  the codebase (a Rubocop cop is cheap).
- One more row per transition; negligible at Corvid's volumes.
- Requires `TenantContext.current_actor` to be set by hosts (as tenant
  already must be); missing actor on a transition raises.

### Alternatives considered

- **Full event sourcing (Rails Event Store).** Rejected: Corvid is a
  CRUD-shaped staff application with AASM guards already in Ruby;
  projections/upcasting overhead buys replay-to-rebuild, which no
  requirement asks for. Attribution, immutability, and audit are the
  requirements, and B delivers them.
- **PaperTrail/audited only.** Rejected: a version diff records that a
  column changed, not the domain event, guard, actor kind, or digest.
- **Status quo + more hook calls.** Rejected: the hook's shape is
  underspecified, its defaults fail silent, and it puts the audit record in
  the host, where a public-engine consumer cannot rely on it.
- **Event sourcing at the boundary only, Corvid unchanged.** Partially
  adopted: the external ledger is event-sourced; but "Corvid unchanged"
  leaves funder audits unmet, so Corvid gets B.

## References

- ADR 0002 §7 host hooks; ADR 0003 tokenization (metadata must be
  token-keyed); ADR 0005 adapter injection
- `app/models/corvid/management_approval_event.rb` (the pattern this
  generalizes); `lib/corvid/configuration.rb`;
  `app/services/corvid/program_template_service.rb#record_provenance`
- #261 cross-product event bus; #249 cross-product ADRs; #231 idempotency;
  #529 governed-AI contract
- `docs/workforce_domain_module.md` (the second domain that motivates this)
