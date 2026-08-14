# AdapterRouter credential-rotation flow

`Corvid::AdapterRouter` (issue #390, ADR 0006 Decision 4) caches built
adapter instances per `(tenant_identifier, facility_identifier)` for
`Corvid.configuration.adapter_router_cache_ttl` seconds (default 60). A
rotated credential does not take effect on its own until that cache entry
expires or is explicitly busted. This document is the rotation runbook the
#390 acceptance criteria asks for.

## Rotating a credential

1. **Update the secret at its source of truth**, not in corvid. `secret_ref`
   on `Corvid::TenantConnectionConfig` is a *reference* (an ENV var name, a
   Vault path, an SSM parameter name) — never a literal credential (ADR
   0006 Decision 3). Rotate the value at that source: write the new secret
   to Vault/SSM/ENV under the same `secret_ref`, or write it under a new
   `secret_ref` and update the `TenantConnectionConfig` row's `secret_ref`
   column to point at it.
2. **Bust the cache for that tenant** so the next call rebuilds the adapter
   against the new credential instead of serving the stale cached instance:

   ```ruby
   Corvid::AdapterRouter.invalidate(tenant_identifier, facility_identifier: facility_identifier)
   ```

   Call this from whatever triggers the rotation — an admin action, a
   webhook from the secret manager, a scheduled rotation job. There is no
   automatic invalidation-on-write today: updating a `TenantConnectionConfig`
   row does not itself bust the cache (see "Known limitation" below).
3. **Confirm** by resolving again and checking the adapter behaves as
   expected (e.g. a test call against the new credential), or rely on the
   next natural request to surface an auth failure if step 1 or 2 was
   missed — a wrong credential fails loudly (`SecretReader::Env#fetch`
   raises `KeyError` on a missing ENV var; a real secret-manager
   implementation should raise similarly rather than return nil).

## Fallback/degraded rotation

If you don't know the exact tenant/facility affected, or want to force a
full re-resolution after a broad rotation event:

```ruby
Corvid::AdapterRouter.invalidate_all!
```

This clears every cached adapter; the next `resolve` per tenant rebuilds
from the current `TenantConnectionConfig` + `SecretReader` state. Safe to
call at any time — it only drops cached instances, not data.

## Known limitation

`AdapterRouter` does not currently watch `TenantConnectionConfig` for
writes (no `after_update` hook calling `invalidate`). Any code path that
updates a `TenantConnectionConfig` row (endpoint change, secret_ref
change, adapter_type change, deactivation) **must** call
`AdapterRouter.invalidate` itself, or the change won't be visible until
the TTL naturally expires. Wiring that hook automatically is a reasonable
follow-up once there's a real admin surface for editing
`TenantConnectionConfig` rows; today rows are created/edited directly
(console, seed data, a future admin UI), so this is a manual step until
that surface exists.

## Reducing exposure window

Lower `Corvid.configuration.adapter_router_cache_ttl` to shrink the
maximum staleness window if a fleet-wide rotation cadence needs it; this
trades off more frequent `TenantConnectionConfig` lookups (and, for
adapter types with expensive construction, more frequent rebuilds) against
faster credential propagation.
