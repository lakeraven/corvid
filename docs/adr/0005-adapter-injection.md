# ADR 0005: Adapter dependency injection in services

**Status:** Proposed
**Date:** 2026-05-09

## Context

Today every service in corvid reaches for `Corvid.adapter` directly — a global accessor backed by `Corvid.configuration.adapter`. That global made sense when the engine was single-tenant and single-backend, but it has accumulated three concrete costs:

1. **Per-tenant adapter routing is impossible.** A US tribal tenant on RPMS-via-rpc and a Swedish Inera tenant on a FHIR adapter cannot coexist in one process — there is one global adapter, and rebinding it during request handling is racy.
2. **Tests mutate global state.** Every test that needs a different adapter calls `Corvid.configure { |c| c.adapter = ... }`, which mutates the singleton for the duration of the test. Parallelizing the suite, or running adapter-contract tests against multiple backends, requires per-test isolation that the global precludes.
3. **Adapter contract testing (#233) is awkward.** Asserting parity across mock / RPC / FHIR adapters wants instance-based DI: instantiate the service with each adapter in turn and run the same scenarios.

Twenty source files touch `Corvid.adapter` directly today — eight services and twelve models. This ADR scopes the services half (#222); the model half is tracked separately under #264.

## Decision

1. **Services accept `adapter:` via the constructor.** The pattern is:

   ```ruby
   class FooService
     def initialize(adapter: Corvid.adapter)
       @adapter = adapter
     end

     def do_something(arg)
       @adapter.some_call(arg)
     end
   end
   ```

   Default to `Corvid.adapter` so existing call sites and one-off scripts that don't care about DI keep working. Tests and per-tenant code paths inject explicitly.

2. **Class-method form preserves backward compatibility.** Services that today expose static methods (`Corvid::FooService.do_something(arg)`) gain class-method shims that take `adapter:` and delegate to `new(adapter: adapter).do_something(arg)`:

   ```ruby
   class << self
     def do_something(arg, adapter: Corvid.adapter)
       new(adapter: adapter).do_something(arg)
     end
   end
   ```

   This keeps every existing caller in the engine, host apps, and step definitions working without touching them. A future PR can deprecate the class-method shims if no internal callers remain.

3. **Models stay on the global for now.** Per #264, models also reach for `Corvid.adapter` (via concerns like `Determinable`, and directly in `PrcReferral#service_request`, `CommitteeReview#reviewer`, etc.). Refactoring models is meaningfully harder — they're often constructed implicitly by ActiveRecord and don't have a constructor we control. That's a separate ADR / issue.

4. **Module-style services convert to class-style.** Some existing services are pure modules with `class << self` (e.g., `PrcImporter`, `OverpaymentRecovery::*`). When they need adapter injection, they become classes following the pattern above. Pure-function services that don't touch the adapter (e.g., `Timeline`, `PayoutCalculator`) stay as modules.

5. **Rollout is staged across PRs.** This ADR ships with one exemplar (`CommitteeReviewSyncService`). Subsequent PRs convert the remaining seven adapter-touching services in `app/services/corvid/`, one cluster per PR, with the same pattern. Each PR adds an `_injection_test.rb` asserting the service routes through the injected adapter rather than the global.

## Consequences

### Positive

- Per-tenant adapter routing becomes possible — a service instance carries its own adapter, so a job processing a Swedish tenant's records can use a SEK-aware adapter while a job processing a Yakama tenant's records uses RPMS.
- Tests inject adapters per-instance; no more `Corvid.configure { |c| c.adapter = ... }` mutation pattern.
- Adapter contract tests (#233) become straightforward: instantiate the service with each adapter implementation, run the same scenario, assert parity.
- Migration to per-instance state is forward-compatible with the cross-product event bus (#261) and the future model decoupling (#264).

### Negative

- Eight services to refactor; each PR is mechanical but touches multiple methods.
- The class-method shim layer is technical debt — it exists to keep callers working during the rollout. We'll need to revisit whether to keep it long-term once internal callers all use instances.
- New `_injection_test.rb` files add test surface; parity checks are valuable but slow CI down a bit.

### Alternatives considered

- **Thread-local adapter override.** `Corvid.with_adapter(x) { ... }` Thread.current-based swap. Less invasive than DI, but: thread-local state is fragile under concurrent jobs/Sidekiq, doesn't help with parallel test runs, and doesn't compose with multi-tenant routing (one thread might handle requests for two tenants).
- **Dependency container.** A container that resolves adapters by tenant key. Heavier than DI for the marginal benefit; can be layered on top of DI later if we ever need it.
- **Leave the global; add documentation.** Cheap today, but every blocking-labeled architecture issue (#264, #233, #261) gets harder. Punting forward compounds the cost.
- **Partial migration: only the services that need per-tenant routing.** Two-class system invites confusion. Better to migrate all services to one pattern even if not all of them have a near-term per-tenant story.

## References

- #222 Services should use instance-based injection instead of Corvid.adapter global
- #264 Decouple models from Corvid.adapter global (deeper than #222)
- #233 Add shared adapter contract tests for adapter parity
- #261 Cross-product event bus abstraction
- ADR 0002 Architectural foundations
- ADR 0004 Monetary values (the trust-boundary pattern this ADR extends to adapter calls)
