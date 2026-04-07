# Corvid

Open-source case management Rails engine for healthcare, social services, and benefit programs.

Corvid manages service authorization workflows, referral tracking, eligibility verification, and budget obligations. It works with any FHIR R4 server via pluggable adapters and stores **no PHI at rest** — all clinical and identifying data lives in the host's vault, accessed through the adapter interface.

## Use cases

- **PRC/CHS** — IHS Contract Health Services referral authorization
- **State Medicaid** — prior authorization and care coordination (e.g. Washington State with 200+ tribes)
- **City homelessness** — housing placement and service delivery
- **Foster care** — case management across counties (e.g. iFoster: California, Nevada, Kentucky)

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
      └── Corvid::Adapters::Stedi, IRIS, RPMS, etc.
```

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

Examples:

| Tenant | Facilities |
|---|---|
| Yakama Nation | White Swan Clinic, Behavioral Health, PCH |
| iFoster | California, Nevada, Kentucky |
| State of Washington | 200+ tribes (each a facility) |

Cross-facility data sharing within a tenant is supported. Cross-tenant queries are not.

## PHI handling

Per [ADR 0003](docs/adr/0003-phi-tokenization.md), Corvid stores **no PHI at rest**. All identifying and clinical data is tokenized:

- Patient names, DOBs, MRNs → adapter-resolved (in-memory only)
- Notes, rationale, reasons → vault tokens (resolved on demand)
- Insurance policy numbers → vault tokens
- Workflow dates → stored (combination risk documented)

A Corvid Postgres dump viewed without vault access reveals no PHI — only opaque tokens, workflow state, counts, and timestamps.

The `phi_sanitizer` hook defaults to fail-safe redact-all. Forgetting to configure it will not increase PHI exposure in logs.

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
