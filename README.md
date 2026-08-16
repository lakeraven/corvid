# Corvid

Open-source Rails engine for the coordination, adjudication, and billing layer that sits **between an EHR and its payers** — the connective tissue for programs that manage and pay for care delivered *outside* the clinic.

Corvid runs service authorization and referral workflows, eligibility and payer-of-last-resort verification, budget obligations, and **Medicare-Like-Rates repricing** of purchased/referred-care claims. It's **EHR-agnostic** (any FHIR R4 server via pluggable adapters) and **chart-free** — it stores **no PHI at rest**; all clinical and identifying data lives in the host's vault, resolved through the adapter interface.

## Use cases

- **PRC/CHS** — IHS/tribal Purchased/Referred Care referral authorization **and Medicare-Like-Rates repricing** of outside claims
- **State Medicaid** — prior authorization and care coordination across many tribes/facilities
- **Cross-org coordination** — a de facto HIE control plane that lets programs share the right data without warehousing each other's records
- **City homelessness** — housing placement and service delivery
- **Foster care** — case management across counties and states

## Status

Pre-1.0. The engine is being extracted from a production Rails app and is not yet recommended for new production deployments. The API will change before 1.0.

## Installation

```ruby
# Gemfile
gem "corvid", git: "https://github.com/lakeraven/corvid"
```

Mount the engine in your routes:

```ruby
# config/routes.rb
mount Corvid::Engine => "/corvid"
```

Run migrations:

```bash
rails db:migrate
```

## Configuration

```ruby
# config/initializers/corvid.rb
Corvid.configure do |c|
  # EHR adapter (REQUIRED in production)
  c.adapter = Corvid::Adapters::FhirAdapter.new(
    base_url: ENV["FHIR_BASE_URL"]
  )

  # PHI sanitizer for log messages (REQUIRED in production — defaults to redact-all)
  c.phi_sanitizer = ->(msg) { PhiSanitizer.redact(msg) }

  # Provenance hooks (optional)
  c.on_provenance = ->(**attrs) { Provenance.create!(**attrs) }
  c.fetch_provenance = ->(**attrs) { Provenance.where(**attrs).to_a }
end
```

In each request (web or job), set the tenant context:

```ruby
class ApplicationController < ActionController::Base
  around_action :set_corvid_tenant

  private

  def set_corvid_tenant
    Corvid.with_tenant(current_account.identifier) { yield }
  end
end
```

**Background jobs MUST set tenant context explicitly.** Without it, queries against `Corvid::Case`, `Corvid::PrcReferral`, etc. will raise `Corvid::MissingTenantContextError`.

## Architecture

```
Host App (e.g. lakeraven-ehr, corvid-saas)
  ├── Corvid::Engine (this gem, public)
  │   ├── Models: Case, PrcReferral, Task, CareTeam, etc.
  │   ├── Services: AuthorizationWizard, CommitteeReviewSyncService, etc.
  │   └── Adapters::Base contract → MockAdapter / FhirAdapter
  └── corvid-adapters (private, optional)
      └── Corvid::Adapters::Clearinghouse, EHR, RPMS, etc.
```

### What the engine owns vs. what the host application owns

Corvid is deliberately split so the engine stays EHR-agnostic, reusable, and
publishable, while identity, authorization, UI, and deployment live in the host
(the private SaaS shell, e.g. `corvid-saas`, or `lakeraven-ehr`).

