# ADR 0006: RPMS deployment topology — customer-side connector as north star

**Status:** Proposed
**Date:** 2026-07-10

## Context

Corvid's implicit deployment model today is **the SaaS host reaches inbound into the customer's RPMS**: one corvid process, one pinned adapter (`Corvid.adapter`), a network path arranged per customer (VPN / proxy / private CA). That works for a single tenant; it scales poorly to 5–50 tribal sites with heterogeneous firewall postures.

The decisive constraint is who controls the customer-side firewall. At federally supported sites, the perimeter is centrally group-policy-managed by the customer's supporting federal IT organization, and the authoritative security specification is held at the area level — not at the site. An inbound connection into the customer network is therefore not the customer's to grant: every onboarding becomes an O(n) negotiation with a third-party security authority, repeated per site, with per-site VPN and private-CA surface accumulating on the SaaS side.

Before we harden connection pooling, retry, or circuit-breaking (and before the AdapterRouter (#390), callback-to-job extraction (#391), and operational runbook (#392) can proceed), the production deployment shape must be decided. The rpms-rpc connection-pool design is also blocked on one specific answer from this ADR: the broker-session user-context model, which determines the pool key shape.

Three candidate modes:

- **Mode 1 — single-tenant direct.** One corvid host, one pinned adapter, direct connection to one RPMS. What exists today.
- **Mode 2 — multi-tenant direct.** Multi-tenant SaaS reaches inbound into each customer's RPMS via VPN / proxy / private CA, with per-tenant routing.
- **Mode 3 — customer-side connector.** A small vendor-provided binary runs inside the customer network, opens an *outbound* persistent connection to corvid SaaS, and proxies RPMS reads/writes locally. The customer firewall only needs outbound egress.

Decisions this ADR must settle (from #388):

1. Recommended topology and rationale.
2. Mode 3 transport (mTLS WebSocket vs queue), reconnect behavior, message envelope.
3. Where RPMS credentials live.
4. Adapter router shape.
5. Audit ownership: RPC-level trail vs workflow-level decisions.
6. RPMS broker session user-context — service account vs per-end-user DUZ (gates the rpms-rpc pool key).

Out of scope: implementation of any mode. This is a decision artifact; implementation follows in #390, #391, #392, and the connector's own design work.

## Decision

1. **Mode 3 (customer-side connector) is the north star. Mode 1 (single-tenant direct) remains supported for pilots and development. Mode 2 (multi-tenant inbound direct) is explicitly not built.**

   - *Mode 3 — adopt.* Outbound-only egress is the network shape federal IT organizations approve most readily; it removes the per-site inbound-firewall negotiation entirely. The connector proxies RPMS traffic locally, so RPMS credentials and RPC-level payloads never leave the customer network.
   - *Mode 1 — keep.* It is what exists today and is correct for single-tenant pilots and development. Its cost of retention is zero: it is the degenerate case of the adapter router (one tenant, one direct adapter).
   - *Mode 2 — do not build.* Every property that makes it attractive (no customer-side install) is outweighed by the firewall-authority reality above, by per-site VPN/private-CA operational surface, and by the fact that it puts RPMS credentials on the SaaS side. Pooling/retry hardening built for this shape would be sunk cost.

2. **Mode 3 transport: mTLS WebSocket, not a message queue.** The connector dials out to corvid SaaS over plain 443 egress and holds a persistent, mutually-authenticated WebSocket.

   - **Authentication:** per-tenant client certificate (mTLS) minted by corvid SaaS at connector enrollment.
   - **Envelope:** JSON `{id, tenant, facility, method, params, deadline, schema_version}`. `id` is the correlation identifier for request/response matching over the multiplexed socket; `deadline` lets the connector abandon work the caller has already timed out on; `schema_version` allows envelope evolution without a flag day.
   - **Liveness:** heartbeat frames both directions; missed heartbeats tear down the socket; the connector reconnects with exponential backoff and jitter.
   - Rationale over a queue: the RPC contract is bidirectional request/response with correlation and deadlines — a synchronous shape. A broker adds infrastructure to run, at-least-once delivery semantics the contract doesn't want, extra latency, and (for managed brokers) cloud-vendor coupling. See Alternatives.

3. **Credentials: RPMS broker credentials live only customer-side in Mode 3.** They sit in the connector's local configuration inside the customer network and never transit to or rest in corvid SaaS. In Mode 1 (and Mode 2, had it been built), credentials are secret-manager *references* resolved through the `SecretReader` abstraction that #390 defines — never literals in corvid tables. This is the strongest data-sovereignty property of Mode 3 and a primary driver of the decision.

4. **Adapter router shape: resolver/factory, not a static registry** (per #390). `AdapterRouter.resolve(tenant)` looks up a `TenantConnectionConfig`, resolves any secret references via `SecretReader`, and calls `AdapterFactory.build(config)`. Both `RpmsDirectAdapter` (Mode 1) and `RpmsConnectorAdapter` (Mode 3) satisfy `Corvid::Adapters::Base` (`lib/corvid/adapters/base.rb`), so the engine is topology-blind: services and models see the same adapter contract regardless of deployment mode. The `adapter_type` enum gets stable values: `rpms_direct | rpms_connector | fhir | mock`. This ADR asserts the interface invariant; the implementation stays in #390.

5. **Audit ownership is split by trust zone.**

   - **RPC-level audit trail** (every broker call, with payloads) is recorded **connector-side**, as a customer-owned log inside the customer network. This aligns with community-data-sovereignty expectations and keeps PHI-bearing RPC payload logs off SaaS infrastructure.
   - **Workflow-level decision audit** (what corvid decided and why) stays in corvid — `Determination` rows via the `Determinable` concern, as today.
   - In Mode 1, the RPC-level trail is recorded in the host process log with PHI sanitization applied (`Corvid.sanitize_phi`, see `app/models/corvid/prc_referral.rb`).

6. **Broker session user-context: service account per (tenant, facility). The rpms-rpc pool key is `(tenant, facility)`.** Each tenant/facility pair authenticates to the RPMS broker as a dedicated service account; the acting end-user's identity is carried in the message envelope and recorded in corvid's workflow-level audit (per decision 5), so human attribution is never lost — it is just not expressed as a broker session.

   Per-end-user DUZ sessions are **deferred**, with an explicit revisit trigger: *if write-back attribution inside RPMS itself becomes a compliance requirement, the pool key becomes `(tenant, facility, user)` and rpms-rpc must support session multiplexing.* Until that trigger fires, rpms-rpc should design its connection pool keyed on `(tenant, facility)` — this is the answer its pool design is waiting on.

7. **Connector binary placement: outside public corvid.** The connector's design doc and binary live in the private integrations repo, consistent with the standing rule that vendor adapters and deployment-specific components live in private repos (`lib/corvid/adapters/base.rb`). Public corvid contains only the connector-shaped adapter (`RpmsConnectorAdapter`) speaking the envelope protocol.

## Consequences

### Positive

- Customer onboarding needs only an outbound-egress allowance — the network ask federal IT organizations grant most readily; no per-site inbound firewall negotiation.
- RPMS credentials never leave the customer network in the target topology; corvid SaaS holds no broker secrets for Mode 3 tenants.
- PHI-bearing RPC payload logs stay customer-side, strengthening corvid's no-PHI-at-rest posture (complementing ADR 0003's tokenization) and matching community-data-sovereignty expectations.
- Per-tenant isolation by construction: one connector, one client cert, one service account per tenant/facility.
- #390 gets stable `adapter_type` enum values, and the engine stays topology-blind behind `Corvid::Adapters::Base`.
- rpms-rpc's pool design is unblocked with an unambiguous key shape and a named revisit trigger.

### Negative

- A shippable, updatable customer-side binary is a new product surface: packaging, code signing, auto-update, version skew between connector and SaaS (mitigated by `schema_version` in the envelope), and fleet monitoring.
- The connector adds one hop of latency to every RPMS call relative to a direct connection.
- An offline connector means that tenant is hard-down for RPMS operations; SaaS-side health surfacing for connector liveness becomes mandatory (cf. #85).
- Mode 1 pilots keep credentials SaaS-adjacent (secret-manager references) until they migrate to Mode 3.
- Two supported topologies (Modes 1 and 3) mean the runbook (#392) and the adapter factory each carry two branches, though Mode 2's absence keeps that surface small.

### Alternatives considered

- **Mode 2 — multi-tenant inbound direct.** Rejected. The customer-side firewall at federally supported sites is centrally group-policy-managed with the security spec held at the area level, so every site is an inbound negotiation with a third party; per-site VPN/private-CA multiplies ops surface; RPMS credentials would rest on the SaaS side. Hardening work for this shape would be sunk cost.
- **Queue transport for the connector (instead of mTLS WebSocket).** Rejected. Adds broker infrastructure and at-least-once delivery semantics that a synchronous RPC contract doesn't want, plus extra latency and potential cloud-vendor coupling. The WebSocket gives bidirectional request/response with correlation IDs over plain 443.
- **Site-to-site VPN as a managed service.** Rejected. Still inbound-shaped — and the firewall is not the customer's to open, so managing the VPN doesn't remove the third-party negotiation.
- **Per-end-user DUZ broker sessions now.** Deferred, not adopted. It forces session multiplexing into rpms-rpc's pool and per-user credential lifecycle into every deployment before any compliance requirement demands it. The envelope + workflow-audit path preserves attribution; the revisit trigger is named in Decision 6.

## References

- #388 ADR 0006: RPMS deployment topology — direct adapter vs customer-side connector
- #390 AdapterRouter should resolve via factory + config + secret manager (gated on this ADR)
- #391 Move remote side effects out of model callbacks (sync job routes through the router)
- #392 On-premises / connector runbook + reachability binary (structure branches on this ADR)
- ADR 0002 Architectural foundations
- ADR 0003 PHI tokenization (the no-PHI-at-rest posture this ADR strengthens)
- ADR 0005 Adapter dependency injection in services (the DI seam the router plugs into)
- `lib/corvid/adapters/base.rb` — adapter contract both topologies implement
- rpms-rpc connection-pool design — consumes Decision 6's pool key