| This engine (public gem) | Host application (private shell) |
|---|---|
| Domain models + state machines (`PrcReferral` AASM, `EligibilityChecklist`, `Determination`, obligations, payments) | Identity: users, accounts, authentication, sessions |
| **Business invariants**: the approval gate, dual control (approver ≠ submitter), checklist completeness, eligibility rules, MLR/repricing, adjudication | **Authorization / roles**: *who* may submit, approve, etc. (e.g. Pundit policies over the host's roles) |
| EHR-agnostic **adapter contract** (`Corvid::Adapters::Base`) | The **concrete** adapter/EHR wiring, endpoints, and secrets |
| Opaque **identifiers** only — no `current_user`, no session, no UI | Maps the authenticated user/account → engine identifiers + tenant, and renders the UI |
| Tenant scoping as a **data boundary** (`tenant_identifier`) | Supplies the tenant **value**; controllers, views, routing, billing |
| PHI-minimized (tokens, not PHI text) | The PHI vault the adapter resolves against |

**Rule of thumb:** the engine enforces *what must always be true* (invariants on
identifiers); the host decides *who is allowed to act* and *how it looks*. For
example, the PRC management-approval gate enforces dual control **in the engine**,
but "only a PRC Director may approve" is **role-gated in the host** — the host
passes an already-authorized identifier into the engine.

## Adapters

| Adapter | Use case |
|---|---|
| `Corvid::Adapters::MockAdapter` | Dev/test only — **not a security boundary** |
| `Corvid::Adapters::FhirAdapter` | Generic FHIR R4 — works with any compliant server |
| Vendor adapters | Implement `Corvid::Adapters::Base` for proprietary EHRs (private repos) |

## Tenancy model

Corvid supports a two-level tenancy hierarchy:

- **Tenant** (required, hard isolation boundary) — typically maps to one EHR instance
- **Facility** (optional, soft classification) — typically maps to one EHR division

Examples (illustrative):

| Tenant | Facilities |
|---|---|
| A tribal health program | Main clinic, Behavioral Health, PCH |
| A multi-state nonprofit | State A, State B, State C |
| A state Medicaid program | Many tribes/clinics (each a facility) |

Cross-facility data sharing within a tenant is supported. Cross-tenant queries are not.

## PHI handling

Per [ADR 0003](docs/adr/0003-phi-tokenization.md), Corvid stores **no PHI at rest**. All identifying and clinical data is tokenized:

- Patient names, DOBs, MRNs → adapter-resolved (in-memory only)
- Notes, rationale, reasons → vault tokens (resolved on demand)
- Insurance policy numbers → vault tokens
- Workflow dates → stored (combination risk documented)

A Corvid Postgres dump viewed without vault access reveals no PHI — only opaque tokens, workflow state, counts, and timestamps.

The `phi_sanitizer` hook defaults to fail-safe redact-all. Forgetting to configure it will not increase PHI exposure in logs.

## CMS fee schedule data

Corvid ships with a derived snapshot of the Medicare Physician Fee Schedule (RVUs, GPCIs, conversion factors) so that `PrcOverpaymentAnalyzer` can compute professional-service Medicare-equivalent rates without reading raw CMS files at runtime.

**Default path — load the bundled snapshot:**

```bash
rails db:migrate
rake cms:snapshot:load
```

This populates `corvid_fee_schedule_entries` with all available years from the snapshot at `db/seeds/cms_fee_schedules.csv.gz`. Snapshot integrity is verified by SHA256 on load.

**Advanced — re-ingest from CMS source files:**

Only needed when CMS publishes a new year and you want to refresh the snapshot. Source files (PPRRVU\*.csv and GPCI\*.csv) live under `db/data/cms_fee_schedules/{year}/` and are not committed — they're large, re-fetchable, and accumulate. The canonical source zips are mirrored in the [`cms-fee-schedules-v1` GitHub Release](https://github.com/lakeraven/corvid/releases/tag/cms-fee-schedules-v1), or download fresh from [CMS PFS Relative Value Files](https://www.cms.gov/medicare/payment/fee-schedules/physician/pfs-relative-value-files).

```bash
rake cms:fetch[2026]            # download + extract one year
rake cms:fetch_all              # mirror everything (2007-2026)
rake cms:import[2026]           # re-ingest one year into the DB
rake cms:import_all             # re-ingest every year directory found
rake cms:snapshot:export        # regenerate db/seeds/cms_fee_schedules.csv.gz
```

```bash
rake cms:import[2026]          # one year
rake cms:import_all            # every year directory found on disk
rake cms:snapshot:export       # regenerate db/seeds/cms_fee_schedules.csv.gz
```

Each `cms:import` writes a `Corvid::CmsFeeScheduleRelease` record capturing the source file checksum and parser version, so the provenance of every imported year is auditable.

## Architectural decisions

| ADR | Topic |
|---|---|
| [0001](docs/adr/0001-id-vs-identifier-naming.md) | Reserve `id`/`*_id` for Rails keys; use `identifier`/`*_identifier` for external references |
| [0002](docs/adr/0002-architectural-foundations.md) | Tenancy, table prefixes, string enums, hooks, namespacing |
| [0003](docs/adr/0003-phi-tokenization.md) | PHI tokenization (Stripe-style for HIPAA) |

## Development

```bash
bundle install
cd test/dummy && bundle exec rails db:create db:migrate && cd ../..
bundle exec rake test
```

## License

MIT
